import 'package:flutter/services.dart';

class BatterySnapshot {
  const BatterySnapshot({required this.percent, required this.isCharging});

  final double percent;
  final bool isCharging;
}

abstract interface class BatterySampler {
  Future<BatterySnapshot?> sample();
}

class AndroidBatterySampler implements BatterySampler {
  const AndroidBatterySampler({
    MethodChannel channel = const MethodChannel(
      'shadownetwork/android_transport',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<BatterySnapshot?> sample() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getBatteryStatus',
      );
      final percent = (result?['percent'] as num?)?.toDouble();
      if (percent == null) return null;
      return BatterySnapshot(
        percent: percent.clamp(0, 100).toDouble(),
        isCharging: result?['isCharging'] as bool? ?? false,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

class UnavailableBatterySampler implements BatterySampler {
  const UnavailableBatterySampler();

  @override
  Future<BatterySnapshot?> sample() async => null;
}
