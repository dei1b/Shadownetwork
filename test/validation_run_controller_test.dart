import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/validation/data/repositories/sqlite_validation_metrics_repository.dart';
import 'package:shadownetwork/features/validation/data/services/battery_sampler.dart';
import 'package:shadownetwork/features/validation/presentation/providers/validation_session_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/database_migration_test_harness.dart';
import 'support/validation_run_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test(
    'prefill uses most recent local code, never a foreign imported run',
    () async {
      final h = await DatabaseMigrationTestHarness.create();
      addTearDown(h.dispose);
      final db = await h.openCurrentDatabase();
      addTearDown(db.close);
      final repo = SqliteValidationMetricsRepository(database: db);
      final base = DateTime.utc(2026, 10, 26);
      for (final fixture in [
        runFixture(id: 'old', runId: 'LOCAL-OLD', startedAt: base),
        runFixture(
          id: 'recent',
          runId: 'LOCAL-RECENT',
          startedAt: base.add(const Duration(hours: 1)),
        ),
        runFixture(
          id: 'legacy',
          runId: null,
          startedAt: base.add(const Duration(hours: 2)),
        ),
        runFixture(
          id: 'remote',
          deviceId: 'foreign',
          runId: 'FOREIGN',
          startedAt: base.add(const Duration(hours: 3)),
        ),
      ]) {
        await repo.importSessionData(fixture);
      }
      final container = ProviderContainer(
        overrides: [
          localMessagingDatabaseProvider.overrideWith((ref) async => db),
          batterySamplerProvider.overrideWithValue(
            const UnavailableBatterySampler(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(validationSessionProvider.future);
      final controller = container.read(validationSessionProvider.notifier);
      expect(await controller.lastLocalRunCode('local'), 'LOCAL-RECENT');
      expect(await controller.lastLocalRunCode('absent'), isNull);
      await controller.startSession(
        name: 'New trial',
        environment: 'Lab',
        deviceId: 'local',
        deviceRole: 'responder',
        testRunId: ' local-recent ',
      );
      expect(
        container
            .read(validationSessionProvider)
            .value!
            .activeSession!
            .testRunId,
        'LOCAL-RECENT',
      );
      await controller.stopSession();
      expect(
        container.read(validationSessionProvider).value!.activeSession,
        isNull,
      );
      expect(await controller.lastLocalRunCode('local'), 'LOCAL-RECENT');
    },
  );
}
