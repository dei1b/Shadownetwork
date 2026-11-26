import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/models/secure_sos_message_payload.dart';
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
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/message_encryption_service.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/presentation/providers/device_access_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _TestPhone {
  _TestPhone(this.peer);

  final Peer peer;
  final identityStore = DeviceIdentityStore(
    secretStore: InMemorySecretValueStore(),
  );
  final signingStore = DeviceSigningIdentityStore(
    secretStore: InMemorySecretValueStore(),
  );

  static Future<_TestPhone> create(String id, DateTime now) async => _TestPhone(
    Peer(
      id: id,
      name: '$id phone',
      type: PeerType.civilian,
      isConnected: false,
      lastSeenAt: now,
    ),
  );

  Future<TrustedDevice> registration(DateTime now) async => TrustedDevice(
    deviceId: peer.id,
    ownerName: 'Verified ${peer.id}',
    role: 'civilian',
    status: 'approved',
    publicKey: (await identityStore.loadOrCreate()).encodedPublicKey,
    signingPublicKey: (await signingStore.loadOrCreate()).encodedPublicKey,
    keyVersion: 1,
    updatedAt: now,
  );
}

Future<ProviderContainer> _openReceiver({
  required MockScfTransportNetwork network,
  required _TestPhone receiver,
  required List<_TestPhone> approved,
  required SosInboxAccess inboxAccess,
  required DateTime now,
}) async {
  final dir = await Directory.systemTemp.createTemp('shadow-stu-sos-');
  final dbPath = '${dir.path}/local.db';
  addTearDown(() async {
    await databaseFactoryFfi.deleteDatabase(dbPath);
    await dir.delete(recursive: true);
  });
  final database = await LocalMessagingDatabase.open(
    databasePath: dbPath,
    factory: databaseFactoryFfi,
  );
  addTearDown(database.close);
  final container = ProviderContainer(
    overrides: [
      localMessagingDatabaseProvider.overrideWith((ref) async => database),
      localPeerProvider.overrideWith((ref) async => receiver.peer),
      scfTransportProvider.overrideWithValue(
        network.registerPeer(receiver.peer),
      ),
      deviceIdentityStoreProvider.overrideWithValue(receiver.identityStore),
      deviceSigningIdentityStoreProvider.overrideWithValue(
        receiver.signingStore,
      ),
      sosInboxAccessProvider.overrideWith((ref) => () async => inboxAccess),
    ],
  );
  addTearDown(container.dispose);

  final trust = await container.read(trustRepositoryProvider.future);
  await trust.replaceFromBundle(
    TrustBundle(
      schemaVersion: 2,
      bundleVersion: 1,
      generatedAt: now,
      issuedAt: now,
      expiresAt: now.add(const Duration(days: 1)),
      issuer: const TrustBundleIssuer(
        issuerId: 'dnsc-admin',
        signingKeyId: 'k1',
        signatureAlgorithm: 'ed25519',
        publicKey: 'root-key',
      ),
      approvedDevices: [for (final p in approved) await p.registration(now)],
      revokedDevices: const [],
      signature: 'sig',
    ).withVerifiedImport(importedAt: now, bundleHash: 'bundle-hash'),
  );
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'schema 5 signed plaintext broadcast delivers to verified student, while encrypted SOS and unverified/revoked receivers skip inbox',
    () async {
      final now = DateTime.now().toUtc();
      final network = MockScfTransportNetwork();
      final sender = await _TestPhone.create('sender-stu', now);
      final student = await _TestPhone.create('verified-stu', now);
      final responder = await _TestPhone.create('verified-resp', now);
      final denied = await _TestPhone.create('unverified-phone', now);
      final revoked = await _TestPhone.create('revoked-phone', now);

      network.registerPeer(sender.peer);
      final senderSigning = await sender.signingStore.loadOrCreate();
      final studentCrypto = await student.identityStore.loadOrCreate();
      final responderCrypto = await responder.identityStore.loadOrCreate();
      final encryption = MessageEncryptionService();

      // 1) Schema 5 signed plaintext campus broadcast (recipient == null)
      final broadcastSos = SosMessage(
        id: 'sos-bcast-1',
        sender: sender.peer,
        body: 'Medical emergency near main gym',
        category: Category.medical,
        latitude: 7.313,
        longitude: 125.670,
        ttl: const Duration(hours: 24),
        hopCount: 0,
        status: MessageStatus.queued,
        createdAt: now,
      );
      final preparedBroadcast = await SecureSosMessagePayload.prepare(
        broadcastSos,
        encryptionService: encryption,
        signingIdentity: senderSigning,
      );
      expect(
        (jsonDecode(preparedBroadcast.payloadJson) as Map)['schema_version'],
        5,
      );
      final bcastEnvelope = ScfEnvelope(
        messageHash: preparedBroadcast.hash,
        payloadType: 'sos_message',
        payloadJson: preparedBroadcast.payloadJson,
        hopCount: 0,
        expiresAt: now.add(const Duration(minutes: 30)),
        receivedAt: now,
        receivedFromPeerId: sender.peer.id,
      );

      // Verified student (broadcastOnly) stores signed plaintext broadcast in SOS inbox.
      final studentContainer = await _openReceiver(
        network: network,
        receiver: student,
        approved: [sender, student, responder],
        inboxAccess: SosInboxAccess.broadcastOnly,
        now: now,
      );
      network.send(
        fromPeerId: sender.peer.id,
        toPeerId: student.peer.id,
        envelope: bcastEnvelope,
      );
      final storedBroadcast = await studentContainer
          .read(relayRuntimeProvider.notifier)
          .receiveIncoming();
      expect(storedBroadcast, 1);
      final studentRepo = await studentContainer.read(
        sosMessageRepositoryProvider.future,
      );
      final inbox = await studentRepo.getMessages();
      expect(inbox, hasLength(1));
      expect(inbox.single.id, 'sos-bcast-1');
      expect(inbox.single.body, 'Medical emergency near main gym');

      // 2) Encrypted schema 5 SOS (targeted or marked encrypted) must NOT store in student inbox.
      for (final (id, recipient, pubKey, keyVersion) in [
        (
          'sos-enc-target-stu',
          student.peer,
          studentCrypto.encodedPublicKey,
          studentCrypto.keyVersion,
        ),
        (
          'sos-enc-target-resp',
          responder.peer,
          responderCrypto.encodedPublicKey,
          responderCrypto.keyVersion,
        ),
      ]) {
        final encryptedSos = SosMessage(
          id: id,
          sender: sender.peer,
          recipient: recipient,
          body: 'Confidential responder emergency',
          category: Category.medical,
          latitude: 7.313,
          longitude: 125.670,
          ttl: const Duration(hours: 24),
          hopCount: 0,
          status: MessageStatus.queued,
          createdAt: now.add(const Duration(seconds: 5)),
        );
        final preparedEncrypted = await SecureSosMessagePayload.prepare(
          encryptedSos,
          encryptionService: encryption,
          recipientPublicKey: pubKey,
          recipientKeyVersion: keyVersion,
          signingIdentity: senderSigning,
        );
        network.send(
          fromPeerId: sender.peer.id,
          toPeerId: student.peer.id,
          envelope: ScfEnvelope(
            messageHash: preparedEncrypted.hash,
            payloadType: 'sos_message',
            payloadJson: preparedEncrypted.payloadJson,
            hopCount: 0,
            expiresAt: now.add(const Duration(minutes: 30)),
            receivedAt: now.add(const Duration(seconds: 5)),
            receivedFromPeerId: sender.peer.id,
          ),
        );
      }
      final encryptedBroadcastMap =
          jsonDecode(preparedBroadcast.payloadJson) as Map<String, Object?>;
      encryptedBroadcastMap['security'] = {
        'encrypted': true,
        'protocol_version': MessageEncryptionService.protocolVersion,
      };
      network.send(
        fromPeerId: sender.peer.id,
        toPeerId: student.peer.id,
        envelope: ScfEnvelope(
          messageHash: 'forged-encrypted-bcast-hash',
          payloadType: 'sos_message',
          payloadJson: jsonEncode(encryptedBroadcastMap),
          hopCount: 0,
          expiresAt: now.add(const Duration(minutes: 30)),
          receivedAt: now.add(const Duration(seconds: 10)),
          receivedFromPeerId: sender.peer.id,
        ),
      );
      final storedEncrypted = await studentContainer
          .read(relayRuntimeProvider.notifier)
          .receiveIncoming();
      expect(storedEncrypted, 0);
      expect(await studentRepo.getMessages(), hasLength(1));

      // 3) Denied & awaitingRenewal receivers must NOT store broadcasts in SOS inbox.
      for (final (peer, access) in [
        (denied, SosInboxAccess.denied),
        (revoked, SosInboxAccess.awaitingRenewal),
      ]) {
        final otherContainer = await _openReceiver(
          network: network,
          receiver: peer,
          approved: [sender],
          inboxAccess: access,
          now: now,
        );
        network.send(
          fromPeerId: sender.peer.id,
          toPeerId: peer.peer.id,
          envelope: bcastEnvelope,
        );
        final count = await otherContainer
            .read(relayRuntimeProvider.notifier)
            .receiveIncoming();
        expect(count, 0);
        final repo = await otherContainer.read(
          sosMessageRepositoryProvider.future,
        );
        expect(await repo.getMessages(), isEmpty);
      }
    },
  );
}
