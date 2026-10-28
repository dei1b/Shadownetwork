import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/domain/services/device_access_resolver.dart';
import 'package:shadownetwork/features/trust/presentation/providers/device_access_provider.dart';
import 'package:shadownetwork/features/validation/data/repositories/sqlite_validation_metrics_repository.dart';
import 'package:shadownetwork/features/validation/data/services/battery_sampler.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_session.dart';
import 'package:shadownetwork/features/validation/domain/repositories/validation_bundle_file_gateway.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_bundle_codec.dart';
import 'package:shadownetwork/features/validation/presentation/pages/validation_session_page.dart';
import 'package:shadownetwork/features/validation/presentation/providers/validation_bundle_export_provider.dart';
import 'package:shadownetwork/features/validation/presentation/providers/validation_session_provider.dart';
import 'package:shadownetwork/features/validation/presentation/widgets/validation_bundle_share_button.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/database_migration_test_harness.dart';
import 'support/validation_run_fixtures.dart';

class _Files implements ValidationBundleFileGateway {
  int writes = 0;
  int shares = 0;
  Completer<void>? pending;
  @override
  Future<String> write({
    required String filename,
    required String source,
  }) async {
    writes++;
    const ValidationBundleCodec().decodeJson(source);
    await pending?.future;
    return '/exports/$filename';
  }

