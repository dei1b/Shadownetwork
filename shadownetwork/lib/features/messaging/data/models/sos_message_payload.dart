import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/entities/category.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';
import '../../domain/entities/sos_message.dart';

class SosMessagePayload {
  const SosMessagePayload._();

  static const int schemaVersion = 1;

  static Map<String, Object?> toPayload(SosMessage message) {
    return {
      'schema_version': schemaVersion,
      'id': message.id,
      'sender': _peerPayload(message.sender),
      'body': message.body.trim(),
      'category': message.category.name,
      'created_at': _timestamp(message.createdAt),
      'latitude': message.latitude,
      'longitude': message.longitude,
    };
  }

  static SosMessage fromPayload(Map<String, Object?> payload) {
    final version = payload['schema_version'];
    if (version != schemaVersion) {
      throw FormatException('Unsupported SOS payload schema: $version.');
    }

    return SosMessage(
      id: payload['id']! as String,
      sender: _peerFromPayload(payload['sender']! as Map<String, Object?>),
      body: payload['body']! as String,
      category: Category.values.byName(payload['category']! as String),
      status: MessageStatus.received,
      createdAt: DateTime.parse(payload['created_at']! as String),
      latitude: payload['latitude'] as double?,
      longitude: payload['longitude'] as double?,
    );
  }

  static String canonicalJson(SosMessage message) {
    return jsonEncode(toPayload(message));
  }

  static String messageHash(SosMessage message) {
    return hashPayload(canonicalJson(message));
  }

  static String hashPayload(String canonicalPayload) {
    return sha256.convert(utf8.encode(canonicalPayload)).toString();
  }

  static Map<String, Object?> _peerPayload(Peer peer) {
    return {
      'id': peer.id,
      'name': peer.name.trim(),
      'type': peer.type.name,
      'latitude': peer.latitude,
      'longitude': peer.longitude,
    };
  }

  static Peer _peerFromPayload(Map<String, Object?> payload) {
    return Peer(
      id: payload['id']! as String,
      name: payload['name']! as String,
      type: PeerType.values.byName(payload['type']! as String),
      isConnected: false,
      latitude: payload['latitude'] as double?,
      longitude: payload['longitude'] as double?,
    );
  }

  static String _timestamp(DateTime value) {
    return value.toUtc().toIso8601String();
  }
}
