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

  final message = SosMessage(
    id: 'sos-1',
    sender: sender,
    body: 'Need medical assistance.',
    category: Category.medical,
    status: MessageStatus.queued,
    createdAt: DateTime.utc(2026, 5, 2, 5, 30),
    latitude: 7.3026,
    longitude: 125.6888,
  );

  test('serializes SOS messages into deterministic canonical JSON', () {
    expect(
      SosMessagePayload.canonicalJson(message),
      '{"schema_version":1,"id":"sos-1","sender":{"id":"peer-1",'
      '"name":"Responder 1","type":"responder","latitude":null,'
      '"longitude":null},"body":"Need medical assistance.",'
      '"category":"medical","created_at":"2026-05-02T05:30:00.000Z",'
      '"latitude":7.3026,"longitude":125.6888}',
    );
  });

  test('creates a deterministic SHA-256 message hash', () {
    expect(
      SosMessagePayload.messageHash(message),
      '48c03f2cd0475f80286a9cd213ced26dea4fe021516396499ce5dfa676041864',
    );
  });

  test('hash ignores mutable local delivery state', () {
    final deliveredMessage = message.copyWith(
      status: MessageStatus.delivered,
      updatedAt: DateTime.utc(2026, 5, 2, 5, 35),
    );

    expect(
      SosMessagePayload.messageHash(deliveredMessage),
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
  });
}
