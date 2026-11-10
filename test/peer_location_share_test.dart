import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/models/secure_chat_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/services/mock_scf_transport.dart';
import 'package:shadownetwork/features/messaging/domain/entities/chat_message.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_location_share.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/scf_envelope.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/peer_location_providers.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/relay_runtime_provider.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/message_encryption_service.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'queues an encrypted pin only for recently seen approved phones',
    () async {
      final now = DateTime.now().toUtc();
      final network = MockScfTransportNetwork();
      final local = await _Node.create('resident', now);
      final approved = await _Node.create('approved', now);
      final stale = await _Node.create(
        'stale',
        now.subtract(const Duration(minutes: 4)),
      );
      final unknown = await _Node.create('unknown', now);
      for (final node in [approved, stale, unknown]) {
        network.registerPeer(node.peer);
      }
      final sender = await _container(network, local, [local, approved, stale]);
      final count = await sender.read(queuePeerLocationProvider)(
        latitude: 7.31123,
        longitude: 125.69234,
        capturedAt: now,
      );
      expect(count, 1);
      final scf = await sender.read(scfServiceProvider.future);
      final envelope = (await scf.prepareOutboundForPeer(
        approved.peer.id,
      )).single;
      expect((jsonDecode(envelope.payloadJson) as Map)['schema_version'], 4);
      expect(envelope.payloadJson, isNot(contains('7.31123')));
      expect(envelope.payloadJson, isNot(contains('125.69234')));
      expect(envelope.expiresAt, now.add(const Duration(minutes: 15)));

      final recipient = await _container(network, approved, [local, approved]);
      final receiveQueue = await recipient.read(scfServiceProvider.future);
      expect(
        await receiveQueue.containsActiveEnvelope(envelope.messageHash),
        isFalse,
      );
      network.send(
        fromPeerId: local.peer.id,
        toPeerId: approved.peer.id,
        envelope: envelope,
      );
      expect(
        await recipient.read(relayRuntimeProvider.notifier).receiveIncoming(),
        1,
      );
      final pin = recipient.read(sharedPeerLocationsProvider).values.single;
      expect(pin.peerId, 'resident');
      expect(pin.ownerName, 'Registered resident');
      expect(pin.latitude, 7.31123);
      expect(pin.longitude, 125.69234);
      expect(pin.sharedAt, now);
      final chats = await recipient.read(chatRepositoryProvider.future);
      expect(await chats.getConversations(approved.peer.id), isEmpty);
    },
  );

  test('unapproved or invalid shares do not create pins or chats', () async {
    final now = DateTime.now().toUtc();
    final network = MockScfTransportNetwork();
    final local = await _Node.create('receiver', now);
    final sender = await _Node.create('sender', now);
    final unknown = await _Node.create('unknown', now);
    final receiver = await _container(network, local, [local, sender]);
    for (final (origin, body) in [
      (unknown, '{"latitude":7.31,"longitude":125.69}'),
      (sender, '{"latitude":91,"longitude":125.69}'),
    ]) {
      final prepared = await SecureChatMessagePayload.prepare(
        ChatMessage(
          id: 'location-test-${origin.peer.id}',
          conversationId: 'shadow-network-location-v1',
          sender: origin.peer,
          recipient: local.peer,
          body: body,
          status: MessageStatus.queued,
          createdAt: now,
          ttl: const Duration(minutes: 15),
        ),
        encryptionService: MessageEncryptionService(),
        recipientPublicKey:
            (await local.encryption.loadOrCreate()).encodedPublicKey,
        signingIdentity: await origin.signing.loadOrCreate(),
      );
      network.send(
        fromPeerId: origin.peer.id,
        toPeerId: local.peer.id,
        envelope: ScfEnvelope(
          messageHash: prepared.hash,
          payloadJson: prepared.payloadJson,
          hopCount: 0,
          receivedAt: now,
          expiresAt: now.add(const Duration(minutes: 15)),
        ),
      );
    }
    await receiver.read(relayRuntimeProvider.notifier).receiveIncoming();
    expect(receiver.read(sharedPeerLocationsProvider), isEmpty);
    final chats = await receiver.read(chatRepositoryProvider.future);
    expect(await chats.getConversations(local.peer.id), isEmpty);
  });

  test(
    'an older share cannot replace a newer pin and the pin expires',
    () async {
      final now = DateTime.now().toUtc();
      final source = await _Node.create('source', now);
      final target = await _Node.create('target', now);
      final message = ChatMessage(
        id: 'temporary-location',
        conversationId: PeerLocationShare.conversationId,
        sender: source.peer,
        recipient: target.peer,
        body: '{"latitude":7.31,"longitude":125.69}',
        status: MessageStatus.received,
        createdAt: now,
        ttl: const Duration(minutes: 15),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final store = container.read(sharedPeerLocationsProvider.notifier);
      final removed = Completer<void>();
      container.listen(sharedPeerLocationsProvider, (previous, next) {
        if (previous?.isNotEmpty == true && next.isEmpty) removed.complete();
      });
      store.record(
        PeerLocationShare.fromChat(
          message,
          ownerName: 'Registered source',
          now: now,
          expiresAt: now.add(const Duration(milliseconds: 500)),
        ),
      );
      store.record(
        PeerLocationShare.fromChat(
          message.copyWith(
            createdAt: now.subtract(const Duration(minutes: 1)),
            body: '{"latitude":7.32,"longitude":125.69}',
          ),
          ownerName: 'Registered source',
          now: now,
          expiresAt: now.add(const Duration(minutes: 1)),
        ),
      );
      expect(
        container.read(sharedPeerLocationsProvider).values.single.latitude,
        7.31,
      );
      await removed.future.timeout(const Duration(seconds: 3));
      expect(container.read(sharedPeerLocationsProvider), isEmpty);
    },
  );
}

