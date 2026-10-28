import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/presentation/providers/admin_recovery_provider.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/admin_recovery_panel.dart';

class _KeyStore implements AdminSigningKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String source) async {
    value = source;
  }
}

void main() {
  testWidgets(
    'fresh desktop offers recovery and never silently creates an issuer',
    (tester) async {
      final db = (await tester.runAsync(
        () => openDesktopAdminRegistryDatabase(':memory:'),
      ))!;
      addTearDown(db.close);
      final keys = _KeyStore();
      final repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);
      final container = ProviderContainer(
        overrides: [
          desktopAdminRegistryProvider.overrideWith((ref) async => repo),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() => container.read(adminRecoveryProvider.future));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: AdminRecoveryPanel(
                onSaveBackup: (source) async => false,
                onReadBackup: () async => null,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(keys.value, isNull);
      expect(find.text('Restore encrypted backup'), findsOneWidget);
      await tester.tap(find.text('Create administrator identity'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.textContaining('already trusted by existing phones'),
        findsOneWidget,
      );
      expect(keys.value, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(keys.value, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
