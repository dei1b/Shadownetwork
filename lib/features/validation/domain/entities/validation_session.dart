enum ValidationSessionStatus { active, completed }

class ValidationSession {
  const ValidationSession({
    required this.id,
    required this.name,
    required this.environment,
    required this.deviceId,
    required this.deviceRole,
    required this.startedAt,
    required this.status,
    this.endedAt,
    this.notes,
  });

  final String id;
  final String name;
  final String environment;
  final String deviceId;
  final String deviceRole;
  final DateTime startedAt;
  final DateTime? endedAt;
  final ValidationSessionStatus status;
  final String? notes;

  Duration elapsedAt(DateTime now) {
    final end = endedAt ?? now;
    return end.isBefore(startedAt) ? Duration.zero : end.difference(startedAt);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'environment': environment,
    'device_id': deviceId,
    'device_role': deviceRole,
    'started_at': startedAt.toUtc().toIso8601String(),
    'ended_at': endedAt?.toUtc().toIso8601String(),
    'status': status.name,
    'notes': notes,
  };

  factory ValidationSession.fromJson(Map<String, Object?> json) {
    return ValidationSession(
      id: json['id']! as String,
      name: json['name']! as String,
      environment: json['environment']! as String,
      deviceId: json['device_id']! as String,
      deviceRole: json['device_role']! as String,
      startedAt: DateTime.parse(json['started_at']! as String).toUtc(),
      endedAt: json['ended_at'] == null
          ? null
          : DateTime.parse(json['ended_at']! as String).toUtc(),
      status: ValidationSessionStatus.values.byName(json['status']! as String),
      notes: json['notes'] as String?,
    );
  }
}
