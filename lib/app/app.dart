import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../features/auth/presentation/pages/login_page.dart';
import '../features/auth/presentation/pages/signup_page.dart';
import '../features/trust/presentation/pages/trust_bundle_import_page.dart';
import '../features/validation/presentation/pages/validation_session_page.dart';
import 'presentation/pages/app_shell_page.dart';
import 'presentation/pages/first_run_guide.dart';
import 'presentation/pages/settings_page.dart';
import 'presentation/pages/startup_splash_page.dart';

class DisasterCommApp extends StatelessWidget {
  const DisasterCommApp({super.key, this.initialization, this.firstRunGuide});

  final Future<void>? initialization;
  final Future<bool>? firstRunGuide;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Disaster-Resilient Communication',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: firstRunGuide == null
          ? const AppShellPage()
          : FirstRunGuideGate(
              shouldShow: firstRunGuide!,
              child: const AppShellPage(),
            ),
      builder: (context, child) => initialization == null
          ? child!
          : StartupGate(initialization: initialization!, child: child!),
      routes: {
        '/login': (context) => const LoginPage(),
        '/signup': (context) => const SignUpPage(),
        '/app': (context) => const AppShellPage(),
        '/trust-bundle': (context) => const TrustBundleImportPage(),
        '/settings': (context) => const SettingsPage(),
        '/validation': (context) => const ValidationSessionPage(),
      },
    );
  }
}
