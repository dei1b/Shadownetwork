import 'dart:convert';

import 'chat_message_payload.dart';
import 'sos_message_payload.dart';

class RelayPayloadCodec {
  const RelayPayloadCodec._();

  static const sosPayloadType = 'sos_message';

  static String payloadType(String payloadJson) {
    final payload = jsonDecode(payloadJson) as Map<String, Object?>;
    return (payload['payload_type'] as String?) ?? sosPayloadType;
  }

  static String hashPayload(String payloadJson) {
    return switch (payloadType(payloadJson)) {
      ChatMessagePayload.payloadType => ChatMessagePayload.hashPayload(
        payloadJson,
      ),
      _ => SosMessagePayload.hashPayload(payloadJson),
    };
  }

  static String payloadJsonForRelay(
    String payloadJson, {
    required int hopCount,
  }) {
    return switch (payloadType(payloadJson)) {
      ChatMessagePayload.payloadType => ChatMessagePayload.payloadJsonForRelay(
        payloadJson,
        hopCount: hopCount,
      ),
      _ => SosMessagePayload.payloadJsonForRelay(
        payloadJson,
        hopCount: hopCount,
      ),
    };
  }
}
