import '../../domain/entities/chat_message.dart';
import '../../domain/entities/message_moderation_status.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';
import 'chat_message_payload.dart';
import '../../../trust/domain/entities/device_trust_status.dart';

class ChatMessageModel {
  const ChatMessageModel._();

  static ChatMessage fromMap(Map<String, Object?> map) {
    return ChatMessage(
      id: map['id']! as String,
      messageHash: map['message_hash']! as String,
      conversationId: map['conversation_id']! as String,
      sender: _peer(map, 'sender'),
      recipient: _peer(map, 'recipient'),
      body: map['body']! as String,
      status: MessageStatus.values.byName(map['status']! as String),
      relatedSosMessageHash: map['related_sos_message_hash'] as String?,
      hopCount: (map['hop_count']! as num).toInt(),
      ttl: Duration(seconds: (map['ttl_seconds']! as num).toInt()),
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: map['updated_at'] == null
          ? null
          : DateTime.parse(map['updated_at']! as String),
      moderationStatus: MessageModerationStatus.values.byName(
        (map['moderation_status'] as String?) ??
            MessageModerationStatus.normal.name,
      ),
      moderationReason: map['moderation_reason'] as String?,
      moderationScore: (map['moderation_score'] as num?)?.toDouble(),
      trustStatus: DeviceTrustStatus.values.byName(
        (map['trust_status'] as String?) ?? DeviceTrustStatus.unknown.name,
      ),
      trustRole: map['trust_role'] as String?,
      trustOwnerName: map['trust_owner_name'] as String?,
    );
  }

  static Map<String, Object?> toMap(ChatMessage message) => {
    'id': message.id,
    'message_hash':
        message.messageHash ?? ChatMessagePayload.messageHash(message),
    'conversation_id': message.conversationId,
    'sender_peer_id': message.sender.id,
    'recipient_peer_id': message.recipient.id,
    'body': message.body.trim(),
    'status': message.status.name,
    'related_sos_message_hash': message.relatedSosMessageHash,
    'hop_count': message.hopCount,
    'ttl_seconds': message.ttl.inSeconds,
    'moderation_status': message.moderationStatus.name,
    'moderation_reason': message.moderationReason,
    'moderation_score': message.moderationScore,
    'trust_status': message.trustStatus.name,
    'trust_role': message.trustRole,
    'trust_owner_name': message.trustOwnerName,
    'created_at': message.createdAt.toUtc().toIso8601String(),
    'updated_at': message.updatedAt?.toUtc().toIso8601String(),
  };

  static Peer _peer(Map<String, Object?> map, String prefix) => Peer(
    id: map['${prefix}_peer_id']! as String,
    name: map['${prefix}_display_name']! as String,
    type: PeerType.values.byName(map['${prefix}_peer_type']! as String),
    isConnected: (map['${prefix}_is_connected']! as int) == 1,
    signalStrength: map['${prefix}_signal_strength'] as int?,
    lastSeenAt: map['${prefix}_last_seen_at'] == null
        ? null
        : DateTime.parse(map['${prefix}_last_seen_at']! as String),
  );
}
