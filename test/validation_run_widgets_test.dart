import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/presentation/providers/device_access_provider.dart';
import 'package:shadownetwork/features/validation/data/repositories/sqlite_validation_metrics_repository.dart';
import 'package:shadownetwork/features/validation/data/services/battery_sampler.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_session.dart';
import 'package:shadownetwork/features/validation/presentation/pages/validation_session_page.dart';
import 'package:shadownetwork/features/validation/presentation/providers/validation_session_provider.dart';
import 'package:shadownetwork/features/validation/presentation/widgets/validation_session_start_dialog.dart';
import 'package:shadownetwork/features/validation/presentation/widgets/validation_run_qr_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/database_migration_test_harness.dart';
import 'support/validation_run_fixtures.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  testWidgets('approval lost while form is open cannot start recording', (
    tester,
  ) async {
    final h = (await tester.runAsync(DatabaseMigrationTestHarness.create))!;
    addTearDown(h.dispose);
    final db = (await tester.runAsync(h.openCurrentDatabase))!;
    addTearDown(db.close);
    final repo = SqliteValidationMetricsRepository(database: db);
    final access = StateProvider<DeviceAccessLevel>(
      (ref) => DeviceAccessLevel.responder,
    );
    final container = ProviderContainer(
      overrides: [
        localMessagingDatabaseProvider.overrideWith((ref) async => db),
        batterySamplerProvider.overrideWithValue(
          const UnavailableBatterySampler(),
        ),
        deviceAccessProfileProvider.overrideWith(
          (ref) async =>
              DeviceAccessProfile(deviceId: 'local', level: ref.watch(access)),
        ),
        localPeerProvider.overrideWith(
          (ref) async => const Peer(
            id: 'local',
            name: 'Local',
            type: PeerType.responder,
            isConnected: true,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container.read(validationSessionProvider.future),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ValidationSessionPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('START VALIDATION SESSION'));
      await repo.getSessions();
    });
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('validation-session-name')),
      'Approval race',
    );
    await tester.enterText(
      find.byKey(const ValueKey('validation-run-code')),
      'RACE-RUN',
    );
    container.read(access.notifier).state = DeviceAccessLevel.keyMismatch;
    await tester.pump();
    await tester.runAsync(
      () => container.read(deviceAccessProfileProvider.future),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Start recording'));
      await Future<void>.delayed(Duration.zero);
      if (container.read(validationSessionProvider).isLoading) {
        await container.read(validationSessionProvider.future);
      }
    });
    await tester.pumpAndSettle();
    expect(await tester.runAsync(repo.getSessions), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'form validates run code without losing input and confirms canonical identity',
    (tester) async {
      ValidationSessionInput? result;
      await tester.pumpWidget(
        _host((context) async {
          result = await showValidationSessionStartDialog(context);
        }),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('validation-session-name')),
        'Indoor trial',
      );
      await tester.enterText(
        find.byKey(const ValueKey('validation-session-notes')),
        'Preserve notes',
      );
      await tester.enterText(
        find.byKey(const ValueKey('validation-run-code')),
        'bad code',
      );
      await tester.tap(find.text('Start recording'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.text('Preserve notes'), findsOneWidget);
      expect(find.textContaining('3–48'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('validation-run-code')),
        ' panabo-2026-001 ',
      );
      await tester.tap(find.text('Start recording'));
      await tester.pumpAndSettle();
      expect(result!.testRunId, 'PANABO-2026-001');
      expect(result!.name, 'Indoor trial');
      expect(result!.notes, 'Preserve notes');
    },
  );
  testWidgets(
    'generation is explicit and scan fills but never submits the form',
    (tester) async {
      var starts = 0;
      await tester.pumpWidget(
        _host((context) async {
          final input = await showValidationSessionStartDialog(
            context,
            initialRunCode: 'OLD-RUN',
            scanRunCode: (_) async => 'SCANNED-RUN',
          );
          if (input != null) starts++;
        }),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('OLD-RUN'), findsOneWidget);
      await tester.tap(find.text('Generate code'));
      await tester.pump();
      final field = tester.widget<TextFormField>(
        find.byKey(const ValueKey('validation-run-code')),
      );
      expect(
        field.controller!.text,
        matches(RegExp(r'^SN-[0-9]{8}-[A-F0-9]{32}$')),
      );
      await tester.tap(find.text('Scan run QR'));
      await tester.pumpAndSettle();
      expect(find.text('SCANNED-RUN'), findsOneWidget);
      expect(starts, 0);
    },
  );
  testWidgets('cancelled and late scan results cannot change a disposed form', (
    tester,
  ) async {
    final scan = Completer<String?>();
    await tester.pumpWidget(
      _host(
        (context) => showValidationSessionStartDialog(
          context,
          initialRunCode: 'KEEP-RUN',
          scanRunCode: (_) => scan.future,
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scan run QR'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    scan.complete('LATE-RUN');
    await tester.pumpAndSettle();
    expect(find.text('LATE-RUN'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final fails in [false, true]) {
    testWidgets(
      'QR shows typed identity and copy ${fails ? 'failure' : 'success'}',
      (tester) async {
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              if (fails) throw PlatformException(code: 'unavailable');
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          _host(
            (context) =>
                showValidationRunQrDialog(context, testRunId: 'RUN-001'),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('RUN-001'), findsOneWidget);
        expect(find.byType(QrImageView), findsOneWidget);
        await tester.ensureVisible(find.text('Copy run code'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy run code'));
        await tester.pumpAndSettle();
        expect(
          find.text(fails ? 'Unable to copy run code' : 'Run code copied'),
          findsOneWidget,
        );
        expect(copied, fails ? isEmpty : ['RUN-001']);
      },
    );
  }
  for (final width in [320.0, 412.0]) {
    testWidgets('start form fits $width with keyboard and enlarged text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _host(
          (context) => showValidationSessionStartDialog(context),
          mediaQuery: MediaQueryData(
            size: Size(width, 900),
            textScaler: TextScaler.linear(1.5),
            viewInsets: const EdgeInsets.only(bottom: 280),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Start recording'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });
  }
  for (final runId in ['RUN-001', null]) {
    testWidgets(
      'active/history/details preserve ${runId ?? 'legacy'} run state',
      (tester) async {
        final h = (await tester.runAsync(DatabaseMigrationTestHarness.create))!;
        addTearDown(h.dispose);
        final db = (await tester.runAsync(h.openCurrentDatabase))!;
        addTearDown(db.close);
        final repo = SqliteValidationMetricsRepository(database: db);
        await tester.runAsync(
          () => repo.importSessionData(
            runFixture(runId: runId, status: ValidationSessionStatus.active),
          ),
        );
        final container = ProviderContainer(
          overrides: [
            localMessagingDatabaseProvider.overrideWith((ref) async => db),
            batterySamplerProvider.overrideWithValue(
              const UnavailableBatterySampler(),
            ),
            deviceAccessProfileProvider.overrideWith(
              (ref) async => const DeviceAccessProfile(
                deviceId: 'local',
                level: DeviceAccessLevel.responder,
              ),
            ),
            localPeerProvider.overrideWith(
              (ref) async => const Peer(
                id: 'local',
                name: 'Local',
                type: PeerType.responder,
                isConnected: true,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.runAsync(
          () => container.read(validationSessionProvider.future),
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: ValidationSessionPage()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(runId ?? 'No run ID (legacy)'), findsWidgets);
        expect(find.text('Scan run QR'), findsNothing);
        if (runId == null) {
          expect(find.text('Show run QR'), findsNothing);
        }
        await tester.ensureVisible(find.text('Local trial').last);
        await tester.runAsync(() async {
          await tester.tap(find.text('Local trial').last);
          await repo.getSessionData('session');
        });
        await tester.pumpAndSettle();
        expect(find.text(runId ?? 'No run ID (legacy)'), findsWidgets);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('unregistered phones cannot enter responder validation', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceAccessProfileProvider.overrideWith(
            (ref) async =>
                const DeviceAccessProfile.unregistered(deviceId: 'local'),
          ),
        ],
        child: const MaterialApp(home: ValidationSessionPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('approved responder device'), findsOneWidget);
    expect(find.text('Generate code'), findsNothing);
  });
}

Widget _host(
  Future<void> Function(BuildContext) onOpen, {
  MediaQueryData? mediaQuery,
}) => MaterialApp(
  builder: (context, child) =>
      mediaQuery == null ? child! : MediaQuery(data: mediaQuery, child: child!),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => onOpen(context),
        child: const Text('Open'),
      ),
    ),
  ),
);
