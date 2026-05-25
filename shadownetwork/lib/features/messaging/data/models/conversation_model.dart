import '../../domain/entities/conversation.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';

class ConversationModel {
  const ConversationModel._();

  static Conversation fromMap(Map<String, Object?> map) {
    final latestStatus = map['latest_status'] as String?;
    return Conversation(
      id: map['id']! as String,
      localPeerId: map['local_peer_id']! as String,
      remotePeer: Peer(
        id: map['remote_peer_id']! as String,
        name: map['remote_display_name']! as String,
        type: PeerType.values.byName(map['remote_peer_type']! as String),
        isConnected: (map['remote_is_connected']! as int) == 1,
        signalStrength: map['remote_signal_strength'] as int?,
        lastSeenAt: _dateTime(map['remote_last_seen_at']),
        latitude: map['remote_latitude'] as double?,
        longitude: map['remote_longitude'] as double?,
      ),
      relatedSosMessageHash: map['related_sos_message_hash'] as String?,
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: DateTime.parse(map['updated_at']! as String),
      lastMessageAt: _dateTime(map['last_message_at']),
      unreadCount: map['unread_count']! as int,
      latestBody: map['latest_body'] as String?,
      latestStatus: latestStatus == null
          ? null
          : MessageStatus.values.byName(latestStatus),
    );
  }

  static DateTime? _dateTime(Object? value) =>
      value == null ? null : DateTime.parse(value as String);
}
