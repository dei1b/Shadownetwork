import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/entities/category.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';
import '../../domain/entities/sos_message.dart';
import 'sos_payload_crypto.dart';

class SosMessagePayload {
  const SosMessagePayload._();

  static const int schemaVersion = 3;
  static const Duration defaultTtl = Duration(hours: 24);

  static Map<String, Object?> toPayload(SosMessage message) {
    final messageHash = _hashV2Payload(message);
    final recipient = message.recipient;
    final createdAt = _timestamp(message.createdAt);
    final encrypted = recipient == null
        ? null
        : SosPayloadCrypto.encrypt(
            plainText: message.body.trim(),
            messageId: message.id,
            senderPeerId: message.sender.id,
            recipientPeerId: recipient.id,
            createdAt: createdAt,
          );

    return {
      'schema_version': schemaVersion,
      'message_hash': messageHash,
      'message_id': message.id,
      'payload_text': recipient == null ? message.body.trim() : null,
      'category': message.category.name,
      'location': {
        'latitude': message.latitude,
        'longitude': message.longitude,
        'accuracy_meters': message.gpsAccuracyMeters,
      },
      'routing': {'hop_count': message.hopCount, 'ttl': message.ttl.inSeconds},
      'timestamp': {'created_at': createdAt},
      'sender': _peerPayload(message.sender),
      'recipient': recipient == null ? null : _peerPayload(recipient),
      'security': recipient == null
          ? {'encrypted': false}
          : {
              'encrypted': true,
              'algorithm': SosPayloadCrypto.algorithm,
              'cipher_text': encrypted!.cipherText,
              'nonce': encrypted.nonce,
              'tag': encrypted.tag,
            },
    };
  }

  static SosMessage fromPayload(
    Map<String, Object?> payload, {
    String? localPeerId,
  }) {
    final version = payload['schema_version'];
    if (version == 1) {
      return _fromLegacyPayload(payload);
    }
    if (version == 2) {
      return _fromV2Payload(payload);
    }
    if (version != schemaVersion) {
      throw FormatException('Unsupported SOS payload schema: $version.');
    }

    final messageHash = payload['message_hash'] as String?;
    final computedHash = hashPayload(jsonEncode(payload));
    if (messageHash == null || messageHash != computedHash) {
      throw const FormatException('SOS payload message hash is invalid.');
    }

    final location = payload['location']! as Map<String, Object?>;
    final routing = payload['routing']! as Map<String, Object?>;
    final timestamp = payload['timestamp']! as Map<String, Object?>;
    final sender = _peerFromPayload(payload['sender']! as Map<String, Object?>);
    final recipientPayload = payload['recipient'] as Map<String, Object?>?;
    final recipient = recipientPayload == null
        ? null
        : _peerFromPayload(recipientPayload);
    final security = payload['security'] as Map<String, Object?>?;
    final encrypted = security?['encrypted'] == true;
    final body = encrypted
        ? _decryptTargetedBody(
            security: security!,
            sender: sender,
            recipient: recipient,
            localPeerId: localPeerId,
          )
        : payload['payload_text']! as String;

    return SosMessage(
      id: payload['message_id']! as String,
      sender: sender,
      recipient: recipient,
      isEncrypted: encrypted,
      body: body,
      category: Category.values.byName(payload['category']! as String),
      status: MessageStatus.received,
      createdAt: DateTime.parse(timestamp['created_at']! as String),
      messageHash: messageHash,
      latitude: _doubleOrNull(location['latitude']),
      longitude: _doubleOrNull(location['longitude']),
      gpsAccuracyMeters: _doubleOrNull(location['accuracy_meters']),
      hopCount: (routing['hop_count']! as num).toInt(),
      ttl: Duration(seconds: (routing['ttl']! as num).toInt()),
    );
  }

  static String canonicalJson(SosMessage message) {
    return jsonEncode(toPayload(message));
  }

  static String messageHash(SosMessage message) {
    return _hashV2Payload(message);
  }

  static String hashPayload(String canonicalPayload) {
    final decoded = jsonDecode(canonicalPayload);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException(
        'SOS payload must decode into a JSON object.',
      );
    }

