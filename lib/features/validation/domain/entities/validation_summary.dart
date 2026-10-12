class ValidationSummary {
  const ValidationSummary({
    required this.telemetryRecordCount,
    required this.queuedMessageCount,
    required this.deliveredMessageCount,
    required this.sentTransferCount,
    required this.failedTransferCount,
    required this.hopDistribution,
    required this.transportUsage,
    this.deliverySuccessRate,
    this.discoverySuccessRate,
    this.averageNodeLatencyMs,
    this.averagePropagationMs,
    this.fallbackRate,
    this.batteryConsumedPercent,
    this.batteryConsumedPerHour,
  });

  final int telemetryRecordCount;
  final int queuedMessageCount;
  final int deliveredMessageCount;
  final int sentTransferCount;
  final int failedTransferCount;
  final double? deliverySuccessRate;
  final double? discoverySuccessRate;
  final double? averageNodeLatencyMs;
  final double? averagePropagationMs;
  final Map<int, int> hopDistribution;
  final Map<String, int> transportUsage;
  final double? fallbackRate;
  final double? batteryConsumedPercent;
  final double? batteryConsumedPerHour;
}
