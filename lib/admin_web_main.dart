import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'features/admin/presentation/pages/browser_admin_dashboard_page.dart';

void main() {
  runApp(const ProviderScope(child: ShadowNetworkAdminWebApp()));
}

class ShadowNetworkAdminWebApp extends StatelessWidget {
  const ShadowNetworkAdminWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shadow Network Admin',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const BrowserAdminDashboardPage(),
    );
  }
}