    final version = decoded['schema_version'];
    if (version == 1) {
      return sha256
          .convert(utf8.encode(_canonicalLegacyJson(decoded)))
          .toString();
    }
    if (version == 2) {
      return sha256
          .convert(utf8.encode(_canonicalV2HashJson(decoded)))
          .toString();
    }
    if (version != schemaVersion) {
      throw FormatException('Unsupported SOS payload schema: $version.');
    }

    return sha256
        .convert(utf8.encode(_canonicalV2HashJson(decoded)))
        .toString();
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

  static String? targetPeerId(String payloadJson) {
    final payload = jsonDecode(payloadJson) as Map<String, Object?>;
    final recipient = payload['recipient'] as Map<String, Object?>?;
    return recipient?['peer_id'] as String?;
  }

  static Map<String, Object?> _peerPayload(Peer peer) {
    return {
      'peer_id': peer.id,
      'peer_name': peer.name.trim(),
      'peer_type': peer.type.name,
    };
  }

  static Peer _peerFromPayload(Map<String, Object?> payload) {
    return Peer(
      id: payload['peer_id']! as String,
      name: payload['peer_name']! as String,
      type: PeerType.values.byName(
        (payload['peer_type'] ?? PeerType.unknown.name) as String,
      ),
      isConnected: false,
    );
  }

  static String _timestamp(DateTime value) {
    return value.toUtc().toIso8601String();
  }

  static SosMessage _fromLegacyPayload(Map<String, Object?> payload) {
    return SosMessage(
      id: payload['id']! as String,
      sender: Peer(
        id: (payload['sender']! as Map<String, Object?>)['id']! as String,
        name: (payload['sender']! as Map<String, Object?>)['name']! as String,
        type: PeerType.values.byName(
          (payload['sender']! as Map<String, Object?>)['type']! as String,
        ),
        isConnected: false,
        latitude: _doubleOrNull(
          (payload['sender']! as Map<String, Object?>)['latitude'],
        ),
        longitude: _doubleOrNull(
          (payload['sender']! as Map<String, Object?>)['longitude'],
        ),
      ),
      body: payload['body']! as String,
      category: Category.values.byName(payload['category']! as String),
      status: MessageStatus.received,
      createdAt: DateTime.parse(payload['created_at']! as String),
      latitude: _doubleOrNull(payload['latitude']),
      longitude: _doubleOrNull(payload['longitude']),
      ttl: defaultTtl,
    );
  }

  static String _hashV2Payload(SosMessage message) {
    final recipient = message.recipient;
    final createdAt = _timestamp(message.createdAt);
    final encrypted = recipient == null
        ? null
        : SosPayloadCrypto.encrypt(
            plainText: message.body.trim(),
            messageId: message.id,
            senderPeerId: message.sender.id,
            recipientPeerId: recipient.id,
            createdAt: createdAt,
          );

    return sha256
        .convert(
          utf8.encode(
            _canonicalV2HashJson({
              'schema_version': schemaVersion,
              'message_id': message.id,
              'payload_text': recipient == null ? message.body.trim() : null,
              'category': message.category.name,
              'location': {
                'latitude': message.latitude,
                'longitude': message.longitude,
                'accuracy_meters': message.gpsAccuracyMeters,
              },
              'routing': {'hop_count': 0, 'ttl': message.ttl.inSeconds},
              'timestamp': {'created_at': createdAt},
              'sender': _peerPayload(message.sender),
              'recipient': recipient == null ? null : _peerPayload(recipient),
              'security': recipient == null
                  ? {'encrypted': false}
                  : {
                      'encrypted': true,
                      'algorithm': SosPayloadCrypto.algorithm,
                      'cipher_text': encrypted!.cipherText,
                      'nonce': encrypted.nonce,
                      'tag': encrypted.tag,
                    },
            }),
          ),
        )
        .toString();
  }

