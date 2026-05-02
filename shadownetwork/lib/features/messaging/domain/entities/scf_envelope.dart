class ScfEnvelope {
  const ScfEnvelope({
    required this.messageHash,
    required this.payloadJson,
    required this.hopCount,
    required this.receivedAt,
    required this.expiresAt,
  });

  final String messageHash;
  final String payloadJson;
  final int hopCount;
  final DateTime receivedAt;
  final DateTime expiresAt;

  bool isExpired(DateTime now) {
    return !expiresAt.isAfter(now);
  }

  ScfEnvelope copyWith({
    String? messageHash,
    String? payloadJson,
    int? hopCount,
    DateTime? receivedAt,
    DateTime? expiresAt,
  }) {
    return ScfEnvelope(
      messageHash: messageHash ?? this.messageHash,
      payloadJson: payloadJson ?? this.payloadJson,
      hopCount: hopCount ?? this.hopCount,
      receivedAt: receivedAt ?? this.receivedAt,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }
}
