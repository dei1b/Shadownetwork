import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/validation_analysis.dart';
import 'providers/validation_analysis_provider.dart';
import 'providers/validation_import_provider.dart';

ValidationRunAnalysis _calculate(
  (List<ValidationAnalysisInput>, ValidationAnalysisFilter) args,
) => const ValidationAnalysisCalculator().calculate(args.$1, args.$2);

class ValidationAnalysisDashboard extends ConsumerStatefulWidget {
  const ValidationAnalysisDashboard({super.key});
  @override
  ConsumerState<ValidationAnalysisDashboard> createState() => _DashboardState();
}

class _DashboardState extends ConsumerState<ValidationAnalysisDashboard> {
  String? run, device, role, transport;
  DateTime? start, end;
  String search = '', kind = 'All';
  int page = 0;
  int? calculationKey;
  Future<ValidationRunAnalysis>? calculation;
  String short(String value) =>
      value.length > 18 ? '${value.substring(0, 18)}…' : value;
  String rate(int n, int d) => d == 0
      ? 'Unavailable: no eligible attempts'
      : '${(100 * n / d).toStringAsFixed(1)}% ($n/$d)';
  String ms(double? value) =>
      value == null ? 'Unavailable' : '${value.toStringAsFixed(0)} ms';
  String local(DateTime? date) => date == null
      ? 'Unknown'
      : '${date.toUtc().add(const Duration(hours: 8)).toIso8601String().replaceFirst('T', ' ').split('.').first} Manila (UTC+8)';

