import 'dart:math';

import '../../trust/domain/services/canonical_json.dart';
import '../../validation/domain/services/validation_bundle_codec.dart';

class AnalysisRecord {
  const AnalysisRecord(
    this.run,
    this.device,
    this.role,
    this.session,
    this.kind,
    this.data,
  );
  final String run, device, role, session, kind;
  final Map<String, dynamic> data;
  String? get transfer => data['transfer_id'] as String?;
  String? get hash => data['message_hash'] as String?;
  String get type => data['event_type'] as String? ?? kind;
  String get transport => data['transport'] as String? ?? 'unknown';
  DateTime? get time => DateTime.tryParse(
    '${data['occurred_at'] ?? data['received_at'] ?? data['ended_at'] ?? data['sampled_at']}',
  );
}

class ValidationAnalysisInput {
  const ValidationAnalysisInput(
    this.records,
    this.issues, {
    this.runId,
    this.runName,
  });
  final List<AnalysisRecord> records;
  final List<String> issues;
  final String? runId, runName;
}

class ValidationAnalysisDecoder {
  const ValidationAnalysisDecoder();
  ValidationAnalysisInput decode(String source) {
    final json = const ValidationBundleCodec().decodeJson(source).toJson();
    final device = json['device']! as Map;
    final testRun = json['test_run']! as Map;
    final run = testRun['id'] as String;
    final session = (json['session']! as Map)['id'] as String;
    final records = <AnalysisRecord>[];
    for (final kind in [
      'message_events',
      'sos_receipts',
      'discovery_attempts',
      'battery_samples',
    ]) {
      for (final value in json[kind]! as List) {
        records.add(
          AnalysisRecord(
            run,
            device['peer_id'] as String,
            device['role'] as String,
            session,
            kind,
            Map<String, dynamic>.from(value as Map),
          ),
        );
      }
    }
    return ValidationAnalysisInput(
      List.unmodifiable(records),
      const [],
      runId: run,
      runName: testRun['name'] as String,
    );
  }
}

class ValidationAnalysisFilter {
  const ValidationAnalysisFilter({
    required this.run,
    this.device,
    this.role,
    this.transport,
    this.start,
    this.end,
  });
  final String run;
  final String? device, role, transport;
  final DateTime? start, end;
}

class AnalysisStatistics {
  AnalysisStatistics(Iterable<num> source)
    : values = source.map((v) => v.toDouble()).toList()..sort();
  final List<double> values;
  int get count => values.length;
  double? get mean =>
      count == 0 ? null : values.reduce((a, b) => a + b) / count;
  double? get median =>
      count == 0 ? null : (values[(count - 1) ~/ 2] + values[count ~/ 2]) / 2;
  double? get p95 => count == 0 ? null : values[(count * .95).ceil() - 1];
}

class ValidationRunAnalysis {
  const ValidationRunAnalysis({
    required this.records,
    required this.issues,
    required this.offered,
    required this.acknowledged,
    required this.open,
    required this.failed,
    required this.sent,
    required this.fallback,
    required this.discovery,
    required this.discoverySuccess,
    required this.receipts,
    required this.hops,
    required this.transports,
    required this.latency,
    required this.propagation,
    required this.battery,
    required this.sosStarted,
    required this.sosConfirmed,
    required this.sosHandoffTime,
  });
  final List<AnalysisRecord> records;
  final List<String> issues;
  final int offered,
      acknowledged,
      open,
      failed,
      sent,
      fallback,
      discovery,
      discoverySuccess;
  final List<AnalysisRecord> receipts;
  final Map<String, int> hops, transports;
  final AnalysisStatistics latency, propagation;
  final Map<String, double?> battery;
  final int sosStarted, sosConfirmed;
  final AnalysisStatistics sosHandoffTime;
}

