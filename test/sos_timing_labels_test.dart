import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/presentation/utils/sos_timing_labels.dart';

void main() {
  for (final sample in [
    (Duration.zero, '0s'),
    (const Duration(seconds: 18), '18s'),
    (const Duration(seconds: 59), '59s'),
    (const Duration(minutes: 1), '1m 00s'),
    (const Duration(minutes: 12, seconds: 8), '12m 08s'),
    (const Duration(minutes: 59, seconds: 59), '59m 59s'),
    (const Duration(hours: 1), '1h 00m'),
    (const Duration(hours: 1, minutes: 14), '1h 14m'),
    (const Duration(days: 2, minutes: 3), '48h 03m'),
  ]) {
    test('formats duration ${sample.$2}', () {
      expect(SosTimingLabels.duration(sample.$1), sample.$2);
    });
  }

  test('missing and inconsistent receipts are not invented measurements', () {
    final created = DateTime.utc(2026, 10, 14, 2);
    final message = _message(created);
    expect(
      SosTimingLabels.propagation(message),
      'Propagation time unavailable',
    );
    expect(
      SosTimingLabels.age(message, created.add(const Duration(seconds: 18))),
      'Created 18s ago',
    );
    final skew = message.copyWith(
      receivedAt: created.subtract(const Duration(seconds: 1)),
    );
    expect(SosTimingLabels.propagation(skew), 'Clock mismatch detected');
    expect(SosTimingLabels.hasClockMismatch(skew), isTrue);
    expect(
      SosTimingLabels.age(
        message.copyWith(receivedAt: created.add(const Duration(seconds: 1))),
        created,
      ),
      'Clock mismatch detected',
    );
  });

  test(
    'TTL uses creation, preserves expiry boundary, and flags future clocks',
    () {
      final created = DateTime.utc(2026, 10, 14, 2);
      final message = _message(created).copyWith(
        ttl: const Duration(minutes: 5),
        receivedAt: created.add(const Duration(minutes: 4)),
      );
      expect(
        SosTimingLabels.ttl(message, created.add(const Duration(minutes: 4))),
        '1m 00s remaining',
      );
      expect(
        SosTimingLabels.ttl(message, created.add(const Duration(minutes: 5))),
        'Expired',
      );
      expect(
        SosTimingLabels.ttl(message, created.add(const Duration(minutes: 6))),
        'Expired',
      );
      expect(
        SosTimingLabels.ttl(
          message,
          created.subtract(const Duration(seconds: 1)),
        ),
        'Clock mismatch detected',
      );
    },
  );

  test(
    'hop, transport, audit time and hash labels preserve source meaning',
    () {
      expect(SosTimingLabels.hops(0), 'Direct');
      expect(SosTimingLabels.hops(1), '1 hop');
      expect(SosTimingLabels.hops(3), '3 hops');
      expect(SosTimingLabels.transport(null), isNull);
      expect(SosTimingLabels.transport('  '), isNull);
      expect(SosTimingLabels.transport('wifi_direct'), 'Wi-Fi Direct');
      expect(SosTimingLabels.transport('bluetooth'), 'Bluetooth (BLE)');
      expect(SosTimingLabels.transport('mock'), 'Mock (simulation)');
      expect(
        SosTimingLabels.timestamp(DateTime.parse('2026-10-14T10:00:00+08:00')),
        '2026-10-14 02:00:00 UTC',
      );
      expect(SosTimingLabels.timestamp(null), 'Not recorded');
      expect(
        SosTimingLabels.shortHash('0123456789abcdefghijkl'),
        '01234567…efghijkl',
      );
      expect(SosTimingLabels.shortHash('short'), 'short');
    },
  );
}

SosMessage _message(DateTime createdAt) => SosMessage(
  id: 'test',
  sender: const Peer(
    id: 'resident',
    name: 'Resident',
    type: PeerType.civilian,
    isConnected: false,
  ),
  body: 'Need help',
  category: Category.medical,
  status: MessageStatus.received,
  createdAt: createdAt,
);
