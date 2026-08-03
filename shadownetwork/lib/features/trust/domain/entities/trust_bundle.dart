import 'dart:convert';

class TrustBundle {
  const TrustBundle({
    required this.schemaVersion,
    required this.generatedAt,
    required this.approvedDevices,
    required this.revokedDevices,
  });

  final int schemaVersion;
  final DateTime generatedAt;
  final List<TrustedDevice> approvedDevices;
  final List<TrustedDevice> revokedDevices;

  int get approvedCount => approvedDevices.length;
  int get revokedCount => revokedDevices.length;
  int get totalCount => approvedCount + revokedCount;

  Map<String, Object?> toJson() {
    return {
      'schema_version': schemaVersion,
      'bundle_type': 'shadow_network_device_trust_bundle',
      'generated_at': generatedAt.toUtc().toIso8601String(),
      'approved_devices': approvedDevices
          .map((device) => device.toJson())
          .toList(growable: false),
      'revoked_devices': revokedDevices
          .map((device) => device.toJson())
          .toList(growable: false),
    };
  }

  String toPrettyJson() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  factory TrustBundle.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Trust bundle must be a JSON object.');
    }
    return TrustBundle.fromJson(Map<String, Object?>.from(decoded));
  }

  factory TrustBundle.fromJson(Map<String, Object?> json) {
    if (json['bundle_type'] != 'shadow_network_device_trust_bundle') {
      throw const FormatException('Unsupported trust bundle type.');
    }

    return TrustBundle(
      schemaVersion: json['schema_version'] as int? ?? 1,
      generatedAt: _parseDate(json['generated_at'] as String?),
      approvedDevices: _parseDevices(json['approved_devices']),
      revokedDevices: _parseDevices(json['revoked_devices']),
    );
  }

  static List<TrustedDevice> _parseDevices(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value
        .whereType<Map>()
        .map((item) => TrustedDevice.fromJson(Map<String, Object?>.from(item)))
        .where((device) => device.deviceId.isNotEmpty)
        .toList(growable: false);
  }

  static DateTime _parseDate(String? value) {
    if (value == null) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    return DateTime.tryParse(value)?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
}

class TrustedDevice {
  const TrustedDevice({
    required this.deviceId,
    required this.ownerName,
    required this.role,
    required this.status,
    required this.updatedAt,
    this.publicKey,
  });

  final String deviceId;
  final String ownerName;
  final String role;
  final String status;
  final DateTime updatedAt;
  final String? publicKey;

  Map<String, Object?> toJson() {
    return {
      'device_id': deviceId,
      'owner_name': ownerName,
      'role': role,
      'status': status,
      'public_key': publicKey,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  factory TrustedDevice.fromJson(Map<String, Object?> json) {
    return TrustedDevice(
      deviceId: json['device_id'] as String? ?? '',
      ownerName: json['owner_name'] as String? ?? 'Unknown device',
      role: json['role'] as String? ?? 'unknown',
      status: json['status'] as String? ?? 'unknown',
      publicKey: json['public_key'] as String?,
      updatedAt: TrustBundle._parseDate(json['updated_at'] as String?),
    );
  }
}
