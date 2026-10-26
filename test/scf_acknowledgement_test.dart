import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/services/mock_scf_transport.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_relay_service.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_service.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/envelope_transfer_result.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/scf_envelope.dart';
import 'package:shadownetwork/features/messaging/domain/entities/scf_peer_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/transport_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/domain/services/scf_transport.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/relay_runtime_provider.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_trust_status.dart';
import 'package:shadownetwork/features/validation/data/repositories/sqlite_validation_metrics_repository.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_event.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_metrics_calculator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/database_migration_test_harness.dart';

const sender = Peer(
  id: 'sender',
  name: 'Sender',
  type: PeerType.civilian,
  isConnected: true,
  transport: 'mock',
);
const receiver = Peer(
  id: 'receiver',
  name: 'Receiver',
  type: PeerType.responder,
  isConnected: true,
  transport: 'mock',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'both runtimes receive and ACK while outbound sends are waiting',
    () async {
      final f = await _fixture();
      await f.scfB.storeMessage(
        SosMessage(
          id: 'reverse-sos',
          sender: receiver,
          body: 'Rescuer update',
          category: Category.rescue,
          status: MessageStatus.queued,
          createdAt: DateTime.now().toUtc(),
        ),
      );
      ProviderContainer container(Database db, ScfTransport transport) {
        final result = ProviderContainer(
          overrides: [
            localMessagingDatabaseProvider.overrideWith((ref) async => db),
            scfTransportProvider.overrideWithValue(transport),
            deviceIdentityStoreProvider.overrideWithValue(
              DeviceIdentityStore(secretStore: InMemorySecretValueStore()),
            ),
          ],
        );
        addTearDown(result.dispose);
        return result;
      }

      final a = container(f.dbA, f.a);
      final b = container(f.dbB, f.b);
      final runtimeA = a.read(relayRuntimeProvider.notifier);
      final runtimeB = b.read(relayRuntimeProvider.notifier);
      await Future.wait([runtimeA.start(), runtimeB.start()]);
      runtimeA.stop();
      runtimeB.stop();
      expect(a.read(relayRuntimeProvider).lastError, isNull);
      expect(b.read(relayRuntimeProvider).lastError, isNull);
      expect(a.read(relayRuntimeProvider).lastRelayedCount, greaterThan(0));
      expect(b.read(relayRuntimeProvider).lastRelayedCount, greaterThan(0));
      final repoA = await a.read(sosMessageRepositoryProvider.future);
      final repoB = await b.read(sosMessageRepositoryProvider.future);
      expect((await repoA.getMessages()).single.id, 'reverse-sos');
      final receipt = (await repoB.getMessages()).single;
      expect(receipt.id, 'sos');
      expect(receipt.receivedAt, isNotNull);
      expect(receipt.transferId, isNotNull);
      expect(f.network.pendingTransferCount, 0);
    },
  );

  test(
    'write alone and wrong ACK do not complete; valid ACK completes once',
    () async {
      final f = await _fixture();
      final outbound = (await f.scfA.prepareOutboundForPeer(
        receiver.id,
      )).single.copyWith(transferId: 'attempt');
      var completed = false;
      final sending = f.a.sendEnvelope(peer: receiver, envelope: outbound).then(
        (result) {
          completed = true;
          return result;
        },
      );
      final incoming = (await f.b.receiveEnvelopes()).single;
      expect(f.network.pendingTransferCount, 1);
      expect(completed, isFalse);
      f.network.acknowledge('wrong-peer', incoming, true);
      f.network.acknowledge(
        receiver.id,
        incoming.copyWith(messageHash: 'wrong-hash'),
        true,
      );
      expect(completed, isFalse);
      expect(f.network.pendingTransferCount, 1);
      expect(await f.scfB.storeEnvelope(incoming), isTrue);
      await f.b.acknowledgeEnvelope(envelope: incoming);
      final result = await sending;
      await f.b.acknowledgeEnvelope(envelope: incoming);
      expect(result.acknowledged, isTrue);
      expect(result.transferId, 'attempt');
      expect(result.latencyMs, greaterThanOrEqualTo(0));
      expect(result.sentAt!.isUtc, isTrue);
      expect(result.acknowledgedAt!.isUtc, isTrue);
      expect(f.network.pendingTransferCount, 0);
    },
  );

  test(
    'timeout logs failure; retry gets new ID and active duplicate ACK',
    () async {
      final f = await _fixture(timeout: const Duration(milliseconds: 100));
      final relayA = ScfRelayService(
        scfService: f.scfA,
        transport: f.a,
        metricsRecorder: f.metrics,
      );
      final relayB = ScfRelayService(scfService: f.scfB, transport: f.b);
      final first = await relayA.relayToPeer(receiver);
      expect(first.failedCount, 1);
      expect(first.sentCount, 0);
      expect(f.network.pendingTransferCount, 0);
      final data = await f.metrics.getSessionData(f.sessionId);
      expect(data.events.map((e) => e.type), [
        ValidationEventType.envelopeOffered,
        ValidationEventType.envelopeSent,
        ValidationEventType.envelopeRejected,
      ]);
      expect(data.events.last.metadata?['failure_code'], 'ack_timeout');
      final firstId = data.events.first.transferId;
      // The first write did arrive. Storage after sender timeout cannot turn that
      // timed-out attempt into success, but the next attempt can ACK a duplicate.
      expect(await relayB.ingestIncoming(), 1);
      expect(
        (await f.scfA.getPeerStatus(
          messageHash: data.events.first.messageHash!,
          peerId: receiver.id,
        ))!.status,
        ScfPeerStatus.failed,
      );
      final ready = f.b.relayEvents.first;
      final sending = relayA.relayToPeer(receiver);
      await ready;
      expect(await relayB.ingestIncoming(), 0);
      expect((await sending).sentCount, 1);
      final retried = await f.metrics.getSessionData(f.sessionId);
      final offered = retried.events
          .where((e) => e.type == ValidationEventType.envelopeOffered)
          .toList();
      expect(offered, hasLength(2));
      expect(offered.last.transferId, isNot(firstId));
      expect(offered.first.messageHash, offered.last.messageHash);
      expect(offered.map((e) => e.hopCount), [1, 1]);
      expect((await f.scfB.getStoredEnvelopes()).single.hopCount, 1);
      final summary = const ValidationMetricsCalculator().calculate(retried);
      expect(summary.deliverySuccessRate, 0.5);
      expect(summary.failedTransferCount, 1);
      expect(f.network.pendingTransferCount, 0);
    },
  );

  for (final reason in [
    'expired',
    'invalid hash',
    'revoked',
    'storage failure',
  ]) {
    test('$reason returns a rejection, never a stored ACK', () async {
      final f = await _fixture();
      var outbound = (await f.scfA.prepareOutboundForPeer(
        receiver.id,
      )).single.copyWith(transferId: 'rejected-attempt');
      if (reason == 'expired') {
        // Even a valid active local copy must not ACK an expired incoming frame.
        await f.scfB.storeEnvelope(outbound);
        outbound = outbound.copyWith(
          expiresAt: DateTime.now().toUtc().subtract(
            const Duration(seconds: 1),
          ),
        );
      }
      if (reason == 'invalid hash') {
        outbound = outbound.copyWith(messageHash: 'invalid');
      }
      final sending = f.a.sendEnvelope(peer: receiver, envelope: outbound);
      final failure = expectLater(
        sending,
        throwsA(
          isA<EnvelopeTransferException>().having(
            (e) => e.code,
            'code',
            'receiver_rejected',
          ),
        ),
      );
      if (reason == 'storage failure') await f.dbB.close();
      final relay = ScfRelayService(
        scfService: f.scfB,
        transport: f.b,
        originTrustResolver: reason == 'revoked'
            ? (_) async => DeviceTrustStatus.revoked
            : null,
      );
      final received = await relay.ingestIncomingEnvelopes();
      await failure;
      expect(f.network.pendingTransferCount, 0);
      if (reason == 'revoked') {
        expect(received, hasLength(1));
        expect(
          (await f.dbB.query(
            LocalMessagingDatabase.scfMessagesTable,
          )).single['origin_trust_status'],
          'revoked',
        );
        expect(await f.scfB.prepareOutboundForPeer(sender.id), isEmpty);
      } else {
        expect(received, isEmpty);
      }
    });
  }

  test(
    'lost ACK does not discard the stored envelope from runtime input',
    () async {
      final f = await _fixture(timeout: const Duration(milliseconds: 100));
      final outbound = (await f.scfA.prepareOutboundForPeer(
        receiver.id,
      )).single.copyWith(transferId: 'lost-ack');
      final sending = f.a.sendEnvelope(peer: receiver, envelope: outbound);
      final failure = expectLater(
        sending,
        throwsA(isA<EnvelopeAcknowledgementTimeout>()),
      );
      final relay = ScfRelayService(
        scfService: f.scfB,
        transport: _BrokenAckTransport(f.b),
      );
      expect(await relay.ingestIncoming(), 1);
      expect(await f.scfB.getStoredEnvelopes(), hasLength(1));
      await failure;
      expect(f.network.pendingTransferCount, 0);
    },
  );
}

