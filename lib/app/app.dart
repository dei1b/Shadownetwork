import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../features/auth/presentation/pages/login_page.dart';
import '../features/auth/presentation/pages/signup_page.dart';
import '../features/trust/presentation/pages/trust_bundle_import_page.dart';
import '../features/validation/presentation/pages/validation_session_page.dart';
import 'presentation/pages/app_shell_page.dart';

class DisasterCommApp extends StatelessWidget {
  const DisasterCommApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Disaster-Resilient Communication',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const AppShellPage(),
      routes: {
        '/login': (context) => const LoginPage(),
        '/signup': (context) => const SignUpPage(),
        '/app': (context) => const AppShellPage(),
        '/trust-bundle': (context) => const TrustBundleImportPage(),
        '/validation': (context) => const ValidationSessionPage(),
      },
    );
  }
}
