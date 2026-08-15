import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/registered_device.dart';
import '../../../trust/domain/entities/trust_bundle.dart';
import '../../../trust/domain/services/canonical_json.dart';

class AdminDeviceRegistryStore {
  static const _devicesKey = 'shadow_network_admin_devices_v1';
  static const _signingPrivateKey = 'shadow_network_admin_ed25519_private_v1';
  static const _signingPublicKey = 'shadow_network_admin_ed25519_public_v1';
  static const _bundleVersionKey = 'shadow_network_admin_bundle_version_v2';
  static const _issuerId = 'shadow-network-admin';
  static const _legacySampleDeviceIds = {
    'SN-RESPONDER-001',
    'SN-RELAY-014',
    'SN-CIVILIAN-073',
  };

  Future<List<RegisteredDevice>> loadDevices() async {
    final preferences = await SharedPreferences.getInstance();
    final rawDevices = preferences.getString(_devicesKey);
    if (rawDevices == null || rawDevices.trim().isEmpty) {
      return const [];
    }

    final decoded = jsonDecode(rawDevices);
    if (decoded is! List) {
      return const [];
    }

    final devices = decoded
        .whereType<Map>()
        .map(
          (item) => RegisteredDevice.fromJson(Map<String, Object?>.from(item)),
        )
        .where((device) => device.deviceId.isNotEmpty)
        .where((device) => !_legacySampleDeviceIds.contains(device.deviceId))
        .toList(growable: false);

    if (devices.length != decoded.length) {
      await saveDevices(devices);
    }

    return devices;
  }

  Future<void> saveDevices(List<RegisteredDevice> devices) async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      devices.map((device) => device.toJson()).toList(growable: false),
    );
    await preferences.setString(_devicesKey, encoded);
  }

  Future<String> buildTrustBundleJson(List<RegisteredDevice> devices) async {
    _validatePublishableDevices(devices);
    final preferences = await SharedPreferences.getInstance();
    final identity = await _loadOrCreateSigningIdentity(preferences);
    final bundleVersion = (preferences.getInt(_bundleVersionKey) ?? 0) + 1;
    final issuedAt = DateTime.now().toUtc();
    final approved = devices
        .where((device) => device.status == RegisteredDeviceStatus.approved)
        .map((device) => TrustedDevice.fromJson(_trustEntry(device)))
        .toList(growable: false);
    final revoked = devices
        .where((device) => device.status == RegisteredDeviceStatus.revoked)
        .map((device) => TrustedDevice.fromJson(_trustEntry(device)))
        .toList(growable: false);
    final unsignedBundle = TrustBundle(
      schemaVersion: 2,
      bundleVersion: bundleVersion,
      generatedAt: issuedAt,
      issuedAt: issuedAt,
      expiresAt: issuedAt.add(const Duration(days: 30)),
      issuer: TrustBundleIssuer(
        issuerId: _issuerId,
        signingKeyId: identity.signingKeyId,
        signatureAlgorithm: 'ed25519',
        publicKey: base64UrlEncode(identity.publicKeyBytes),
      ),
      approvedDevices: approved,
      revokedDevices: revoked,
    );
    final signature = await Ed25519().sign(
      utf8.encode(
        canonicalJsonEncode(unsignedBundle.toJson(includeSignature: false)),
      ),
      keyPair: identity.keyPair,
    );
    final signedBundle = TrustBundle(
      schemaVersion: unsignedBundle.schemaVersion,
      bundleVersion: unsignedBundle.bundleVersion,
      generatedAt: unsignedBundle.generatedAt,
      issuedAt: unsignedBundle.issuedAt,
      expiresAt: unsignedBundle.expiresAt,
      issuer: unsignedBundle.issuer,
      approvedDevices: unsignedBundle.approvedDevices,
      revokedDevices: unsignedBundle.revokedDevices,
      signature: base64UrlEncode(signature.bytes),
    );
    await preferences.setInt(_bundleVersionKey, bundleVersion);
    return signedBundle.toPrettyJson();
  }

  void _validatePublishableDevices(List<RegisteredDevice> devices) {
    final publishedIds = <String>{};
    for (final device in devices.where(
      (device) => device.status != RegisteredDeviceStatus.pending,
    )) {
      final normalizedId = device.deviceId.trim().toLowerCase();
      if (normalizedId.isEmpty || !publishedIds.add(normalizedId)) {
        throw const FormatException(
          'Approved and revoked device IDs must be present and unique.',
        );
      }
      if (device.status != RegisteredDeviceStatus.approved) {
        continue;
      }
      final publicKey = device.publicKey?.trim();
      try {
        if (publicKey == null || base64Url.decode(publicKey).length != 32) {
          throw const FormatException();
        }
      } catch (_) {
        throw FormatException(
          '${device.deviceId} has no valid X25519 public key. Delete and register the phone again before publishing.',
        );
      }
    }
  }

  Future<_AdminSigningIdentity> _loadOrCreateSigningIdentity(
    SharedPreferences preferences,
  ) async {
    final encodedPrivateKey = preferences.getString(_signingPrivateKey);
    final encodedPublicKey = preferences.getString(_signingPublicKey);
    if (encodedPrivateKey != null && encodedPublicKey != null) {
      final privateKeyBytes = base64Url.decode(encodedPrivateKey);
      final publicKeyBytes = base64Url.decode(encodedPublicKey);
      return _AdminSigningIdentity(
        privateKeyBytes: privateKeyBytes,
        publicKeyBytes: publicKeyBytes,
      );
    }

    final keyPair = await Ed25519().newKeyPair();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final publicKeyBytes = (await keyPair.extractPublicKey()).bytes;
    await preferences.setString(
      _signingPrivateKey,
      base64UrlEncode(privateKeyBytes),
    );
    await preferences.setString(
      _signingPublicKey,
      base64UrlEncode(publicKeyBytes),
    );
    return _AdminSigningIdentity(
      privateKeyBytes: privateKeyBytes,
      publicKeyBytes: publicKeyBytes,
    );
  }

  Map<String, Object?> _trustEntry(RegisteredDevice device) {
    return {
      'device_id': device.deviceId,
      'owner_name': device.ownerName,
      'role': device.role.name,
      'status': device.status.name,
      'public_key': device.publicKey,
      'key_version': device.keyVersion,
      'updated_at': device.updatedAt.toUtc().toIso8601String(),
    };
  }
}

class _AdminSigningIdentity {
  const _AdminSigningIdentity({
    required this.privateKeyBytes,
    required this.publicKeyBytes,
  });

  final List<int> privateKeyBytes;
  final List<int> publicKeyBytes;

  String get signingKeyId =>
      'ed25519-${sha256.convert(publicKeyBytes).toString().substring(0, 16)}';

  SimpleKeyPairData get keyPair => SimpleKeyPairData(
    privateKeyBytes,
    publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
    type: KeyPairType.ed25519,
  );
}
