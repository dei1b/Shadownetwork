import '../../../messaging/domain/entities/category.dart';
import '../../../messaging/domain/entities/message_moderation_status.dart';
import '../../../trust/domain/entities/device_trust_status.dart';
import '../entities/validation_event.dart';
import 'validation_bundle_identifiers.dart';
import 'validation_run_identity.dart';

/// Structural/privacy validation is separate from the codec's integrity check.
class ValidationBundleValidator {
  const ValidationBundleValidator();

  static const runtimeModes = {
    'foreground',
    'background',
    'stopped',
    'active_relay',
    'unknown',
  };
  static const transports = {
    'bluetooth',
    'ble',
    'wifi_direct',
    'mock',
    'hybrid',
    'unknown',
  };

  void validate(Map<String, dynamic> json) {
    _fields(json, {
      'schema_version',
      'bundle_type',
      'bundle_id',
      'generated_at',
      'payload_hash',
      'test_run',
      'device',
      'session',
      'privacy',
      'sos_receipts',
      'message_events',
      'discovery_attempts',
      'battery_samples',
    });
    _pattern(json['bundle_id'], r'^bundle-[a-f0-9]{32}$');
    final generated = _date(json, 'generated_at');
    final run = _map(json['test_run']);
    _fields(run, {'id', 'name', 'environment'});
    final runId = _string(run, 'id');
    if (ValidationRunIdentity.normalizeCode(runId) != runId) {
      throw const FormatException('Invalid run code.');
    }
    _string(run, 'name');
    _string(run, 'environment');
    final device = _map(json['device']);
    _fields(device, {'peer_id', 'role', 'app_version', 'protocol_version'});
    _peer(device['peer_id']);
    _member(device['role'], {
      'responder',
      'civilian',
      'relay',
      'admin',
      'unknown',
    });
    _pattern(device['app_version'], r'^[0-9A-Za-z.+_-]{1,80}$');
    if (_nonNegative(device, 'protocol_version') < 1) {
      throw const FormatException('Invalid transport version.');
    }
    final session = _map(json['session']);
    _fields(session, {'id', 'started_at', 'ended_at', 'status'});
    _pattern(session['id'], r'^session-[a-f0-9]{64}$');
    final sessionId = session['id'];
    final start = _date(session, 'started_at');
    _member(session['status'], {'active', 'completed'});
    final completed = session['status'] == 'completed';
    if (completed == (session['ended_at'] == null)) {
      throw const FormatException('Invalid session end/status.');
    }
    final end = completed ? _date(session, 'ended_at') : generated;
    if (end.isBefore(start)) {
      throw const FormatException('Invalid recording interval.');
    }
    final privacy = _map(json['privacy']);
    _fields(privacy, {'mode', 'identifiers', 'clock_synchronized'});
    if (privacy['mode'] != 'metrics_only' ||
        privacy['identifiers'] != 'run_scoped_sha256_pseudonyms' ||
        privacy['clock_synchronized'] != false) {
      throw const FormatException('Unsupported privacy/clock mode.');
    }
    final deliveredHashes = <String>{};
    for (final event in _records(json, 'message_events')) {
      _fields(event, {
        'id',
        'session_id',
        'event_type',
        'occurred_at',
        'message_hash',
        'transfer_id',
        'payload_type',
        'peer_id',
        'transport',
        'hop_count',
        'error',
        'fallback_used',
        'latency_ms',
        'metadata',
      });
      _owned(event, sessionId, 'event');
      _member(
        event['event_type'],
        ValidationEventType.values.map((e) => e.name),
      );
      _date(event, 'occurred_at');
      _correlation(event['message_hash'], 'message', nullable: true);
      _correlation(event['transfer_id'], 'transfer', nullable: true);
      if (event['payload_type'] != null) {
        _member(event['payload_type'], {
          'sos_message',
          'chat_message',
          'unknown',
        });
      }
      if (event['peer_id'] != null) _peer(event['peer_id']);
      _transport(event['transport'], nullable: true);
      if (event['hop_count'] != null) _nonNegative(event, 'hop_count');
      if (event['latency_ms'] != null) _nonNegative(event, 'latency_ms');
      _error(event['error']);
      _bool(event['fallback_used']);
      final metadata = _map(event['metadata']);
      if (metadata.keys.any(
        (key) => !{'message_created_at', 'runtime_mode', 'phase'}.contains(key),
      )) {
        throw const FormatException('Unsupported event metadata.');
      }
      if (metadata.containsKey('message_created_at')) {
        _date(metadata, 'message_created_at');
      }
      if (metadata.containsKey('runtime_mode')) {
        _member(metadata['runtime_mode'], runtimeModes);
      }
      if (metadata.containsKey('phase')) {
        _member(metadata['phase'], {'send', 'receive', 'ack_send'});
      }
      if (event['event_type'] == 'envelopeDelivered' &&
          event['payload_type'] == 'sos_message' &&
          event['message_hash'] is String) {
        deliveredHashes.add(event['message_hash'] as String);
      }
    }
    for (final attempt in _records(json, 'discovery_attempts')) {
      _fields(attempt, {
        'id',
        'session_id',
        'transport',
        'started_at',
        'ended_at',
        'discovered_count',
        'success',
        'error',
      });
      _owned(attempt, sessionId, 'discovery');
      _transport(attempt['transport']);
      if (_date(attempt, 'ended_at').isBefore(_date(attempt, 'started_at'))) {
        throw const FormatException('Invalid discovery interval.');
      }
      _nonNegative(attempt, 'discovered_count');
      _bool(attempt['success']);
      _error(attempt['error']);
    }
    for (final sample in _records(json, 'battery_samples')) {
      _fields(sample, {
        'id',
        'session_id',
        'battery_percent',
        'is_charging',
        'sampled_at',
        'runtime_mode',
      });
      _owned(sample, sessionId, 'battery');
      _date(sample, 'sampled_at');
      _bool(sample['is_charging']);
      _member(sample['runtime_mode'], runtimeModes);
      final battery = sample['battery_percent'];
      if (battery is! num ||
          !battery.isFinite ||
          battery < 0 ||
          battery > 100) {
        throw const FormatException('Invalid battery sample.');
      }
    }
    for (final receipt in _records(
      json,
      'sos_receipts',
      idKey: 'message_hash',
    )) {
      _fields(receipt, {
        'message_hash',
        'category',
        'created_at',
        'received_at',
        'propagation_ms',
        'clock_quality',
        'hop_count',
        'last_peer_id',
        'transfer_id',
        'transport',
        'trust_status',
        'moderation_status',
      });
      _correlation(receipt['message_hash'], 'message');
      _correlation(receipt['transfer_id'], 'transfer', nullable: true);
      _member(receipt['category'], Category.values.map((c) => c.name));
      _member(
        receipt['trust_status'],
        DeviceTrustStatus.values.map((s) => s.name),
      );
      _member(
        receipt['moderation_status'],
        MessageModerationStatus.values.map((s) => s.name),
      );
      if (receipt['last_peer_id'] != null) _peer(receipt['last_peer_id']);
      _transport(receipt['transport'], nullable: true);
      _nonNegative(receipt, 'hop_count');
      final created = _date(receipt, 'created_at');
      final received = _date(receipt, 'received_at');
      if (received.isBefore(start) ||
          received.isAfter(end) ||
          !deliveredHashes.contains(receipt['message_hash'])) {
        throw const FormatException(
          'Receipt is outside this session or has no SOS delivery event.',
        );
      }
      final duration = received.difference(created);
      final invalidOrder = duration.isNegative;
      if (invalidOrder
          ? receipt['propagation_ms'] != null ||
                receipt['clock_quality'] != 'invalid_order'
          : receipt['propagation_ms'] != duration.inMilliseconds ||
                receipt['clock_quality'] != 'unsynchronized') {
        throw const FormatException('Invalid receipt timing.');
      }
      if (!invalidOrder) _nonNegative(receipt, 'propagation_ms');
    }
  }

