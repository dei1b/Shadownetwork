import 'peer_type.dart';

class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.type,
    required this.isConnected,
    this.signalStrength,
    this.lastSeenAt,
    this.latitude,
    this.longitude,
    this.transport,
  });

  final String id;
  final String name;
  final PeerType type;
  final bool isConnected;
  final int? signalStrength;
  final DateTime? lastSeenAt;
  final double? latitude;
  final double? longitude;
  final String? transport;

  Peer copyWith({
    String? id,
    String? name,
    PeerType? type,
    bool? isConnected,
    int? signalStrength,
    DateTime? lastSeenAt,
    double? latitude,
    double? longitude,
    String? transport,
  }) {
    return Peer(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      isConnected: isConnected ?? this.isConnected,
      signalStrength: signalStrength ?? this.signalStrength,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      transport: transport ?? this.transport,
    );
  }
}
