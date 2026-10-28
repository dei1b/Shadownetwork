import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../../messaging/domain/entities/sos_message.dart';
import '../../../trust/domain/services/canonical_json.dart';
import '../entities/validation_bundle.dart';
import '../entities/validation_event.dart';
import '../entities/validation_session_data.dart';
import 'validation_run_identity.dart';
import 'validation_bundle_identifiers.dart';
import 'validation_bundle_validator.dart';

/// Schema 2 is independent of the SOS wire/encryption schemas and schema-1
/// debugging exports. The checksum detects changes, not a trusted author.
class ValidationBundleCodec {
  const ValidationBundleCodec();

  static const maxSourceBytes = 10 * 1024 * 1024;
  // Matches AndroidTransportBridge.PROTOCOL_VERSION, not encryption version 1.
  static const transportProtocolVersion = 2;

  ValidationBundle create({
    required ValidationSessionData data,
    required List<SosMessage> messages,
    required String appVersion,
    DateTime? generatedAt,
  }) {
    final session = data.session;
    if (session.testRunId == null) {
      throw StateError(
        'This legacy session has no run code. Use Copy JSON or Copy CSV.',
      );
    }
    final run = ValidationRunIdentity.normalizeCode(session.testRunId!);
    final owners = [
      ...data.events.map((e) => e.sessionId),
      ...data.discoveryAttempts.map((e) => e.sessionId),
      ...data.batterySamples.map((e) => e.sessionId),
    ];
    if (owners.any((owner) => owner != session.id)) {
      throw const FormatException('Evidence belongs to another session.');
    }
    final now = (generatedAt ?? DateTime.now()).toUtc();
    final end = session.endedAt ?? now;
    if (end.isBefore(session.startedAt)) {
      throw const FormatException('Invalid session recording interval.');
    }
    String pseudonym(String kind, String value) =>
        ValidationBundleIdentifiers.pseudonym(run, kind, value);
    final sessionId = pseudonym('session', session.id);
    final deliveredHashes = data.events
        .where(
          (event) =>
              event.type == ValidationEventType.envelopeDelivered &&
              event.payloadType == 'sos_message',
        )
        .map((event) => event.messageHash)
        .toSet();
    final receipts = <String, SosMessage>{};
    for (final message in messages) {
      final hash = message.messageHash;
      final receivedAt = message.receivedAt;
      if (hash == null ||
          receivedAt == null ||
          !deliveredHashes.contains(hash) ||
          receivedAt.isBefore(session.startedAt) ||
          receivedAt.isAfter(end)) {
        continue;
      }
      final existing = receipts[hash];
      if (existing == null || receivedAt.isBefore(existing.receivedAt!)) {
        receipts[hash] = message;
      }
    }
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final json = <String, Object?>{
      'schema_version': 2,
      'bundle_type': 'shadow_network_validation_bundle',
      'bundle_id': 'bundle-$id',
      'generated_at': now.toIso8601String(),
      'test_run': {
        'id': run,
        'name': session.name,
        'environment': session.environment,
      },
      'device': {
        'peer_id': pseudonym('peer', session.deviceId),
        'role': _choice(session.deviceRole, {
          'responder',
          'civilian',
          'relay',
          'admin',
        }),
        'app_version': appVersion,
        'protocol_version': transportProtocolVersion,
      },
      'session': {
        'id': sessionId,
        'started_at': session.startedAt.toUtc().toIso8601String(),
        'ended_at': session.endedAt?.toUtc().toIso8601String(),
        'status': session.status.name,
      },
      'privacy': {
        'mode': 'metrics_only',
        'identifiers': 'run_scoped_sha256_pseudonyms',
        'clock_synchronized': false,
      },
      'sos_receipts': (receipts.keys.toList()..sort()).map((hash) {
        final message = receipts[hash]!;
        final duration = message.propagationDuration;
        return {
          'message_hash': ValidationBundleIdentifiers.correlation(
            run,
            'message',
            hash,
          ),
          'category': message.category.name,
          'created_at': message.createdAt.toUtc().toIso8601String(),
          'received_at': message.receivedAt!.toUtc().toIso8601String(),
          'propagation_ms': duration?.inMilliseconds,
          'clock_quality': duration == null
              ? 'invalid_order'
              : 'unsynchronized',
          'hop_count': message.hopCount,
          'last_peer_id': message.receivedFromPeerId == null
              ? null
              : pseudonym('peer', message.receivedFromPeerId!),
          'transfer_id': ValidationBundleIdentifiers.correlation(
            run,
            'transfer',
            message.transferId,
          ),
          'transport': _transport(message.receivedTransport),
          'trust_status': message.trustStatus.name,
          'moderation_status': message.moderationStatus.name,
        };
      }).toList(),
      'message_events': data.events
          .map(
            (event) => {
              'id': pseudonym('event', event.id),
              'session_id': sessionId,
              'event_type': event.type.name,
              'occurred_at': event.occurredAt.toUtc().toIso8601String(),
              'message_hash': ValidationBundleIdentifiers.correlation(
                run,
                'message',
                event.messageHash,
              ),
              'transfer_id': ValidationBundleIdentifiers.correlation(
                run,
                'transfer',
                event.transferId,
              ),
              'payload_type': event.payloadType == null
                  ? null
                  : _choice(event.payloadType!, {
                      'sos_message',
                      'chat_message',
                    }),
              'peer_id': event.peerId == null
                  ? null
                  : pseudonym('peer', event.peerId!),
              'transport': _transport(event.transport),
              'hop_count': event.hopCount,
              'error': event.error == null ? null : 'redacted',
              'fallback_used': event.fallbackUsed,
              'latency_ms': event.latencyMs,
              'metadata': _metadata(event.metadata),
            },
          )
          .toList(),
      'discovery_attempts': data.discoveryAttempts
          .map(
            (attempt) => {
              'id': pseudonym('discovery', attempt.id),
              'session_id': sessionId,
              'transport': _transport(attempt.transport),
              'started_at': attempt.startedAt.toUtc().toIso8601String(),
              'ended_at': attempt.endedAt.toUtc().toIso8601String(),
              'discovered_count': attempt.discoveredCount,
              'success': attempt.success,
              'error': attempt.error == null ? null : 'redacted',
            },
          )
          .toList(),
      'battery_samples': data.batterySamples
          .map(
            (sample) => {
              'id': pseudonym('battery', sample.id),
              'session_id': sessionId,
              'battery_percent': sample.batteryPercent,
              'is_charging': sample.isCharging,
              'sampled_at': sample.sampledAt.toUtc().toIso8601String(),
              'runtime_mode': _choice(sample.runtimeMode, {
                'foreground',
                'background',
                'stopped',
                'active_relay',
              }),
            },
          )
          .toList(),
    };
    json['payload_hash'] = _hash(canonicalJsonEncode(json));
    // Apply the same structural checks that the future Web importer will use.
    return decodeJson(jsonEncode(json));
  }

