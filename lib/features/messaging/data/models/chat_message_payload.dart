import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/entities/chat_message.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';

class ChatMessagePayload {
  const ChatMessagePayload._();

  static const payloadType = 'chat_message';
  static const schemaVersion = 1;

  static Map<String, Object?> toPayload(ChatMessage message) {
    final payload = _hashablePayload(message, hopCount: message.hopCount);
    return {...payload, 'message_hash': messageHash(message)};
  }

  static String canonicalJson(ChatMessage message) {
    return jsonEncode(toPayload(message));
  }

  static String messageHash(ChatMessage message) {
    return sha256
        .convert(
          utf8.encode(
            _canonicalHashJson(_hashablePayload(message, hopCount: 0)),
          ),
        )
        .toString();
  }

  static String hashPayload(String payloadJson) {
    final payload = jsonDecode(payloadJson);
    if (payload is! Map<String, Object?> ||
        payload['payload_type'] != payloadType ||
        payload['schema_version'] != schemaVersion) {
      throw const FormatException('Unsupported chat payload.');
    }
    return sha256.convert(utf8.encode(_canonicalHashJson(payload))).toString();
  }

  static ChatMessage fromPayload(Map<String, Object?> payload) {
    if (payload['payload_type'] != payloadType ||
        payload['schema_version'] != schemaVersion) {
      throw const FormatException('Unsupported chat payload.');
    }
    final hash = payload['message_hash'] as String?;
    if (hash == null || hash != hashPayload(jsonEncode(payload))) {
      throw const FormatException('Chat payload message hash is invalid.');
    }
    final routing = payload['routing']! as Map<String, Object?>;
    final timestamp = payload['timestamp']! as Map<String, Object?>;
    return ChatMessage(
      id: payload['message_id']! as String,
      conversationId: payload['conversation_id']! as String,
      sender: _peerFromPayload(payload['sender']! as Map<String, Object?>),
      recipient: _peerFromPayload(
        payload['recipient']! as Map<String, Object?>,
      ),
      body: payload['body']! as String,
      status: MessageStatus.received,
      createdAt: DateTime.parse(timestamp['created_at']! as String),
      messageHash: hash,
      relatedSosMessageHash: payload['related_sos_message_hash'] as String?,
      hopCount: (routing['hop_count']! as num).toInt(),
      ttl: Duration(seconds: (routing['ttl']! as num).toInt()),
    );
  }

  static String payloadJsonForRelay(
    String payloadJson, {
    required int hopCount,
  }) {
    final message = fromPayload(
      jsonDecode(payloadJson) as Map<String, Object?>,
    );
    return canonicalJson(message.copyWith(hopCount: hopCount));
  }

  static Map<String, Object?> _hashablePayload(
    ChatMessage message, {
    required int hopCount,
  }) {
    return {
      'schema_version': schemaVersion,
      'payload_type': payloadType,
      'message_id': message.id,
      'conversation_id': message.conversationId,
      'body': message.body.trim(),
      'related_sos_message_hash': message.relatedSosMessageHash,
      'routing': {'hop_count': hopCount, 'ttl': message.ttl.inSeconds},
      'timestamp': {'created_at': message.createdAt.toUtc().toIso8601String()},
      'sender': _peerPayload(message.sender),
      'recipient': _peerPayload(message.recipient),
    };
  }

  static String _canonicalHashJson(Map<String, Object?> payload) {
    final routing = payload['routing']! as Map<String, Object?>;
    final timestamp = payload['timestamp']! as Map<String, Object?>;
    return jsonEncode({
      'schema_version': schemaVersion,
      'payload_type': payloadType,
      'message_id': payload['message_id'],
      'conversation_id': payload['conversation_id'],
      'body': payload['body'],
      'related_sos_message_hash': payload['related_sos_message_hash'],
      'routing': {'hop_count': 0, 'ttl': routing['ttl']},
      'timestamp': {'created_at': timestamp['created_at']},
      'sender': payload['sender'],
      'recipient': payload['recipient'],
    });
  }

  static Map<String, Object?> _peerPayload(Peer peer) => {
    'peer_id': peer.id,
    'peer_name': peer.name.trim(),
    'peer_type': peer.type.name,
  };

  static Peer _peerFromPayload(Map<String, Object?> payload) => Peer(
    id: payload['peer_id']! as String,
    name: payload['peer_name']! as String,
    type: PeerType.values.byName(
      (payload['peer_type'] ?? PeerType.unknown.name) as String,
    ),
    isConnected: false,
  );
}
