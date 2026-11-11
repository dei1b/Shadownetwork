import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/validation_analysis.dart';
import '../../admin/presentation/theme/admin_theme.dart';
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
      ? 'Not measured'
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

  Widget grid({
    required List<Widget> children,
    double spacing = 16,
    double runSpacing = 16,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 1100 && children.length >= 4
          ? 4
          : constraints.maxWidth >= 640
          ? 2
          : 1;
      return Column(
        children: [
          for (var index = 0; index < children.length; index += columns)
            Padding(
              padding: EdgeInsets.only(
                bottom: index + columns < children.length ? 16 : 0,
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var column = 0; column < columns; column++) ...[
                      if (column > 0) const SizedBox(width: 16),
                      Expanded(
                        child: index + column < children.length
                            ? children[index + column]
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget panel({required Widget child}) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border.all(color: AdminTheme.border),
      borderRadius: BorderRadius.circular(AdminTheme.radius),
    ),
    child: child,
  );

  Widget metric(String label, String value, String explanation) => panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Icon(
                switch (label) {
                  'SOS alerts received' => Icons.sos_outlined,
                  'Phone-to-phone handoffs' => Icons.phonelink_ring_outlined,
                  'Typical handoff time' ||
                  'Handoff timing' => Icons.schedule_outlined,
                  'Transfer status' => Icons.sync_alt_outlined,
                  'Nearby phone searches' => Icons.radar_outlined,
                  'Backup connection use' => Icons.swap_horiz_outlined,
                  _ => Icons.insights_outlined,
                },
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AdminTheme.muted,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          value,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontSize: 25,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          explanation,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            height: 1.5,
            color: AdminTheme.muted,
          ),
        ),
      ],
    ),
  );

  Widget disclosure({
    required Widget title,
    Widget? subtitle,
    EdgeInsetsGeometry? tilePadding,
    required List<Widget> children,
  }) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: AdminTheme.border),
        borderRadius: BorderRadius.circular(AdminTheme.radius),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        shape: const Border(),
        collapsedShape: const Border(),
        title: title,
        subtitle: subtitle,
        children: children,
      ),
    ),
  );

  Widget section(String title, String explanation, List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.only(top: 24),
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
    return panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '$total samples',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (total == 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.bar_chart_outlined,
                    size: 32,
                    color: AdminTheme.muted,
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'No measurements yet',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Import phone files with matching delivery or transfer records to show this chart.',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          for (final entry in values.entries.where((e) => e.value > 0))
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(radio(entry.key))),
                      Text(
                        '${entry.value} · ${(100 * entry.value / total).toStringAsFixed(0)}%',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      minHeight: 8,
                      value: entry.value / total,
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      semanticsLabel: '${entry.key}: ${entry.value} of $total',
                    ),
                  ),
                ],
              ),
            ),
        ],
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
                  disclosure(
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
                    'Confirmed transfers and final SOS receipts, shown separately.',
                    [
                      grid(
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
                            'Transfer status',
                            result.offered == 0 && result.failed == 0
                                ? 'No attempts'
                                : '${result.failed} failed · ${result.open} pending',
                            'Failed attempts may be retried by Store-Carry-Forward. Pending attempts have no recorded confirmation.',
                          ),
                        ],
                      ),
                    ],
                  ),
                  section(
                    'How messages travelled',
                    'Hops count the phone-to-phone steps in a message’s journey.',
                    [
                      grid(
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
                      grid(
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
                  disclosure(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Timing and battery details'),
                    subtitle: const Text(
                      'Slower transfers, total travel time and battery readings',
                    ),
                    children: [
                      grid(
                        children: [
                          metric(
                            'Handoff timing',
                            ms(result.latency.median),
                            result.latency.count == 0
                                ? 'No confirmed transfer timing is recorded.'
                                : 'Median of ${result.latency.count} confirmations. Average ${ms(result.latency.mean)}; 95% within ${ms(result.latency.p95)}.',
                          ),
                          metric(
                            'Total SOS travel time',
                            ms(result.propagation.median),
                            result.propagation.count == 0
                                ? 'A final SOS receipt is needed to measure total travel time.'
                                : 'Median across ${result.propagation.count} final receipts. Average ${ms(result.propagation.mean)}. Estimates may be affected by differences between phone clocks.',
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      bars('Handoff time distribution', histogram),
                      const SizedBox(height: 24),
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
                                'Battery level over time · orange dots indicate charging.',
                              ),
                              SizedBox(
                                height: 200,
                                width: double.infinity,
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
                  disclosure(
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
                  disclosure(
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
    final plot = Rect.fromLTRB(46, 16, size.width - 16, size.height - 34);
    if (plot.width <= 0) return;
    void label(String text, Offset at, {bool right = false}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(
            fontSize: 12,
            color: AdminTheme.muted,
            fontFamily: AdminTheme.fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(right ? at.dx - painter.width : at.dx, at.dy),
      );
    }

    final grid = Paint()
      ..color = AdminTheme.border
      ..strokeWidth = 1;
    for (final percent in [0, 25, 50, 75, 100]) {
      final y = plot.bottom - percent / 100 * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      label('$percent%', Offset(0, y - 7));
    }
    String clock(DateTime value) {
      final time = value.toUtc().add(const Duration(hours: 8));
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
    }

    label(clock(sorted.first.time!), Offset(plot.left, plot.bottom + 12));
    if (sorted.last.time != sorted.first.time) {
      label(
        clock(sorted.last.time!),
        Offset(plot.right, plot.bottom + 12),
        right: true,
      );
    }
    final span = max(
      1,
      sorted.last.time!.difference(sorted.first.time!).inMilliseconds,
    );
    final path = Path();
    for (var i = 0; i < sorted.length; i++) {
      final record = sorted[i];
      final x =
          plot.left +
          record.time!.difference(sorted.first.time!).inMilliseconds /
              span *
              plot.width;
      final y =
          plot.bottom -
          (record.data['battery_percent'] as num) / 100 * plot.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      canvas.drawCircle(
        Offset(x, y),
        3,
        Paint()
          ..color = record.data['is_charging'] == true
              ? AdminTheme.charging
              : AdminTheme.chartLine,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = AdminTheme.chartLine
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _BatteryPainter oldDelegate) =>
      oldDelegate.samples != samples;
}
