import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'device_identity_store.dart';
import '../../domain/entities/device_signing_identity.dart';

/// Kept separately from the X25519 decryption key and never exported.
class DeviceSigningIdentityStore {
  DeviceSigningIdentityStore({
    SecretValueStore secretStore = const FlutterSecureSecretValueStore(),
  }) : _secretStore = secretStore;

  static const _storageKey = 'shadow_network_device_signing_identity_v1';
  final SecretValueStore _secretStore;
  Future<DeviceSigningIdentity>? _pending;

  Future<DeviceSigningIdentity> loadOrCreate() => _pending ??= _loadOrCreate();

  Future<DeviceSigningIdentity> _loadOrCreate() async {
    try {
      final source = await _secretStore.read(_storageKey);
      if (source != null) {
        final json = jsonDecode(source) as Map<String, Object?>;
        final privateBytes = base64Url.decode(json['private_key']! as String);
        final publicBytes = base64Url.decode(json['public_key']! as String);
        final pair = await Ed25519().newKeyPairFromSeed(privateBytes);
        if (privateBytes.length != 32 ||
            base64UrlEncode((await pair.extractPublicKey()).bytes) !=
                base64UrlEncode(publicBytes)) {
          throw const FormatException('Stored signing identity is invalid.');
        }
        return DeviceSigningIdentity(
          privateKeyBytes: privateBytes,
          publicKeyBytes: publicBytes,
        );
      }
      final pair = await Ed25519().newKeyPair();
      final identity = DeviceSigningIdentity(
        privateKeyBytes: await pair.extractPrivateKeyBytes(),
        publicKeyBytes: (await pair.extractPublicKey()).bytes,
      );
      await _secretStore.write(
        _storageKey,
        jsonEncode({
          'private_key': base64UrlEncode(identity.privateKeyBytes),
          'public_key': identity.encodedPublicKey,
        }),
      );
      return identity;
    } catch (_) {
      // Preserve corrupt storage for recovery; never silently replace an identity.
      _pending = null;
      rethrow;
    }
  }
}
