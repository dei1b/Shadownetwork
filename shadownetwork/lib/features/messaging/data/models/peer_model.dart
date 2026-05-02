import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';

class PeerModel {
  const PeerModel._();

  static Peer fromMap(Map<String, Object?> map) {
    return Peer(
      id: map['id']! as String,
      name: map['display_name']! as String,
      type: PeerType.values.byName(map['peer_type_code']! as String),
      isConnected: (map['is_connected']! as int) == 1,
      signalStrength: map['signal_strength'] as int?,
      lastSeenAt: _dateTimeFromMap(map['last_seen_at']),
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
    );
  }

  static Map<String, Object?> toMap(Peer peer, {DateTime? timestamp}) {
    final now = timestamp ?? DateTime.now();

    return {
      'id': peer.id,
      'display_name': peer.name,
      'peer_type_code': peer.type.name,
      'is_connected': peer.isConnected ? 1 : 0,
      'signal_strength': peer.signalStrength,
      'last_seen_at': peer.lastSeenAt?.toIso8601String(),
      'latitude': peer.latitude,
      'longitude': peer.longitude,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    };
  }

  static DateTime? _dateTimeFromMap(Object? value) {
    if (value == null) {
      return null;
    }

    return DateTime.parse(value as String);
  }
}
