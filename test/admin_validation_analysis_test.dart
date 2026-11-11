import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin_validation/domain/validation_analysis.dart';
import 'admin_validation_import_repository_test.dart' show importFixture;

AnalysisRecord event(
  String id,
  String type, {
  String device = 'a',
  String run = 'run',
  String transfer = 't',
  int latency = 100,
  String radio = 'bluetooth',
  bool fallback = false,
  int hour = 0,
  String hash = 'hash',
}) => AnalysisRecord(run, device, 'responder', 's', 'message_events', {
  'id': id,
  'event_type': type,
  'transfer_id': transfer,
  'message_hash': hash,
  'peer_id': 'target',
  'transport': radio,
  'latency_ms': latency,
  'occurred_at': DateTime.utc(2026, 11, 11, hour).toIso8601String(),
  'fallback_used': fallback,
  'metadata': {'phase': 'send'},
});
ValidationRunAnalysis calculate(
  List<AnalysisRecord> records, {
  ValidationAnalysisFilter filter = const ValidationAnalysisFilter(run: 'run'),
}) => const ValidationAnalysisCalculator().calculate([
  ValidationAnalysisInput(records, []),
], filter);
void main() {
  test(
    'failure after window closes offer and uncorrelated failures stay visible',
    () {
      final result = calculate(
        [
          event('o', 'envelopeOffered'),
          event('f', 'envelopeRejected', hour: 2),
        ],
        filter: ValidationAnalysisFilter(
          run: 'run',
          end: DateTime.utc(2026, 11, 11, 1),
        ),
      );
      expect(result.failed, 1);
      expect(result.open, 0);
      final missing = AnalysisRecord(
        'run',
        'a',
        'responder',
        's',
        'message_events',
        {
          'id': 'missing',
          'event_type': 'envelopeRejected',
          'occurred_at': '2026-11-11T00:00:00Z',
          'metadata': {'phase': 'send'},
        },
      );
      expect(calculate([missing]).issues.join(), contains('1 uncorrelated'));
    },
  );
  test('earliest valid receipt wins over invalid ordering', () {
    AnalysisRecord receipt(String received) =>
        AnalysisRecord('run', 'a', 'responder', 's', 'sos_receipts', {
          'message_hash': 'hash',
          'received_at': received,
          'created_at': '2026-11-11T01:00:00Z',
          'hop_count': 2,
        });
    final result = calculate([
      receipt('2026-11-11T00:00:00Z'),
      receipt('2026-11-11T01:00:01Z'),
    ]);
    expect(result.receipts.length, 1);
    expect(result.propagation.mean, 1000);
  });
  test('large overlapping evidence stays linear and deduplicated', () {
    final records = List.generate(
      50000,
      (i) => event('s$i', 'envelopeSent', transfer: '$i'),
    );
    final watch = Stopwatch()..start();
    final result = calculate([...records, ...records]);
    watch.stop();
    expect(result.sent, 50000);
    // Measurement only, not a project performance acceptance threshold.
    // ignore: avoid_print
    print(
      '100000 overlapping records analyzed in ${watch.elapsedMilliseconds} ms',
    );
  });
  test('validated decoder retains records and rejects tampering', () {
    final file = importFixture();
    final input = const ValidationAnalysisDecoder().decode(file.source);
    expect(input.records, isNotEmpty);
    expect(
      () => const ValidationAnalysisDecoder().decode(
        file.source.replaceFirst('test', 'modified'),
      ),
      throwsFormatException,
    );
  });
  test(
    'overlapping snapshots, repeated event and cross-session telemetry do not inflate attempts',
    () {
      final offer = event('1', 'envelopeOffered');
      final ack = event('2', 'envelopeAcknowledged');
      final result = calculate([
        offer,
        ack,
        offer,
        ack,
        event('3', 'envelopeSent', fallback: true),
      ]);
      expect(result.offered, 1);
      expect(result.acknowledged, 1);
      expect(result.sent, 1);
      expect(result.fallback, 1);
    },
  );
  test('ACK after offer time window still matches', () {
    final result = calculate(
      [
        event('1', 'envelopeOffered'),
        event('2', 'envelopeAcknowledged', hour: 2),
      ],
      filter: ValidationAnalysisFilter(
        run: 'run',
        end: DateTime.utc(2026, 11, 11, 1),
      ),
    );
    expect(result.acknowledged, 1);
  });
  test(
    'device and run isolate reused transfer IDs; mismatched identities excluded',
    () {
      final result = calculate([
        event('1', 'envelopeOffered'),
        event('2', 'envelopeAcknowledged', device: 'b'),
        event('3', 'envelopeAcknowledged', run: 'other'),
      ]);
      expect(result.acknowledged, 0);
      expect(result.open, 1);
      expect(
        calculate([
          event('1', 'envelopeOffered'),
          event('2', 'envelopeAcknowledged', hash: 'different'),
        ]).offered,
        0,
      );
    },
  );
  test('conflicting duplicate records excluded', () {
    final result = calculate([
      event('same', 'envelopeSent'),
      event('same', 'envelopeSent', radio: 'wifi_direct'),
    ]);
    expect(result.sent, 0);
    expect(result.issues.join(), contains('conflicting'));
  });
  test('partial responder data supplies no final receipt estimates', () {
    final result = calculate([event('1', 'envelopeReceived')]);
    expect(result.receipts, isEmpty);
    expect(result.hops, isEmpty);
    expect(result.latency.mean, isNull);
    expect(result.offered, 0);
  });
  test('statistics use midpoint median and nearest rank P95', () {
    final stats = AnalysisStatistics([100, 200, 300, 400]);
    expect(stats.mean, 250);
    expect(stats.median, 250);
    expect(stats.p95, 400);
  });
  test('fallback and ACK rates use distinct populations', () {
    final records = <AnalysisRecord>[];
    for (var i = 0; i < 4; i++) {
      records.add(event('o$i', 'envelopeOffered', transfer: '$i'));
      records.add(
        event('s$i', 'envelopeSent', transfer: '$i', fallback: i == 0),
      );
      if (i < 3) {
        records.add(event('a$i', 'envelopeAcknowledged', transfer: '$i'));
      }
    }
    final result = calculate(records);
    expect(result.acknowledged / result.offered, .75);
    expect(result.fallback / result.sent, .25);
    expect(result.transports, {'bluetooth': 4});
  });
  AnalysisRecord battery(
    String id,
    int hour,
    int percent, {
    bool charging = false,
  }) => AnalysisRecord('run', 'a', 'responder', 's', 'battery_samples', {
    'id': id,
    'sampled_at': DateTime.utc(2026, 11, 11, hour).toIso8601String(),
    'battery_percent': percent,
    'is_charging': charging,
  });
  test('battery needs unplugged non-rising ordered samples', () {
    expect(
      calculate([
        battery('1', 0, 80),
        battery('2', 1, 78),
      ]).battery.values.single,
      2,
    );
    expect(
      calculate([
        battery('1', 0, 80),
        battery('2', 1, 78, charging: true),
      ]).battery.values.single,
      isNull,
    );
    expect(
      calculate([
        battery('1', 0, 80),
        battery('2', 1, 81),
      ]).battery.values.single,
      isNull,
    );
  });
  test('receipt hops require SOS receipts; negative propagation excluded', () {
    final r = AnalysisRecord('run', 'a', 'responder', 's', 'sos_receipts', {
      'message_hash': 'hash',
      'received_at': '2026-11-11T00:00:00Z',
      'created_at': '2026-11-11T01:00:00Z',
      'hop_count': 2,
    });
    final result = calculate([r, r, event('x', 'envelopeDelivered')]);
    expect(result.receipts.length, 1);
    expect(result.hops, {'2': 1});
    expect(result.propagation.count, 0);
    expect(result.issues.join(), contains('Invalid'));
  });
}
