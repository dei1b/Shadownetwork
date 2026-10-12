import '../entities/device_access_profile.dart';
import '../entities/trust_bundle.dart';

class DeviceAccessResolver {
  const DeviceAccessResolver();

  DeviceAccessProfile resolve({
    required String deviceId,
    required String publicKey,
    required int keyVersion,
    required TrustBundle? bundle,
    DateTime? now,
  }) {
    final normalizedDeviceId = deviceId.trim();
    final revokedDevice = _findDevice(
      bundle?.revokedDevices,
      normalizedDeviceId,
    );
    if (revokedDevice != null) {
      return DeviceAccessProfile(
        deviceId: normalizedDeviceId,
        ownerName: revokedDevice.ownerName,
        level: DeviceAccessLevel.revoked,
      );
    }

    if (bundle?.isSignatureVerified != true) {
      return DeviceAccessProfile.unregistered(deviceId: normalizedDeviceId);
    }
    if (bundle!.isExpiredAt(now ?? DateTime.now())) {
      return DeviceAccessProfile(
        deviceId: normalizedDeviceId,
        level: DeviceAccessLevel.outdatedBundle,
      );
    }

    final approvedDevice = _findDevice(
      bundle.approvedDevices,
      normalizedDeviceId,
    );
    if (approvedDevice == null || approvedDevice.status != 'approved') {
      return DeviceAccessProfile.unregistered(deviceId: normalizedDeviceId);
    }

    if (!_matchesLocalKey(approvedDevice, publicKey, keyVersion)) {
      return DeviceAccessProfile(
        deviceId: normalizedDeviceId,
        ownerName: approvedDevice.ownerName,
        level: DeviceAccessLevel.keyMismatch,
      );
    }

    return DeviceAccessProfile(
      deviceId: normalizedDeviceId,
      ownerName: approvedDevice.ownerName,
      level: _approvedLevel(approvedDevice.role),
    );
  }

  TrustedDevice? _findDevice(List<TrustedDevice>? devices, String deviceId) {
    if (devices == null) {
      return null;
    }
    for (final device in devices) {
      if (device.deviceId.trim().toLowerCase() == deviceId.toLowerCase()) {
        return device;
      }
    }
    return null;
  }

  bool _matchesLocalKey(
    TrustedDevice device,
    String publicKey,
    int keyVersion,
  ) {
    final trustedPublicKey = device.publicKey?.trim();
    if (trustedPublicKey == null || trustedPublicKey.isEmpty) {
      return false;
    }
    return _withoutPadding(trustedPublicKey) ==
            _withoutPadding(publicKey.trim()) &&
        device.keyVersion == keyVersion;
  }

  String _withoutPadding(String value) => value.replaceAll('=', '');

  DeviceAccessLevel _approvedLevel(String role) {
    return switch (role.trim().toLowerCase()) {
      'responder' || 'rescuer' => DeviceAccessLevel.responder,
      'relay' => DeviceAccessLevel.relay,
      'admin' => DeviceAccessLevel.admin,
      _ => DeviceAccessLevel.civilian,
    };
  }
}
