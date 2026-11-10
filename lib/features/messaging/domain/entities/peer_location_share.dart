import 'dart:convert';

import 'chat_message.dart';

class PeerLocationShare {
  const PeerLocationShare._({
    required this.peerId,
    required this.ownerName,
    required this.latitude,
    required this.longitude,
    required this.sharedAt,
    required this.expiresAt,
  });

  static const schemaVersion = 4;
  static const conversationId = 'shadow-network-location-v1';
  static const lifetime = Duration(minutes: 15);
  static const maxAge = Duration(minutes: 2);

  final String peerId;
  final String ownerName;
  final double latitude;
  final double longitude;
  final DateTime sharedAt;
  final DateTime expiresAt;

  static bool hasValidCoordinates(double latitude, double longitude) =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180;

  static String encodePosition(double latitude, double longitude) {
    if (!hasValidCoordinates(latitude, longitude)) {
      throw const FormatException('The GPS position is invalid.');
    }
    return jsonEncode({'latitude': latitude, 'longitude': longitude});
  }

  static PeerLocationShare fromChat(
    ChatMessage message, {
    required String ownerName,
    required DateTime now,
    required DateTime expiresAt,
  }) {
    final sharedAt = message.createdAt.toUtc();
    final signedExpiry = sharedAt.add(lifetime);
    final expiry = expiresAt.isBefore(signedExpiry) ? expiresAt : signedExpiry;
    if (message.conversationId != conversationId ||
        message.ttl != lifetime ||
        sharedAt.isAfter(now.add(maxAge)) ||
        !expiry.isAfter(now)) {
      throw const FormatException(
        'Location share timing is invalid or expired.',
      );
    }
    final decoded = jsonDecode(message.body);
    if (decoded is! Map ||
        decoded['latitude'] is! num ||
        decoded['longitude'] is! num) {
      throw const FormatException('Location share coordinates are missing.');
    }
    final latitude = (decoded['latitude'] as num).toDouble();
    final longitude = (decoded['longitude'] as num).toDouble();
    if (!hasValidCoordinates(latitude, longitude)) {
      throw const FormatException('Location share coordinates are invalid.');
    }
    return PeerLocationShare._(
      peerId: message.sender.id,
      ownerName: ownerName,
      latitude: latitude,
      longitude: longitude,
      sharedAt: sharedAt,
      expiresAt: expiry,
    );
  }
}
