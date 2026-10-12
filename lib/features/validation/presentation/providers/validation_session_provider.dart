import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../data/services/battery_sampler.dart';
import '../../domain/entities/validation_event.dart';
import '../../domain/entities/validation_session.dart';
import '../../domain/entities/validation_session_data.dart';
import '../../domain/entities/validation_summary.dart';
import '../../domain/services/validation_export_service.dart';
import '../../domain/services/validation_metrics_calculator.dart';

final batterySamplerProvider = Provider<BatterySampler>((ref) {
  return Platform.isAndroid
      ? const AndroidBatterySampler()
      : const UnavailableBatterySampler();
});

final validationExportServiceProvider = Provider<ValidationExportService>(
  (ref) => const ValidationExportService(),
);

final validationMetricsCalculatorProvider =
    Provider<ValidationMetricsCalculator>(
      (ref) => const ValidationMetricsCalculator(),
    );

class ValidationSessionViewState {
  const ValidationSessionViewState({
    required this.sessions,
    required this.now,
    this.activeSession,
    this.activeData,
    this.activeSummary,
  });

  final ValidationSession? activeSession;
  final ValidationSessionData? activeData;
  final ValidationSummary? activeSummary;
  final List<ValidationSession> sessions;
  final DateTime now;

  ValidationSessionViewState copyWith({DateTime? now}) {
    return ValidationSessionViewState(
      activeSession: activeSession,
      activeData: activeData,
      activeSummary: activeSummary,
      sessions: sessions,
      now: now ?? this.now,
    );
  }
}

class ValidationSessionController
    extends AsyncNotifier<ValidationSessionViewState> {
  Timer? _clockTimer;
  Timer? _refreshTimer;
  Timer? _batteryTimer;

  @override
  Future<ValidationSessionViewState> build() async {
    ref.onDispose(_cancelTimers);
    final loaded = await _loadState();
    if (loaded.activeSession != null) {
      _startTimers();
    }
    return loaded;
  }

  Future<void> startSession({
    required String name,
    required String environment,
    required String deviceId,
    required String deviceRole,
    String? notes,
  }) async {
    final repository = await ref.read(
      validationMetricsRepositoryProvider.future,
    );
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await repository.startSession(
        name: name,
        environment: environment,
        deviceId: deviceId,
        deviceRole: deviceRole,
        notes: notes,
      );
      await repository.captureEvent(
        type: ValidationEventType.runtimeModeChanged,
        metadata: const {
          'runtime_mode': 'foreground',
          'reason': 'session_start',
        },
      );
      await _sampleBattery('foreground');
      _startTimers();
      return _loadState();
    });
  }

  Future<void> stopSession() async {
    final repository = await ref.read(
      validationMetricsRepositoryProvider.future,
    );
    await _sampleBattery('foreground');
    await repository.captureEvent(
      type: ValidationEventType.runtimeModeChanged,
      metadata: const {'runtime_mode': 'stopped', 'reason': 'session_stop'},
    );
    await repository.stopActiveSession();
    _cancelTimers();
    state = AsyncData(await _loadState());
  }

  Future<void> recordRuntimeMode(String runtimeMode) async {
    final repository = await ref.read(
      validationMetricsRepositoryProvider.future,
    );
    final captured = await repository.captureEvent(
      type: ValidationEventType.runtimeModeChanged,
      metadata: {'runtime_mode': runtimeMode},
    );
    if (captured) {
      await _sampleBattery(runtimeMode);
    }
  }

  Future<String> exportJson(String sessionId) async {
    return _export(sessionId, format: 'json');
  }

  Future<String> exportCsv(String sessionId) async {
    return _export(sessionId, format: 'csv');
  }

  Future<void> refresh() async {
    state = AsyncData(await _loadState());
  }

  Future<String> _export(String sessionId, {required String format}) async {
    final repository = await ref.read(
      validationMetricsRepositoryProvider.future,
    );
    final service = ref.read(validationExportServiceProvider);
    final data = await repository.getSessionData(sessionId);
    final source = format == 'json'
        ? service.encodeJson(data)
        : service.encodeCsv(data);
    final timestamp = DateTime.now().toUtc();
    final payloadHash = sha256.convert(utf8.encode(source)).toString();
    await repository.recordExport(
      ValidationExportRecord(
        id: 'export-${timestamp.microsecondsSinceEpoch}-$format',
        sessionId: sessionId,
        createdAt: timestamp,
        destination: 'clipboard_$format',
        result: 'exported',
        retryCount: 0,
        payloadHash: payloadHash,
      ),
    );
    await refresh();
    return source;
  }

  Future<ValidationSessionViewState> _loadState() async {
    final repository = await ref.read(
      validationMetricsRepositoryProvider.future,
    );
    final sessions = await repository.getSessions();
    final active = await repository.getActiveSession();
    final activeData = active == null
        ? null
        : await repository.getSessionData(active.id);
    return ValidationSessionViewState(
      activeSession: active,
      activeData: activeData,
      activeSummary: activeData == null
          ? null
          : ref.read(validationMetricsCalculatorProvider).calculate(activeData),
      sessions: sessions,
      now: DateTime.now(),
    );
  }

  Future<void> _sampleBattery(String runtimeMode) async {
    final snapshot = await ref.read(batterySamplerProvider).sample();
    if (snapshot == null) return;
    final repository = await ref.read(
      validationMetricsRepositoryProvider.future,
    );
    await repository.captureBatterySample(
      batteryPercent: snapshot.percent,
      isCharging: snapshot.isCharging,
      runtimeMode: runtimeMode,
    );
  }

  void _startTimers() {
    _cancelTimers();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = state.valueOrNull;
      if (current != null) {
        state = AsyncData(current.copyWith(now: DateTime.now()));
      }
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(refresh());
    });
    _batteryTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      unawaited(_sampleBattery('active_relay'));
    });
  }

  void _cancelTimers() {
    _clockTimer?.cancel();
    _refreshTimer?.cancel();
    _batteryTimer?.cancel();
    _clockTimer = null;
    _refreshTimer = null;
    _batteryTimer = null;
  }
}

final validationSessionProvider =
    AsyncNotifierProvider<
      ValidationSessionController,
      ValidationSessionViewState
    >(ValidationSessionController.new);
