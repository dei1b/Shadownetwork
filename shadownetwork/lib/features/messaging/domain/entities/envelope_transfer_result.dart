class EnvelopeTransferResult {
  const EnvelopeTransferResult({
    required this.transport,
    this.fallbackUsed = false,
  });

  final String transport;
  final bool fallbackUsed;
}
