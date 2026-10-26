import 'package:shadownetwork/features/validation/domain/entities/validation_event.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_session.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_session_data.dart';

ValidationSessionData runFixture({
  String id = 'session',
  String deviceId = 'local',
  String? runId = 'RUN-001',
  DateTime? startedAt,
  bool telemetry = true,
  ValidationSessionStatus status = ValidationSessionStatus.completed,
}) {
  final start = startedAt ?? DateTime.utc(2026, 10, 26, 2);
  return ValidationSessionData(
    session: ValidationSession(
      id: id,
      name: 'Local trial',
      environment: 'Lab',
      deviceId: deviceId,
      deviceRole: 'responder',
      testRunId: runId,
      startedAt: start,
      endedAt: status == ValidationSessionStatus.completed
          ? start.add(const Duration(minutes: 1))
          : null,
      status: status,
    ),
    events: telemetry
        ? [
            ValidationMessageEvent(
              id: '$id-event',
              sessionId: id,
              type: ValidationEventType.envelopeAcknowledged,
              occurredAt: start,
              transferId: '$id-hop',
              messageHash: '$id-hash',
              peerId: 'receiver',
              latencyMs: 123,
            ),
          ]
        : [],
    discoveryAttempts: telemetry
        ? [
            ValidationDiscoveryAttempt(
              id: '$id-scan',
              sessionId: id,
              startedAt: start,
              endedAt: start.add(const Duration(seconds: 1)),
              transport: 'mock',
              discoveredCount: 1,
              success: true,
            ),
          ]
        : [],
    batterySamples: telemetry
        ? [
            ValidationBatterySample(
              id: '$id-battery',
              sessionId: id,
              batteryPercent: 80,
              isCharging: true,
              sampledAt: start,
              runtimeMode: 'foreground',
            ),
          ]
        : [],
    exportRecords: const [],
  );
}
