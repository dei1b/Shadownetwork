import 'dart:async';

import 'startup_splash_page.dart';
import '../../../features/registration/data/pilot_registration.dart';
import '../../../features/trust/data/services/trust_directory_sync_service.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadownetwork/features/messaging/presentation/pages/home_page.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/relay_runtime_provider.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/presentation/providers/device_access_provider.dart';
import 'package:shadownetwork/features/validation/presentation/providers/validation_session_provider.dart';

class AppShellPage extends ConsumerStatefulWidget {
  const AppShellPage({super.key});

  @override
  ConsumerState<AppShellPage> createState() => _AppShellPageState();
}

class _AppShellPageState extends ConsumerState<AppShellPage>
    with WidgetsBindingObserver {
  Timer? _directoryTimer;

  void _startDirectoryRefresh() {
    if (!pilotRegistrationEnabled || !pilotRegistrationIsLive) return;
    _directoryTimer?.cancel();
    void refresh() {
      if (!mounted) return;
      unawaited(
        ref
            .read(trustDirectorySyncProvider)
            .refresh()
            .catchError((Object _) {}),
      );
    }

    refresh();
    _directoryTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => refresh(),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final isVisible =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (isVisible) _startDirectoryRefresh();
      ref.read(relayRuntimeProvider.notifier).setBackground(!isVisible);
      ref.read(relayRuntimeProvider.notifier).start();
      unawaited(
        ref
            .read(validationSessionProvider.notifier)
            .recordRuntimeMode(isVisible ? 'foreground' : 'background'),
      );
    });
  }

  @override
  void dispose() {
    _directoryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _directoryTimer?.cancel();
    final controller = ref.read(relayRuntimeProvider.notifier);
    switch (state) {
      case AppLifecycleState.resumed:
        _startDirectoryRefresh();
        controller.setBackground(false);
        controller.start();
        unawaited(
          ref
              .read(validationSessionProvider.notifier)
              .recordRuntimeMode('foreground'),
        );
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.inactive:
        controller.setBackground(true);
        // Keep the relay alive while the UI is backgrounded. Android keeps the
        // native radio work visible through a foreground service notification.
        unawaited(
          ref
              .read(validationSessionProvider.notifier)
              .recordRuntimeMode('background'),
        );
        break;
      case AppLifecycleState.detached:
        controller.setBackground(true);
        unawaited(
          ref
              .read(validationSessionProvider.notifier)
              .recordRuntimeMode('detached'),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accessProfile = ref.watch(deviceAccessProfileProvider);
    return accessProfile.when(
      data: (profile) => HomePage(accessProfile: profile),
      loading: () => const StartupSplashPage(),
      error: (_, _) => const HomePage(
        accessProfile: DeviceAccessProfile.unregistered(deviceId: 'unknown'),
      ),
    );
  }
}
