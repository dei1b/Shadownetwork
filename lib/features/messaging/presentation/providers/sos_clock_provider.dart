import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared only by visible SOS timing widgets, never by the database or shell.
final sosClockProvider =
    NotifierProvider.autoDispose<SosClockController, DateTime>(
      SosClockController.new,
    );

class SosClockController extends AutoDisposeNotifier<DateTime>
    with WidgetsBindingObserver {
  SosClockController({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  Timer? _timer;

  @override
  DateTime build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _timer?.cancel();
      WidgetsBinding.instance.removeObserver(this);
    });
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      _startTimer();
    }
    return _now().toUtc();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      state = _now().toUtc();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      this.state = _now().toUtc();
      _startTimer();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }
}
