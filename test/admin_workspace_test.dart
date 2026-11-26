import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/admin/presentation/pages/desktop_admin_shell.dart';
import 'package:shadownetwork/features/admin/presentation/providers/admin_recovery_provider.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin_validation/domain/validation_import.dart';
import 'package:shadownetwork/features/admin_validation/presentation/providers/validation_import_provider.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

import 'support/signed_trust_bundle_fixture.dart';

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
  Future<List<CampusRegistration>> loadRegistrations() async => [
    for (final device in await loadDevices())
      CampusRegistration.fromLegacyDevice(device),
  ];

  @override
  Future<List<PendingSyncOperation>> loadPendingSync() async => const [];

  @override
  Future<ReviewerProfile?> loadReviewerProfile() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RestoringRegistry extends _Registry {
  _RestoringRegistry({this.failRestore = false}) : super(empty: true);
  final bool failRestore;
  List<RegisteredDevice> saved = [];
  List<String> publicationIds = [];
  int loads = 0;

  @override
  Future<AdminIdentityStatus> identityStatus() async =>
      const AdminIdentityStatus(
        fingerprint: 'same-test-administrator',
        bundleVersion: 0,
        hasIdentity: true,
      );

  @override
  Future<List<RegisteredDevice>> loadDevices() async {
    loads++;
    return List.of(saved);
  }

  @override
  Future<List<CampusRegistration>> loadRegistrations() async => [
    for (final device in await loadDevices())
      CampusRegistration.fromLegacyDevice(device),
  ];

  @override
  Future<void> restoreEncryptedBackup(String source, String password) async {
    if (failRestore) throw StateError('Restore rejected');
    saved = [
      RegisteredDevice(
        deviceId: 'RESTORED-PHONE',
        ownerName: 'Recovered responder',
        role: RegisteredDeviceRole.responder,
        status: RegisteredDeviceStatus.approved,
        registeredAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        lastSeenLabel: 'Restored registration',
      ),
    ];
  }

  @override
  Future<void> saveDevices(List<RegisteredDevice> devices) async =>
      saved = List.of(devices);

  @override
  Future<void> saveRegistration(
    CampusRegistration registration, {
    PendingSyncOperation? pendingSync,
    bool removePendingForRegistration = false,
    bool syncDeviceList = true,
  }) async {
    final device = registration.toRegisteredDevice();
    final next = [
      for (final existing in saved)
        if (existing.deviceId == device.deviceId) device else existing,
      if (!saved.any((existing) => existing.deviceId == device.deviceId))
        device,
    ];
    saved = next;
  }

  @override
  Future<String> buildTrustBundleJson(
    List<RegisteredDevice> devices, {
    String? directoryProject,
    int minimumPreviousVersion = 0,
  }) async {
    publicationIds = devices.map((device) => device.deviceId).toList();
    // Capture the publication boundary without producing a fake signed bundle.
    throw StateError('Publication captured by test');
  }
}

