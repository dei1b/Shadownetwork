import 'dart:convert';

import 'device_crypto_identity.dart';

class DeviceRegistrationQr {
  const DeviceRegistrationQr({
    required this.deviceId,
    required this.publicKey,
    required this.keyId,
    required this.keyVersion,
  });

  static const schemaVersion = 1;
  static const registrationType = 'shadow_network_device_registration';

  final String deviceId;
  final String publicKey;
  final String keyId;
  final int keyVersion;

  factory DeviceRegistrationQr.fromIdentity({
    required String deviceId,
    required DeviceCryptoIdentity identity,
  }) {
    return DeviceRegistrationQr(
      deviceId: deviceId,
      publicKey: identity.encodedPublicKey,
      keyId: identity.keyId,
      keyVersion: identity.keyVersion,
    );
  }

  Map<String, Object?> toJson() => {
    'registration_type': registrationType,
    'schema_version': schemaVersion,
    'device_id': deviceId,
    'public_key': publicKey,
    'key_id': keyId,
    'key_version': keyVersion,
  };

  String toJsonString() => jsonEncode(toJson());

  factory DeviceRegistrationQr.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Registration QR must contain an object.');
    }
    return DeviceRegistrationQr.fromJson(Map<String, Object?>.from(decoded));
  }

  factory DeviceRegistrationQr.fromJson(Map<String, Object?> json) {
    if (json['registration_type'] != registrationType ||
        json['schema_version'] != schemaVersion) {
      throw const FormatException('Unsupported device registration QR.');
    }
    if (json.containsKey('private_key')) {
      throw const FormatException(
        'Registration QR must never contain a private key.',
      );
    }
    final deviceId = (json['device_id'] as String? ?? '').trim();
    final publicKey = (json['public_key'] as String? ?? '').trim();
    final keyId = (json['key_id'] as String? ?? '').trim();
    final keyVersion = (json['key_version'] as num?)?.toInt() ?? 0;
    if (deviceId.isEmpty || publicKey.isEmpty || keyId.isEmpty) {
      throw const FormatException('Registration QR is missing device data.');
    }
    if (keyVersion <= 0) {
      throw const FormatException('Registration QR key version is invalid.');
    }

    List<int> publicKeyBytes;
    try {
      publicKeyBytes = base64Url.decode(publicKey);
    } catch (_) {
      throw const FormatException(
        'Registration QR public key is not valid base64url.',
      );
    }
    if (publicKeyBytes.length != 32) {
      throw const FormatException(
        'Registration QR public key must contain 32 bytes.',
      );
    }
    if (DeviceCryptoIdentity.keyIdForPublicKey(publicKeyBytes) != keyId) {
      throw const FormatException('Registration QR key ID does not match.');
    }

    return DeviceRegistrationQr(
      deviceId: deviceId,
      publicKey: publicKey,
      keyId: keyId,
      keyVersion: keyVersion,
    );
  }
}
