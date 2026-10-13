class EnvelopeTransferResult {
  const EnvelopeTransferResult({
    required this.transport,
    required this.transferId,
    required this.acknowledged,
    required this.latencyMs,
    this.sentAt,
    this.acknowledgedAt,
    this.fallbackUsed = false,
  });

  final String transport;
  final String transferId;
  final bool acknowledged;
  final int latencyMs;
  final DateTime? sentAt;
  final DateTime? acknowledgedAt;
  final bool fallbackUsed;
}

class EnvelopeTransferException implements Exception {
  const EnvelopeTransferException({
    required this.transferId,
    required this.message,
    this.code = 'transport_failed',
    this.transport,
    this.sentAt,
    this.latencyMs,
    this.fallbackUsed = false,
  });

  final String transferId;
  final String message;
  final String code;
  final String? transport;
  final DateTime? sentAt;
  final int? latencyMs;
  final bool fallbackUsed;

  @override
  String toString() => '$code: $message';
}

class EnvelopeAcknowledgementTimeout extends EnvelopeTransferException {
  const EnvelopeAcknowledgementTimeout({
    required super.transferId,
    required super.message,
    super.transport,
    super.sentAt,
    super.latencyMs,
    super.fallbackUsed,
  }) : super(code: 'ack_timeout');
}
