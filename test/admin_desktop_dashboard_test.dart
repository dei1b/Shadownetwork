import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/admin/domain/repositories/admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/presentation/pages/browser_admin_dashboard_page.dart';

class _Registry implements AdminRegistryRepository {
  _Registry({
    this.missingIdentity = false,
    this.extraDevices = const [],
    this.saveGate,
    this.failSave = false,
  });
  final Completer<void>? saveGate;
  final bool failSave;
  int saves = 0;
  final List<RegisteredDevice> extraDevices;
  final bool missingIdentity;
  @override
  Future<List<RegisteredDevice>> loadDevices() async => [
    ...extraDevices,
    RegisteredDevice(
      deviceId: 'DESKTOP-PHONE',
      ownerName: 'Stored desktop resident',
      role: RegisteredDeviceRole.civilian,
      status: RegisteredDeviceStatus.pending,
      registeredAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      lastSeenLabel: 'Stored',
    ),
  ];
  @override
  Future<void> saveDevices(List<RegisteredDevice> devices) async {
    saves++;
    await saveGate?.future;
    if (failSave) throw StateError('Storage unavailable');
  }

  @override
  Future<String> buildTrustBundleJson(List<RegisteredDevice> devices) async {
    if (missingIdentity) {
      throw StateError(
        'Administrator identity is missing. Restore the original identity backup.',
      );
    }
    return '{}';
  }
}

void main() {
  testWidgets('legacy approval labels explain manual distribution', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AdminTheme.light,
        home: BrowserAdminDashboardPage(
          desktopMode: true,
          registry: _Registry(
            extraDevices: [
              RegisteredDevice(
                deviceId: 'LEGACY-APPROVED',
                ownerName: 'Existing registration',
                role: RegisteredDeviceRole.relay,
                status: RegisteredDeviceStatus.approved,
                registeredAt: DateTime.utc(2026),
                updatedAt: DateTime.utc(2026),
                lastSeenLabel: 'Approved for next sync',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Approved for next sync'), findsNothing);
    expect(
      find.textContaining('Approved locally - share updated trust bundle'),
      findsOneWidget,
    );
  });

  for (final (fail, width, scale) in [
    (false, 1440.0, 1.0),
    (true, 1440.0, 1.0),
    (false, 480.0, 2.0),
  ]) {
    testWidgets(
      'saving disables mutations and recovers after ${fail ? 'failure' : 'success'} at $width',
      (tester) async {
        final gate = Completer<void>();
        final registry = _Registry(saveGate: gate, failSave: fail);
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: AdminTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: BrowserAdminDashboardPage(
              desktopMode: true,
              registry: registry,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Approve'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Approve'));
        await tester.pump();
        expect(find.text('Saving registry changes...'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Approve'),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Edit'),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(
                  OutlinedButton,
                  'Paste Phone Registration JSON',
                ),
              )
              .onPressed,
          isNull,
        );
        expect(registry.saves, 1);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('Saving registry changes...'), findsNothing);
        if (fail) {
          expect(
            find.textContaining('Unable to save the registry'),
            findsOneWidget,
          );
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Approve'),
                )
                .onPressed,
            isNotNull,
          );
        } else {
          expect(
            find.textContaining(
              'Approved locally - share updated trust bundle',
            ),
            findsOneWidget,
          );
          expect(
            find.textContaining(
              'Export a new trust bundle and import it on each phone.',
            ),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('device search combines with status and role and can reset', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AdminTheme.light,
        home: BrowserAdminDashboardPage(
          desktopMode: true,
          registry: _Registry(
            extraDevices: [
              RegisteredDevice(
                deviceId: 'RESCUE-02',
                ownerName: 'Maria Santos',
                role: RegisteredDeviceRole.responder,
                status: RegisteredDeviceStatus.approved,
                registeredAt: DateTime.utc(2026),
                updatedAt: DateTime.utc(2026),
                lastSeenLabel: 'Approved for next sync',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('admin-device-search'));
    expect(search, findsOneWidget);
    await tester.enterText(search, '  MARIA  ');
    await tester.pumpAndSettle();
    expect(find.text('Maria Santos'), findsOneWidget);
    expect(find.text('Stored desktop resident'), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'Pending'));
    await tester.pumpAndSettle();
    expect(find.text('No devices match your filters.'), findsOneWidget);
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('Maria Santos'), findsOneWidget);
    expect(find.text('Stored desktop resident'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('admin-role-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Responder').last);
    await tester.pumpAndSettle();
    expect(find.text('Maria Santos'), findsOneWidget);
    expect(find.text('Stored desktop resident'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('registry review is visible immediately at laptop size', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AdminTheme.light,
        home: BrowserAdminDashboardPage(
          desktopMode: true,
          registry: _Registry(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Stored desktop resident').hitTestable(), findsOneWidget);
    expect(find.text('Approve').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [480.0, 900.0]) {
    testWidgets('admin supports enlarged text at width $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: BrowserAdminDashboardPage(
            desktopMode: true,
            registry: _Registry(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Stored desktop resident'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Registration details'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Registration details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Registration details'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Add to registry'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Add to registry'));
      await tester.pumpAndSettle();
      expect(find.text('Add to registry').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('missing desktop identity gives publication feedback', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AdminTheme.light,
        home: BrowserAdminDashboardPage(
          registry: _Registry(missingIdentity: true),
          desktopMode: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Copy Trust Bundle JSON'));
    await tester.tap(find.text('Copy Trust Bundle JSON'));
    await tester.pump();
    expect(
      find.textContaining('Administrator identity is missing'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'desktop uses injected registry and pasted registration instead of camera',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: BrowserAdminDashboardPage(
            registry: _Registry(),
            desktopMode: true,
            validationPanel: const Text('Open desktop validation imports'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Stored desktop resident'), findsOneWidget);
      expect(find.text('Open desktop validation imports'), findsOneWidget);
      expect(find.text('Scan Phone QR with PC Camera'), findsNothing);
      await tester.ensureVisible(find.text('Paste Phone Registration JSON'));
      await tester.tap(find.text('Paste Phone Registration JSON'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-registration-json')),
        findsOneWidget,
      );
      expect(find.byType(MobileScanner), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
