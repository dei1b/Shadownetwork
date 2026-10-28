import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/presentation/providers/admin_recovery_provider.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/admin_recovery_panel.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';

class _KeyStore implements AdminSigningKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String source) async {
    value = source;
  }
}

class _ReadyRecovery extends AdminRecoveryController {
  @override
  Future<AdminIdentityStatus> build() async => const AdminIdentityStatus(
    fingerprint: null,
    bundleVersion: 0,
    hasIdentity: true,
  );
}

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'backup fields stay separated and mismatch is attached at scale $scale',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [adminRecoveryProvider.overrideWith(_ReadyRecovery.new)],
            child: MaterialApp(
              theme: AdminTheme.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: AdminRecoveryPanel(
                  onSaveBackup: (_) async => false,
                  onReadBackup: () async => null,
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.scrollUntilVisible(
          find.text('Save encrypted backup'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.text('Save encrypted backup'));
        await tester.tap(find.text('Save encrypted backup'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.enterText(
          find.byType(TextField).first,
          'example-password',
        );
        await tester.tap(find.byType(TextField).last);
        await tester.pump(const Duration(milliseconds: 400));
        final helper = tester.getRect(find.text('At least 12 characters'));
        final repeat = tester.getRect(find.text('Repeat password'));
        expect(repeat.top - helper.bottom, greaterThanOrEqualTo(8));
        await tester.ensureVisible(find.text('Continue'));
        await tester.tap(find.text('Continue'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester
              .widget<TextField>(find.byType(TextField).last)
              .decoration!
              .errorText,
          'The passwords do not match.',
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pump(const Duration(milliseconds: 400));
      },
    );
  }

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
