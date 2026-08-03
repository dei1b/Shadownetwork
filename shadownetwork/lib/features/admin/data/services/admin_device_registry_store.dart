import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/registered_device.dart';

class AdminDeviceRegistryStore {
  static const _devicesKey = 'shadow_network_admin_devices_v1';
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

  String buildTrustBundleJson(List<RegisteredDevice> devices) {
    final approved = devices
        .where((device) => device.status == RegisteredDeviceStatus.approved)
        .map(_trustEntry)
        .toList(growable: false);
    final revoked = devices
        .where((device) => device.status == RegisteredDeviceStatus.revoked)
        .map(_trustEntry)
        .toList(growable: false);

    return const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
      'bundle_type': 'shadow_network_device_trust_bundle',
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'approved_devices': approved,
      'revoked_devices': revoked,
    });
  }

  Map<String, Object?> _trustEntry(RegisteredDevice device) {
    return {
      'device_id': device.deviceId,
      'owner_name': device.ownerName,
      'role': device.role.name,
      'status': device.status.name,
      'public_key': device.publicKey,
      'updated_at': device.updatedAt.toUtc().toIso8601String(),
    };
  }
}
