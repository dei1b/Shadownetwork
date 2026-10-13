import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/models/secure_sos_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/models/sos_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/services/mock_scf_transport.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/scf_envelope.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/relay_runtime_provider.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/message_encryption_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final scenario in [
    (encrypted: false, localOrigin: false),
    (encrypted: true, localOrigin: false),
    (encrypted: false, localOrigin: true),
  ]) {
    final encrypted = scenario.encrypted;
    final localOrigin = scenario.localOrigin;
    test(
      'runtime receipt for ${localOrigin
          ? "returned local"
          : encrypted
          ? "encrypted"
          : "plain"} SOS',
      () async {
        final database = await LocalMessagingDatabase.open(
          databasePath: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        addTearDown(database.close);
        const victim = Peer(
          id: 'victim',
          name: 'Resident',
          type: PeerType.civilian,
          isConnected: false,
        );
        const relay = Peer(
          id: 'relay',
          name: 'Relay',
          type: PeerType.relay,
          isConnected: true,
        );
        const rescuer = Peer(
          id: 'rescuer',
          name: 'Rescuer',
          type: PeerType.responder,
          isConnected: true,
        );
        final identityStore = DeviceIdentityStore(
          secretStore: InMemorySecretValueStore(),
        );
        final identity = await identityStore.loadOrCreate();
        final network = MockScfTransportNetwork();
        final transport = network.registerPeer(rescuer);
        final container = ProviderContainer(
          overrides: [
            localMessagingDatabaseProvider.overrideWith(
              (ref) async => database,
            ),
            scfTransportProvider.overrideWithValue(transport),
            deviceIdentityStoreProvider.overrideWithValue(identityStore),
          ],
        );
        addTearDown(container.dispose);
        final createdAt = DateTime.now().toUtc().subtract(
          const Duration(minutes: 5),
        );
        final message = SosMessage(
          id: 'sos-runtime',
          sender: localOrigin ? rescuer : victim,
          recipient: encrypted ? rescuer : null,
          body: 'Need medical assistance',
          category: Category.medical,
          status: MessageStatus.queued,
          createdAt: createdAt,
          hopCount: 2,
        );
        final prepared = encrypted
            ? await SecureSosMessagePayload.prepare(
                message,
                encryptionService: MessageEncryptionService(),
                recipientPublicKey: identity.encodedPublicKey,
              )
            : null;
        final hash = prepared?.hash ?? SosMessagePayload.messageHash(message);
        network.send(
          fromPeerId: relay.id,
          toPeerId: rescuer.id,
          envelope: ScfEnvelope(
            messageHash: hash,
            payloadJson:
                prepared?.payloadJson ??
                SosMessagePayload.canonicalJson(message),
            hopCount: 2,
            // This timestamp is from an earlier relay, not rescuer receipt.
            receivedAt: createdAt.add(const Duration(seconds: 10)),
            expiresAt: createdAt.add(const Duration(hours: 24)),
            transferId: 'incoming-attempt',
          ),
        );

        final before = DateTime.now().toUtc();
        await container.read(relayRuntimeProvider.notifier).syncNow();
        final after = DateTime.now().toUtc();
        expect(container.read(relayRuntimeProvider).lastError, isNull);
        final repository = await container.read(
          sosMessageRepositoryProvider.future,
        );
        final stored = (await repository.getMessages()).single;
        expect(stored.body, message.body);
        expect(stored.createdAt, createdAt);
        if (localOrigin) {
          expect(stored.receivedAt, isNull);
          expect(stored.receivedFromPeerId, isNull);
          expect(stored.receivedTransport, isNull);
          expect(stored.transferId, isNull);
          expect(stored.propagationDuration, isNull);
        } else {
          expect(stored.receivedAt!.isUtc, isTrue);
          expect(stored.receivedAt!.isBefore(before), isFalse);
          expect(stored.receivedAt!.isAfter(after), isFalse);
          expect(stored.receivedFromPeerId, relay.id);
          expect(stored.receivedFromPeerId, isNot(victim.id));
          expect(stored.receivedTransport, 'mock');
          expect(stored.transferId, 'incoming-attempt');
          expect(stored.propagationDuration!.inMinutes, 5);
        }
        expect(stored.hopCount, 2);

        // Repeat the delivery; even a consumed targeted SCF envelope must retain
        // the SOS's first receipt in the persistent message repository.
        network.send(
          fromPeerId: relay.id,
          toPeerId: rescuer.id,
          envelope: ScfEnvelope(
            messageHash: hash,
            payloadJson:
                prepared?.payloadJson ??
                SosMessagePayload.canonicalJson(message),
            hopCount: 2,
            receivedAt: after,
            expiresAt: createdAt.add(const Duration(hours: 24)),
            transferId: 'duplicate-attempt',
          ),
        );
        await container.read(relayRuntimeProvider.notifier).syncNow();
        expect(container.read(relayRuntimeProvider).lastError, isNull);
        final repeated = (await repository.getMessages()).single;
        expect(repeated.receivedAt, stored.receivedAt);
        expect(repeated.transferId, stored.transferId);
      },
    );
  }
}
