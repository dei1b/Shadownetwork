import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/models/sos_message_payload.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';

void main() {
  const sender = Peer(
    id: 'peer-1',
    name: 'Responder 1',
    type: PeerType.responder,
    isConnected: true,
    signalStrength: 88,
  );
  const recipient = Peer(
    id: 'rescuer-1',
    name: 'Rescuer Endpoint',
    type: PeerType.responder,
    isConnected: false,
  );

  final message = SosMessage(
    id: 'sos-1',
    sender: sender,
    body: 'Need medical assistance.',
    category: Category.medical,
    status: MessageStatus.queued,
    createdAt: DateTime.utc(2026, 5, 2, 5, 30),
    latitude: 7.3026,
    longitude: 125.6888,
    gpsAccuracyMeters: 8.5,
    ttl: const Duration(hours: 2),
  );

  test('serializes SOS messages into deterministic canonical JSON', () {
    final firstJson = SosMessagePayload.canonicalJson(message);
    final secondJson = SosMessagePayload.canonicalJson(message);
    final payload = jsonDecode(firstJson) as Map<String, Object?>;
    final routing = payload['routing']! as Map<String, Object?>;
    final location = payload['location']! as Map<String, Object?>;
    final senderPayload = payload['sender']! as Map<String, Object?>;

    expect(firstJson, secondJson);
    expect(payload['schema_version'], 3);
    expect(payload['message_id'], 'sos-1');
    expect(payload['message_hash'], SosMessagePayload.messageHash(message));
    expect(payload['payload_text'], 'Need medical assistance.');
    expect(location['latitude'], 7.3026);
    expect(location['longitude'], 125.6888);
    expect(location['accuracy_meters'], 8.5);
    expect(routing['hop_count'], 0);
    expect(routing['ttl'], 7200);
    expect(senderPayload['peer_id'], 'peer-1');
    expect(senderPayload['peer_name'], 'Responder 1');
    expect(senderPayload['peer_type'], 'responder');
  });

  test('creates a deterministic SHA-256 message hash', () {
    final hash = SosMessagePayload.messageHash(message);

    expect(hash, hasLength(64));
    expect(hash, SosMessagePayload.messageHash(message));
  });

  test('hash ignores mutable local delivery and hop state', () {
    final relayedMessage = message.copyWith(
      status: MessageStatus.delivered,
      hopCount: 4,
      updatedAt: DateTime.utc(2026, 5, 2, 5, 35),
    );

    expect(
      SosMessagePayload.messageHash(relayedMessage),
      SosMessagePayload.messageHash(message),
    );
  });

  test('deserializes payloads into received SOS messages', () {
    final payload =
        jsonDecode(SosMessagePayload.canonicalJson(message))
            as Map<String, Object?>;
    final decoded = SosMessagePayload.fromPayload(payload);

    expect(decoded.id, message.id);
    expect(decoded.sender.id, sender.id);
    expect(decoded.sender.type, PeerType.responder);
    expect(decoded.body, message.body);
    expect(decoded.category, Category.medical);
    expect(decoded.status, MessageStatus.received);
    expect(decoded.createdAt, message.createdAt);
    expect(decoded.messageHash, SosMessagePayload.messageHash(message));
    expect(decoded.gpsAccuracyMeters, 8.5);
    expect(decoded.hopCount, 0);
    expect(decoded.ttl, const Duration(hours: 2));
  });

  test('keeps legacy SOS schema version 1 readable', () {
    final decoded = SosMessagePayload.fromPayload({
      'schema_version': 1,
      'id': 'legacy-sos-v1',
      'sender': {
        'id': 'legacy-peer',
        'name': 'Legacy Peer',
        'type': 'civilian',
        'latitude': 7.3,
        'longitude': 125.68,
      },
      'body': 'Legacy v1 SOS',
      'category': 'rescue',
      'created_at': '2026-06-01T01:02:03.000Z',
      'latitude': 7.3,
      'longitude': 125.68,
    });

    expect(decoded.id, 'legacy-sos-v1');
    expect(decoded.sender.id, 'legacy-peer');
    expect(decoded.body, 'Legacy v1 SOS');
    expect(decoded.category, Category.rescue);
    expect(decoded.ttl, SosMessagePayload.defaultTtl);
  });

  test('keeps legacy SOS schema version 2 readable with stable hash', () {
    final payload = <String, Object?>{
      'schema_version': 2,
      'message_id': 'legacy-sos-v2',
      'payload_text': 'Legacy v2 SOS',
      'category': 'rescue',
      'location': {
        'latitude': 7.3,
        'longitude': 125.68,
        'accuracy_meters': 12.0,
      },
      'routing': {'hop_count': 0, 'ttl': 3600},
      'timestamp': {'created_at': '2026-06-01T01:02:03.000Z'},
      'sender': {
        'peer_id': 'legacy-peer',
        'peer_name': 'Legacy Peer',
        'peer_type': 'civilian',
      },
    };
    const expectedHash =
        '4d41f058bb589979df589deff0fd85fe41ba0ac920d5bdf703081f3def2d99b0';
    expect(SosMessagePayload.hashPayload(jsonEncode(payload)), expectedHash);
    payload['message_hash'] = expectedHash;

    final decoded = SosMessagePayload.fromPayload(payload);

    expect(decoded.id, 'legacy-sos-v2');
    expect(decoded.body, 'Legacy v2 SOS');
    expect(decoded.messageHash, expectedHash);
    expect(decoded.gpsAccuracyMeters, 12.0);
    expect(decoded.ttl, const Duration(hours: 1));
    expect(decoded.recipient, isNull);
    expect(decoded.isEncrypted, isFalse);
  });

  test('rejects unsupported future SOS schema versions', () {
    expect(
      () => SosMessagePayload.fromPayload(const {'schema_version': 99}),
      throwsFormatException,
    );
  });

  test('rewrites routing metadata for relay without changing message hash', () {
    final relayedJson = SosMessagePayload.payloadJsonForRelay(
      SosMessagePayload.canonicalJson(message),
      hopCount: 3,
    );
    final relayedPayload = jsonDecode(relayedJson) as Map<String, Object?>;
    final decoded = SosMessagePayload.fromPayload(relayedPayload);

    expect(
      relayedPayload['message_hash'],
      SosMessagePayload.messageHash(message),
    );
    expect(
      (relayedPayload['routing']! as Map<String, Object?>)['hop_count'],
      3,
    );
    expect(decoded.hopCount, 3);
    expect(decoded.messageHash, SosMessagePayload.messageHash(message));
  });

  test('encrypts targeted SOS payloads for the selected recipient', () {
    final targeted = message.copyWith(recipient: recipient, isEncrypted: true);
    final payload =
        jsonDecode(SosMessagePayload.canonicalJson(targeted))
            as Map<String, Object?>;
    final security = payload['security']! as Map<String, Object?>;
    final recipientPayload = payload['recipient']! as Map<String, Object?>;

    expect(payload['payload_text'], isNull);
    expect(security['encrypted'], isTrue);
    expect(security['cipher_text'], isNot(contains(targeted.body)));
    expect(recipientPayload['peer_id'], recipient.id);

    final decoded = SosMessagePayload.fromPayload(
      payload,
      localPeerId: recipient.id,
    );
    expect(decoded.body, targeted.body);
    expect(decoded.recipient?.id, recipient.id);
    expect(decoded.isEncrypted, isTrue);
  });

  test('rejects targeted SOS payloads on non-recipient devices', () {
    final targetedPayload =
        jsonDecode(
              SosMessagePayload.canonicalJson(
                message.copyWith(recipient: recipient, isEncrypted: true),
              ),
            )
            as Map<String, Object?>;

    expect(
      () => SosMessagePayload.fromPayload(
        targetedPayload,
        localPeerId: 'relay-only-peer',
      ),
      throwsFormatException,
    );
  });

  test('relays targeted SOS without decrypting plaintext', () {
    final targeted = message.copyWith(recipient: recipient, isEncrypted: true);
    final relayedJson = SosMessagePayload.payloadJsonForRelay(
      SosMessagePayload.canonicalJson(targeted),
      hopCount: 2,
    );
    final relayedPayload = jsonDecode(relayedJson) as Map<String, Object?>;

    expect(relayedJson, isNot(contains(targeted.body)));
    expect(
      (relayedPayload['routing']! as Map<String, Object?>)['hop_count'],
      2,
    );
    expect(
      relayedPayload['message_hash'],
      SosMessagePayload.messageHash(targeted),
    );
  });
}
