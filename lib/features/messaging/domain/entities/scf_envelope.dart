class ScfEnvelope {
  const ScfEnvelope({
    required this.messageHash,
    required this.payloadJson,
    required this.hopCount,
    required this.receivedAt,
    required this.expiresAt,
    this.payloadType = 'sos_message',
  });

  final String messageHash;
  final String payloadJson;
  final int hopCount;
  final DateTime receivedAt;
  final DateTime expiresAt;
  final String payloadType;

  bool isExpired(DateTime now) {
    return !expiresAt.isAfter(now);
  }

  ScfEnvelope copyWith({
    String? messageHash,
    String? payloadJson,
    int? hopCount,
    DateTime? receivedAt,
    DateTime? expiresAt,
    String? payloadType,
  }) {
    return ScfEnvelope(
      messageHash: messageHash ?? this.messageHash,
      payloadJson: payloadJson ?? this.payloadJson,
      hopCount: hopCount ?? this.hopCount,
      receivedAt: receivedAt ?? this.receivedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      payloadType: payloadType ?? this.payloadType,
    );
  }
}
