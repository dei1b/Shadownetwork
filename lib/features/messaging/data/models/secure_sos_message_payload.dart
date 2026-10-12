import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../security/data/services/message_encryption_service.dart';
import '../../../security/domain/entities/device_crypto_identity.dart';
import '../../../security/domain/entities/encrypted_message_body.dart';
import '../../domain/entities/category.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';
import '../../domain/entities/sos_message.dart';
import 'prepared_relay_payload.dart';

class SecureSosMessagePayload {
  const SecureSosMessagePayload._();

  static const schemaVersion = 4;

  static Future<PreparedRelayPayload> prepare(
    SosMessage message, {
    required MessageEncryptionService encryptionService,
    String? recipientPublicKey,
    int recipientKeyVersion = 1,
  }) async {
    final basePayload = _basePayload(message, hopCount: message.hopCount);
    final recipient = message.recipient;
    final Map<String, Object?> security;
    if (recipient == null) {
      security = const {
        'encrypted': false,
        'protocol_version': MessageEncryptionService.protocolVersion,
      };
    } else {
      final publicKey = recipientPublicKey?.trim();
      if (publicKey == null || publicKey.isEmpty) {
        throw MissingRecipientPublicKeyException(recipient.id);
      }
      final encryptedBody = await encryptionService.encrypt(
        plainText: message.body.trim(),
        recipientPublicKey: publicKey,
        recipientKeyVersion: recipientKeyVersion,
        authenticatedData: _authenticatedData(basePayload),
      );
      security = encryptedBody.toJson();
    }

    final payload = <String, Object?>{
      ...basePayload,
      'payload_text': recipient == null ? message.body.trim() : null,
      'security': security,
    };
    final hash = _hashMap(payload);
    return PreparedRelayPayload(
      payloadJson: jsonEncode({...payload, 'message_hash': hash}),
      hash: hash,
    );
  }

  static Future<SosMessage> decode(
    Map<String, Object?> payload, {
    required String localPeerId,
    required MessageEncryptionService encryptionService,
    required DeviceCryptoIdentity localIdentity,
  }) async {
    if (payload['schema_version'] != schemaVersion) {
      throw const FormatException('Unsupported secure SOS payload.');
    }
    final hash = payload['message_hash'] as String?;
    if (hash == null || hash != _hashMap(payload)) {
      throw const FormatException('SOS payload message hash is invalid.');
    }

    final recipientPayload = payload['recipient'] as Map<String, Object?>?;
    final recipient = recipientPayload == null
        ? null
        : _peerFromPayload(recipientPayload);
    final security = payload['security']! as Map<String, Object?>;
    final encrypted = security['encrypted'] == true;
    if (encrypted && (recipient == null || recipient.id != localPeerId)) {
      throw const FormatException('Encrypted SOS payload is for another peer.');
    }
    final body = encrypted
        ? await encryptionService.decrypt(
            encryptedBody: EncryptedMessageBody.fromJson(security),
            localIdentity: localIdentity,
            authenticatedData: _authenticatedData(payload),
          )
        : payload['payload_text']! as String;
    final location = payload['location']! as Map<String, Object?>;
    final routing = payload['routing']! as Map<String, Object?>;
    final timestamp = payload['timestamp']! as Map<String, Object?>;

    return SosMessage(
      id: payload['message_id']! as String,
      sender: _peerFromPayload(payload['sender']! as Map<String, Object?>),
      recipient: recipient,
      isEncrypted: encrypted,
      body: body,
      category: Category.values.byName(payload['category']! as String),
      status: MessageStatus.received,
      createdAt: DateTime.parse(timestamp['created_at']! as String),
      messageHash: hash,
      latitude: _doubleOrNull(location['latitude']),
      longitude: _doubleOrNull(location['longitude']),
      gpsAccuracyMeters: _doubleOrNull(location['accuracy_meters']),
      hopCount: (routing['hop_count']! as num).toInt(),
      ttl: Duration(seconds: (routing['ttl']! as num).toInt()),
    );
  }

  static String hashPayload(String payloadJson) {
    final decoded = jsonDecode(payloadJson);
    if (decoded is! Map<String, Object?> ||
        decoded['schema_version'] != schemaVersion) {
      throw const FormatException('Unsupported secure SOS payload.');
    }
    return _hashMap(decoded);
  }

  static String payloadJsonForRelay(
    String payloadJson, {
    required int hopCount,
  }) {
    final payload = jsonDecode(payloadJson) as Map<String, Object?>;
    if (payload['schema_version'] != schemaVersion) {
      throw const FormatException('Unsupported secure SOS payload.');
    }
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

  static Map<String, Object?> _basePayload(
    SosMessage message, {
    required int hopCount,
  }) => {
    'schema_version': schemaVersion,
    'payload_type': 'sos_message',
    'message_id': message.id,
    'category': message.category.name,
    'location': {
      'latitude': message.latitude,
      'longitude': message.longitude,
      'accuracy_meters': message.gpsAccuracyMeters,
    },
    'routing': {'hop_count': hopCount, 'ttl': message.ttl.inSeconds},
    'timestamp': {'created_at': message.createdAt.toUtc().toIso8601String()},
    'sender': _peerPayload(message.sender),
    'recipient': message.recipient == null
        ? null
        : _peerPayload(message.recipient!),
  };

  static String _authenticatedData(Map<String, Object?> payload) {
    final routing = payload['routing']! as Map<String, Object?>;
    return jsonEncode({
      'schema_version': schemaVersion,
      'payload_type': 'sos_message',
      'message_id': payload['message_id'],
      'category': payload['category'],
      'location': payload['location'],
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
              'payload_type': 'sos_message',
              'message_id': payload['message_id'],
              'payload_text': payload['payload_text'],
              'category': payload['category'],
              'location': payload['location'],
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

  static double? _doubleOrNull(Object? value) => switch (value) {
    null => null,
    final num number => number.toDouble(),
    _ => throw FormatException('Expected numeric payload value, got $value.'),
  };
}
