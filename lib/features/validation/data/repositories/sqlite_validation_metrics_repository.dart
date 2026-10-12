import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../../../messaging/data/datasources/local_messaging_database.dart';
import '../../domain/entities/validation_event.dart';
import '../../domain/entities/validation_session.dart';
import '../../domain/entities/validation_session_data.dart';
import '../../domain/repositories/validation_metrics_repository.dart';

class SqliteValidationMetricsRepository implements ValidationMetricsRepository {
  SqliteValidationMetricsRepository({required Database database})
    : _database = database;

  final Database _database;
  final Random _random = Random.secure();
  int _sequence = 0;

  @override
  Future<ValidationSession> startSession({
    required String name,
    required String environment,
    required String deviceId,
    required String deviceRole,
    String? notes,
    DateTime? startedAt,
  }) async {
    final normalizedName = name.trim();
    final normalizedEnvironment = environment.trim();
    if (normalizedName.isEmpty || normalizedEnvironment.isEmpty) {
      throw const FormatException(
        'Session name and test environment are required.',
      );
    }
    final timestamp = (startedAt ?? DateTime.now()).toUtc();
    final session = ValidationSession(
      id: _id('session', timestamp),
      name: normalizedName,
      environment: normalizedEnvironment,
      deviceId: deviceId.trim(),
      deviceRole: deviceRole.trim(),
      startedAt: timestamp,
      status: ValidationSessionStatus.active,
      notes: notes?.trim().isEmpty == true ? null : notes?.trim(),
    );

    await _database.transaction((transaction) async {
      final active = await transaction.query(
        LocalMessagingDatabase.validationSessionsTable,
        columns: ['id'],
        where: 'status = ?',
        whereArgs: [ValidationSessionStatus.active.name],
        limit: 1,
      );
      if (active.isNotEmpty) {
        throw StateError('A validation session is already active.');
      }
      await transaction.insert(
        LocalMessagingDatabase.validationSessionsTable,
        _sessionMap(session),
      );
    });
    return session;
  }

