import '../../domain/entities/category.dart';
import '../../domain/entities/message_moderation_status.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';
import '../../domain/entities/sos_message.dart';
import 'sos_message_payload.dart';

class SosMessageModel {
  const SosMessageModel._();

  static SosMessage fromMap(Map<String, Object?> map) {
    return SosMessage(
      id: map['id']! as String,
      sender: Peer(
        id: map['sender_peer_id']! as String,
        name: map['sender_display_name']! as String,
        type: PeerType.values.byName(map['sender_peer_type']! as String),
        isConnected: (map['sender_is_connected']! as int) == 1,
        signalStrength: map['sender_signal_strength'] as int?,
        lastSeenAt: _dateTimeFromMap(map['sender_last_seen_at']),
        latitude: map['sender_latitude'] as double?,
        longitude: map['sender_longitude'] as double?,
      ),
      body: map['body']! as String,
      category: Category.values.byName(map['category_code']! as String),
      status: MessageStatus.values.byName(map['status']! as String),
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: _dateTimeFromMap(map['updated_at']),
      messageHash: map['message_hash'] as String?,
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      gpsAccuracyMeters: map['gps_accuracy_meters'] as double?,
      hopCount: (map['hop_count'] as num?)?.toInt() ?? 0,
      ttl: Duration(seconds: (map['ttl_seconds'] as num?)?.toInt() ?? 86400),
      recipient: map['recipient_peer_id'] == null
          ? null
          : Peer(
              id: map['recipient_peer_id']! as String,
              name:
                  (map['recipient_display_name'] as String?) ??
                  map['recipient_peer_id']! as String,
              type: PeerType.values.byName(
                (map['recipient_peer_type'] as String?) ??
                    PeerType.unknown.name,
              ),
              isConnected: (map['recipient_is_connected'] as int? ?? 0) == 1,
              signalStrength: map['recipient_signal_strength'] as int?,
              lastSeenAt: _dateTimeFromMap(map['recipient_last_seen_at']),
              latitude: map['recipient_latitude'] as double?,
              longitude: map['recipient_longitude'] as double?,
            ),
      isEncrypted: (map['is_encrypted'] as int? ?? 0) == 1,
      moderationStatus: MessageModerationStatus.values.byName(
        (map['moderation_status'] as String?) ??
            MessageModerationStatus.normal.name,
      ),
      moderationReason: map['moderation_reason'] as String?,
      moderationScore: (map['moderation_score'] as num?)?.toDouble(),
    );
  }

  static Map<String, Object?> toMap(SosMessage message) {
    return {
      'id': message.id,
      'sender_peer_id': message.sender.id,
      'body': message.body,
      'category_code': message.category.name,
      'status': message.status.name,
      'message_hash':
          message.messageHash ?? SosMessagePayload.messageHash(message),
      'latitude': message.latitude,
      'longitude': message.longitude,
      'gps_accuracy_meters': message.gpsAccuracyMeters,
      'hop_count': message.hopCount,
      'ttl_seconds': message.ttl.inSeconds,
      'recipient_peer_id': message.recipient?.id,
      'is_encrypted': message.isEncrypted ? 1 : 0,
      'moderation_status': message.moderationStatus.name,
      'moderation_reason': message.moderationReason,
      'moderation_score': message.moderationScore,
      'created_at': message.createdAt.toIso8601String(),
      'updated_at': message.updatedAt?.toIso8601String(),
    };
  }

  static DateTime? _dateTimeFromMap(Object? value) {
    if (value == null) {
      return null;
    }

    return DateTime.parse(value as String);
  }
}
