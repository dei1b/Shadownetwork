enum ValidationEventType {
  sosQueued,
  chatQueued,
  peerDiscovered,
  connectionStarted,
  connectionSucceeded,
  connectionFailed,
  envelopeOffered,
  envelopeSent,
  envelopeReceived,
  envelopeRelayed,
  envelopeDelivered,
  envelopeExpired,
  envelopeRejected,
  transportFallback,
  runtimeModeChanged,
}

class ValidationMessageEvent {
  const ValidationMessageEvent({
    required this.id,
    required this.sessionId,
    required this.type,
    required this.occurredAt,
    this.messageHash,
    this.payloadType,
    this.peerId,
    this.transport,
    this.hopCount,
    this.error,
    this.fallbackUsed = false,
    this.latencyMs,
    this.metadata,
  });

  final String id;
  final String sessionId;
  final ValidationEventType type;
  final DateTime occurredAt;
  final String? messageHash;
  final String? payloadType;
  final String? peerId;
  final String? transport;
  final int? hopCount;
  final String? error;
  final bool fallbackUsed;
  final int? latencyMs;
  final Map<String, Object?>? metadata;

  Map<String, Object?> toJson() => {
    'id': id,
    'session_id': sessionId,
    'event_type': type.name,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'message_hash': messageHash,
    'payload_type': payloadType,
    'peer_id': peerId,
    'transport': transport,
    'hop_count': hopCount,
    'error': error,
    'fallback_used': fallbackUsed,
    'latency_ms': latencyMs,
    'metadata': metadata,
  };

  factory ValidationMessageEvent.fromJson(Map<String, Object?> json) {
    return ValidationMessageEvent(
      id: json['id']! as String,
      sessionId: json['session_id']! as String,
      type: ValidationEventType.values.byName(json['event_type']! as String),
      occurredAt: DateTime.parse(json['occurred_at']! as String).toUtc(),
      messageHash: json['message_hash'] as String?,
      payloadType: json['payload_type'] as String?,
      peerId: json['peer_id'] as String?,
      transport: json['transport'] as String?,
      hopCount: (json['hop_count'] as num?)?.toInt(),
      error: json['error'] as String?,
      fallbackUsed: json['fallback_used'] == true,
      latencyMs: (json['latency_ms'] as num?)?.toInt(),
      metadata: json['metadata'] is Map
          ? Map<String, Object?>.from(json['metadata']! as Map)
          : null,
    );
  }
}

class ValidationDiscoveryAttempt {
  const ValidationDiscoveryAttempt({
    required this.id,
    required this.sessionId,
    required this.transport,
    required this.startedAt,
    required this.endedAt,
    required this.discoveredCount,
    required this.success,
    this.error,
  });

  final String id;
  final String sessionId;
  final String transport;
  final DateTime startedAt;
  final DateTime endedAt;
  final int discoveredCount;
  final bool success;
  final String? error;

  int get durationMs => endedAt.difference(startedAt).inMilliseconds;

  Map<String, Object?> toJson() => {
    'id': id,
    'session_id': sessionId,
    'transport': transport,
    'started_at': startedAt.toUtc().toIso8601String(),
    'ended_at': endedAt.toUtc().toIso8601String(),
    'discovered_count': discoveredCount,
    'success': success,
    'error': error,
  };

  factory ValidationDiscoveryAttempt.fromJson(Map<String, Object?> json) {
    return ValidationDiscoveryAttempt(
      id: json['id']! as String,
      sessionId: json['session_id']! as String,
      transport: json['transport']! as String,
      startedAt: DateTime.parse(json['started_at']! as String).toUtc(),
      endedAt: DateTime.parse(json['ended_at']! as String).toUtc(),
      discoveredCount: (json['discovered_count']! as num).toInt(),
      success: json['success'] == true,
      error: json['error'] as String?,
    );
  }
}

class ValidationBatterySample {
  const ValidationBatterySample({
    required this.id,
    required this.sessionId,
    required this.batteryPercent,
    required this.isCharging,
    required this.sampledAt,
    required this.runtimeMode,
  });

  final String id;
  final String sessionId;
  final double batteryPercent;
  final bool isCharging;
  final DateTime sampledAt;
  final String runtimeMode;

  Map<String, Object?> toJson() => {
    'id': id,
    'session_id': sessionId,
    'battery_percent': batteryPercent,
    'is_charging': isCharging,
    'sampled_at': sampledAt.toUtc().toIso8601String(),
    'runtime_mode': runtimeMode,
  };

  factory ValidationBatterySample.fromJson(Map<String, Object?> json) {
    return ValidationBatterySample(
      id: json['id']! as String,
      sessionId: json['session_id']! as String,
      batteryPercent: (json['battery_percent']! as num).toDouble(),
      isCharging: json['is_charging'] == true,
      sampledAt: DateTime.parse(json['sampled_at']! as String).toUtc(),
      runtimeMode: json['runtime_mode']! as String,
    );
  }
}

class ValidationExportRecord {
  const ValidationExportRecord({
    required this.id,
    required this.sessionId,
    required this.createdAt,
    required this.destination,
    required this.result,
    required this.retryCount,
    required this.payloadHash,
  });

  final String id;
  final String sessionId;
  final DateTime createdAt;
  final String destination;
  final String result;
  final int retryCount;
  final String payloadHash;

  Map<String, Object?> toJson() => {
    'id': id,
    'session_id': sessionId,
    'created_at': createdAt.toUtc().toIso8601String(),
    'destination': destination,
    'result': result,
    'retry_count': retryCount,
    'payload_hash': payloadHash,
  };

  factory ValidationExportRecord.fromJson(Map<String, Object?> json) {
    return ValidationExportRecord(
      id: json['id']! as String,
      sessionId: json['session_id']! as String,
      createdAt: DateTime.parse(json['created_at']! as String).toUtc(),
      destination: json['destination']! as String,
      result: json['result']! as String,
      retryCount: (json['retry_count']! as num).toInt(),
      payloadHash: json['payload_hash']! as String,
    );
  }
}