class _Node {
  _Node(this.peer);

  final Peer peer;
  final encryption = DeviceIdentityStore(
    secretStore: InMemorySecretValueStore(),
  );
  final signing = DeviceSigningIdentityStore(
    secretStore: InMemorySecretValueStore(),
  );

  static Future<_Node> create(String id, DateTime lastSeenAt) async => _Node(
    Peer(
      id: id,
      name: '$id phone',
      type: PeerType.civilian,
      isConnected: false,
      lastSeenAt: lastSeenAt,
    ),
  );

  Future<TrustedDevice> get registration async => TrustedDevice(
    deviceId: peer.id,
    ownerName: 'Registered ${peer.id}',
    role: 'civilian',
    status: 'approved',
    publicKey: (await encryption.loadOrCreate()).encodedPublicKey,
    signingPublicKey: (await signing.loadOrCreate()).encodedPublicKey,
    keyVersion: 1,
    updatedAt: DateTime.now().toUtc(),
  );
}

Future<ProviderContainer> _container(
  MockScfTransportNetwork network,
  _Node node,
  List<_Node> approved,
) async {
  final folder = await Directory.systemTemp.createTemp('shadow-peer-pin-');
  final databasePath = '${folder.path}/local.db';
  addTearDown(() async {
    await databaseFactoryFfi.deleteDatabase(databasePath);
    await folder.delete();
  });
  final database = await LocalMessagingDatabase.open(
    databasePath: databasePath,
    factory: databaseFactoryFfi,
  );
  addTearDown(database.close);
  final container = ProviderContainer(
    overrides: [
      localMessagingDatabaseProvider.overrideWith((ref) async => database),
      scfTransportProvider.overrideWithValue(network.registerPeer(node.peer)),
      deviceIdentityStoreProvider.overrideWithValue(node.encryption),
      deviceSigningIdentityStoreProvider.overrideWithValue(node.signing),
    ],
  );
  addTearDown(container.dispose);
  final trust = await container.read(trustRepositoryProvider.future);
  final now = DateTime.now().toUtc();
  await trust.replaceFromBundle(
    TrustBundle(
      schemaVersion: 2,
      bundleVersion: 1,
      generatedAt: now,
      issuedAt: now,
      expiresAt: now.add(const Duration(days: 1)),
      issuer: const TrustBundleIssuer(
        issuerId: 'test-admin',
        signingKeyId: 'test-key',
        signatureAlgorithm: 'ed25519',
        publicKey: 'test-key',
      ),
      approvedDevices: [for (final item in approved) await item.registration],
      revokedDevices: const [],
      signature: 'test-signature',
    ).withVerifiedImport(importedAt: now, bundleHash: 'test-bundle'),
  );
  return container;
}