Future<_Fixture> _fixture({
  Duration timeout = const Duration(seconds: 2),
}) async {
  final harnessA = await DatabaseMigrationTestHarness.create();
  final harnessB = await DatabaseMigrationTestHarness.create();
  addTearDown(harnessA.dispose);
  addTearDown(harnessB.dispose);
  final dbA = await harnessA.openCurrentDatabase();
  final dbB = await harnessB.openCurrentDatabase();
  addTearDown(dbA.close);
  addTearDown(dbB.close);
  final metrics = SqliteValidationMetricsRepository(database: dbA);
  final session = await metrics.startSession(
    testRunId: 'FIXTURE-RUN',
    name: 'ACK test',
    environment: 'Mock',
    deviceId: sender.id,
    deviceRole: 'civilian',
  );
  final network = MockScfTransportNetwork(acknowledgementTimeout: timeout);
  final scfA = ScfService(database: dbA);
  await scfA.storeMessage(
    SosMessage(
      id: 'sos',
      sender: sender,
      body: 'Need help',
      category: Category.medical,
      status: MessageStatus.queued,
      createdAt: DateTime.now().toUtc(),
    ),
  );
  return _Fixture(
    dbA,
    dbB,
    scfA,
    ScfService(database: dbB),
    network,
    network.registerPeer(sender),
    network.registerPeer(receiver),
    metrics,
    session.id,
  );
}

