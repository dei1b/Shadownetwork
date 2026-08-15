import 'dart:async';

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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(relayRuntimeProvider.notifier).start();
      unawaited(
        ref
            .read(validationSessionProvider.notifier)
            .recordRuntimeMode('foreground'),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(relayRuntimeProvider.notifier);
    switch (state) {
      case AppLifecycleState.resumed:
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
        // Keep the relay alive while the UI is backgrounded. Android keeps the
        // native radio work visible through a foreground service notification.
        unawaited(
          ref
              .read(validationSessionProvider.notifier)
              .recordRuntimeMode('background'),
        );
        break;
      case AppLifecycleState.detached:
        controller.stop();
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
      loading: () => const _AccessLoadingPage(),
      error: (_, _) => const HomePage(
        accessProfile: DeviceAccessProfile.unregistered(deviceId: 'unknown'),
      ),
    );
  }
}

class _AccessLoadingPage extends StatelessWidget {
  const _AccessLoadingPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFFE83C3D)),
              SizedBox(height: 16),
              Text(
                'VERIFYING DEVICE ACCESS',
                style: TextStyle(
                  color: Color(0xFF5C5C5C),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
