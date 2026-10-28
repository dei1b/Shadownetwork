import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class AdminSigningKeyStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// Uses the Windows plugin's protected, per-user secure storage.
class WindowsAdminSigningKeyStore implements AdminSigningKeyStore {
  const WindowsAdminSigningKeyStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;
  final FlutterSecureStorage _storage;
  static const _key = 'shadow_network_desktop_admin_ed25519_v1';
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}