class _Fixture {
  const _Fixture(
    this.dbA,
    this.dbB,
    this.scfA,
    this.scfB,
    this.network,
    this.a,
    this.b,
    this.metrics,
    this.sessionId,
  );
  final Database dbA;
  final Database dbB;
  final ScfService scfA;
  final ScfService scfB;
  final MockScfTransportNetwork network;
  final MockScfTransportEndpoint a;
  final MockScfTransportEndpoint b;
  final SqliteValidationMetricsRepository metrics;
  final String sessionId;
}

class _BrokenAckTransport implements ScfTransport {
  _BrokenAckTransport(this.delegate);
  final ScfTransport delegate;
  @override
  String get localPeerId => delegate.localPeerId;
  @override
  Stream<void> get relayEvents => delegate.relayEvents;
  @override
  Future<Peer> getLocalPeer() => delegate.getLocalPeer();
  @override
  Future<TransportStatus> getStatus() => delegate.getStatus();
  @override
  Future<List<Peer>> discoverPeers() => delegate.discoverPeers();
  @override
  Future<Peer> connectPeer(Peer peer) => delegate.connectPeer(peer);
  @override
  Future<List<ScfEnvelope>> receiveEnvelopes() => delegate.receiveEnvelopes();
  @override
  Future<EnvelopeTransferResult> sendEnvelope({
    required Peer peer,
    required ScfEnvelope envelope,
  }) => delegate.sendEnvelope(peer: peer, envelope: envelope);
  @override
  Future<void> acknowledgeEnvelope({
    required ScfEnvelope envelope,
    bool accepted = true,
  }) async {
    throw StateError('ACK connection closed');
  }
}
