import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/admin/domain/repositories/admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/presentation/pages/browser_admin_dashboard_page.dart';

class _Registry implements AdminRegistryRepository {
  _Registry({this.missingIdentity = false});
  final bool missingIdentity;
  @override
  Future<List<RegisteredDevice>> loadDevices() async => [
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
  Future<void> saveDevices(List<RegisteredDevice> devices) async {}
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
  testWidgets('missing desktop identity gives publication feedback', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
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
