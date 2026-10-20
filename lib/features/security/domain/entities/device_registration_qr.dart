import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'device_signing_identity.dart';
import '../../../trust/domain/services/canonical_json.dart';
import 'device_crypto_identity.dart';

class DeviceRegistrationQr {
  const DeviceRegistrationQr({
    required this.deviceId,
    required this.publicKey,
    required this.keyId,
    required this.keyVersion,
    this.signingPublicKey,
    this.registrationSignature,
  });

  static const schemaVersion = 1;
  static const registrationType = 'shadow_network_device_registration';

  final String deviceId;
  final String publicKey;
  final String keyId;
  final int keyVersion;
  final String? signingPublicKey;
  final String? registrationSignature;

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

  static Future<DeviceRegistrationQr> createSigned({
    required String deviceId,
    required DeviceCryptoIdentity identity,
    required DeviceSigningIdentity signingIdentity,
  }) async {
    final draft = DeviceRegistrationQr(
      deviceId: deviceId,
      publicKey: identity.encodedPublicKey,
      keyId: identity.keyId,
      keyVersion: identity.keyVersion,
      signingPublicKey: signingIdentity.encodedPublicKey,
    );
    final signature = await Ed25519().sign(
      utf8.encode(draft._signingData()),
      keyPair: signingIdentity.keyPair,
    );
    return DeviceRegistrationQr(
      deviceId: draft.deviceId,
      publicKey: draft.publicKey,
      keyId: draft.keyId,
      keyVersion: draft.keyVersion,
      signingPublicKey: draft.signingPublicKey,
      registrationSignature: base64UrlEncode(signature.bytes),
    );
  }

  String _signingData() {
    final payload = toJson()..remove('registration_signature');
    return 'shadow-network-registration-v2\n${canonicalJsonEncode(payload)}';
  }

  Future<void> verifySignature() async {
    if (signingPublicKey == null || registrationSignature == null) {
      throw const FormatException(
        'Show a new registration QR from the updated phone app.',
      );
    }
    try {
      final key = base64Url.decode(signingPublicKey!);
      final signature = base64Url.decode(registrationSignature!);
      if (key.length != 32 ||
          signature.length != 64 ||
          !await Ed25519().verify(
            utf8.encode(_signingData()),
            signature: Signature(
              signature,
              publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
            ),
          )) {
        throw const FormatException('Registration signature is invalid.');
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Registration signature is invalid.');
    }
  }

  Map<String, Object?> toJson() => {
    'registration_type': registrationType,
    'schema_version': signingPublicKey == null ? schemaVersion : 2,
    'device_id': deviceId,
    'public_key': publicKey,
    'key_id': keyId,
    'key_version': keyVersion,
    if (signingPublicKey != null) 'signing_public_key': signingPublicKey,
    if (registrationSignature != null)
      'registration_signature': registrationSignature,
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
        (json['schema_version'] != schemaVersion &&
            json['schema_version'] != 2)) {
      throw const FormatException('Unsupported device registration QR.');
    }
    if (json.containsKey('private_key') ||
        json.containsKey('signing_private_key')) {
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
      signingPublicKey: json['signing_public_key'] as String?,
      registrationSignature: json['registration_signature'] as String?,
    );
  }
}
