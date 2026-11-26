import '../entities/approval_receipt.dart';
import '../entities/device_access_profile.dart';
import '../entities/trust_bundle.dart';

class DeviceAccessResolver {
  const DeviceAccessResolver();

  DeviceAccessProfile resolve({
    required String deviceId,
    required String publicKey,
    required int keyVersion,
    required TrustBundle? bundle,
    SignedApprovalReceipt? receipt,
    DateTime? now,
    String? signingPublicKey,
  }) {
    final normalizedDeviceId = deviceId.trim();
    final checkNow = now ?? DateTime.now();
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

    final bundleValid =
        bundle?.isSignatureVerified == true && !bundle!.isExpiredAt(checkNow);
    final approvedDevice = bundleValid
        ? _findDevice(bundle.approvedDevices, normalizedDeviceId)
        : null;
    if (approvedDevice != null && approvedDevice.status == 'approved') {
      if (!_matchesLocalKey(approvedDevice, publicKey, keyVersion) ||
          (signingPublicKey != null &&
              (approvedDevice.signingPublicKey == null ||
                  _withoutPadding(approvedDevice.signingPublicKey!) !=
                      _withoutPadding(signingPublicKey)))) {
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

    if (receipt != null &&
        receipt.isSignatureVerified &&
        !receipt.isExpiredAt(checkNow) &&
        receipt.matchesPhone(
          deviceId: normalizedDeviceId,
          publicKey: publicKey,
          signingPublicKey: signingPublicKey ?? '',
          keyVersion: keyVersion,
        ) &&
        (receipt.status ?? 'approved') == 'approved' &&
        receipt.role != null &&
        receipt.role!.isNotEmpty) {
      return DeviceAccessProfile(
        deviceId: normalizedDeviceId,
        ownerName: receipt.ownerName,
        level: _approvedLevel(receipt.role!),
      );
    }

    if (bundle?.isSignatureVerified != true) {
      return DeviceAccessProfile.unregistered(deviceId: normalizedDeviceId);
    }
    if (bundle!.isExpiredAt(checkNow)) {
      return DeviceAccessProfile(
        deviceId: normalizedDeviceId,
        level: DeviceAccessLevel.outdatedBundle,
      );
    }
    return DeviceAccessProfile.unregistered(deviceId: normalizedDeviceId);
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
