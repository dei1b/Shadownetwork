import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/admin/presentation/pages/desktop_admin_shell.dart';
import 'package:shadownetwork/features/admin/presentation/providers/admin_recovery_provider.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin_validation/domain/validation_import.dart';
import 'package:shadownetwork/features/admin_validation/presentation/providers/validation_import_provider.dart';

// These fixtures never touch the real Windows registry or signing identity.
class _Registry implements DesktopAdminRegistryRepository {
  _Registry({this.hasIdentity = true, this.empty = false});
  final bool empty;
  final bool hasIdentity;
  @override
  Future<AdminIdentityStatus> identityStatus() async => AdminIdentityStatus(
    fingerprint: null,
    bundleVersion: 0,
    hasIdentity: hasIdentity,
  );
  @override
  Future<List<RegisteredDevice>> loadDevices() async => empty
      ? []
      : [
          for (final (id, name, role, status) in [
            (
              'SN-RESCUE-002',
              'Maria Santos',
              RegisteredDeviceRole.responder,
              RegisteredDeviceStatus.pending,
            ),
            (
              'SN-RELAY-014',
              'Barangay relay team',
              RegisteredDeviceRole.relay,
              RegisteredDeviceStatus.approved,
            ),
          ])
            RegisteredDevice(
              deviceId: id,
              ownerName: name,
              role: role,
              status: status,
              registeredAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
              lastSeenLabel: 'Registered locally',
            ),
        ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Imports implements ValidationImportRepository {
  @override
  Future<List<ValidationImportedDataset>> listDatasets() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    Size size, {
    double scale = 1,
    bool identity = true,
    bool empty = false,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopAdminRegistryProvider.overrideWith(
            (ref) async => _Registry(hasIdentity: identity, empty: empty),
          ),
          validationImportRepositoryProvider.overrideWithValue(_Imports()),
        ],
        child: MaterialApp(
          theme: AdminTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const RepaintBoundary(
            key: ValueKey('workspace-preview'),
            child: DesktopAdminShell(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'registration draft survives validation and recovery navigation',
    (tester) async {
      await mount(tester, const Size(1440, 1000));
      await tester.ensureVisible(find.text('Registration details'));
      await tester.tap(find.text('Registration details'));
      await tester.pumpAndSettle();
      final owner = find.widgetWithText(
        TextField,
        'User full name / Unit name',
      );
      await tester.ensureVisible(owner);
      await tester.enterText(owner, 'Draft responder name');
      await tester.tap(find.text('Validation data').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Backup & recovery').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(owner).controller!.text,
        'Draft responder name',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty registry offers registration above fold in a small PC window',
    (tester) async {
      await mount(tester, const Size(786, 715), empty: true);
      final action = find.byKey(const ValueKey('admin-first-registration'));
      expect(action.hitTestable(), findsOneWidget);
      expect(find.text('Search devices'), findsNothing);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-registration-json')),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop shell keeps device review visible and all destinations reachable',
    (tester) async {
      await mount(tester, const Size(1440, 900));
      expect(find.text('Maria Santos').hitTestable(), findsOneWidget);
      expect(find.text('Approve').hitTestable(), findsOneWidget);
      expect(
        find.text('Paste Phone Registration JSON').hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.text('Validation data').first);
      await tester.pumpAndSettle();
      expect(find.text('Choose JSON files'), findsOneWidget);
      await tester.tap(find.text('Backup & recovery').first);
      await tester.pumpAndSettle();
      expect(find.text('Restore encrypted backup'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [480.0, 900.0]) {
    testWidgets(
      'full shell and recovery notice reflow at $width with 200% text',
      (tester) async {
        await mount(tester, Size(width, 1000), scale: 2, identity: false);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Open recovery'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Restore encrypted backup'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Restore encrypted backup'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('render admin workspace for visual review', (tester) async {
    if (!const bool.fromEnvironment('ADMIN_UI_CAPTURE')) return;
    await tester.runAsync(() async {
      var sdk = File(Platform.resolvedExecutable).parent;
      while (!Directory(
        '${sdk.path}/bin/cache/artifacts/material_fonts',
      ).existsSync()) {
        final parent = sdk.parent;
        if (parent.path == sdk.path) {
          throw StateError('Flutter font cache not found');
        }
        sdk = parent;
      }
      final fontRoot = '${sdk.path}/bin/cache/artifacts/material_fonts';
      for (final family in ['Roboto', 'Ahem', 'Segoe UI']) {
        final loader = FontLoader(family);
        for (final name in [
          'roboto-regular.ttf',
          'roboto-medium.ttf',
          'roboto-bold.ttf',
        ]) {
          loader.addFont(
            Future.value(
              ByteData.sublistView(await File('$fontRoot/$name').readAsBytes()),
            ),
          );
        }
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File('$fontRoot/materialicons-regular.otf').readAsBytes(),
            ),
          ),
        );
      await icons.load();
    });
    await mount(tester, const Size(786, 715), empty: true);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('workspace-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/admin-ui-review/p1-empty.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  });
}
