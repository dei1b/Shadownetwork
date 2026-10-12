import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/entities/device_crypto_identity.dart';

abstract interface class SecretValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class FlutterSecureSecretValueStore implements SecretValueStore {
  const FlutterSecureSecretValueStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class InMemorySecretValueStore implements SecretValueStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

class DeviceIdentityStore {
  DeviceIdentityStore({
    SecretValueStore secretStore = const FlutterSecureSecretValueStore(),
    X25519? x25519,
  }) : _secretStore = secretStore,
       _x25519 = x25519 ?? X25519();

  static const currentKeyVersion = 1;
  static const _privateKeyName = 'shadow_network_x25519_private_key_v1';
  static const _publicKeyName = 'shadow_network_x25519_public_key_v1';
  static const _keyIdName = 'shadow_network_x25519_key_id_v1';

  final SecretValueStore _secretStore;
  final X25519 _x25519;

  Future<DeviceCryptoIdentity> loadOrCreate() async {
    final privateValue = await _secretStore.read(_privateKeyName);
    final publicValue = await _secretStore.read(_publicKeyName);
    final keyId = await _secretStore.read(_keyIdName);

    if (privateValue != null && publicValue != null && keyId != null) {
      return DeviceCryptoIdentity(
        keyId: keyId,
        keyVersion: currentKeyVersion,
        privateKeyBytes: base64Url.decode(privateValue),
        publicKeyBytes: base64Url.decode(publicValue),
      );
    }

    if (privateValue != null || publicValue != null || keyId != null) {
      await clear();
    }

    final keyPair = await _x25519.newKeyPair();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final publicKeyBytes = (await keyPair.extractPublicKey()).bytes;
    final generatedKeyId = keyIdForPublicKey(publicKeyBytes);

    await _secretStore.write(_privateKeyName, base64UrlEncode(privateKeyBytes));
    await _secretStore.write(_publicKeyName, base64UrlEncode(publicKeyBytes));
    await _secretStore.write(_keyIdName, generatedKeyId);

    return DeviceCryptoIdentity(
      keyId: generatedKeyId,
      keyVersion: currentKeyVersion,
      privateKeyBytes: privateKeyBytes,
      publicKeyBytes: publicKeyBytes,
    );
  }

  Future<void> clear() async {
    await _secretStore.delete(_privateKeyName);
    await _secretStore.delete(_publicKeyName);
    await _secretStore.delete(_keyIdName);
  }

  static String keyIdForPublicKey(List<int> publicKeyBytes) {
    return DeviceCryptoIdentity.keyIdForPublicKey(publicKeyBytes);
  }
}
