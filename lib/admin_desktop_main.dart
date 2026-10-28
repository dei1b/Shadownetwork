import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'features/admin/presentation/theme/admin_theme.dart';
import 'features/admin/data/admin_signing_key_store.dart';
import 'features/admin/data/desktop_admin_registry_database.dart';
import 'features/admin/data/desktop_admin_registry_repository.dart';
import 'features/admin/presentation/pages/desktop_admin_shell.dart';
import 'features/admin/presentation/providers/admin_recovery_provider.dart';
import 'features/admin_validation/data/desktop_validation_database.dart';
import 'features/admin_validation/data/sqlite_validation_import_repository.dart';
import 'features/admin_validation/presentation/providers/validation_import_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _start();
}

Future<void> _start() async {
  Database? registryDatabase;
  Database? validationDatabase;
  try {
    final roaming = Platform.environment['APPDATA'];
    final base = roaming == null || roaming.isEmpty
        ? (await getApplicationSupportDirectory()).path
        : roaming;
    final directory = Directory(path.join(base, 'ShadowNetwork', 'Admin'));
    await directory.create(recursive: true);
    registryDatabase = await openDesktopAdminRegistryDatabase(
      path.join(directory.path, 'admin_registry.sqlite'),
    );
    validationDatabase = await openDesktopValidationDatabase(
      path.join(directory.path, 'admin_validation.sqlite'),
    );
    final registry = DesktopAdminRegistryRepository(
      database: registryDatabase,
      keyStore: const WindowsAdminSigningKeyStore(),
    );
    final imports = SqliteValidationImportRepository(
      database: validationDatabase,
    );
    runApp(
      ProviderScope(
        overrides: [
          desktopAdminRegistryProvider.overrideWith((ref) async => registry),
          validationImportRepositoryProvider.overrideWithValue(imports),
        ],
        child: const ShadowNetworkAdminDesktopApp(),
      ),
    );
  } catch (_) {
    await validationDatabase?.close();
    await registryDatabase?.close();
    runApp(
      MaterialApp(
        theme: AdminTheme.light,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Shadow Network Admin could not open its saved data. Your data was not reset.',
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _start,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ShadowNetworkAdminDesktopApp extends StatelessWidget {
  const ShadowNetworkAdminDesktopApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Shadow Network Admin',
    debugShowCheckedModeBanner: false,
    theme: AdminTheme.light,
    home: const DesktopAdminShell(),
  );
}
