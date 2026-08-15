enum DeviceTrustStatus {
  approved,
  unknown,
  revoked;

  String get displayLabel => switch (this) {
    DeviceTrustStatus.approved => 'Verified',
    DeviceTrustStatus.unknown => 'Unverified',
    DeviceTrustStatus.revoked => 'Revoked',
  };
}
