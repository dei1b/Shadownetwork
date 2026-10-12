import '../entities/validation_event.dart';
import '../entities/validation_session_data.dart';
import '../entities/validation_summary.dart';

class ValidationMetricsCalculator {
  const ValidationMetricsCalculator();

  ValidationSummary calculate(ValidationSessionData data) {
    final queuedEvents = data.events.where(
      (event) =>
          event.type == ValidationEventType.sosQueued ||
          event.type == ValidationEventType.chatQueued,
    );
    final deliveredEvents = data.events.where(
      (event) => event.type == ValidationEventType.envelopeDelivered,
    );
    final queuedHashes = queuedEvents
        .map((event) => event.messageHash)
        .whereType<String>()
        .toSet();
    final deliveredHashes = deliveredEvents
        .map((event) => event.messageHash)
        .whereType<String>()
        .toSet();
    final receivedEvents = data.events.where(
      (event) => event.type == ValidationEventType.envelopeReceived,
    );
    final sentEvents = data.events
        .where((event) => event.type == ValidationEventType.envelopeSent)
        .toList(growable: false);
    final failedEvents = data.events
        .where(
          (event) =>
              event.type == ValidationEventType.envelopeRejected &&
              event.messageHash != null &&
              event.metadata?['phase'] == 'send',
        )
        .toList(growable: false);
    final latencies = sentEvents
        .map((event) => event.latencyMs)
        .whereType<int>()
        .where((value) => value >= 0)
        .toList(growable: false);

    final queuedAtByHash = <String, DateTime>{};
    for (final event in queuedEvents) {
      final hash = event.messageHash;
      if (hash == null) continue;
      final previous = queuedAtByHash[hash];
      if (previous == null || event.occurredAt.isBefore(previous)) {
        queuedAtByHash[hash] = event.occurredAt;
      }
    }
    for (final event in receivedEvents) {
      final hash = event.messageHash;
      final createdAtSource = event.metadata?['message_created_at'] as String?;
      final createdAt = createdAtSource == null
          ? null
          : DateTime.tryParse(createdAtSource)?.toUtc();
      if (hash == null || createdAt == null) continue;
      final previous = queuedAtByHash[hash];
      if (previous == null || createdAt.isBefore(previous)) {
        queuedAtByHash[hash] = createdAt;
      }
    }
    final propagationDurations = <int>[];
    for (final event in deliveredEvents) {
      final startedAt = queuedAtByHash[event.messageHash];
      if (startedAt == null || event.occurredAt.isBefore(startedAt)) continue;
      propagationDurations.add(
        event.occurredAt.difference(startedAt).inMilliseconds,
      );
    }

    final hopEvents = deliveredEvents.isNotEmpty
        ? deliveredEvents
        : data.events.where(
            (event) => event.type == ValidationEventType.envelopeReceived,
          );
    final hopDistribution = <int, int>{};
    for (final event in hopEvents) {
      final hop = event.hopCount;
      if (hop != null) {
        hopDistribution.update(hop, (count) => count + 1, ifAbsent: () => 1);
      }
    }

    final transportUsage = <String, int>{};
    for (final event in sentEvents) {
      final transport = event.transport?.trim();
      if (transport != null && transport.isNotEmpty) {
        transportUsage.update(
          transport,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }

    final successfulDiscoveryCount = data.discoveryAttempts
        .where((attempt) => attempt.success)
        .length;
    final fallbackCount = sentEvents
        .where((event) => event.fallbackUsed)
        .length;
    final battery = _batteryMetrics(data);

    return ValidationSummary(
      telemetryRecordCount: data.telemetryRecordCount,
      queuedMessageCount: queuedHashes.length,
      deliveredMessageCount: deliveredHashes.length,
      sentTransferCount: sentEvents.length,
      failedTransferCount: failedEvents.length,
      deliverySuccessRate: _deliverySuccessRate(
        sentEvents: sentEvents,
        failedEvents: failedEvents,
        receivedEvents: receivedEvents,
        deliveredHashes: deliveredHashes,
      ),
      discoverySuccessRate: data.discoveryAttempts.isEmpty
          ? null
          : successfulDiscoveryCount / data.discoveryAttempts.length,
      averageNodeLatencyMs: _average(latencies),
      averagePropagationMs: _average(propagationDurations),
      hopDistribution: Map.unmodifiable(hopDistribution),
      transportUsage: Map.unmodifiable(transportUsage),
      fallbackRate: sentEvents.isEmpty
          ? null
          : fallbackCount / sentEvents.length,
      batteryConsumedPercent: battery.$1,
      batteryConsumedPerHour: battery.$2,
    );
  }

  double? _average(List<int> values) {
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  double? _deliverySuccessRate({
    required List<ValidationMessageEvent> sentEvents,
    required List<ValidationMessageEvent> failedEvents,
    required Iterable<ValidationMessageEvent> receivedEvents,
    required Set<String> deliveredHashes,
  }) {
    final transferAttempts = sentEvents.length + failedEvents.length;
    if (transferAttempts > 0) {
      return sentEvents.length / transferAttempts;
    }
    final receivedHashes = receivedEvents
        .map((event) => event.messageHash)
        .whereType<String>()
        .toSet();
    if (receivedHashes.isEmpty) return null;
    return deliveredHashes.intersection(receivedHashes).length /
        receivedHashes.length;
  }

  (double?, double?) _batteryMetrics(ValidationSessionData data) {
    if (data.batterySamples.length < 2 ||
        data.batterySamples.any((sample) => sample.isCharging)) {
      return (null, null);
    }
    final first = data.batterySamples.first;
    final last = data.batterySamples.last;
    final elapsedHours =
        last.sampledAt.difference(first.sampledAt).inMilliseconds / 3600000;
    if (elapsedHours <= 0) return (null, null);
    final consumed = (first.batteryPercent - last.batteryPercent).clamp(0, 100);
    return (consumed.toDouble(), consumed / elapsedHours);
  }
}
