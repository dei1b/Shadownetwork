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
      ? 'Not enough data'
      : '${(100 * n / d).toStringAsFixed(0)}% · $n of $d';
  String ms(double? value) => value == null
      ? 'Not recorded'
      : value >= 1000
      ? '${(value / 1000).toStringAsFixed(2)} seconds'
      : '${value.toStringAsFixed(0)} ms';
  String local(DateTime? date) => date == null
      ? 'Unknown'
      : '${date.toUtc().add(const Duration(hours: 8)).toIso8601String().replaceFirst('T', ' ').split('.').first} Manila (UTC+8)';

  Widget picker(
    String label,
    String? value,
    List<String> values,
    ValueChanged<String?> change, {
    bool all = true,
    Map<String, String> labels = const {},
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
            child: Text(
              labels[v] ??
                  switch (v) {
                    'bluetooth' => 'Bluetooth (BLE)',
                    'civilian' => 'Resident',
                    'relay' => 'Relay phone',
                    'responder' => 'Responder',
                    'admin' => 'Administrator',
                    'message_events' => 'Message activity',
                    'sos_receipts' => 'Received SOS alerts',
                    'discovery_attempts' => 'Nearby phone searches',
                    'battery_samples' => 'Battery readings',
                    'wifi_direct' => 'Wi-Fi Direct',
                    _ => short(v),
                  },
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
      onChanged: (v) => setState(() {
        page = 0;
        change(v == '' ? null : v);
      }),
    ),
  );

  Widget metric(String label, String value, String explanation) => SizedBox(
    width: 430,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(explanation, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    ),
  );

  Widget section(String title, String explanation, List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.only(top: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(explanation),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      );

  String radio(String value) => switch (value) {
    'bluetooth' || 'ble' => 'Bluetooth (BLE)',
    'wifi_direct' => 'Wi-Fi Direct',
    'unknown' => 'Not recorded',
    'mock' => 'Simulation',
    _ => value,
  };

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
              if (total == 0) const Text('No measurements for this selection.'),
              ...values.entries
                  .where((e) => e.value > 0)
                  .map(
                    (e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${radio(e.key)}: ${e.value} (${total == 0 ? 0 : (100 * e.value / total).toStringAsFixed(0)}%)',
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
                'Import phone exports to see the test results. Older files without the required measurements remain available below.',
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
                  Wrap(
                    spacing: 20,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      picker('Test run', selectedRun, runs, (v) {
                        run = v;
                        device = null;
                      }, all: false),
                      Text(
                        '${devices.length} ${devices.length == 1 ? 'phone imported' : 'phones imported'}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Filter results'),
                    subtitle: Text(
                      selectedDevice == null &&
                              role == null &&
                              transport == null &&
                              start == null
                          ? 'All phones, connection types and dates'
                          : 'Filters applied · expand to adjust',
                    ),
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          picker(
                            'Phone',
                            selectedDevice,
                            devices,
                            (v) => device = v,
                            labels: {
                              for (var i = 0; i < devices.length; i++)
                                devices[i]: 'Phone ${i + 1}',
                            },
                          ),
                          picker('Phone role', role, const [
                            'civilian',
                            'relay',
                            'responder',
                            'admin',
                          ], (v) => role = v),
                          picker('Connection type', transport, const [
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
                          TextButton.icon(
                            onPressed: dates,
                            icon: const Icon(Icons.date_range_outlined),
                            label: Text(
                              start == null
                                  ? 'All dates (Manila)'
                                  : '${MaterialLocalizations.of(context).formatMediumDate(start!.add(const Duration(hours: 8)))} – ${MaterialLocalizations.of(context).formatMediumDate(end!.add(const Duration(hours: 8)).subtract(const Duration(days: 1)))} (Manila)',
                            ),
                          ),
                          TextButton(
                            onPressed: () => setState(() {
                              device = null;
                              role = null;
                              transport = null;
                              start = null;
                              end = null;
                              page = 0;
                            }),
                            child: const Text('Reset filters'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (result.issues.any(
                    (v) => !v.startsWith('Clocks unsynchronized'),
                  ))
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Some records need review. See “How to interpret these results” for details.',
                      ),
                    ),
                  section(
                    'What this test shows',
                    'Results from the imported phone files for $selectedRun.',
                    [
                      Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        children: [
                          metric(
                            'SOS alerts received',
                            '${result.receipts.length}',
                            result.receipts.isEmpty
                                ? 'No final SOS receipt is recorded in these files. Import the receiving phone’s file to check delivery.'
                                : '${result.receipts.map((r) => r.hash).toSet().length} different SOS messages received by responders. Each receiving phone is counted separately.',
                          ),
                          metric(
                            'Phone-to-phone handoffs',
                            rate(result.acknowledged, result.offered),
                            result.offered == 0
                                ? 'No outgoing attempts available to measure.'
                                : '${result.acknowledged} of ${result.offered} attempts confirmed storage on the next phone. This does not confirm arrival at the final recipient.',
                          ),
                          metric(
                            'Typical handoff time',
                            ms(result.latency.median),
                            result.latency.count == 0
                                ? 'A confirmed transfer is needed to measure this.'
                                : 'The middle value from ${result.latency.count} confirmed transfers, including connection setup and storage confirmation.',
                          ),
                          metric(
                            'Transfer attempts needing attention',
                            '${result.failed} failed · ${result.open} awaiting confirmation',
                            'A failed attempt can be retried by Store-Carry-Forward. Awaiting confirmation means no recorded outcome yet.',
                          ),
                        ],
                      ),
                    ],
                  ),
                  section(
                    'How messages travelled',
                    'Hops count the phone-to-phone steps in a message’s journey.',
                    [
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          bars('Steps to the receiving responder (hop count)', {
                            for (final e in result.hops.entries)
                              '${e.key} ${e.key == '1' ? 'hop' : 'hops'}':
                                  e.value,
                          }),
                          bars(
                            'Connections used to send messages',
                            result.transports,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Connection counts describe outgoing transfers, including repeat sends. They do not compare radio speed or range.',
                      ),
                    ],
                  ),
                  section(
                    'Discovery and backup connections',
                    'These results describe how phones found peers and sent messages.',
                    [
                      Wrap(
                        spacing: 16,
                        children: [
                          metric(
                            'Nearby phone searches',
                            rate(result.discoverySuccess, result.discovery),
                            '${result.discoverySuccess} of ${result.discovery} searches found a nearby phone. Finding a phone does not confirm message delivery.',
                          ),
                          metric(
                            'Backup connection use',
                            rate(result.fallback, result.sent),
                            'Recorded fallback during sending: ${result.fallback} of ${result.sent} outgoing transfers. An earlier connection change may not be recorded here.',
                          ),
                        ],
                      ),
                    ],
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Timing and battery details'),
                    subtitle: const Text(
                      'Slower transfers, total travel time and battery readings',
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: metric(
                          'Handoff timing',
                          'Typical: ${ms(result.latency.median)}',
                          result.latency.count == 0
                              ? 'No confirmed transfer timing is recorded.'
                              : 'Average: ${ms(result.latency.mean)}. 95% completed within ${ms(result.latency.p95)}. Fastest: ${ms(result.latency.values.firstOrNull)}. Slowest: ${ms(result.latency.values.lastOrNull)}. Based on ${result.latency.count} confirmations.',
                        ),
                      ),
                      bars('Handoff time distribution', histogram),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: metric(
                          'Total SOS travel time',
                          ms(result.propagation.median),
                          'Median across ${result.propagation.count} final receipts. Average: ${ms(result.propagation.mean)}; 95th percentile: ${ms(result.propagation.p95)}. Phone clocks are not synchronized, so these times are estimates.',
                        ),
                      ),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Battery readings are grouped by phone and session. Connection-type filters do not change this section.',
                        ),
                      ),
                      if (batteryGroups.isEmpty)
                        const ListTile(
                          title: Text('No battery readings in this selection.'),
                        ),
                      for (final entry in batteryGroups.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Phone ${devices.indexOf(entry.value.first.device) + 1} · battery level',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                result.battery[entry.key] == null
                                    ? 'Battery drain cannot be measured: at least two readings in time order, without charging or a rising level, are needed.'
                                    : '${result.battery[entry.key]!.toStringAsFixed(2)} percentage points used per hour.',
                              ),
                              const Text(
                                'Vertical scale: 0–100%. Horizontal scale: time. Orange marks charging.',
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
                                  '${entry.value.length} battery readings · view first 50',
                                ),
                                children: [
                                  SelectableText(entry.key),
                                  ...entry.value
                                      .take(50)
                                      .map(
                                        (r) => ListTile(
                                          title: Text(
                                            '${local(r.time)} · ${r.data['battery_percent']}%${r.data['is_charging'] == true ? ' · charging' : ''}',
                                          ),
                                        ),
                                      ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('How to interpret these results'),
                    subtitle: const Text(
                      'Data coverage, clock accuracy and calculation notes',
                    ),
                    children: [
                      const ListTile(
                        title: Text('Import every participating phone'),
                        subtitle: Text(
                          'The number of expected participants is not recorded. Imported files alone cannot confirm that this test is complete.',
                        ),
                      ),
                      const ListTile(
                        title: Text('A handoff is one step'),
                        subtitle: Text(
                          'The next phone confirms that it stored a message. A final SOS receipt shows that a responder received it.',
                        ),
                      ),
                      const ListTile(
                        title: Text('Phone clocks may differ'),
                        subtitle: Text(
                          'Total travel times use phone timestamps. Clock differences can affect them. Handoff timing uses a separate elapsed-time measurement.',
                        ),
                      ),
                      for (final issue in result.issues.where(
                        (v) => !v.startsWith('Clocks unsynchronized'),
                      ))
                        ListTile(title: Text(issue)),
                      if (result.issues.any(
                        (v) => !v.startsWith('Clocks unsynchronized'),
                      ))
                        const ListTile(
                          title: Text('Some records need review'),
                          subtitle: Text(
                            'Review the notes above before presenting percentages as complete results.',
                          ),
                        ),
                    ],
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Detailed records'),
                    subtitle: Text(
                      '${rows.length} records · search messages and inspect the evidence',
                    ),
                    children: [
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Search message or transfer ID',
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
                            '${r.type} · Phone ${devices.indexOf(r.device) + 1} · ${radio(r.transport)}',
                          ),
                          subtitle: Text(
                            '${local(r.time)} · hop ${r.data['hop_count'] ?? '—'} · latency ${r.data['latency_ms'] ?? '—'} ms',
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: SelectableText(
                                'Device: ${r.device}\nSession: ${r.session}\nMessage: ${r.hash ?? 'Not recorded'}\nTransfer: ${r.transfer ?? 'Not recorded'}\n${r.data}',
                              ),
                            ),
                          ],
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
