import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadownetwork/features/messaging/presentation/pages/home_page.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/relay_runtime_provider.dart';

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
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.inactive:
        // Keep the relay alive while the UI is backgrounded. Android keeps the
        // native radio work visible through a foreground service notification.
        break;
      case AppLifecycleState.detached:
        controller.stop();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return const HomePage();
  }
}
