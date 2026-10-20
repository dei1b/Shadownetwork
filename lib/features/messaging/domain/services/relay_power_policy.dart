class RelayPowerPolicy {
  const RelayPowerPolicy({required this.profile, required this.syncInterval});

  final String profile;
  final Duration syncInterval;

  factory RelayPowerPolicy.resolve({
    required bool background,
    required bool hasQueuedMessages,
    double? batteryPercent,
    bool charging = false,
  }) {
    if (!charging && batteryPercent != null && batteryPercent <= 20) {
      return RelayPowerPolicy(
        profile: 'saving',
        syncInterval: Duration(seconds: hasQueuedMessages ? 15 : 60),
      );
    }
    if (hasQueuedMessages) {
      return const RelayPowerPolicy(
        profile: 'active',
        syncInterval: Duration(seconds: 4),
      );
    }
    return RelayPowerPolicy(
      profile: 'balanced',
      syncInterval: Duration(seconds: background ? 30 : 12),
    );
  }
}
