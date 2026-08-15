enum DeviceAccessLevel {
  unregistered,
  civilian,
  responder,
  relay,
  admin,
  revoked,
  keyMismatch,
  outdatedBundle,
}

class DeviceAccessProfile {
  const DeviceAccessProfile({
    required this.deviceId,
    required this.level,
    this.ownerName,
  });

  const DeviceAccessProfile.unregistered({required String deviceId})
    : this(deviceId: deviceId, level: DeviceAccessLevel.unregistered);

  final String deviceId;
  final DeviceAccessLevel level;
  final String? ownerName;

  bool get canAccessResponderInterface => level == DeviceAccessLevel.responder;

  bool get isApproved => switch (level) {
    DeviceAccessLevel.civilian ||
    DeviceAccessLevel.responder ||
    DeviceAccessLevel.relay ||
    DeviceAccessLevel.admin => true,
    _ => false,
  };

  String get roleLabel => switch (level) {
    DeviceAccessLevel.civilian => 'Civilian',
    DeviceAccessLevel.responder => 'Responder',
    DeviceAccessLevel.relay => 'Relay',
    DeviceAccessLevel.admin => 'Admin',
    DeviceAccessLevel.revoked => 'Revoked',
    DeviceAccessLevel.keyMismatch => 'Key mismatch',
    DeviceAccessLevel.outdatedBundle => 'Bundle expired',
    DeviceAccessLevel.unregistered => 'Unregistered',
  };
}