  Widget picker(
    String label,
    String? value,
    List<String> values,
    ValueChanged<String?> change, {
    bool all = true,
  }) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 270),
    child: DropdownButtonFormField<String>(
      key: ValueKey('$label/$value'),
      initialValue: values.contains(value) ? value : (all ? '' : null),
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        if (all) const DropdownMenuItem(value: '', child: Text('All')),
        ...values.map(
          (v) => DropdownMenuItem(
            value: v,
            child: Text(switch (v) {
              'bluetooth' => 'BLE',
              'wifi_direct' => 'Wi-Fi Direct',
              _ => short(v),
            }, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: (v) => setState(() {
        page = 0;
        change(v == '' ? null : v);
      }),
    ),
  );

  Widget tile(String label, String value) => Container(
    width: 250,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        const SizedBox(height: 8),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );

  Widget bars(String title, Map<String, int> values) {
    final total = values.values.fold(0, (a, b) => a + b);
    return SizedBox(
      width: 470,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              if (total == 0)
                const Text('Unavailable: no eligible observations'),
              ...values.entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${e.key}: ${e.value} (${total == 0 ? 0 : (100 * e.value / total).toStringAsFixed(1)}%)',
                      ),
                      LinearProgressIndicator(
                        value: total == 0 ? 0 : e.value / total,
                        semanticsLabel: '${e.key}: ${e.value} of $total',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> dates() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: 'Manila dates (inclusive)',
    );
    if (range == null || !mounted) return;
    setState(() {
      start = DateTime.utc(
        range.start.year,
        range.start.month,
        range.start.day,
      ).subtract(const Duration(hours: 8));
      end = DateTime.utc(
        range.end.year,
        range.end.month,
        range.end.day + 1,
      ).subtract(const Duration(hours: 8));
      page = 0;
    });
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(validationAnalysisProvider)
      .when(
        loading: () => const Padding(
          padding: EdgeInsets.all(20),
          child: Text('Loading validation analysis…'),
        ),
        error: (_, _) => TextButton(
          onPressed: () => ref.invalidate(validationAnalysisProvider),
          child: const Text('Unable to analyze imports. Retry'),
        ),
        data: (inputs) {
          final datasets =
              ref
                  .watch(validationImportControllerProvider)
                  .valueOrNull
                  ?.datasets
                  .where((d) => !d.isLegacy)
                  .toList() ??
              [];
          datasets.sort(
            (a, b) => (b.exportedAt ?? DateTime(1970)).compareTo(
              a.exportedAt ?? DateTime(1970),
            ),
          );
          final runs = datasets
              .map((d) => d.runId)
              .whereType<String>()
              .toSet()
              .toList();
          if (runs.isEmpty) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Import schema 2 phone exports to view run analysis. Legacy imports remain listed below.',
              ),
            );
          }
          final selectedRun = runs.contains(run) ? run! : runs.first;
          final devices = datasets
              .where((d) => d.runId == selectedRun)
              .map((d) => d.deviceId)
              .toSet()
              .toList();
          final selectedDevice = devices.contains(device) ? device : null;
          final filter = ValidationAnalysisFilter(
            run: selectedRun,
            device: selectedDevice,
            role: role,
            transport: transport,
            start: start,
            end: end,
          );
          final nextKey = Object.hash(
            inputs,
            selectedRun,
            selectedDevice,
            role,
            transport,
            start,
            end,
          );
          if (calculationKey != nextKey) {
            calculationKey = nextKey;
            calculation = compute(_calculate, (inputs, filter));
          }
          return FutureBuilder<ValidationRunAnalysis>(
            future: calculation,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Calculating run metrics…'),
                );
              }
              if (snapshot.hasError || !snapshot.hasData) {
                return const Text(
                  'Unable to calculate run metrics. Reopen Validation data to retry.',
                );
              }
              final result = snapshot.data!;
              final rows =
                  result.records
                      .where(
                        (r) =>
                            (kind == 'All' || r.kind == kind) &&
                            (search.isEmpty ||
                                '${r.hash} ${r.transfer}'.contains(search)),
                      )
                      .toList()
                    ..sort(
                      (a, b) => (b.time ?? DateTime(1970)).compareTo(
                        a.time ?? DateTime(1970),
                      ),
                    );
              final pages = max(1, (rows.length / 50).ceil());
              final current = min(page, pages - 1);
              final histogram = <String, int>{
                '<100 ms': 0,
                '100–<500 ms': 0,
                '500–<1000 ms': 0,
                '1000–<5000 ms': 0,
                '≥5000 ms': 0,
              };
              for (final value in result.latency.values) {
                final key = histogram.keys.elementAt(
                  value < 100
                      ? 0
                      : value < 500
                      ? 1
                      : value < 1000
                      ? 2
                      : value < 5000
                      ? 3
                      : 4,
                );
                histogram[key] = histogram[key]! + 1;
              }
              final batteryGroups = <String, List<AnalysisRecord>>{};
              for (final r in result.records.where(
                (r) => r.kind == 'battery_samples',
              )) {
                batteryGroups
                    .putIfAbsent('${r.device}/${r.session}', () => [])
                    .add(r);
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 24),
                  Text(
                    'Run analysis',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      picker('Run', selectedRun, runs, (v) {
                        run = v;
                        device = null;
                      }, all: false),
                      picker(
                        'Device',
                        selectedDevice,
                        devices,
                        (v) => device = v,
                      ),
                      picker('Role', role, const [
                        'civilian',
                        'relay',
                        'responder',
                        'admin',
                      ], (v) => role = v),
                      picker('Transport', transport, const [
                        'bluetooth',
                        'wifi_direct',
                        'mock',
                        'unknown',
                      ], (v) => transport = v),
                    ],
                  ),
                  Wrap(
                    spacing: 12,
                    children: [
                      TextButton(
                        onPressed: dates,
                        child: Text(
                          start == null
                              ? 'All dates (Manila)'
                              : '${local(start)} to ${local(end)} exclusive',
                        ),
                      ),
                      if (start != null)
                        TextButton(
                          onPressed: () => setState(() {
                            start = null;
                            end = null;
                            page = 0;
                          }),
                          child: const Text('Clear dates'),
                        ),
                    ],
                  ),
                  Text(
                    '${devices.length} imported devices · Expected participants: Unknown',
                  ),
                  const Text(
                    'Partial evidence: import every participating phone. Next-hop ACKs do not establish final-recipient delivery.',
                  ),
                  for (final issue in result.issues) Text(issue),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      tile(
                        'Final SOS receipts',
                        '${result.receipts.length} recipient/message pairs · ${result.receipts.map((r) => r.hash).toSet().length} unique messages',
                      ),
                      tile(
                        'Recorded next-hop ACK success',
                        rate(result.acknowledged, result.offered),
                      ),
                      tile(
                        'Failed / open outgoing attempts',
                        '${result.failed} failed / ${result.open} open',
                      ),
                      tile(
                        'Node latency (n=${result.latency.count})',
                        'Median ${ms(result.latency.median)} · P95 ${ms(result.latency.p95)}\nMean ${ms(result.latency.mean)}\nMin ${ms(result.latency.values.firstOrNull)} · Max ${ms(result.latency.values.lastOrNull)}',
                      ),
                      tile(
                        'Recorded send-stage fallback',
                        rate(result.fallback, result.sent),
                      ),
                      tile(
                        'Peer discovery success',
                        rate(result.discoverySuccess, result.discovery),
                      ),
                      tile(
                        'Propagation: clock-uncertain (n=${result.propagation.count})',
                        'Mean ${ms(result.propagation.mean)} · Median ${ms(result.propagation.median)} · P95 ${ms(result.propagation.p95)}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      bars('Final SOS hop distribution', result.hops),
                      bars('Outgoing transport usage', result.transports),
                      bars('Acknowledged node latency', histogram),
                    ],
                  ),
                  const Text(
                    'Battery by device/session · unaffected by transport filter',
                  ),
                  for (final entry in batteryGroups.entries)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(entry.key),
                            Text(
                              result.battery[entry.key] == null
                                  ? 'Drain unavailable: needs increasing timestamps and non-charging, non-rising samples.'
                                  : '${result.battery[entry.key]!.toStringAsFixed(2)} percentage points/hour',
                            ),
                            SizedBox(
                              height: 110,
                              width: 600,
                              child: CustomPaint(
                                painter: _BatteryPainter(entry.value),
                              ),
                            ),
                            ExpansionTile(
                              title: Text(
                                '${entry.value.length} samples · percent over time · first 50 listed',
                              ),
                              children: entry.value
                                  .take(50)
                                  .map(
                                    (r) => ListTile(
                                      title: Text(
                                        '${local(r.time)} · ${r.data['battery_percent']}%${r.data['is_charging'] == true ? ' · charging' : ''}',
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    'Evidence records',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Search full message hash or transfer ID',
                    ),
                    onChanged: (v) => setState(() {
                      search = v;
                      page = 0;
                    }),
                  ),
                  picker(
                    'Record type',
                    kind,
                    const [
                      'All',
                      'message_events',
                      'sos_receipts',
                      'discovery_attempts',
                      'battery_samples',
                    ],
                    (v) => kind = v ?? 'All',
                    all: false,
                  ),
                  Text(
                    '${rows.length} records · Page ${current + 1} of $pages',
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: current == 0
                            ? null
                            : () => setState(() => page = current - 1),
                        child: const Text('Previous'),
                      ),
                      TextButton(
                        onPressed: current + 1 >= pages
                            ? null
                            : () => setState(() => page = current + 1),
                        child: const Text('Next'),
                      ),
                    ],
                  ),
                  for (final r in rows.skip(current * 50).take(50))
                    ExpansionTile(
                      title: Text(
                        '${r.type} · ${short(r.device)} · ${r.transport}',
                      ),
                      subtitle: Text(
                        '${local(r.time)} · hop ${r.data['hop_count'] ?? '—'} · latency ${r.data['latency_ms'] ?? '—'} ms',
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(
                            'Device: ${r.device}\nSession: ${r.session}\nMessage: ${r.hash ?? 'Unavailable'}\nTransfer: ${r.transfer ?? 'Unavailable'}\n${r.data}',
                          ),
                        ),
                      ],
                    ),
                ],
              );
            },
          );
        },
      );
}

class _BatteryPainter extends CustomPainter {
  _BatteryPainter(this.samples);
  final List<AnalysisRecord> samples;
  @override
  void paint(Canvas canvas, Size size) {
    final sorted = [...samples]..sort((a, b) => a.time!.compareTo(b.time!));
    if (sorted.isEmpty) return;
    final span = max(
      1,
      sorted.last.time!.difference(sorted.first.time!).inMilliseconds,
    );
    final paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < sorted.length; i++) {
      final r = sorted[i];
      final x =
          r.time!.difference(sorted.first.time!).inMilliseconds /
          span *
          size.width;
      final y = (1 - (r.data['battery_percent'] as num) / 100) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      canvas.drawCircle(
        Offset(x, y),
        3,
        Paint()
          ..color = r.data['is_charging'] == true ? Colors.orange : Colors.blue,
      );
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BatteryPainter oldDelegate) =>
      oldDelegate.samples != samples;
}