  @override
  Future<ValidationSession?> getActiveSession() async {
    final rows = await _database.query(
      LocalMessagingDatabase.validationSessionsTable,
      where: 'status = ?',
      whereArgs: [ValidationSessionStatus.active.name],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : _sessionFromMap(rows.single);
  }

  @override
  Future<ValidationSession?> stopActiveSession({DateTime? endedAt}) async {
    final active = await getActiveSession();
    if (active == null) {
      return null;
    }
    final timestamp = (endedAt ?? DateTime.now()).toUtc();
    final safeEnd = timestamp.isBefore(active.startedAt)
        ? active.startedAt
        : timestamp;
    await _database.update(
      LocalMessagingDatabase.validationSessionsTable,
      {
        'ended_at': safeEnd.toIso8601String(),
        'status': ValidationSessionStatus.completed.name,
      },
      where: 'id = ?',
      whereArgs: [active.id],
    );
    return ValidationSession(
      id: active.id,
      name: active.name,
      environment: active.environment,
      deviceId: active.deviceId,
      deviceRole: active.deviceRole,
      startedAt: active.startedAt,
      endedAt: safeEnd,
      status: ValidationSessionStatus.completed,
      notes: active.notes,
    );
  }

  @override
  Future<List<ValidationSession>> getSessions() async {
    final rows = await _database.query(
      LocalMessagingDatabase.validationSessionsTable,
      orderBy: 'started_at DESC',
    );
    return rows.map(_sessionFromMap).toList(growable: false);
  }

  @override
  Future<ValidationSessionData> getSessionData(String sessionId) async {
    final sessions = await _database.query(
      LocalMessagingDatabase.validationSessionsTable,
      where: 'id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (sessions.isEmpty) {
      throw StateError('Validation session $sessionId was not found.');
    }
    final eventRows = await _database.query(
      LocalMessagingDatabase.messageEventsTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'occurred_at ASC',
    );
    final discoveryRows = await _database.query(
      LocalMessagingDatabase.discoveryAttemptsTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'started_at ASC',
    );
    final batteryRows = await _database.query(
      LocalMessagingDatabase.batterySamplesTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'sampled_at ASC',
    );
    final exportRows = await _database.query(
      LocalMessagingDatabase.metricSyncBatchesTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at ASC',
    );
    return ValidationSessionData(
      session: _sessionFromMap(sessions.single),
      events: eventRows.map(_eventFromMap).toList(growable: false),
      discoveryAttempts: discoveryRows
          .map(_discoveryFromMap)
          .toList(growable: false),
      batterySamples: batteryRows.map(_batteryFromMap).toList(growable: false),
      exportRecords: exportRows.map(_exportFromMap).toList(growable: false),
    );
  }

  @override
  Future<bool> recordEvent(ValidationMessageEvent event) async {
    final id = await _database.insert(
      LocalMessagingDatabase.messageEventsTable,
      _eventMap(event),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id != 0;
  }

  @override
  Future<bool> captureEvent({
    required ValidationEventType type,
    DateTime? occurredAt,
    String? messageHash,
    String? payloadType,
    String? peerId,
    String? transport,
    int? hopCount,
    String? error,
    bool fallbackUsed = false,
    int? latencyMs,
    Map<String, Object?>? metadata,
  }) async {
    final session = await getActiveSession();
    if (session == null) {
      return false;
    }
    final timestamp = (occurredAt ?? DateTime.now()).toUtc();
    return recordEvent(
      ValidationMessageEvent(
        id: _id('event', timestamp),
        sessionId: session.id,
        type: type,
        occurredAt: timestamp,
        messageHash: messageHash,
        payloadType: payloadType,
        peerId: peerId,
        transport: transport,
        hopCount: hopCount,
        error: error,
        fallbackUsed: fallbackUsed,
        latencyMs: latencyMs,
        metadata: metadata,
      ),
    );
  }

  @override
  Future<bool> recordDiscoveryAttempt(
    ValidationDiscoveryAttempt attempt,
  ) async {
    final id = await _database.insert(
      LocalMessagingDatabase.discoveryAttemptsTable,
      _discoveryMap(attempt),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id != 0;
  }

  @override
  Future<bool> captureDiscoveryAttempt({
    required DateTime startedAt,
    required DateTime endedAt,
    required int discoveredCount,
    required bool success,
    String transport = 'hybrid',
    String? error,
  }) async {
    final session = await getActiveSession();
    if (session == null) {
      return false;
    }
    return recordDiscoveryAttempt(
      ValidationDiscoveryAttempt(
        id: _id('discovery', startedAt),
        sessionId: session.id,
        transport: transport,
        startedAt: startedAt.toUtc(),
        endedAt: endedAt.toUtc(),
        discoveredCount: discoveredCount,
        success: success,
        error: error,
      ),
    );
  }

  @override
  Future<bool> recordBatterySample(ValidationBatterySample sample) async {
    final id = await _database.insert(
      LocalMessagingDatabase.batterySamplesTable,
      _batteryMap(sample),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id != 0;
  }

  @override
  Future<bool> captureBatterySample({
    required double batteryPercent,
    required bool isCharging,
    required String runtimeMode,
    DateTime? sampledAt,
  }) async {
    final session = await getActiveSession();
    if (session == null) {
      return false;
    }
    final timestamp = (sampledAt ?? DateTime.now()).toUtc();
    return recordBatterySample(
      ValidationBatterySample(
        id: _id('battery', timestamp),
        sessionId: session.id,
        batteryPercent: batteryPercent.clamp(0, 100).toDouble(),
        isCharging: isCharging,
        sampledAt: timestamp,
        runtimeMode: runtimeMode,
      ),
    );
  }

  @override
  Future<bool> recordExport(ValidationExportRecord record) async {
    final id = await _database.insert(
      LocalMessagingDatabase.metricSyncBatchesTable,
      _exportMap(record),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id != 0;
  }

  @override
  Future<void> importSessionData(ValidationSessionData data) async {
    await _database.transaction((transaction) async {
      await transaction.insert(
        LocalMessagingDatabase.validationSessionsTable,
        _sessionMap(data.session),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      for (final event in data.events) {
        await transaction.insert(
          LocalMessagingDatabase.messageEventsTable,
          _eventMap(event),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      for (final attempt in data.discoveryAttempts) {
        await transaction.insert(
          LocalMessagingDatabase.discoveryAttemptsTable,
          _discoveryMap(attempt),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      for (final sample in data.batterySamples) {
        await transaction.insert(
          LocalMessagingDatabase.batterySamplesTable,
          _batteryMap(sample),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      for (final record in data.exportRecords) {
        await transaction.insert(
          LocalMessagingDatabase.metricSyncBatchesTable,
          _exportMap(record),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  String _id(String prefix, DateTime timestamp) {
    _sequence++;
    final randomPart = _random.nextInt(0xFFFFFF).toRadixString(16);
    return '$prefix-${timestamp.toUtc().microsecondsSinceEpoch}-$_sequence-$randomPart';
  }

  Map<String, Object?> _sessionMap(ValidationSession session) => {
    'id': session.id,
    'name': session.name,
    'environment': session.environment,
    'device_id': session.deviceId,
    'device_role': session.deviceRole,
    'started_at': session.startedAt.toUtc().toIso8601String(),
    'ended_at': session.endedAt?.toUtc().toIso8601String(),
    'status': session.status.name,
    'notes': session.notes,
  };

  ValidationSession _sessionFromMap(Map<String, Object?> row) =>
      ValidationSession(
        id: row['id']! as String,
        name: row['name']! as String,
        environment: row['environment']! as String,
        deviceId: row['device_id']! as String,
        deviceRole: row['device_role']! as String,
        startedAt: DateTime.parse(row['started_at']! as String).toUtc(),
        endedAt: row['ended_at'] == null
            ? null
            : DateTime.parse(row['ended_at']! as String).toUtc(),
        status: ValidationSessionStatus.values.byName(row['status']! as String),
        notes: row['notes'] as String?,
      );

  Map<String, Object?> _eventMap(ValidationMessageEvent event) => {
    'event_id': event.id,
    'session_id': event.sessionId,
    'message_hash': event.messageHash,
    'payload_type': event.payloadType,
    'event_type': event.type.name,
    'peer_id': event.peerId,
    'transport': event.transport,
    'hop_count': event.hopCount,
    'occurred_at': event.occurredAt.toUtc().toIso8601String(),
    'error': event.error,
    'fallback_used': event.fallbackUsed ? 1 : 0,
    'latency_ms': event.latencyMs,
    'metadata_json': event.metadata == null ? null : jsonEncode(event.metadata),
  };

  ValidationMessageEvent _eventFromMap(Map<String, Object?> row) =>
      ValidationMessageEvent(
        id: row['event_id']! as String,
        sessionId: row['session_id']! as String,
        type: ValidationEventType.values.byName(row['event_type']! as String),
        occurredAt: DateTime.parse(row['occurred_at']! as String).toUtc(),
        messageHash: row['message_hash'] as String?,
        payloadType: row['payload_type'] as String?,
        peerId: row['peer_id'] as String?,
        transport: row['transport'] as String?,
        hopCount: row['hop_count'] as int?,
        error: row['error'] as String?,
        fallbackUsed: (row['fallback_used']! as int) == 1,
        latencyMs: row['latency_ms'] as int?,
        metadata: row['metadata_json'] == null
            ? null
            : Map<String, Object?>.from(
                jsonDecode(row['metadata_json']! as String) as Map,
              ),
      );

  Map<String, Object?> _discoveryMap(ValidationDiscoveryAttempt attempt) => {
    'attempt_id': attempt.id,
    'session_id': attempt.sessionId,
    'transport': attempt.transport,
    'started_at': attempt.startedAt.toUtc().toIso8601String(),
    'ended_at': attempt.endedAt.toUtc().toIso8601String(),
    'discovered_count': attempt.discoveredCount,
    'success': attempt.success ? 1 : 0,
    'error': attempt.error,
  };

  ValidationDiscoveryAttempt _discoveryFromMap(Map<String, Object?> row) =>
      ValidationDiscoveryAttempt(
        id: row['attempt_id']! as String,
        sessionId: row['session_id']! as String,
        transport: row['transport']! as String,
        startedAt: DateTime.parse(row['started_at']! as String).toUtc(),
        endedAt: DateTime.parse(row['ended_at']! as String).toUtc(),
        discoveredCount: row['discovered_count']! as int,
        success: (row['success']! as int) == 1,
        error: row['error'] as String?,
      );

  Map<String, Object?> _batteryMap(ValidationBatterySample sample) => {
    'sample_id': sample.id,
    'session_id': sample.sessionId,
    'battery_percent': sample.batteryPercent,
    'is_charging': sample.isCharging ? 1 : 0,
    'sampled_at': sample.sampledAt.toUtc().toIso8601String(),
    'runtime_mode': sample.runtimeMode,
  };

  ValidationBatterySample _batteryFromMap(Map<String, Object?> row) =>
      ValidationBatterySample(
        id: row['sample_id']! as String,
        sessionId: row['session_id']! as String,
        batteryPercent: (row['battery_percent']! as num).toDouble(),
        isCharging: (row['is_charging']! as int) == 1,
        sampledAt: DateTime.parse(row['sampled_at']! as String).toUtc(),
        runtimeMode: row['runtime_mode']! as String,
      );

  Map<String, Object?> _exportMap(ValidationExportRecord record) => {
    'batch_id': record.id,
    'session_id': record.sessionId,
    'created_at': record.createdAt.toUtc().toIso8601String(),
    'destination': record.destination,
    'result': record.result,
    'retry_count': record.retryCount,
    'payload_hash': record.payloadHash,
  };

  ValidationExportRecord _exportFromMap(Map<String, Object?> row) =>
      ValidationExportRecord(
        id: row['batch_id']! as String,
        sessionId: row['session_id']! as String,
        createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
        destination: row['destination']! as String,
        result: row['result']! as String,
        retryCount: row['retry_count']! as int,
        payloadHash: row['payload_hash']! as String,
      );
}
