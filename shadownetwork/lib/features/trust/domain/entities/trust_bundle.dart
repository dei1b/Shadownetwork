import 'dart:convert';

class TrustBundle {
  const TrustBundle({
    required this.schemaVersion,
    required this.generatedAt,
    required this.approvedDevices,
    required this.revokedDevices,
    this.bundleVersion = 0,
    this.issuedAt,
    this.expiresAt,
    this.issuer,
    this.signature,
    this.importedAt,
    this.bundleHash,
    this.isSignatureVerified = false,
  });

  final int schemaVersion;
  final int bundleVersion;
  final DateTime generatedAt;
  final DateTime? issuedAt;
  final DateTime? expiresAt;
  final TrustBundleIssuer? issuer;
  final List<TrustedDevice> approvedDevices;
  final List<TrustedDevice> revokedDevices;
  final String? signature;
  final DateTime? importedAt;
  final String? bundleHash;
  final bool isSignatureVerified;

  int get approvedCount => approvedDevices.length;
  int get revokedCount => revokedDevices.length;
  int get totalCount => approvedCount + revokedCount;
  bool get isSignedVersion =>
      schemaVersion == 2 && bundleVersion > 0 && issuer != null;

  bool isExpiredAt(DateTime timestamp) =>
      expiresAt == null || !expiresAt!.isAfter(timestamp.toUtc());

  Map<String, Object?> toJson({bool includeSignature = true}) {
    if (schemaVersion < 2) {
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

    return {
      'schema_version': schemaVersion,
      'bundle_type': 'shadow_network_device_trust_bundle',
      'bundle_version': bundleVersion,
      'issued_at': (issuedAt ?? generatedAt).toUtc().toIso8601String(),
      'expires_at': expiresAt?.toUtc().toIso8601String(),
      'issuer': issuer?.toJson(),
      'approved_devices': approvedDevices
          .map((device) => device.toJson())
          .toList(growable: false),
      'revoked_devices': revokedDevices
          .map((device) => device.toJson())
          .toList(growable: false),
      if (includeSignature) 'signature': signature,
    };
  }

  String toPrettyJson() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  TrustBundle withVerifiedImport({
    required DateTime importedAt,
    required String bundleHash,
  }) {
    return TrustBundle(
      schemaVersion: schemaVersion,
      bundleVersion: bundleVersion,
      generatedAt: generatedAt,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      issuer: issuer,
      approvedDevices: approvedDevices,
      revokedDevices: revokedDevices,
      signature: signature,
      importedAt: importedAt,
      bundleHash: bundleHash,
      isSignatureVerified: true,
    );
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

    final schemaVersion = (json['schema_version'] as num?)?.toInt() ?? 1;
    final issuedAt = _parseOptionalDate(json['issued_at'] as String?);
    final generatedAt =
        _parseOptionalDate(json['generated_at'] as String?) ??
        issuedAt ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return TrustBundle(
      schemaVersion: schemaVersion,
      bundleVersion: (json['bundle_version'] as num?)?.toInt() ?? 0,
      generatedAt: generatedAt,
      issuedAt: issuedAt,
      expiresAt: _parseOptionalDate(json['expires_at'] as String?),
      issuer: json['issuer'] is Map
          ? TrustBundleIssuer.fromJson(
              Map<String, Object?>.from(json['issuer']! as Map),
            )
          : null,
      approvedDevices: _parseDevices(json['approved_devices']),
      revokedDevices: _parseDevices(json['revoked_devices']),
      signature: json['signature'] as String?,
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
    return _parseOptionalDate(value) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  static DateTime? _parseOptionalDate(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(value)?.toUtc();
  }
}

class TrustBundleIssuer {
  const TrustBundleIssuer({
    required this.issuerId,
    required this.signingKeyId,
    required this.signatureAlgorithm,
    required this.publicKey,
  });

  final String issuerId;
  final String signingKeyId;
  final String signatureAlgorithm;
  final String publicKey;

  Map<String, Object?> toJson() => {
    'issuer_id': issuerId,
    'signing_key_id': signingKeyId,
    'signature_algorithm': signatureAlgorithm,
    'public_key': publicKey,
  };

  factory TrustBundleIssuer.fromJson(Map<String, Object?> json) {
    return TrustBundleIssuer(
      issuerId: (json['issuer_id'] as String? ?? '').trim(),
      signingKeyId: (json['signing_key_id'] as String? ?? '').trim(),
      signatureAlgorithm: (json['signature_algorithm'] as String? ?? '').trim(),
      publicKey: (json['public_key'] as String? ?? '').trim(),
    );
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
    this.keyVersion = 1,
  });

  final String deviceId;
  final String ownerName;
  final String role;
  final String status;
  final DateTime updatedAt;
  final String? publicKey;
  final int keyVersion;

  Map<String, Object?> toJson() {
    return {
      'device_id': deviceId,
      'owner_name': ownerName,
      'role': role,
      'status': status,
      'public_key': publicKey,
      'key_version': keyVersion,
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
      keyVersion: (json['key_version'] as num?)?.toInt() ?? 1,
      updatedAt: TrustBundle._parseDate(json['updated_at'] as String?),
    );
  }
}
