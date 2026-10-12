import '../../domain/entities/scf_envelope.dart';

class ScfEnvelopeModel {
  const ScfEnvelopeModel._();

  static ScfEnvelope fromMap(Map<String, Object?> map) {
    return ScfEnvelope(
      messageHash: map['message_hash']! as String,
      payloadJson: map['payload_json']! as String,
      hopCount: map['hop_count']! as int,
      receivedAt: DateTime.parse(map['received_at']! as String),
      expiresAt: DateTime.parse(map['expires_at']! as String),
      payloadType: (map['payload_type'] as String?) ?? 'sos_message',
    );
  }

  static Map<String, Object?> toMap(ScfEnvelope envelope) {
    return {
      'message_hash': envelope.messageHash,
      'payload_json': envelope.payloadJson,
      'hop_count': envelope.hopCount,
      'received_at': envelope.receivedAt.toUtc().toIso8601String(),
      'expires_at': envelope.expiresAt.toUtc().toIso8601String(),
      'payload_type': envelope.payloadType,
    };
  }
}
