import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/trust/domain/services/canonical_json.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_event.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_session_data.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_bundle_codec.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_export_service.dart';

import 'support/validation_run_fixtures.dart';

final bundleStart = DateTime.utc(2026, 10, 27, 2);

ValidationSessionData bundleFixture({String? runId = 'RUN-001'}) {
  final base = runFixture(
    id: 'PRIVATE_SENTINEL-session',
    deviceId: 'PRIVATE_SENTINEL-device',
    runId: runId,
    startedAt: bundleStart,
  );
  return ValidationSessionData(
    session: base.session,
    events: [
      ValidationMessageEvent(
        id: 'PRIVATE_SENTINEL-event',
        sessionId: base.session.id,
        type: ValidationEventType.envelopeDelivered,
        occurredAt: bundleStart.add(const Duration(seconds: 3)),
        messageHash: 'message-hash',
        payloadType: 'sos_message',
        transferId: '0123456789abcdef0123456789abcdef',
        peerId: base.session.deviceId,
        hopCount: 2,
        latencyMs: 123,
        error: 'PRIVATE_SENTINEL-error',
        metadata: {
          'payload_text': 'PRIVATE_SENTINEL-body',
          'latitude': 7.123456,
          'private_key': 'PRIVATE_SENTINEL-key',
          'message_created_at': bundleStart.toIso8601String(),
          'runtime_mode': 'foreground',
        },
      ),
    ],
    discoveryAttempts: base.discoveryAttempts,
    batterySamples: base.batterySamples,
    exportRecords: [],
  );
}

SosMessage bundleMessage({
  String hash = 'message-hash',
  DateTime? createdAt,
  DateTime? receivedAt,
}) => SosMessage(
  id: 'PRIVATE_SENTINEL-message',
  sender: const Peer(
    id: 'PRIVATE_SENTINEL-sender',
    name: 'PRIVATE_SENTINEL-name',
    type: PeerType.civilian,
    isConnected: false,
  ),
  body: 'PRIVATE_SENTINEL-SOS',
  category: Category.medical,
  status: MessageStatus.received,
  createdAt: createdAt ?? bundleStart.subtract(const Duration(seconds: 10)),
  receivedAt: receivedAt ?? bundleStart.add(const Duration(seconds: 2)),
  receivedFromPeerId: 'PRIVATE_SENTINEL-relay',
  receivedTransport: 'bluetooth',
  messageHash: hash,
  transferId: '0123456789abcdef0123456789abcdef',
  latitude: 7.123456,
  longitude: 125.654321,
  hopCount: 2,
);

