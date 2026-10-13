import '../../domain/entities/sos_message.dart';

class SosTimingLabels {
  const SosTimingLabels._();

  static String duration(Duration value) {
    if (value.isNegative) return 'Clock mismatch detected';
    if (value.inHours > 0) {
      return '${value.inHours}h ${value.inMinutes.remainder(60).toString().padLeft(2, '0')}m';
    }
    if (value.inMinutes > 0) {
      return '${value.inMinutes}m ${value.inSeconds.remainder(60).toString().padLeft(2, '0')}s';
    }
    return '${value.inSeconds}s';
  }

  static String hops(int count) => switch (count) {
    0 => 'Direct',
    1 => '1 hop',
    _ => '$count hops',
  };

  static bool hasClockMismatch(SosMessage message) =>
      message.receivedAt?.isBefore(message.createdAt) ?? false;

  static String propagation(SosMessage message) {
    if (hasClockMismatch(message)) return 'Clock mismatch detected';
    final travelTime = message.propagationDuration;
    return travelTime == null
        ? 'Propagation time unavailable'
        : 'Travel time ${duration(travelTime)}';
  }

  static String age(SosMessage message, DateTime now) {
    final receipt = message.receivedAt;
    final elapsed = now.difference(receipt ?? message.createdAt);
    if (elapsed.isNegative) return 'Clock mismatch detected';
    return '${receipt == null ? 'Created' : 'Received'} ${duration(elapsed)} ago';
  }

  static String? transport(String? value) => switch (value?.trim()) {
    null || '' => null,
    'bluetooth' || 'ble' => 'Bluetooth (BLE)',
    'wifi_direct' => 'Wi-Fi Direct',
    'mock' => 'Mock (simulation)',
    final value => value,
  };

  static String timestamp(DateTime? value) {
    if (value == null) return 'Not recorded';
    final utc = value.toUtc();
    final date = utc.toIso8601String().split('.').first.replaceFirst('T', ' ');
    return '$date UTC';
  }

  /// SOS TTL is measured from origin creation, not from the latest receipt.
  static String ttl(SosMessage message, DateTime now) {
    if (now.isBefore(message.createdAt)) return 'Clock mismatch detected';
    final remaining = message.createdAt.add(message.ttl).difference(now);
    return remaining <= Duration.zero
        ? 'Expired'
        : '${duration(remaining)} remaining';
  }

  static String shortHash(String value) => value.length <= 16
      ? value
      : '${value.substring(0, 8)}…${value.substring(value.length - 8)}';
}