  @override
  Future<void> openShareSheet(String path) async {
    shares++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'cached responder access is resolved again after trust bundle expires',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      final db = await harness.openCurrentDatabase();
      addTearDown(db.close);
      await SqliteValidationMetricsRepository(
        database: db,
      ).importSessionData(runFixture());
      final start = DateTime.utc(2026, 10, 27);
      var now = start;
      final bundle = TrustBundle(
        schemaVersion: 2,
        generatedAt: start,
        expiresAt: start.add(const Duration(minutes: 1)),
        isSignatureVerified: true,
        approvedDevices: [
          TrustedDevice(
            deviceId: 'local',
            ownerName: 'Test',
            role: 'responder',
            status: 'approved',
            updatedAt: start,
            publicKey: 'public',
            keyVersion: 1,
          ),
        ],
        revokedDevices: [],
      );
      final files = _Files();
      final container = ProviderContainer(
        overrides: [
          localMessagingDatabaseProvider.overrideWith((ref) async => db),
          localPeerProvider.overrideWith(
            (ref) async => const Peer(
              id: 'local',
              name: 'Phone',
              type: PeerType.responder,
              isConnected: false,
            ),
          ),
          validationAppVersionProvider.overrideWith((ref) async => '1'),
          batterySamplerProvider.overrideWithValue(
            const UnavailableBatterySampler(),
          ),
          deviceAccessProfileProvider.overrideWith(
            (ref) async => const DeviceAccessResolver().resolve(
              deviceId: 'local',
              publicKey: 'public',
              keyVersion: 1,
              bundle: bundle,
              now: now,
            ),
          ),
          validationBundleFileGatewayProvider.overrideWithValue(files),
        ],
      );
      addTearDown(container.dispose);
      expect(
        (await container.read(
          deviceAccessProfileProvider.future,
        )).canAccessResponderInterface,
        isTrue,
      );
      await container.read(validationBundleExportProvider.future);
      now = start.add(const Duration(minutes: 2));
      await expectLater(
        container
            .read(validationBundleExportProvider.notifier)
            .shareSession('session'),
        throwsStateError,
      );
      expect(files.writes, 0);
      expect(files.shares, 0);
    },
  );

  testWidgets('platform failure before writing makes no saved-file claim', (
    tester,
  ) async {
    final harness = (await tester.runAsync(
      DatabaseMigrationTestHarness.create,
    ))!;
    addTearDown(harness.dispose);
    final db = (await tester.runAsync(harness.openCurrentDatabase))!;
    addTearDown(db.close);
    final files = _Files();
    final container = ProviderContainer(
      overrides: [
        localMessagingDatabaseProvider.overrideWith((ref) async => db),
        validationBundleFileGatewayProvider.overrideWithValue(files),
        deviceAccessProfileProvider.overrideWith(
          (ref) async => const DeviceAccessProfile(
            deviceId: 'local',
            level: DeviceAccessLevel.responder,
          ),
        ),
        localPeerProvider.overrideWith(
          (ref) async => const Peer(
            id: 'local',
            name: 'Phone',
            type: PeerType.responder,
            isConnected: false,
          ),
        ),
        validationAppVersionProvider.overrideWith(
          (ref) async => throw PlatformException(code: 'METADATA_UNAVAILABLE'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await container.read(deviceAccessProfileProvider.future);
      await container.read(localPeerProvider.future);
      await container.read(validationMetricsRepositoryProvider.future);
      await container.read(sosMessageRepositoryProvider.future);
      await container.read(validationBundleExportProvider.future);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: ValidationBundleShareButton(session: runFixture().session),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('SHARE VALIDATION FILE'));
      await container
          .read(validationBundleExportProvider.future)
          .catchError((Object _) => null);
    });
    await tester.pumpAndSettle();
    expect(files.writes, 0);
    expect(find.textContaining('file stays saved'), findsNothing);
    expect(find.textContaining('Could not'), findsOneWidget);
  });

  for (final active in [true, false]) {
    testWidgets(
      '${active ? "active" : "history"} session shares file from responder screen',
      (tester) async {
        final harness = (await tester.runAsync(
          DatabaseMigrationTestHarness.create,
        ))!;
        addTearDown(harness.dispose);
        final db = (await tester.runAsync(harness.openCurrentDatabase))!;
        addTearDown(db.close);
        final repo = SqliteValidationMetricsRepository(database: db);
        await tester.runAsync(
          () => repo.importSessionData(
            runFixture(
              status: active
                  ? ValidationSessionStatus.active
                  : ValidationSessionStatus.completed,
            ),
          ),
        );
        final files = _Files();
        final container = ProviderContainer(
          overrides: [
            localMessagingDatabaseProvider.overrideWith((ref) async => db),
            sosMessagesProvider.overrideWith((ref) async => []),
            batterySamplerProvider.overrideWithValue(
              const UnavailableBatterySampler(),
            ),
            validationBundleFileGatewayProvider.overrideWithValue(files),
            validationAppVersionProvider.overrideWith((ref) async => '0.1.0+1'),
            deviceAccessProfileProvider.overrideWith(
              (ref) async => const DeviceAccessProfile(
                deviceId: 'local',
                level: DeviceAccessLevel.responder,
              ),
            ),
            localPeerProvider.overrideWith(
              (ref) async => const Peer(
                id: 'local',
                name: 'Phone',
                type: PeerType.responder,
                isConnected: false,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.runAsync(
          () => container.read(validationSessionProvider.future),
        );
        await tester.runAsync(() async {
          await container.read(deviceAccessProfileProvider.future);
          await container.read(localPeerProvider.future);
          await container.read(sosMessageRepositoryProvider.future);
          await container.read(validationAppVersionProvider.future);
          await container.read(validationBundleExportProvider.future);
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: ValidationSessionPage()),
          ),
        );
        await tester.pumpAndSettle();
        if (!active) {
          await tester.ensureVisible(find.text('Local trial'));
          await tester.runAsync(() async {
            await tester.tap(find.text('Local trial'));
            await repo.getSessionData('session');
          });
          await tester.pumpAndSettle();
          for (
            var attempt = 0;
            attempt < 50 &&
                find.byType(DraggableScrollableSheet).evaluate().isEmpty;
            attempt++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
          await tester.scrollUntilVisible(
            find.byType(ValidationBundleShareButton),
            200,
            scrollable: find
                .descendant(
                  of: find.byType(DraggableScrollableSheet),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
        }
        await tester.ensureVisible(find.byType(ValidationBundleShareButton));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('SHARE VALIDATION FILE'));
          await container
              .read(validationBundleExportProvider.future)
              .timeout(const Duration(seconds: 10));
        });
        await tester.pumpAndSettle();
        expect(files.shares, 1);
        expect(find.text('Validation file created.'), findsOneWidget);
        final exports = (await tester.runAsync(
          () => repo.getSessionData('session'),
        ))!.exportRecords;
        expect(exports.single.result, 'file_created');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    'approval checked at submission and concurrent requests do not duplicate files',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      final db = await harness.openCurrentDatabase();
      addTearDown(db.close);
      await SqliteValidationMetricsRepository(
        database: db,
      ).importSessionData(runFixture());
      final files = _Files();
      final access = StateProvider((ref) => DeviceAccessLevel.keyMismatch);
      final container = ProviderContainer(
        overrides: [
          localMessagingDatabaseProvider.overrideWith((ref) async => db),
          validationBundleFileGatewayProvider.overrideWithValue(files),
          validationAppVersionProvider.overrideWith((ref) async => '1'),
          deviceAccessProfileProvider.overrideWith(
            (ref) async => DeviceAccessProfile(
              deviceId: 'local',
              level: ref.watch(access),
            ),
          ),
          localPeerProvider.overrideWith(
            (ref) async => const Peer(
              id: 'local',
              name: 'Phone',
              type: PeerType.responder,
              isConnected: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(validationBundleExportProvider.future);
      final controller = container.read(
        validationBundleExportProvider.notifier,
      );
      await expectLater(controller.shareSession('session'), throwsStateError);
      expect(files.writes, 0);
      container.read(access.notifier).state = DeviceAccessLevel.responder;
      files.pending = Completer<void>();
      final first = controller.shareSession('session');
      expect(await controller.shareSession('session'), isNull);
      files.pending!.complete();
      expect(await first, isNotNull);
      expect(files.writes, 1);
      expect(files.shares, 1);
    },
  );

  testWidgets('legacy sessions retain clipboard guidance without sharing', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ValidationBundleShareButton(
              session: runFixture(runId: null).session,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('No run code. Use Copy JSON or Copy CSV.'),
      findsOneWidget,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}
