import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../security/data/services/message_encryption_service.dart';
import '../../../security/domain/entities/device_crypto_identity.dart';
import '../../../security/domain/entities/encrypted_message_body.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';
import 'chat_message_payload.dart';
import 'prepared_relay_payload.dart';

class SecureChatMessagePayload {
  const SecureChatMessagePayload._();

  static const schemaVersion = 2;

  static Future<PreparedRelayPayload> prepare(
    ChatMessage message, {
    required MessageEncryptionService encryptionService,
    required String recipientPublicKey,
    int recipientKeyVersion = 1,
  }) async {
    if (recipientPublicKey.trim().isEmpty) {
      throw MissingRecipientPublicKeyException(message.recipient.id);
    }
    final basePayload = _basePayload(message, hopCount: message.hopCount);
    final encryptedBody = await encryptionService.encrypt(
      plainText: message.body.trim(),
      recipientPublicKey: recipientPublicKey,
      recipientKeyVersion: recipientKeyVersion,
      authenticatedData: _authenticatedData(basePayload),
    );
    final payload = <String, Object?>{
      ...basePayload,
      'body': null,
      'security': encryptedBody.toJson(),
    };
    final hash = _hashMap(payload);
    return PreparedRelayPayload(
      payloadJson: jsonEncode({...payload, 'message_hash': hash}),
      hash: hash,
    );
  }

  static Future<ChatMessage> decode(
    Map<String, Object?> payload, {
    required String localPeerId,
    required MessageEncryptionService encryptionService,
    required DeviceCryptoIdentity localIdentity,
  }) async {
    if (payload['payload_type'] != ChatMessagePayload.payloadType ||
        payload['schema_version'] != schemaVersion) {
      throw const FormatException('Unsupported secure chat payload.');
    }
    final hash = payload['message_hash'] as String?;
    if (hash == null || hash != _hashMap(payload)) {
      throw const FormatException('Chat payload message hash is invalid.');
    }
    final recipient = _peerFromPayload(
      payload['recipient']! as Map<String, Object?>,
    );
    if (recipient.id != localPeerId) {
      throw const FormatException(
        'Encrypted chat payload is for another peer.',
      );
    }
    final body = await encryptionService.decrypt(
      encryptedBody: EncryptedMessageBody.fromJson(
        payload['security']! as Map<String, Object?>,
      ),
      localIdentity: localIdentity,
      authenticatedData: _authenticatedData(payload),
    );
    final routing = payload['routing']! as Map<String, Object?>;
    final timestamp = payload['timestamp']! as Map<String, Object?>;

    return ChatMessage(
      id: payload['message_id']! as String,
      conversationId: payload['conversation_id']! as String,
      sender: _peerFromPayload(payload['sender']! as Map<String, Object?>),
      recipient: recipient,
      body: body,
      status: MessageStatus.received,
      createdAt: DateTime.parse(timestamp['created_at']! as String),
      messageHash: hash,
      relatedSosMessageHash: payload['related_sos_message_hash'] as String?,
      hopCount: (routing['hop_count']! as num).toInt(),
      ttl: Duration(seconds: (routing['ttl']! as num).toInt()),
    );
  }

  static String hashPayload(String payloadJson) {
    final payload = jsonDecode(payloadJson);
    if (payload is! Map<String, Object?> ||
        payload['schema_version'] != schemaVersion ||
        payload['payload_type'] != ChatMessagePayload.payloadType) {
      throw const FormatException('Unsupported secure chat payload.');
    }
    return _hashMap(payload);
  }

  static String payloadJsonForRelay(
    String payloadJson, {
    required int hopCount,
  }) {
    final payload = jsonDecode(payloadJson) as Map<String, Object?>;
    final routing = Map<String, Object?>.from(
      payload['routing']! as Map<String, Object?>,
    );
    routing['hop_count'] = hopCount;
    payload['routing'] = routing;
    return jsonEncode(payload);
  }

  static Map<String, Object?> _basePayload(
    ChatMessage message, {
    required int hopCount,
  }) => {
    'schema_version': schemaVersion,
    'payload_type': ChatMessagePayload.payloadType,
    'message_id': message.id,
    'conversation_id': message.conversationId,
    'related_sos_message_hash': message.relatedSosMessageHash,
    'routing': {'hop_count': hopCount, 'ttl': message.ttl.inSeconds},
    'timestamp': {'created_at': message.createdAt.toUtc().toIso8601String()},
    'sender': _peerPayload(message.sender),
    'recipient': _peerPayload(message.recipient),
  };

  static String _authenticatedData(Map<String, Object?> payload) {
    final routing = payload['routing']! as Map<String, Object?>;
    return jsonEncode({
      'schema_version': schemaVersion,
      'payload_type': ChatMessagePayload.payloadType,
      'message_id': payload['message_id'],
      'conversation_id': payload['conversation_id'],
      'related_sos_message_hash': payload['related_sos_message_hash'],
      'routing': {'ttl': routing['ttl']},
      'timestamp': payload['timestamp'],
      'sender': payload['sender'],
      'recipient': payload['recipient'],
    });
  }

  static String _hashMap(Map<String, Object?> payload) {
    final routing = payload['routing']! as Map<String, Object?>;
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'schema_version': schemaVersion,
              'payload_type': ChatMessagePayload.payloadType,
              'message_id': payload['message_id'],
              'conversation_id': payload['conversation_id'],
              'body': null,
              'related_sos_message_hash': payload['related_sos_message_hash'],
              'routing': {'hop_count': 0, 'ttl': routing['ttl']},
              'timestamp': payload['timestamp'],
              'sender': payload['sender'],
              'recipient': payload['recipient'],
              'security': payload['security'],
            }),
          ),
        )
        .toString();
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