void main() {
  const codec = ValidationBundleCodec();

  test(
    'untrusted correlation strings cannot carry private text out of the phone',
    () {
      final data = bundleFixture();
      final hostile = ValidationSessionData(
        session: data.session,
        events: [
          ValidationMessageEvent(
            id: 'rejected',
            sessionId: data.session.id,
            type: ValidationEventType.envelopeRejected,
            occurredAt: bundleStart,
            messageHash: 'PRIVATE_SENTINEL-name-location',
            transferId: 'PRIVATE_SENTINEL-address',
          ),
        ],
        discoveryAttempts: [],
        batterySamples: [],
        exportRecords: [],
      );
      final bundle = codec.create(data: hostile, messages: [], appVersion: '1');
      expect(codec.encodeJson(bundle), isNot(contains('PRIVATE_SENTINEL')));
      final repeat = codec.create(data: hostile, messages: [], appVersion: '1');
      expect(
        (bundle.toJson()['message_events'] as List).single,
        (repeat.toJson()['message_events'] as List).single,
      );
    },
  );

  test(
    'real hash and transfer IDs remain correlatable across device exports',
    () {
      const hash =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      const transfer = '0123456789abcdef0123456789abcdef';
      for (final device in ['sender', 'receiver']) {
        final data = runFixture(deviceId: device);
        final input = ValidationSessionData(
          session: data.session,
          events: [
            ValidationMessageEvent(
              id: 'event',
              sessionId: data.session.id,
              type: ValidationEventType.envelopeAcknowledged,
              occurredAt: bundleStart,
              messageHash: hash,
              transferId: transfer,
            ),
          ],
          discoveryAttempts: [],
          batterySamples: [],
          exportRecords: [],
        );
        final json = codec
            .create(data: input, messages: [], appVersion: '1')
            .toJson();
        final event = (json['message_events'] as List).single as Map;
        expect(event['message_hash'], hash);
        expect(event['transfer_id'], transfer);
      }
    },
  );

  test(
    'checksum-valid files must enforce receipt linkage, window and privacy fields',
    () {
      final valid = codec.create(
        data: bundleFixture(),
        messages: [bundleMessage()],
        appVersion: '1',
      );
      final mutations = <void Function(Map<String, Object?>)>[
        (json) => json['message_events'] = [],
        (json) {
          final receipt = (json['sos_receipts'] as List).single as Map;
          receipt['received_at'] = '2026-10-27T01:59:59.000Z';
          receipt['propagation_ms'] = 9000;
        },
        (json) => ((json['sos_receipts'] as List).single as Map)['latitude'] =
            7.123456,
        (json) => ((json['message_events'] as List).single as Map)['metadata'] =
            {'private_key': 'secret'},
        (json) => ((json['sos_receipts'] as List).single as Map).remove(
          'trust_status',
        ),
        (json) => (json['device'] as Map)['private_key'] = 'secret',
      ];
      for (final mutate in mutations) {
        final json = valid.toJson();
        mutate(json);
        json.remove('payload_hash');
        json['payload_hash'] = sha256
            .convert(utf8.encode(canonicalJsonEncode(json)))
            .toString();
        expect(() => codec.decodeJson(jsonEncode(json)), throwsFormatException);
      }
    },
  );

  test('periodic active relay battery samples keep their measured context', () {
    final data = bundleFixture();
    final input = ValidationSessionData(
      session: data.session,
      events: data.events,
      discoveryAttempts: [],
      exportRecords: [],
      batterySamples: [
        ValidationBatterySample(
          id: 'battery',
          sessionId: data.session.id,
          batteryPercent: 80,
          isCharging: false,
          sampledAt: bundleStart,
          runtimeMode: 'active_relay',
        ),
      ],
    );
    final json = codec
        .create(data: input, messages: [], appVersion: '1')
        .toJson();
    expect(
      ((json['battery_samples'] as List).single as Map)['runtime_mode'],
      'active_relay',
    );
  });

  test(
    'portable export keeps metrics and omits private/free-form evidence',
    () {
      final bundle = codec.create(
        data: bundleFixture(),
        messages: [bundleMessage()],
        appVersion: '0.1.0+1',
        generatedAt: bundleStart.add(const Duration(minutes: 2)),
      );
      final source = codec.encodeJson(bundle);
      final json = bundle.toJson();
      expect(source, isNot(contains('PRIVATE_SENTINEL')));
      expect(source, isNot(contains('7.123456')));
      expect(source, isNot(contains('125.654321')));
      expect(json['schema_version'], 2);
      expect((json['device'] as Map)['protocol_version'], 2);
      expect((json['device'] as Map)['app_version'], '0.1.0+1');
      final event = (json['message_events'] as List).single as Map;
      expect(event['latency_ms'], 123);
      expect(event['transfer_id'], '0123456789abcdef0123456789abcdef');
      expect(event['error'], 'redacted');
      expect(event['peer_id'], (json['device'] as Map)['peer_id']);
      final receipt = (json['sos_receipts'] as List).single as Map;
      expect(receipt['propagation_ms'], 12000);
      expect(receipt['hop_count'], 2);
      expect(receipt['category'], 'medical');
      expect(receipt['clock_quality'], 'unsynchronized');
      expect(receipt['trust_status'], 'unknown');
      expect(receipt['transport'], 'bluetooth');
      expect(codec.decodeJson(source).toJson(), json);
    },
  );

  test(
    'checksum ignores key order but detects changes including bundle ID',
    () {
      final bundle = codec.create(
        data: bundleFixture(),
        messages: [],
        appVersion: '1',
      );
      final json = bundle.toJson();
      final content = {...json}..remove('payload_hash');
      expect(
        bundle.payloadHash,
        sha256.convert(utf8.encode(canonicalJsonEncode(content))).toString(),
      );
      final reordered = Map.fromEntries(json.entries.toList().reversed);
      expect(codec.decodeJson(jsonEncode(reordered)).id, bundle.id);
      for (final change in [
        {'bundle_id': 'other'},
        {'payload_hash': '0' * 64},
        {'schema_version': 3},
        {'bundle_type': 'other'},
      ]) {
        expect(
          () => codec.decodeJson(jsonEncode({...json, ...change})),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'receipt selection excludes other hashes and dates; keeps first receipt',
    () {
      final bundle = codec.create(
        data: bundleFixture(),
        messages: [
          bundleMessage(hash: 'not-in-session'),
          bundleMessage(
            receivedAt: bundleStart.add(const Duration(minutes: 2)),
          ),
          bundleMessage(
            receivedAt: bundleStart.subtract(const Duration(seconds: 1)),
          ),
          bundleMessage(
            receivedAt: bundleStart.add(const Duration(seconds: 8)),
          ),
          bundleMessage(),
        ],
        appVersion: '1',
      );
      final receipt = (bundle.toJson()['sos_receipts'] as List).single as Map;
      expect(receipt['received_at'], '2026-10-27T02:00:02.000Z');
      expect(receipt['propagation_ms'], 12000);
    },
  );

  test('negative cross-device interval is unavailable with clock warning', () {
    final bundle = codec.create(
      data: bundleFixture(),
      messages: [
        bundleMessage(createdAt: bundleStart.add(const Duration(seconds: 10))),
      ],
      appVersion: '1',
    );
    final receipt = (bundle.toJson()['sos_receipts'] as List).single as Map;
    expect(receipt['propagation_ms'], isNull);
    expect(receipt['clock_quality'], 'invalid_order');
  });

  test('fresh IDs/filenames; stable pseudonyms only within the same run', () {
    final first = codec.create(
      data: bundleFixture(),
      messages: [],
      appVersion: '1',
      generatedAt: bundleStart,
    );
    final second = codec.create(
      data: bundleFixture(),
      messages: [],
      appVersion: '1',
      generatedAt: bundleStart,
    );
    final other = codec.create(
      data: bundleFixture(runId: 'RUN-002'),
      messages: [],
      appVersion: '1',
      generatedAt: bundleStart,
    );
    expect(second.id, isNot(first.id));
    expect(second.filename, isNot(first.filename));
    expect(
      first.filename,
      matches(
        RegExp(
          r'^shadow-network-RUN-001-[a-z0-9-]+-20261027T020000Z-[a-f0-9]+\.json$',
        ),
      ),
    );
    expect(
      (first.toJson()['device'] as Map)['peer_id'],
      (second.toJson()['device'] as Map)['peer_id'],
    );
    expect(
      (first.toJson()['device'] as Map)['peer_id'],
      isNot((other.toJson()['device'] as Map)['peer_id']),
    );
    final changed = first.toJson();
    (changed['device'] as Map)['peer_id'] = 'mutated';
    expect((first.toJson()['device'] as Map)['peer_id'], isNot('mutated'));
  });

  test(
    'legacy clipboard stays readable; portable export requires run identity',
    () {
      final legacy = bundleFixture(runId: null);
      const oldCodec = ValidationExportService();
      expect(
        oldCodec.decodeJson(oldCodec.encodeJson(legacy)).session.testRunId,
        isNull,
      );
      expect(
        () => codec.create(data: legacy, messages: [], appVersion: '1'),
        throwsStateError,
      );
    },
  );

  test('records from another session cannot be exported under this one', () {
    final data = bundleFixture();
    final wrong = ValidationSessionData(
      session: data.session,
      events: runFixture(id: 'different').events,
      discoveryAttempts: [],
      batterySamples: [],
      exportRecords: [],
    );
    expect(
      () => codec.create(data: wrong, messages: [], appVersion: '1'),
      throwsFormatException,
    );
  });
}
