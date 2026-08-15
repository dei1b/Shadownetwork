import 'device_trust_status.dart';

class DeviceTrustRecord {
  const DeviceTrustRecord({
    required this.deviceId,
    required this.ownerName,
    required this.role,
    required this.status,
    required this.keyVersion,
    required this.bundleVersion,
    required this.bundleHash,
    required this.adminUpdatedAt,
    required this.importedAt,
    this.publicKey,
  });

  const DeviceTrustRecord.unknown(String deviceId)
    : this(
        deviceId: deviceId,
        ownerName: 'Unknown device',
        role: 'unknown',
        status: DeviceTrustStatus.unknown,
        keyVersion: 1,
        bundleVersion: 0,
        bundleHash: '',
        adminUpdatedAt: null,
        importedAt: null,
      );

  final String deviceId;
  final String ownerName;
  final String role;
  final DeviceTrustStatus status;
  final String? publicKey;
  final int keyVersion;
  final int bundleVersion;
  final String bundleHash;
  final DateTime? adminUpdatedAt;
  final DateTime? importedAt;
}

class TrustBundleMetadata {
  const TrustBundleMetadata({
    required this.bundleVersion,
    required this.bundleHash,
    required this.issuerId,
    required this.signingKeyId,
    required this.issuedAt,
    required this.expiresAt,
    required this.importedAt,
    required this.signatureVerified,
  });

  final int bundleVersion;
  final String bundleHash;
  final String issuerId;
  final String signingKeyId;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final DateTime importedAt;
  final bool signatureVerified;
}
