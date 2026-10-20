import 'dart:convert';

import 'chat_message_payload.dart';
import 'secure_chat_message_payload.dart';
import 'secure_sos_message_payload.dart';
import 'sos_message_payload.dart';

class RelayPayloadCodec {
  const RelayPayloadCodec._();

  static const sosPayloadType = 'sos_message';

  static String payloadType(String payloadJson) {
    final payload = jsonDecode(payloadJson) as Map<String, Object?>;
    return (payload['payload_type'] as String?) ?? sosPayloadType;
  }

  static String hashPayload(String payloadJson) {
    final payload = jsonDecode(payloadJson) as Map<String, Object?>;
    final type = (payload['payload_type'] as String?) ?? sosPayloadType;
    final version = payload['schema_version'];
    if (type == ChatMessagePayload.payloadType &&
        SecureChatMessagePayload.supportsVersion(version)) {
      return SecureChatMessagePayload.hashPayload(payloadJson);
    }
    if (type == sosPayloadType &&
        SecureSosMessagePayload.supportsVersion(version)) {
      return SecureSosMessagePayload.hashPayload(payloadJson);
    }
    return type == ChatMessagePayload.payloadType
        ? ChatMessagePayload.hashPayload(payloadJson)
        : SosMessagePayload.hashPayload(payloadJson);
  }

  static String? senderPeerId(String payloadJson) {
    final payload = jsonDecode(payloadJson) as Map<String, Object?>;
    final sender = payload['sender'];
    if (sender is! Map) {
      return null;
    }
    return sender['peer_id'] as String?;
  }

  static DateTime? createdAt(String payloadJson) {
    final payload = jsonDecode(payloadJson) as Map<String, Object?>;
    final timestamp = payload['timestamp'];
    if (timestamp is! Map) {
      return null;
    }
    final source = timestamp['created_at'] as String?;
    return source == null ? null : DateTime.tryParse(source)?.toUtc();
  }

  /// Signed TTL is anchored at creation, never extended by a relay's envelope.
  static DateTime? signedExpiry(String payloadJson) {
    final payload = jsonDecode(payloadJson) as Map<String, Object?>;
    final signed =
        (payload['payload_type'] == sosPayloadType &&
            payload['schema_version'] ==
                SecureSosMessagePayload.signedSchemaVersion) ||
        (payload['payload_type'] == ChatMessagePayload.payloadType &&
            payload['schema_version'] ==
                SecureChatMessagePayload.signedSchemaVersion);
    if (!signed) return null;
    final seconds = (payload['routing'] as Map)['ttl'];
    final created = createdAt(payloadJson);
    if (seconds is! int || seconds <= 0 || created == null) {
      throw const FormatException(
        'Signed message TTL or timestamp is invalid.',
      );
    }
    return created.add(Duration(seconds: seconds));
  }

  static String payloadJsonForRelay(
    String payloadJson, {
    required int hopCount,
  }) {
    final payload = jsonDecode(payloadJson) as Map<String, Object?>;
    final type = (payload['payload_type'] as String?) ?? sosPayloadType;
    final version = payload['schema_version'];
    if (type == ChatMessagePayload.payloadType &&
        SecureChatMessagePayload.supportsVersion(version)) {
      return SecureChatMessagePayload.payloadJsonForRelay(
        payloadJson,
        hopCount: hopCount,
      );
    }
    if (type == sosPayloadType &&
        SecureSosMessagePayload.supportsVersion(version)) {
      return SecureSosMessagePayload.payloadJsonForRelay(
        payloadJson,
        hopCount: hopCount,
      );
    }
    return type == ChatMessagePayload.payloadType
        ? ChatMessagePayload.payloadJsonForRelay(
            payloadJson,
            hopCount: hopCount,
          )
        : SosMessagePayload.payloadJsonForRelay(
            payloadJson,
            hopCount: hopCount,
          );
  }
}