class ValidationAnalysisCalculator {
  const ValidationAnalysisCalculator();
  ValidationRunAnalysis calculate(
    List<ValidationAnalysisInput> inputs,
    ValidationAnalysisFilter filter,
  ) {
    final issues = inputs.expand((i) => i.issues).toSet();
    final unique = <String, AnalysisRecord>{};
    final conflicts = <String>{};
    for (final r
        in inputs.expand((i) => i.records).where((r) => r.run == filter.run)) {
      // Receipts are snapshots; their earliest valid observation wins below.
      final id = r.kind == 'sos_receipts'
          ? '${r.hash}:${r.data['received_at']}'
          : r.data['id'];
      final key = '${r.device}/${r.session}/${r.kind}/$id';
      final old = unique[key];
      if (old != null &&
          canonicalJsonEncode(old.data) != canonicalJsonEncode(r.data)) {
        conflicts.add(key);
      }
      unique.putIfAbsent(key, () => r);
    }
    for (final key in conflicts) {
      unique.remove(key);
    }
    if (conflicts.isNotEmpty) {
      issues.add('${conflicts.length} conflicting records excluded.');
    }
    bool owner(AnalysisRecord r) =>
        (filter.device == null || r.device == filter.device) &&
        (filter.role == null || r.role == filter.role);
    bool window(AnalysisRecord r) =>
        r.time != null &&
        (filter.start == null || !r.time!.isBefore(filter.start!)) &&
        (filter.end == null || r.time!.isBefore(filter.end!));
    bool transport(AnalysisRecord r) =>
        filter.transport == null || filter.transport == r.transport;
    final all = unique.values.where(owner).toList();
    final selected = all
        .where(
          (r) => window(r) && (r.kind == 'battery_samples' || transport(r)),
        )
        .toList();
    String attempt(AnalysisRecord r) => '${r.device}/${r.transfer}';
    bool matches(AnalysisRecord a, AnalysisRecord b) =>
        a.hash == b.hash && a.data['peer_id'] == b.data['peer_id'];
    final offers = <String, AnalysisRecord>{};
    final sent = <String, AnalysisRecord>{};
    final failed = <String>{};
    final acks = <String, AnalysisRecord>{};
    final badAttempts = <String>{};
    final identityByAttempt = <String, AnalysisRecord>{};
    final outcomes = <String, AnalysisRecord>{};
    for (final r in all.where((r) => r.transfer != null)) {
      if (![
        'envelopeOffered',
        'envelopeSent',
        'envelopeAcknowledged',
        'envelopeRejected',
      ].contains(r.type)) {
        continue;
      }
      final key = attempt(r);
      final previous = identityByAttempt.putIfAbsent(key, () => r);
      if (!matches(previous, r)) badAttempts.add(key);
      if (r.type == 'envelopeSent' || r.type == 'envelopeAcknowledged') {
        outcomes[key] = r;
      }
    }
    for (final r in selected.where(
      (r) => r.transfer != null && !badAttempts.contains(attempt(r)),
    )) {
      final key = attempt(r);
      if (r.type == 'envelopeOffered' &&
          (filter.transport == null ||
              (outcomes[key] ?? r).transport == filter.transport)) {
        offers.putIfAbsent(key, () => r);
      }
      if (r.type == 'envelopeSent') sent.putIfAbsent(key, () => r);
      if (r.type == 'envelopeRejected' &&
          (r.data['metadata'] as Map?)?['phase'] == 'send') {
        failed.add(key);
      }
    }
    // Filter offers by the actual sent transport when available, not a preferred radio.
    if (filter.transport != null) {
      for (final r in all.where(
        (r) =>
            r.type == 'envelopeOffered' &&
            window(r) &&
            r.transfer != null &&
            !badAttempts.contains(attempt(r)),
      )) {
        if ((outcomes[attempt(r)] ?? r).transport == filter.transport) {
          offers[attempt(r)] = r;
        }
      }
    }
    for (final r in all.where(
      (r) => r.type == 'envelopeAcknowledged' && r.transfer != null,
    )) {
      final offer = offers[attempt(r)];
      if (offer != null && matches(offer, r) && transport(r)) {
        acks.putIfAbsent(attempt(r), () => r);
      }
    }
    for (final r in all.where(
      (r) =>
          r.type == 'envelopeRejected' &&
          r.transfer != null &&
          (r.data['metadata'] as Map?)?['phase'] == 'send',
    )) {
      final key = attempt(r);
      final offer = offers[key];
      if (offer != null && matches(offer, r) && !badAttempts.contains(key)) {
        failed.add(key);
      }
    }
    final uncorrelated = selected
        .where(
          (r) =>
              r.type == 'envelopeRejected' &&
              r.transfer == null &&
              (r.data['metadata'] as Map?)?['phase'] == 'send',
        )
        .length;
    if (uncorrelated > 0) {
      issues.add(
        '$uncorrelated uncorrelated send failures excluded from attempt rates.',
      );
    }
    if (badAttempts.isNotEmpty) {
      issues.add(
        '${badAttempts.length} conflicting transfer identities excluded.',
      );
    }
    final receipts = <String, AnalysisRecord>{};
    bool validReceipt(AnalysisRecord r) {
      final created = DateTime.tryParse('${r.data['created_at']}');
      return created != null && r.time != null && !r.time!.isBefore(created);
    }

    var invalidReceipts = 0;
    for (final r in selected.where(
      (r) => r.kind == 'sos_receipts' && r.role == 'responder',
    )) {
      final key = '${r.device}/${r.hash}';
      final old = receipts[key];
      if (!validReceipt(r)) invalidReceipts++;
      if (old == null ||
          (validReceipt(r) && !validReceipt(old)) ||
          (validReceipt(r) == validReceipt(old) &&
              r.time!.isBefore(old.time!))) {
        receipts[key] = r;
      }
    }
    if (invalidReceipts > 0) {
      issues.add(
        '$invalidReceipts invalid receipt time observations excluded from propagation.',
      );
    }
    final startedSos = <String, AnalysisRecord>{};
    for (final r in selected.where((r) => r.type == 'sosQueued')) {
      final hash = r.hash;
      if (hash != null && hash.isNotEmpty) {
        startedSos.putIfAbsent(hash, () => r);
      }
    }
    final confirmedSos = <String>{};
    for (final receipt in receipts.values) {
      final origin = startedSos[receipt.hash];
      if (origin == null || origin.device == receipt.device) continue;
      final target = origin.data['peer_id'];
      if (target == null || target == receipt.device) {
        confirmedSos.add(receipt.hash!);
      }
    }
    final sosHandoffTime = AnalysisStatistics(
      acks.values
          .where(
            (r) =>
                r.data['payload_type'] == 'sos_message' ||
                startedSos.containsKey(r.hash),
          )
          .map((r) => r.data['latency_ms'])
          .whereType<num>()
          .where((n) => n >= 0),
    );
    final hops = <String, int>{}, transports = <String, int>{};
    void count(Map<String, int> map, String key) =>
        map.update(key, (v) => v + 1, ifAbsent: () => 1);
    for (final r in receipts.values) {
      if (r.data['hop_count'] != null) count(hops, '${r.data['hop_count']}');
    }
    for (final r in sent.values) {
      count(transports, r.transport);
    }
    final propagation = <num>[];
    for (final r in receipts.values) {
      final created = DateTime.tryParse('${r.data['created_at']}');
      final duration = created == null
          ? null
          : r.time!.difference(created).inMilliseconds;
      if (duration != null && duration >= 0) {
        propagation.add(duration);
      } else {
        issues.add('Invalid receipt time order excluded (see evidence).');
      }
    }
    issues.add('Clocks unsynchronized: propagation is clock-uncertain.');
    final battery = <String, double?>{};
    final groups = <String, List<AnalysisRecord>>{};
    for (final r in selected.where((r) => r.kind == 'battery_samples')) {
      groups.putIfAbsent('${r.device}/${r.session}', () => []).add(r);
    }
    for (final entry in groups.entries) {
      final samples = entry.value..sort((a, b) => a.time!.compareTo(b.time!));
      final elapsed =
          samples.last.time!.difference(samples.first.time!).inMilliseconds /
          3600000;
      final valid =
          samples.length >= 2 &&
          elapsed > 0 &&
          samples.every((r) => r.data['is_charging'] == false) &&
          List.generate(
            max(0, samples.length - 1),
            (i) =>
                (samples[i + 1].data['battery_percent'] as num) <=
                    (samples[i].data['battery_percent'] as num) &&
                samples[i + 1].time!.isAfter(samples[i].time!),
          ).every((v) => v);
      battery[entry.key] = valid
          ? ((samples.first.data['battery_percent'] as num) -
                    (samples.last.data['battery_percent'] as num)) /
                elapsed
          : null;
    }
    final discovery = selected
        .where((r) => r.kind == 'discovery_attempts')
        .toList();
    return ValidationRunAnalysis(
      records: List.unmodifiable(selected),
      issues: issues.toList(),
      offered: offers.length,
      acknowledged: acks.length,
      open: offers.keys
          .where((k) => !acks.containsKey(k) && !failed.contains(k))
          .length,
      failed: failed.length,
      sent: sent.length,
      fallback: sent.values
          .where((r) => r.data['fallback_used'] == true)
          .length,
      discovery: discovery.length,
      discoverySuccess: discovery
          .where((r) => r.data['success'] == true)
          .length,
      receipts: receipts.values.toList(),
      hops: hops,
      transports: transports,
      latency: AnalysisStatistics(
        acks.values
            .map((r) => r.data['latency_ms'])
            .whereType<num>()
            .where((n) => n >= 0),
      ),
      propagation: AnalysisStatistics(propagation),
      battery: battery,
      sosStarted: startedSos.length,
      sosConfirmed: confirmedSos.length,
      sosHandoffTime: sosHandoffTime,
    );
  }
}
