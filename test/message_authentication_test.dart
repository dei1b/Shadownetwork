import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/models/relay_payload_codec.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_service.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_relay_service.dart';
import 'package:shadownetwork/features/messaging/data/services/mock_scf_transport.dart';
import 'package:shadownetwork/features/messaging/domain/entities/scf_envelope.dart';
import 'package:shadownetwork/features/messaging/domain/entities/envelope_transfer_result.dart';
import 'package:shadownetwork/features/messaging/data/models/secure_sos_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/models/secure_chat_message_payload.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/chat_message.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_signing_identity.dart';
import 'package:shadownetwork/features/security/data/services/message_authentication_service.dart';
import 'package:shadownetwork/features/security/data/services/message_encryption_service.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';
import 'package:shadownetwork/features/trust/data/repositories/sqlite_trust_repository.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_trust_status.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/signed_trust_bundle_fixture.dart';

void main() {
  const auth = MessageAuthenticationService();
  final encryption = MessageEncryptionService();
  final sender = Peer(
    id: 'resident',
    name: 'Resident',
    type: PeerType.civilian,
    isConnected: false,
  );
  final recipient = Peer(
    id: 'responder',
    name: 'Responder',
    type: PeerType.responder,
    isConnected: false,
  );
  late DeviceSigningIdentity signing;
  late SqliteTrustRepository repository;
  late Database db;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    signing = await DeviceSigningIdentityStore(
      secretStore: InMemorySecretValueStore(),
    ).loadOrCreate();
    db = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repository = SqliteTrustRepository(database: db);
  });
  tearDown(() => db.close());

  Future<void> register({
    bool revoked = false,
    Duration validity = const Duration(days: 1),
  }) async {
    final signer = await TestTrustBundleSigner.create();
    final device = TrustedDevice(
      deviceId: sender.id,
      ownerName: 'Registered Resident',
      role: 'civilian',
      status: revoked ? 'revoked' : 'approved',
      updatedAt: DateTime.now(),
      publicKey: base64UrlEncode(List.filled(32, 1)),
      signingPublicKey: signing.encodedPublicKey,
    );
    final source = await signer.sign(
      bundleVersion: 1,
      issuedAt: DateTime.now().toUtc(),
      validity: validity,
      approvedDevices: revoked ? [] : [device],
      revokedDevices: revoked ? [device] : [],
    );
    await repository.replaceFromBundle(
      TrustBundle.fromJsonString(
        source,
      ).withVerifiedImport(importedAt: DateTime.now(), bundleHash: 'test'),
    );
  }

  SosMessage message({bool targeted = false}) => SosMessage(
    id: 'sos-1',
    sender: sender,
    recipient: targeted ? recipient : null,
    body: 'Need rescue',
    category: Category.rescue,
    status: MessageStatus.queued,
    createdAt: DateTime.now().toUtc(),
  );

  test(
    'signing identity survives restart and concurrent initialization',
    () async {
      final secrets = InMemorySecretValueStore();
      final store = DeviceSigningIdentityStore(secretStore: secrets);
      final identities = await Future.wait([
        store.loadOrCreate(),
        store.loadOrCreate(),
      ]);
      expect(identities[0].keyId, identities[1].keyId);
      expect(
        (await DeviceSigningIdentityStore(
          secretStore: secrets,
        ).loadOrCreate()).keyId,
        identities[0].keyId,
      );
    },
  );

  test(
    'signed registration binds both public keys and rejects edited identity',
    () async {
      final identity = await DeviceIdentityStore(
        secretStore: InMemorySecretValueStore(),
      ).loadOrCreate();
      final qr = await DeviceRegistrationQr.createSigned(
        deviceId: sender.id,
        identity: identity,
        signingIdentity: signing,
      );
      final decoded = DeviceRegistrationQr.fromJsonString(qr.toJsonString());
      await decoded.verifySignature();
      expect(qr.toJsonString(), isNot(contains('private_key')));
      final tampered = qr.toJson()..['device_id'] = 'someone-else';
      await expectLater(
        DeviceRegistrationQr.fromJson(tampered).verifySignature(),
        throwsFormatException,
      );
    },
  );

  test(
    'approved signed SOS retains its verified identity, hash and signature through hops',
    () async {
      await register();
      final prepared = await SecureSosMessagePayload.prepare(
        message(),
        encryptionService: encryption,
        signingIdentity: signing,
      );
      expect(jsonDecode(prepared.payloadJson)['schema_version'], 5);
      final relayed = RelayPayloadCodec.payloadJsonForRelay(
        prepared.payloadJson,
        hopCount: 3,
      );
      expect(RelayPayloadCodec.hashPayload(relayed), prepared.hash);
      final result = await auth.authenticate(relayed, repository);
      expect(result.status, DeviceTrustStatus.approved);
      expect(result.ownerName, 'Registered Resident');
      // JSON ordering must not change the cryptographic identity.
      final payload = jsonDecode(relayed) as Map<String, Object?>;
      final reversed = Map<String, Object?>.fromEntries(
        payload.entries.toList().reversed,
      );
      expect(
        (await auth.authenticate(jsonEncode(reversed), repository)).status,
        DeviceTrustStatus.approved,
      );
    },
  );

  test(
    'targeted signed SOS and chat remain encrypted and decrypt after relay',
    () async {
      await register();
      final recipientIdentity = await DeviceIdentityStore(
        secretStore: InMemorySecretValueStore(),
      ).loadOrCreate();
      final sos = await SecureSosMessagePayload.prepare(
        message(targeted: true),
        encryptionService: encryption,
        recipientPublicKey: recipientIdentity.encodedPublicKey,
        signingIdentity: signing,
      );
      expect(sos.payloadJson, isNot(contains('Need rescue')));
      final sosJson = RelayPayloadCodec.payloadJsonForRelay(
        jsonEncode(_reorder(jsonDecode(sos.payloadJson))),
        hopCount: 2,
      );
      expect(
        (await auth.authenticate(sosJson, repository)).status,
        DeviceTrustStatus.approved,
      );
      expect(
        (await SecureSosMessagePayload.decode(
          jsonDecode(sosJson),
          localPeerId: recipient.id,
          encryptionService: encryption,
          localIdentity: recipientIdentity,
        )).body,
        'Need rescue',
      );
      final chat = await SecureChatMessagePayload.prepare(
        ChatMessage(
          id: 'chat',
          conversationId: 'conversation',
          sender: sender,
          recipient: recipient,
          body: 'Private reply',
          status: MessageStatus.queued,
          createdAt: DateTime.now(),
        ),
        encryptionService: encryption,
        recipientPublicKey: recipientIdentity.encodedPublicKey,
        signingIdentity: signing,
      );
      expect(jsonDecode(chat.payloadJson)['schema_version'], 3);
      expect(chat.payloadJson, isNot(contains('Private reply')));
      final relayed = RelayPayloadCodec.payloadJsonForRelay(
        chat.payloadJson,
        hopCount: 4,
      );
      expect(RelayPayloadCodec.hashPayload(relayed), chat.hash);
      expect(
        (await auth.authenticate(relayed, repository)).status,
        DeviceTrustStatus.approved,
      );
      expect(
        (await SecureChatMessagePayload.decode(
          jsonDecode(relayed),
          localPeerId: recipient.id,
          encryptionService: encryption,
          localIdentity: recipientIdentity,
        )).body,
        'Private reply',
      );
    },
  );

  for (final field in [
    'payload_text',
    'sender',
    'timestamp',
    'routing',
    'authentication',
  ]) {
    test('rejects modified $field even with a recomputed hash', () async {
      await register();
      final prepared = await SecureSosMessagePayload.prepare(
        message(),
        encryptionService: encryption,
        signingIdentity: signing,
      );
      final payload = jsonDecode(prepared.payloadJson) as Map<String, Object?>;
      switch (field) {
        case 'payload_text':
          payload[field] = 'False emergency';
        case 'sender':
          (payload[field] as Map)['peer_name'] = 'Impersonated';
        case 'timestamp':
          (payload[field] as Map)['created_at'] = DateTime.utc(
            2030,
          ).toIso8601String();
        case 'routing':
          (payload[field] as Map)['ttl'] = 999999;
        case 'authentication':
          (payload[field] as Map)['signature'] = base64UrlEncode(
            List.filled(64, 0),
          );
      }
      payload['message_hash'] = RelayPayloadCodec.hashPayload(
        jsonEncode(payload),
      );
      await expectLater(
        auth.authenticate(jsonEncode(payload), repository),
        throwsFormatException,
      );
    });
  }

  test(
    'unknown signed emergencies remain unverified and revoked origins remain quarantined',
    () async {
      final prepared = await SecureSosMessagePayload.prepare(
        message(),
        encryptionService: encryption,
        signingIdentity: signing,
      );
      expect(
        (await auth.authenticate(prepared.payloadJson, repository)).status,
        DeviceTrustStatus.unknown,
      );
      await register(revoked: true);
      expect(
        (await auth.authenticate(prepared.payloadJson, repository)).status,
        DeviceTrustStatus.revoked,
      );
    },
  );

  test(
    'legacy unsigned and signature-stripped messages never inherit approval',
    () async {
      await register();
      final legacy = await SecureSosMessagePayload.prepare(
        message(),
        encryptionService: encryption,
      );
      expect(
        (await auth.authenticate(legacy.payloadJson, repository)).status,
        DeviceTrustStatus.unknown,
      );
      final prepared = await SecureSosMessagePayload.prepare(
        message(),
        encryptionService: encryption,
        signingIdentity: signing,
      );
      final payload = jsonDecode(prepared.payloadJson) as Map<String, Object?>;
      payload.remove('authentication');
      await expectLater(
        auth.authenticate(jsonEncode(payload), repository),
        throwsFormatException,
      );
      payload['schema_version'] = 4;
      expect(
        (await auth.authenticate(jsonEncode(payload), repository)).status,
        DeviceTrustStatus.unknown,
      );
    },
  );

  test(
    'another signing key cannot impersonate a registered device ID',
    () async {
      await register();
      final impostor = await DeviceSigningIdentityStore(
        secretStore: InMemorySecretValueStore(),
      ).loadOrCreate();
      final prepared = await SecureSosMessagePayload.prepare(
        message(),
        encryptionService: encryption,
        signingIdentity: impostor,
      );
      await expectLater(
        auth.authenticate(prepared.payloadJson, repository),
        throwsFormatException,
      );
    },
  );

  test(
    'production SOS writer persists a signed payload with the same visible hash',
    () async {
      await register();
      final network = MockScfTransportNetwork();
      final container = ProviderContainer(
        overrides: [
          localMessagingDatabaseProvider.overrideWith((ref) async => db),
          scfTransportProvider.overrideWithValue(network.registerPeer(sender)),
          deviceSigningIdentityProvider.overrideWith((ref) async => signing),
        ],
      );
      addTearDown(container.dispose);
      await container.read(saveSosMessageProvider)(message());
      final queue = await (await container.read(
        scfServiceProvider.future,
      )).getStoredEnvelopes();
      expect(jsonDecode(queue.single.payloadJson)['schema_version'], 5);
      expect(
        (await auth.authenticate(queue.single.payloadJson, repository)).status,
        DeviceTrustStatus.approved,
      );
      final records = await (await container.read(
        sosMessageRepositoryProvider.future,
      )).getMessages();
      expect(records.single.messageHash, queue.single.messageHash);
      expect(records.single.trustStatus, DeviceTrustStatus.approved);
    },
  );

  test(
    'signed TTL cannot be extended by editing the transport envelope',
    () async {
      final original = message();
      final prepared = await SecureSosMessagePayload.prepare(
        original,
        encryptionService: encryption,
        signingIdentity: signing,
      );
      final service = ScfService(database: db);
      final forgedExpiry = ScfEnvelope(
        messageHash: prepared.hash,
        payloadJson: prepared.payloadJson,
        hopCount: 0,
        receivedAt: original.createdAt,
        expiresAt: original.createdAt.add(const Duration(days: 30)),
      );
      expect(await service.storeEnvelope(forgedExpiry), isTrue);
      expect(
        (await service.getStoredEnvelopes()).single.expiresAt,
        original.createdAt.add(original.ttl),
      );
      expect(
        await service.storeEnvelope(
          forgedExpiry,
          now: original.createdAt.add(const Duration(days: 2)),
        ),
        isFalse,
      );
      expect(
        await service.storePayload(
          payloadJson: prepared.payloadJson,
          receivedAt: original.createdAt.add(const Duration(days: 2)),
        ),
        isFalse,
      );
    },
  );

  test(
    'receiver rejects an invalid signature before storage and sends a rejected ACK',
    () async {
      await register();
      final prepared = await SecureSosMessagePayload.prepare(
        message(),
        encryptionService: encryption,
        signingIdentity: signing,
      );
      final payload = jsonDecode(prepared.payloadJson) as Map<String, Object?>;
      payload['payload_text'] = 'Modified by a relay';
      final json = jsonEncode(payload);
      final hash = RelayPayloadCodec.hashPayload(json);
      final network = MockScfTransportNetwork();
      network.registerPeer(sender);
      final transport = network.registerPeer(recipient);
      final service = ScfService(database: db);
      final receiver = ScfRelayService(
        scfService: service,
        transport: transport,
        originTrustResolver: (json) async =>
            (await auth.authenticate(json, repository)).status,
      );
      final sending = network.sendAndWait(
        fromPeerId: sender.id,
        toPeerId: recipient.id,
        envelope: ScfEnvelope(
          messageHash: hash,
          payloadJson: json,
          hopCount: 1,
          receivedAt: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(hours: 24)),
          transferId: 'tampered-attempt',
        ),
      );
      final rejected = expectLater(
        sending,
        throwsA(isA<EnvelopeTransferException>()),
      );
      expect(await receiver.ingestIncoming(), 0);
      await rejected;
      expect(await service.getStoredEnvelopes(), isEmpty);
    },
  );

  test(
    'outbound validation stops tampered data already in a persisted queue',
    () async {
      await register();
      final prepared = await SecureSosMessagePayload.prepare(
        message(),
        encryptionService: encryption,
        signingIdentity: signing,
      );
      final payload = jsonDecode(prepared.payloadJson) as Map<String, Object?>;
      payload['payload_text'] = 'Modified queue';
      final json = jsonEncode(payload);
      final service = ScfService(database: db);
      await service.storePayload(payloadJson: json);
      final network = MockScfTransportNetwork();
      final transport = network.registerPeer(sender);
      network.registerPeer(recipient);
      final relay = ScfRelayService(
        scfService: service,
        transport: transport,
        originTrustResolver: (json) async =>
            (await auth.authenticate(json, repository)).status,
      );
      final result = await relay.relayToPeer(recipient);
      expect(result.sentCount, 0);
      expect(result.failedCount, 1);
      expect(network.drainInbox(recipient.id), isEmpty);
    },
  );

  test(
    'expired administrative approval never produces a verified message',
    () async {
      await register(validity: const Duration(seconds: -1));
      final prepared = await SecureSosMessagePayload.prepare(
        message(),
        encryptionService: encryption,
        signingIdentity: signing,
      );
      expect(
        (await auth.authenticate(prepared.payloadJson, repository)).status,
        DeviceTrustStatus.unknown,
      );
    },
  );
}

Object? _reorder(Object? value) {
  if (value is Map) {
    return Map.fromEntries(
      value.entries.toList().reversed.map(
        (entry) => MapEntry(entry.key, _reorder(entry.value)),
      ),
    );
  }
  if (value is List) return value.map(_reorder).toList();
  return value;
}
