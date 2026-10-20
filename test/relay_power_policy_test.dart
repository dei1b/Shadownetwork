import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/services/relay_power_policy.dart';

void main() {
  test(
    'recent emergency traffic gets faster discovery while idle relays back off',
    () {
      expect(
        RelayPowerPolicy.resolve(
          background: false,
          hasQueuedMessages: true,
        ).syncInterval,
        const Duration(seconds: 4),
      );
      expect(
        RelayPowerPolicy.resolve(
          background: true,
          hasQueuedMessages: false,
        ).syncInterval,
        const Duration(seconds: 30),
      );
      expect(
        RelayPowerPolicy.resolve(
          background: false,
          hasQueuedMessages: false,
        ).syncInterval,
        const Duration(seconds: 12),
      );
    },
  );

  test('low battery keeps emergency relay available with reduced scanning', () {
    final urgent = RelayPowerPolicy.resolve(
      background: true,
      hasQueuedMessages: true,
      batteryPercent: 15,
    );
    final idle = RelayPowerPolicy.resolve(
      background: true,
      hasQueuedMessages: false,
      batteryPercent: 15,
    );
    expect(urgent.profile, 'saving');
    expect(urgent.syncInterval, const Duration(seconds: 15));
    expect(idle.syncInterval, const Duration(seconds: 60));
    expect(
      RelayPowerPolicy.resolve(
        background: true,
        hasQueuedMessages: true,
        batteryPercent: 15,
        charging: true,
      ).profile,
      'active',
    );
  });
}