  static void _fields(Map map, Set<String> fields) {
    if (map.length != fields.length || !fields.every(map.containsKey)) {
      throw const FormatException('Missing or unsupported validation fields.');
    }
  }

  static Map _map(Object? value) {
    if (value is! Map) {
      throw const FormatException('Expected validation object.');
    }
    return value;
  }

  static String _string(Map map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Invalid $key.');
    }
    return value;
  }

  static DateTime _date(Map map, String key) {
    final value = _string(map, key);
    final date = DateTime.tryParse(value);
    if (date == null || !value.endsWith('Z')) {
      throw FormatException('Invalid UTC $key.');
    }
    return date;
  }

  static int _nonNegative(Map map, String key) {
    final value = map[key];
    if (value is! int || value < 0) throw FormatException('Invalid $key.');
    return value;
  }

  static void _pattern(Object? value, String pattern) {
    if (value is! String || !RegExp(pattern).hasMatch(value)) {
      throw const FormatException('Invalid validation identifier.');
    }
  }

  static void _member(Object? value, Iterable<String> values) {
    if (!values.contains(value)) {
      throw const FormatException('Unsupported validation value.');
    }
  }

  static void _peer(Object? value) => _pattern(value, r'^peer-[a-f0-9]{64}$');
  static void _bool(Object? value) {
    if (value is! bool) throw const FormatException('Invalid validation flag.');
  }

  static void _error(Object? value) {
    if (value != null && value != 'redacted') {
      throw const FormatException('Free-form errors are not portable.');
    }
  }

  static void _transport(Object? value, {bool nullable = false}) {
    if (nullable && value == null) return;
    _member(value, transports);
  }

  static void _correlation(
    Object? value,
    String kind, {
    bool nullable = false,
  }) {
    if (nullable && value == null) return;
    if (!ValidationBundleIdentifiers.isCorrelation(kind, value)) {
      throw const FormatException('Invalid correlation ID.');
    }
  }

  static void _owned(Map record, Object? sessionId, String kind) {
    _pattern(record['id'], '^$kind-[a-f0-9]{64}\$');
    if (record['session_id'] != sessionId) {
      throw const FormatException('Evidence belongs to another session.');
    }
  }

  static Iterable<Map> _records(
    Map json,
    String key, {
    String idKey = 'id',
  }) sync* {
    final records = json[key];
    if (records is! List || records.length > 100000) {
      throw FormatException('Invalid $key.');
    }
    final ids = <String>{};
    for (final value in records) {
      final record = _map(value);
      if (!ids.add(_string(record, idKey))) {
        throw const FormatException('Duplicate evidence record.');
      }
      yield record;
    }
  }
}
