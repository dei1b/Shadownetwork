import 'dart:convert';

import '../entities/validation_event.dart';
import '../entities/validation_session_data.dart';

class ValidationExportService {
  const ValidationExportService();

  String encodeJson(ValidationSessionData data) {
    return const JsonEncoder.withIndent('  ').convert(data.toJson());
  }

  ValidationSessionData decodeJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Validation export must be a JSON object.');
    }
    return ValidationSessionData.fromJson(Map<String, Object?>.from(decoded));
  }

  String encodeCsv(ValidationSessionData data) {
    final rows = <List<Object?>>[
      [
        'record_type',
        'record_id',
        'session_id',
        'timestamp',
        'event_type',
        'message_hash',
        'peer_id',
        'transport',
        'hop_count',
        'latency_ms',
        'success',
        'value',
        'detail',
      ],
      ...data.events.map(_eventRow),
      ...data.discoveryAttempts.map(
        (attempt) => [
          'discovery_attempt',
          attempt.id,
          attempt.sessionId,
          attempt.startedAt.toUtc().toIso8601String(),
          'peer_discovery',
          null,
          null,
          attempt.transport,
          null,
          attempt.durationMs,
          attempt.success,
          attempt.discoveredCount,
          attempt.error,
        ],
      ),
      ...data.batterySamples.map(
        (sample) => [
          'battery_sample',
          sample.id,
          sample.sessionId,
          sample.sampledAt.toUtc().toIso8601String(),
          'battery',
          null,
          null,
          null,
          null,
          null,
          !sample.isCharging,
          sample.batteryPercent,
          '${sample.runtimeMode}; charging=${sample.isCharging}',
        ],
      ),
    ];
    return rows.map((row) => row.map(_csvCell).join(',')).join('\r\n');
  }

  List<Object?> _eventRow(ValidationMessageEvent event) => [
    'message_event',
    event.id,
    event.sessionId,
    event.occurredAt.toUtc().toIso8601String(),
    event.type.name,
    event.messageHash,
    event.peerId,
    event.transport,
    event.hopCount,
    event.latencyMs,
    event.error == null,
    event.fallbackUsed ? 1 : 0,
    event.error ?? (event.metadata == null ? null : jsonEncode(event.metadata)),
  ];

  String _csvCell(Object? value) {
    if (value == null) return '';
    final text = value.toString();
    if (!text.contains(RegExp('[,"\r\n]'))) return text;
    return '"${text.replaceAll('"', '""')}"';
  }
}
