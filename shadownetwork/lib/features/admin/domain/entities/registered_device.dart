enum RegisteredDeviceRole {
  civilian,
  responder,
  relay,
  admin;

  String get label {
    switch (this) {
      case RegisteredDeviceRole.civilian:
        return 'Civilian';
      case RegisteredDeviceRole.responder:
        return 'Responder';
      case RegisteredDeviceRole.relay:
        return 'Relay';
      case RegisteredDeviceRole.admin:
        return 'Admin';
    }
  }

  static RegisteredDeviceRole fromCode(String? code) {
    return RegisteredDeviceRole.values.firstWhere(
      (role) => role.name == code,
      orElse: () => RegisteredDeviceRole.civilian,
    );
  }
}

enum RegisteredDeviceStatus {
  pending,
  approved,
  revoked;

  String get label {
    switch (this) {
      case RegisteredDeviceStatus.pending:
        return 'Pending';
      case RegisteredDeviceStatus.approved:
        return 'Approved';
      case RegisteredDeviceStatus.revoked:
        return 'Revoked';
    }
  }

  static RegisteredDeviceStatus fromCode(String? code) {
    return RegisteredDeviceStatus.values.firstWhere(
      (status) => status.name == code,
      orElse: () => RegisteredDeviceStatus.pending,
    );
  }
}

class RegisteredDevice {
  const RegisteredDevice({
    required this.deviceId,
    required this.ownerName,
    required this.role,
    required this.status,
    required this.registeredAt,
    required this.updatedAt,
    required this.lastSeenLabel,
    this.publicKey,
    this.notes,
  });

  final String deviceId;
  final String ownerName;
  final RegisteredDeviceRole role;
  final RegisteredDeviceStatus status;
  final DateTime registeredAt;
  final DateTime updatedAt;
  final String lastSeenLabel;
  final String? publicKey;
  final String? notes;

  RegisteredDevice copyWith({
    String? deviceId,
    String? ownerName,
    RegisteredDeviceRole? role,
    RegisteredDeviceStatus? status,
    DateTime? registeredAt,
    DateTime? updatedAt,
    String? lastSeenLabel,
    String? publicKey,
    String? notes,
  }) {
    return RegisteredDevice(
      deviceId: deviceId ?? this.deviceId,
      ownerName: ownerName ?? this.ownerName,
      role: role ?? this.role,
      status: status ?? this.status,
      registeredAt: registeredAt ?? this.registeredAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastSeenLabel: lastSeenLabel ?? this.lastSeenLabel,
      publicKey: publicKey ?? this.publicKey,
      notes: notes ?? this.notes,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'device_id': deviceId,
      'owner_name': ownerName,
      'role': role.name,
      'status': status.name,
      'registered_at': registeredAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'last_seen_label': lastSeenLabel,
      'public_key': publicKey,
      'notes': notes,
    };
  }

  factory RegisteredDevice.fromJson(Map<String, Object?> json) {
    return RegisteredDevice(
      deviceId: json['device_id'] as String? ?? '',
      ownerName: json['owner_name'] as String? ?? 'Unknown owner',
      role: RegisteredDeviceRole.fromCode(json['role'] as String?),
      status: RegisteredDeviceStatus.fromCode(json['status'] as String?),
      registeredAt: _parseDate(json['registered_at'] as String?),
      updatedAt: _parseDate(json['updated_at'] as String?),
      lastSeenLabel: json['last_seen_label'] as String? ?? 'Not synced',
      publicKey: json['public_key'] as String?,
      notes: json['notes'] as String?,
    );
  }

  static DateTime _parseDate(String? value) {
    if (value == null) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    return DateTime.tryParse(value)?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
}