class _Imports implements ValidationImportRepository {
  @override
  Future<List<ValidationImportedDataset>> listDatasets() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QrRegistry extends _Registry {
  _QrRegistry(this.bundle) : super(empty: true);

  final String bundle;

  @override
  Future<String> buildTrustBundleJson(
    List<RegisteredDevice> devices, {
    String? directoryProject,
    int minimumPreviousVersion = 0,
  }) async => bundle;
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    Size size, {
    double scale = 1,
    bool identity = true,
    bool empty = false,
    DesktopAdminRegistryRepository? registry,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopAdminRegistryProvider.overrideWith(
            (ref) async =>
                registry ?? _Registry(hasIdentity: identity, empty: empty),
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

  for (final count in [3, 12]) {
    testWidgets('publishes an approval QR for a $count-device bundle', (
      tester,
    ) async {
      final bundle = (await tester.runAsync(() async {
        final signer = await TestTrustBundleSigner.create();
        return signer.sign(
          bundleVersion: 7,
          issuedAt: DateTime.utc(2026, 11, 10),
          approvedDevices: [
            for (var index = 0; index < count; index++)
              TrustedDevice(
                deviceId:
                    '01a11062-f847-7203-9ad6-f420a162e${index.toString().padLeft(3, '0')}',
                ownerName: 'María Santos $index',
                role: 'civilian',
                status: 'approved',
                updatedAt: DateTime.utc(2026, 11, 10),
                publicKey: base64UrlEncode(List.filled(32, index + 1)),
                signingPublicKey: base64UrlEncode(List.filled(32, index + 32)),
              ),
          ],
        );
      }))!;
      String? clipboard;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await mount(tester, const Size(1280, 720), registry: _QrRegistry(bundle));
      final showQr = find.text('Show QR for Phone Scan');
      await tester.ensureVisible(showQr);
      await tester.pumpAndSettle();
      await tester.tap(showQr);
      await tester.pumpAndSettle();
      final qr = find.byType(QrImageView);
      expect(qr, findsOneWidget);
      if (count == 3) {
        final painterFinder = find.descendant(
          of: qr,
          matching: find.byWidgetPredicate(
            (widget) => widget is CustomPaint && widget.painter is QrPainter,
          ),
        );
        final painter =
            tester.widget<CustomPaint>(painterFinder).painter! as QrPainter;
        final compact = QrCode.fromData(
          data: jsonEncode(jsonDecode(bundle)),
          errorCorrectLevel: QrErrorCorrectLevel.M,
        );
        final pretty = QrCode.fromData(
          data: bundle,
          errorCorrectLevel: QrErrorCorrectLevel.M,
        );
        expect(painter.version, compact.typeNumber);
        expect(painter.version, lessThan(pretty.typeNumber));
        final desktopWidth = tester.getSize(qr).width;
        expect(desktopWidth, greaterThan(420));
        final tileWidth =
            tester.getSize(painterFinder).width / compact.moduleCount;
        expect(
          tester.widget<QrImageView>(qr).padding.left,
          closeTo(4 * tileWidth, 0.01),
        );

        await tester.binding.setSurfaceSize(const Size(480, 480));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(qr).width, lessThan(desktopWidth));
      } else {
        expect(find.textContaining('Frame 1 of'), findsOneWidget);
      }
      await tester.tap(find.text('Copy JSON'));
      await tester.pumpAndSettle();
      expect(clipboard, bundle);
    });
  }

  for (final failRestore in [false, true]) {
    testWidgets(
      'same-identity restore ${failRestore ? 'failure retains search draft' : 'reloads before publication'}',
      (tester) async {
        final repository = _RestoringRegistry(failRestore: failRestore);
        final container = ProviderContainer(
          overrides: [
            desktopAdminRegistryProvider.overrideWith(
              (ref) async => repository,
            ),
            validationImportRepositoryProvider.overrideWithValue(_Imports()),
          ],
        );
        addTearDown(container.dispose);
        await tester.binding.setSurfaceSize(const Size(1440, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AdminTheme.light,
              home: const DesktopAdminShell(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Scan phone QR'), findsOneWidget);
        final initialLoads = repository.loads;
        final identity = container.read(adminRecoveryProvider).requireValue;
        if (failRestore) {
          final search = find.byKey(const ValueKey('unified-registration-search'));
          await tester.enterText(search, 'Keep unfinished filter');
          await expectLater(
            container
                .read(adminRecoveryProvider.notifier)
                .restoreBackup('fixture', 'password'),
            throwsStateError,
          );
          await tester.pumpAndSettle();
          expect(repository.loads, initialLoads);
          expect(
            tester.widget<TextField>(search).controller!.text,
            'Keep unfinished filter',
          );
        } else {
          await tester.tap(find.text('Backup & recovery').first);
          await tester.pumpAndSettle();
          await container
              .read(adminRecoveryProvider.notifier)
              .restoreBackup('fixture', 'password');
          await tester.pumpAndSettle();
          expect(
            container.read(adminRecoveryProvider).requireValue.fingerprint,
            identity.fingerprint,
          );
          await tester.tap(find.text('Registrations').first);
          await tester.pumpAndSettle();
          expect(find.text('Recovered responder'), findsOneWidget);
          await tester.ensureVisible(find.text('Copy Trust Bundle JSON'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Copy Trust Bundle JSON'));
          await tester.pumpAndSettle();
          expect(repository.publicationIds, ['RESTORED-PHONE']);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'search draft survives validation and recovery navigation',
    (tester) async {
      await mount(tester, const Size(1440, 1000));
      final search = find.byKey(const ValueKey('unified-registration-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, 'Maria');
      await tester.tap(find.text('Validation data').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Backup & recovery').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Registrations').first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(search).controller!.text,
        'Maria',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty registry offers phone QR scan above fold in a small PC window',
    (tester) async {
      await mount(tester, const Size(786, 715), empty: true);
      final action = find.byKey(const ValueKey('unified-scan-qr-button'));
      expect(action.hitTestable(), findsOneWidget);
      await tester.tap(action);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Scan phone QR'), findsWidgets);
      await tester.tap(find.text('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop shell keeps registration queue visible and all destinations reachable',
    (tester) async {
      await mount(tester, const Size(1440, 900));
      expect(find.text('Maria Santos').hitTestable(), findsOneWidget);
      final showQr = find.byKey(const ValueKey('unified-show-approval-qr'));
      await tester.ensureVisible(showQr);
      await tester.pumpAndSettle();
      expect(showQr.hitTestable(), findsOneWidget);
      final pasteRegistration = find.byKey(
        const ValueKey('unified-paste-qr-button'),
      );
      await tester.ensureVisible(pasteRegistration);
      await tester.pumpAndSettle();
      expect(pasteRegistration.hitTestable(), findsOneWidget);
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
