import '../../domain/entities/category.dart';
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
    );
  }

  static Map<String, Object?> toMap(SosMessage message) {
    return {
      'id': message.id,
      'sender_peer_id': message.sender.id,
      'body': message.body,
      'category_code': message.category.name,
      'status': message.status.name,
      'message_hash': message.messageHash ?? SosMessagePayload.messageHash(message),
      'latitude': message.latitude,
      'longitude': message.longitude,
      'gps_accuracy_meters': message.gpsAccuracyMeters,
      'hop_count': message.hopCount,
      'ttl_seconds': message.ttl.inSeconds,
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