  String encodeJson(ValidationBundle bundle) =>
      const JsonEncoder.withIndent('  ').convert(bundle.toJson());

  ValidationBundle decodeJson(String source) {
    if (utf8.encode(source).length > maxSourceBytes) {
      throw const FormatException('Validation bundle exceeds 10 MiB.');
    }
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic> ||
        value['schema_version'] != 2 ||
        value['bundle_type'] != 'shadow_network_validation_bundle') {
      throw const FormatException('Unsupported portable validation bundle.');
    }
    final hash = value['payload_hash'];
    final content = Map<String, Object?>.from(value)..remove('payload_hash');
    if (hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        _hash(canonicalJsonEncode(content)) != hash) {
      throw const FormatException('Validation bundle checksum does not match.');
    }
    const ValidationBundleValidator().validate(value);
    return ValidationBundle(Map<String, Object?>.from(value));
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static String _choice(String value, Set<String> allowed) =>
      allowed.contains(value) ? value : 'unknown';
  static String? _transport(String? value) => value == null
      ? null
      : _choice(value, {
          'bluetooth',
          'ble',
          'wifi_direct',
          'mock',
          'hybrid',
          'unknown',
        });

  static Map<String, Object?> _metadata(Map<String, Object?>? source) {
    if (source == null) return {};
    final created = source['message_created_at'];
    final date = created is String ? DateTime.tryParse(created) : null;
    return {
      if (date != null) 'message_created_at': date.toUtc().toIso8601String(),
      if ({'send', 'receive', 'ack_send'}.contains(source['phase']))
        'phase': source['phase'],
      if ({
        'foreground',
        'background',
        'stopped',
      }.contains(source['runtime_mode']))
        'runtime_mode': source['runtime_mode'],
    };
  }
}
