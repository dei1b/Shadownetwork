import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/models/relay_payload_codec.dart';
import 'package:shadownetwork/features/messaging/data/models/secure_chat_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/models/secure_sos_message_payload.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/chat_message.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/message_encryption_service.dart';
import 'package:shadownetwork/features/security/domain/entities/device_crypto_identity.dart';

void main() {
  final sender = Peer(
    id: 'sender-1',
    name: 'Resident',
    type: PeerType.civilian,
    isConnected: true,
  );
  final recipient = Peer(
    id: 'rescuer-1',
    name: 'Rescuer',
    type: PeerType.responder,
    isConnected: false,
  );

  for (final category in Category.sosCategories) {
    test('${category.name} survives broadcast, encryption and relay', () async {
      final identity = await _newIdentity();
      final service = MessageEncryptionService();
      final message = SosMessage(
        id: 'category-${category.name}',
        sender: sender,
        body: 'Assistance needed near the barangay hall.',
        category: category,
        status: MessageStatus.queued,
        createdAt: DateTime.utc(2026, 10, 6),
      );
      for (final target in <Peer?>[null, recipient]) {
        final prepared = await SecureSosMessagePayload.prepare(
          message.copyWith(recipient: target),
          encryptionService: service,
          recipientPublicKey: target == null ? null : identity.encodedPublicKey,
        );
        final relayed = RelayPayloadCodec.payloadJsonForRelay(
          prepared.payloadJson,
          hopCount: 2,
        );
        expect(RelayPayloadCodec.hashPayload(relayed), prepared.hash);
        final decoded = await SecureSosMessagePayload.decode(
          jsonDecode(relayed) as Map<String, Object?>,
          localPeerId: recipient.id,
          encryptionService: service,
          localIdentity: identity,
        );
        expect(decoded.category, category);
        expect(decoded.body, message.body);
        expect(decoded.hopCount, 2);
      }
    });
  }

  test('SOS v4 hides plaintext and decrypts only for its recipient', () async {
    final identity = await _newIdentity();
    final service = MessageEncryptionService();
    final message = SosMessage(
      id: 'sos-secure-1',
      sender: sender,
      recipient: recipient,
      body: 'Flood water rising behind the school',
      category: Category.rescue,
      status: MessageStatus.queued,
      createdAt: DateTime.utc(2026, 8, 3, 12),
      latitude: 7.3026,
      longitude: 125.6888,
      gpsAccuracyMeters: 6,
    );
    final prepared = await SecureSosMessagePayload.prepare(
      message,
      encryptionService: service,
      recipientPublicKey: identity.encodedPublicKey,
    );
    final payload = jsonDecode(prepared.payloadJson) as Map<String, Object?>;

    expect(payload['schema_version'], 4);
    expect(payload['payload_text'], isNull);
    expect(prepared.payloadJson, isNot(contains(message.body)));
    expect(RelayPayloadCodec.hashPayload(prepared.payloadJson), prepared.hash);

    final decoded = await SecureSosMessagePayload.decode(
      payload,
      localPeerId: recipient.id,
      encryptionService: service,
      localIdentity: identity,
    );
    expect(decoded.body, message.body);
    expect(decoded.messageHash, prepared.hash);
    expect(decoded.isEncrypted, isTrue);
  });

  test(
    'relay changes only SOS hop count and retains authenticated hash',
    () async {
      final identity = await _newIdentity();
      final prepared = await SecureSosMessagePayload.prepare(
        SosMessage(
          id: 'sos-secure-relay',
          sender: sender,
          recipient: recipient,
          body: 'Medical assistance required',
          category: Category.medical,
          status: MessageStatus.queued,
          createdAt: DateTime.utc(2026, 8, 3, 12, 5),
        ),
        encryptionService: MessageEncryptionService(),
        recipientPublicKey: identity.encodedPublicKey,
      );
      final relayed = RelayPayloadCodec.payloadJsonForRelay(
        prepared.payloadJson,
        hopCount: 3,
      );
      final payload = jsonDecode(relayed) as Map<String, Object?>;

      expect((payload['routing']! as Map<String, Object?>)['hop_count'], 3);
      expect(RelayPayloadCodec.hashPayload(relayed), prepared.hash);
      expect(relayed, isNot(contains('Medical assistance required')));
    },
  );

  test(
    'chat v2 is encrypted and detects authenticated metadata changes',
    () async {
      final identity = await _newIdentity();
      final service = MessageEncryptionService();
      final message = ChatMessage(
        id: 'chat-secure-1',
        conversationId: 'conversation-1',
        sender: sender,
        recipient: recipient,
        body: 'We are approaching your location',
        status: MessageStatus.queued,
        createdAt: DateTime.utc(2026, 8, 3, 12, 10),
      );
      final prepared = await SecureChatMessagePayload.prepare(
        message,
        encryptionService: service,
        recipientPublicKey: identity.encodedPublicKey,
      );
      final payload = jsonDecode(prepared.payloadJson) as Map<String, Object?>;

      expect(payload['schema_version'], 2);
      expect(payload['body'], isNull);
      expect(prepared.payloadJson, isNot(contains(message.body)));
      expect(
        (await SecureChatMessagePayload.decode(
          payload,
          localPeerId: recipient.id,
          encryptionService: service,
          localIdentity: identity,
        )).body,
        message.body,
      );

      final routing = Map<String, Object?>.from(
        payload['routing']! as Map<String, Object?>,
      );
      routing['ttl'] = 1;
      payload['routing'] = routing;
      payload['message_hash'] = SecureChatMessagePayload.hashPayload(
        jsonEncode(payload),
      );
      expect(
        () => SecureChatMessagePayload.decode(
          payload,
          localPeerId: recipient.id,
          encryptionService: service,
          localIdentity: identity,
        ),
        throwsFormatException,
      );
    },
  );

  test('targeted SOS refuses missing recipient public key', () async {
    expect(
      () => SecureSosMessagePayload.prepare(
        SosMessage(
          id: 'sos-no-key',
          sender: sender,
          recipient: recipient,
          body: 'Need help',
          category: Category.rescue,
          status: MessageStatus.queued,
          createdAt: DateTime.utc(2026, 8, 3),
        ),
        encryptionService: MessageEncryptionService(),
      ),
      throwsA(isA<MissingRecipientPublicKeyException>()),
    );
  });
}

Future<DeviceCryptoIdentity> _newIdentity() {
  return DeviceIdentityStore(
    secretStore: InMemorySecretValueStore(),
  ).loadOrCreate();
}
