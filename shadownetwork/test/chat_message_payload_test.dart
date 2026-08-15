import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/models/chat_message_payload.dart';
import 'package:shadownetwork/features/messaging/domain/entities/chat_message.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';

void main() {
  test(
    'serializes a recipient-targeted chat payload and validates its hash',
    () {
      final message = _message();
      final json = ChatMessagePayload.canonicalJson(message);
      final payload = jsonDecode(json) as Map<String, Object?>;
      final decoded = ChatMessagePayload.fromPayload(payload);

      expect(payload['payload_type'], ChatMessagePayload.payloadType);
      expect(decoded.recipient.id, 'responder-1');
      expect(decoded.body, 'Are you able to reach the evacuation point?');
      expect(decoded.messageHash, ChatMessagePayload.messageHash(message));
    },
  );

  test('chat hash ignores mutable relay hop count', () {
    final message = _message();
    final relayed = ChatMessagePayload.payloadJsonForRelay(
      ChatMessagePayload.canonicalJson(message),
      hopCount: 3,
    );
    final decoded = ChatMessagePayload.fromPayload(
      jsonDecode(relayed) as Map<String, Object?>,
    );

    expect(decoded.hopCount, 3);
    expect(decoded.messageHash, ChatMessagePayload.messageHash(message));
  });

  test('keeps chat schema version 1 readable with stable hash', () {
    final payload = <String, Object?>{
      'schema_version': 1,
      'payload_type': 'chat_message',
      'message_id': 'legacy-chat-v1',
      'conversation_id': 'conversation-legacy-peer-responder-1',
      'body': 'Legacy chat body',
      'related_sos_message_hash': null,
      'routing': {'hop_count': 0, 'ttl': 7200},
      'timestamp': {'created_at': '2026-06-01T02:03:04.000Z'},
      'sender': {
        'peer_id': 'legacy-peer',
        'peer_name': 'Legacy Peer',
        'peer_type': 'civilian',
      },
      'recipient': {
        'peer_id': 'responder-1',
        'peer_name': 'Responder 1',
        'peer_type': 'responder',
      },
    };
    const expectedHash =
        'b48f3b4d31be5ccd101275bfb6600028c454e4fb7cd2a6dbb7f9eea355e58ed8';
    expect(ChatMessagePayload.hashPayload(jsonEncode(payload)), expectedHash);
    payload['message_hash'] = expectedHash;

    final decoded = ChatMessagePayload.fromPayload(payload);

    expect(decoded.id, 'legacy-chat-v1');
    expect(decoded.body, 'Legacy chat body');
    expect(decoded.sender.id, 'legacy-peer');
    expect(decoded.recipient.id, 'responder-1');
    expect(decoded.messageHash, expectedHash);
    expect(decoded.ttl, const Duration(hours: 2));
  });

  test('rejects unsupported future chat schema versions', () {
    expect(
      () => ChatMessagePayload.fromPayload(const {
        'schema_version': 2,
        'payload_type': 'chat_message',
      }),
      throwsFormatException,
    );
  });
}

ChatMessage _message() {
  return ChatMessage(
    id: 'chat-1',
    conversationId: 'conversation-node-a-responder-1',
    sender: const Peer(
      id: 'node-a',
      name: 'Resident A',
      type: PeerType.civilian,
      isConnected: false,
    ),
    recipient: const Peer(
      id: 'responder-1',
      name: 'Responder 1',
      type: PeerType.responder,
      isConnected: false,
    ),
    body: 'Are you able to reach the evacuation point?',
    status: MessageStatus.queued,
    createdAt: DateTime.utc(2026, 5, 25, 9, 30),
    relatedSosMessageHash: 'sos-hash-1',
    ttl: const Duration(hours: 4),
  );
}
