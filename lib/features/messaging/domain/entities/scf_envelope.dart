class ScfEnvelope {
  const ScfEnvelope({
    required this.messageHash,
    required this.payloadJson,
    required this.hopCount,
    required this.receivedAt,
    required this.expiresAt,
    this.payloadType = 'sos_message',
    this.receivedFromPeerId,
    this.receivedTransport,
    this.transferId,
  });

  final String messageHash;
  final String payloadJson;
  final int hopCount;
  final DateTime receivedAt;
  final DateTime expiresAt;
  final String payloadType;

  /// Inbound hop context supplied by the local transport, not the SOS origin.
  final String? receivedFromPeerId;
  final String? receivedTransport;
  final String? transferId;

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
    String? receivedFromPeerId,
    String? receivedTransport,
    String? transferId,
  }) {
    return ScfEnvelope(
      messageHash: messageHash ?? this.messageHash,
      payloadJson: payloadJson ?? this.payloadJson,
      hopCount: hopCount ?? this.hopCount,
      receivedAt: receivedAt ?? this.receivedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      payloadType: payloadType ?? this.payloadType,
      receivedFromPeerId: receivedFromPeerId ?? this.receivedFromPeerId,
      receivedTransport: receivedTransport ?? this.receivedTransport,
      transferId: transferId ?? this.transferId,
    );
  }
}
