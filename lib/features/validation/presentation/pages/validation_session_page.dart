import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../../trust/presentation/providers/device_access_provider.dart';
import '../../domain/entities/validation_session.dart';
import '../../domain/entities/validation_session_data.dart';
import '../../domain/entities/validation_summary.dart';
import '../providers/validation_session_provider.dart';

const _validationRed = Color(0xFFE83C3D);
const _validationDark = Color(0xFF231F20);
const _validationMuted = Color(0xFF6F6A68);

class ValidationSessionPage extends ConsumerWidget {
  const ValidationSessionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(deviceAccessProfileProvider);
    final isResponder = access.valueOrNull?.canAccessResponderInterface == true;
    if (!isResponder) {
      return Scaffold(
        appBar: AppBar(title: const Text('Validation Metrics')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'Validation sessions are available only on an approved responder device.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final sessionState = ref.watch(validationSessionProvider);
    return Scaffold(
      backgroundColor: const Color(0xFFF7F4F2),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _validationDark,
        elevation: 0,
        title: const Text(
          'VALIDATION METRICS',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () =>
                ref.read(validationSessionProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: sessionState.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: _validationRed),
        ),
        error: (error, _) => _ValidationError(
          message: error.toString(),
          onRetry: () => ref.read(validationSessionProvider.notifier).refresh(),
        ),
        data: (data) => RefreshIndicator(
          color: _validationRed,
          onRefresh: () =>
              ref.read(validationSessionProvider.notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
            children: [
              _SessionHero(state: data),
              const SizedBox(height: 16),
              if (data.activeSession == null)
                _StartSessionCard(onStart: () => _startSession(context, ref))
              else
                _ActiveSessionCard(
                  state: data,
                  onStop: () => _stopSession(context, ref),
                  onExportJson: () => _copyExport(
                    context,
                    ref,
                    data.activeSession!.id,
                    format: 'JSON',
                  ),
                  onExportCsv: () => _copyExport(
                    context,
                    ref,
                    data.activeSession!.id,
                    format: 'CSV',
                  ),
                ),
              if (data.activeSummary != null) ...[
                const SizedBox(height: 18),
                _SectionTitle(
                  title: 'LIVE RESULTS',
                  subtitle: 'Calculated only from persisted session records',
                ),
                const SizedBox(height: 10),
                _MetricsGrid(summary: data.activeSummary!),
              ],
              const SizedBox(height: 20),
              const _SectionTitle(
                title: 'SESSION HISTORY',
                subtitle: 'Stored locally and available after restart',
              ),
              const SizedBox(height: 10),
              if (data.sessions.isEmpty)
                const _EmptyHistory()
              else
                ...data.sessions.map(
                  (session) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _SessionHistoryCard(
                      session: session,
                      now: data.now,
                      onTap: () => _showSessionDetails(context, ref, session),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startSession(BuildContext context, WidgetRef ref) async {
    final nameController = TextEditingController();
    final notesController = TextEditingController();
    var environment = 'Outdoor field test';
    final result = await showDialog<_NewSessionInput>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Start validation session'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Session name',
                      hintText: 'Example: Three-device outdoor test',
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: environment,
                    decoration: const InputDecoration(
                      labelText: 'Test environment',
                    ),
                    items:
                        const [
                              'Outdoor field test',
                              'Indoor field test',
                              'Mixed indoor/outdoor',
                              'Laboratory simulation',
                            ]
                            .map(
                              (item) => DropdownMenuItem(
                                value: item,
                                child: Text(item),
                              ),
                            )
                            .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => environment = value);
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: notesController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      hintText:
                          'Route, weather, phone placement, or test setup',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _validationRed),
              onPressed: () {
                if (nameController.text.trim().isEmpty) return;
                Navigator.of(context).pop(
                  _NewSessionInput(
                    name: nameController.text.trim(),
                    environment: environment,
                    notes: notesController.text.trim(),
                  ),
                );
              },
              child: const Text('Start recording'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    notesController.dispose();
    if (result == null || !context.mounted) return;

    final localPeer = await ref.read(localPeerProvider.future);
    final profile = await ref.read(deviceAccessProfileProvider.future);
    await ref
        .read(validationSessionProvider.notifier)
        .startSession(
          name: result.name,
          environment: result.environment,
          deviceId: localPeer.id,
          deviceRole: profile.roleLabel.toLowerCase(),
          notes: result.notes,
        );
  }

  Future<void> _stopSession(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop validation session?'),
        content: const Text(
          'The session will be completed and remain available for JSON or CSV export.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep recording'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _validationRed),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop session'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(validationSessionProvider.notifier).stopSession();
    }
  }

  Future<void> _copyExport(
    BuildContext context,
    WidgetRef ref,
    String sessionId, {
    required String format,
  }) async {
    final controller = ref.read(validationSessionProvider.notifier);
    final source = format == 'JSON'
        ? await controller.exportJson(sessionId)
        : await controller.exportCsv(sessionId);
    await Clipboard.setData(ClipboardData(text: source));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$format validation export copied to clipboard.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _showSessionDetails(
    BuildContext context,
    WidgetRef ref,
    ValidationSession session,
  ) async {
    final repository = await ref.read(
      validationMetricsRepositoryProvider.future,
    );
    final data = await repository.getSessionData(session.id);
    final summary = ref
        .read(validationMetricsCalculatorProvider)
        .calculate(data);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _SessionDetailsSheet(
        data: data,
        summary: summary,
        onExportJson: () =>
            _copyExport(context, ref, session.id, format: 'JSON'),
        onExportCsv: () => _copyExport(context, ref, session.id, format: 'CSV'),
      ),
    );
  }
}

class _SessionHero extends StatelessWidget {
  const _SessionHero({required this.state});

  final ValidationSessionViewState state;

  @override
  Widget build(BuildContext context) {
    final active = state.activeSession;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF251D1C), Color(0xFF4A2020)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.science_outlined, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  active == null ? 'FIELD VALIDATION READY' : 'RECORDING NOW',
                  style: const TextStyle(
                    color: Color(0xFFFFB5B1),
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  active?.name ?? 'Capture evidence without internet',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  active == null
                      ? 'Start a named session before the three-device test.'
                      : '${_duration(active.elapsedAt(state.now))} elapsed',
                  style: const TextStyle(
                    color: Color(0xFFD8CECA),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (active != null) const _PulseDot(),
        ],
      ),
    );
  }
}

class _StartSessionCard extends StatelessWidget {
  const _StartSessionCard({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'NO ACTIVE SESSION',
            style: TextStyle(
              color: _validationMuted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 7),
          const Text(
            'Messaging remains fully operational. Metrics are recorded only after you deliberately start a validation session.',
            style: TextStyle(fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 15),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _validationRed,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: onStart,
              icon: const Icon(Icons.fiber_manual_record_rounded, size: 18),
              label: const Text('START VALIDATION SESSION'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveSessionCard extends StatelessWidget {
  const _ActiveSessionCard({
    required this.state,
    required this.onStop,
    required this.onExportJson,
    required this.onExportCsv,
  });

  final ValidationSessionViewState state;
  final VoidCallback onStop;
  final VoidCallback onExportJson;
  final VoidCallback onExportCsv;

  @override
  Widget build(BuildContext context) {
    final session = state.activeSession!;
    final count = state.activeData?.telemetryRecordCount ?? 0;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  session.environment,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              _StatusPill(label: '$count RECORDS', active: true),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${session.deviceRole.toUpperCase()}  |  ${session.deviceId}',
            style: const TextStyle(
              color: _validationMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            state.activeData?.exportRecords.isNotEmpty == true
                ? 'SYNC STATE: MANUAL BACKUP EXPORTED'
                : 'SYNC STATE: LOCAL ONLY',
            style: const TextStyle(
              color: _validationRed,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.4,
            ),
          ),
          if (session.notes?.isNotEmpty == true) ...[
            const SizedBox(height: 10),
            Text(session.notes!, style: const TextStyle(fontSize: 12)),
          ],
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onExportJson,
                  child: const Text('COPY JSON'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: onExportCsv,
                  child: const Text('COPY CSV'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _validationDark),
              onPressed: onStop,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('STOP AND COMPLETE SESSION'),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.summary});

  final ValidationSummary summary;

  @override
  Widget build(BuildContext context) {
    final metrics = _metricItems(summary);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 620 ? 3 : 2;
        final width = (constraints.maxWidth - ((columns - 1) * 10)) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: metrics
              .map(
                (metric) => SizedBox(width: width, child: _MetricCard(metric)),
              )
              .toList(growable: false),
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard(this.metric);

  final _MetricItem metric;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE8E1DD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(metric.icon, color: _validationRed, size: 21),
          const SizedBox(height: 9),
          Text(
            metric.value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 3),
          Text(
            metric.label,
            style: const TextStyle(
              color: _validationMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionHistoryCard extends StatelessWidget {
  const _SessionHistoryCard({
    required this.session,
    required this.now,
    required this.onTap,
  });

  final ValidationSession session;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                session.status == ValidationSessionStatus.active
                    ? Icons.fiber_manual_record_rounded
                    : Icons.check_circle_outline_rounded,
                color: session.status == ValidationSessionStatus.active
                    ? _validationRed
                    : const Color(0xFF387653),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${session.environment}  |  ${_duration(session.elapsedAt(now))}',
                      style: const TextStyle(
                        color: _validationMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: _validationMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionDetailsSheet extends StatelessWidget {
  const _SessionDetailsSheet({
    required this.data,
    required this.summary,
    required this.onExportJson,
    required this.onExportCsv,
  });

  final ValidationSessionData data;
  final ValidationSummary summary;
  final VoidCallback onExportJson;
  final VoidCallback onExportCsv;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      minChildSize: 0.55,
      maxChildSize: 0.96,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
        children: [
          Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD3CCC8),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            data.session.name,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            '${data.session.environment}  |  ${summary.telemetryRecordCount} records',
            style: const TextStyle(color: _validationMuted),
          ),
          const SizedBox(height: 18),
          _MetricsGrid(summary: summary),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _validationRed,
                  ),
                  onPressed: onExportJson,
                  child: const Text('COPY JSON'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: onExportCsv,
                  child: const Text('COPY CSV'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE8E1DD)),
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: const TextStyle(color: _validationMuted, fontSize: 11),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFFFE8E6) : const Color(0xFFEAF6EF),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? _validationRed : const Color(0xFF387653),
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _PulseDot extends StatelessWidget {
  const _PulseDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: const BoxDecoration(
        color: Color(0xFFFF5A56),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return const _Panel(
      child: Text(
        'No recorded sessions yet. Start one before a controlled field test.',
        style: TextStyle(color: _validationMuted, fontSize: 12),
      ),
    );
  }
}

class _ValidationError extends StatelessWidget {
  const _ValidationError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: _validationRed),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _NewSessionInput {
  const _NewSessionInput({
    required this.name,
    required this.environment,
    required this.notes,
  });

  final String name;
  final String environment;
  final String notes;
}

class _MetricItem {
  const _MetricItem(this.label, this.value, this.icon);

  final String label;
  final String value;
  final IconData icon;
}

List<_MetricItem> _metricItems(ValidationSummary summary) => [
  _MetricItem(
    'MESSAGE DELIVERY SUCCESS',
    _percent(summary.deliverySuccessRate, empty: 'Needs delivery'),
    Icons.task_alt_rounded,
  ),
  _MetricItem(
    'PEER DISCOVERY SUCCESS',
    _percent(summary.discoverySuccessRate, empty: 'No attempts'),
    Icons.radar_rounded,
  ),
  _MetricItem(
    'NODE-TO-NODE LATENCY',
    _milliseconds(summary.averageNodeLatencyMs),
    Icons.speed_rounded,
  ),
  _MetricItem(
    'END-TO-END PROPAGATION',
    _milliseconds(summary.averagePropagationMs),
    Icons.route_rounded,
  ),
  _MetricItem(
    'HOP DISTRIBUTION',
    summary.hopDistribution.isEmpty
        ? 'No deliveries'
        : summary.hopDistribution.entries
              .map((entry) => '${entry.key}:${entry.value}')
              .join('  '),
    Icons.hub_outlined,
  ),
  _MetricItem(
    'TRANSPORT USAGE',
    summary.transportUsage.isEmpty
        ? 'No transfers'
        : summary.transportUsage.entries
              .map((entry) => '${_transportLabel(entry.key)} ${entry.value}')
              .join(' / '),
    Icons.swap_calls_rounded,
  ),
  _MetricItem(
    'FALLBACK RATE',
    _percent(summary.fallbackRate, empty: 'No transfers'),
    Icons.alt_route_rounded,
  ),
  _MetricItem(
    'BATTERY IMPACT',
    summary.batteryConsumedPerHour == null
        ? 'Needs unplugged samples'
        : '${summary.batteryConsumedPerHour!.toStringAsFixed(1)}% / hour',
    Icons.battery_5_bar_rounded,
  ),
];

String _percent(double? value, {required String empty}) =>
    value == null ? empty : '${(value * 100).toStringAsFixed(1)}%';

String _milliseconds(double? value) {
  if (value == null) return 'Needs matching events';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(2)} s';
  return '${value.toStringAsFixed(0)} ms';
}

String _transportLabel(String transport) => switch (transport) {
  'wifi_direct' => 'Wi-Fi',
  'bluetooth' => 'BLE',
  _ => transport,
};

String _duration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
