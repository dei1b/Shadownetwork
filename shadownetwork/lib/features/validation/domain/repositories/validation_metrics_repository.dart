import '../entities/validation_event.dart';
import '../entities/validation_session.dart';
import '../entities/validation_session_data.dart';

abstract interface class ValidationMetricsRepository {
  Future<ValidationSession> startSession({
    required String name,
    required String environment,
    required String deviceId,
    required String deviceRole,
    String? notes,
    DateTime? startedAt,
  });

  Future<ValidationSession?> getActiveSession();

  Future<ValidationSession?> stopActiveSession({DateTime? endedAt});

  Future<List<ValidationSession>> getSessions();

  Future<ValidationSessionData> getSessionData(String sessionId);

  Future<bool> recordEvent(ValidationMessageEvent event);

  Future<bool> captureEvent({
    required ValidationEventType type,
    DateTime? occurredAt,
    String? messageHash,
    String? payloadType,
    String? peerId,
    String? transport,
    int? hopCount,
    String? error,
    bool fallbackUsed,
    int? latencyMs,
    Map<String, Object?>? metadata,
  });

  Future<bool> recordDiscoveryAttempt(ValidationDiscoveryAttempt attempt);

  Future<bool> captureDiscoveryAttempt({
    required DateTime startedAt,
    required DateTime endedAt,
    required int discoveredCount,
    required bool success,
    String transport,
    String? error,
  });

  Future<bool> recordBatterySample(ValidationBatterySample sample);

  Future<bool> captureBatterySample({
    required double batteryPercent,
    required bool isCharging,
    required String runtimeMode,
    DateTime? sampledAt,
  });

  Future<bool> recordExport(ValidationExportRecord record);

  Future<void> importSessionData(ValidationSessionData data);
}