  static String _canonicalV2HashJson(Map<String, Object?> payload) {
    final location = payload['location']! as Map<String, Object?>;
    final routing = payload['routing']! as Map<String, Object?>;
    final timestamp = payload['timestamp']! as Map<String, Object?>;
    final sender = payload['sender']! as Map<String, Object?>;
    final recipient = payload['recipient'] as Map<String, Object?>?;
    final security = payload['security'] as Map<String, Object?>?;

    return jsonEncode({
      'schema_version': payload['schema_version'],
      'message_id': payload['message_id'],
      'payload_text': payload['payload_text'],
      'category': payload['category'],
      'location': {
        'latitude': location['latitude'],
        'longitude': location['longitude'],
        'accuracy_meters': location['accuracy_meters'],
      },
      'routing': {'hop_count': 0, 'ttl': routing['ttl']},
      'timestamp': {'created_at': timestamp['created_at']},
      'sender': {
        'peer_id': sender['peer_id'],
        'peer_name': sender['peer_name'],
        'peer_type': sender['peer_type'],
      },
      if (payload['schema_version'] == schemaVersion) ...{
        'recipient': recipient == null
            ? null
            : {
                'peer_id': recipient['peer_id'],
                'peer_name': recipient['peer_name'],
                'peer_type': recipient['peer_type'],
              },
        'security': security == null
            ? {'encrypted': false}
            : {
                'encrypted': security['encrypted'],
                'algorithm': security['algorithm'],
                'cipher_text': security['cipher_text'],
                'nonce': security['nonce'],
                'tag': security['tag'],
              },
      },
    });
  }

  static SosMessage _fromV2Payload(Map<String, Object?> payload) {
    final messageHash = payload['message_hash'] as String?;
    final computedHash = hashPayload(jsonEncode(payload));
    if (messageHash == null || messageHash != computedHash) {
      throw const FormatException('SOS payload message hash is invalid.');
    }

    final location = payload['location']! as Map<String, Object?>;
    final routing = payload['routing']! as Map<String, Object?>;
    final timestamp = payload['timestamp']! as Map<String, Object?>;

    return SosMessage(
      id: payload['message_id']! as String,
      sender: _peerFromPayload(payload['sender']! as Map<String, Object?>),
      body: payload['payload_text']! as String,
      category: Category.values.byName(payload['category']! as String),
      status: MessageStatus.received,
      createdAt: DateTime.parse(timestamp['created_at']! as String),
      messageHash: messageHash,
      latitude: _doubleOrNull(location['latitude']),
      longitude: _doubleOrNull(location['longitude']),
      gpsAccuracyMeters: _doubleOrNull(location['accuracy_meters']),
      hopCount: (routing['hop_count']! as num).toInt(),
      ttl: Duration(seconds: (routing['ttl']! as num).toInt()),
    );
  }

  static String _decryptTargetedBody({
    required Map<String, Object?> security,
    required Peer sender,
    required Peer? recipient,
    required String? localPeerId,
  }) {
    if (recipient == null) {
      throw const FormatException(
        'Encrypted SOS payload is missing recipient.',
      );
    }
    if (localPeerId == null || localPeerId != recipient.id) {
      throw const FormatException('Encrypted SOS payload is for another peer.');
    }
    if (security['algorithm'] != SosPayloadCrypto.algorithm) {
      throw const FormatException('Unsupported SOS encryption algorithm.');
    }

    return SosPayloadCrypto.decrypt(
      cipherText: security['cipher_text']! as String,
      nonce: security['nonce']! as String,
      tag: security['tag']! as String,
      senderPeerId: sender.id,
      recipientPeerId: recipient.id,
    );
  }

  static String _canonicalLegacyJson(Map<String, Object?> payload) {
    final sender = payload['sender']! as Map<String, Object?>;
    return jsonEncode({
      'schema_version': 1,
      'id': payload['id'],
      'sender': {
        'id': sender['id'],
        'name': sender['name'],
        'type': sender['type'],
        'latitude': sender['latitude'],
        'longitude': sender['longitude'],
      },
      'body': payload['body'],
      'category': payload['category'],
      'created_at': payload['created_at'],
      'latitude': payload['latitude'],
      'longitude': payload['longitude'],
    });
  }

  static double? _doubleOrNull(Object? value) {
    return switch (value) {
      null => null,
      final num number => number.toDouble(),
      _ => throw FormatException('Expected numeric payload value, got $value.'),
    };
  }
}
