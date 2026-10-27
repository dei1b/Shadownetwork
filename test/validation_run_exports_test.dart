import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/validation/data/repositories/sqlite_validation_metrics_repository.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_export_service.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_session_data.dart';
import 'package:shadownetwork/features/validation/domain/entities/validation_event.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/database_migration_test_harness.dart';
import 'support/validation_run_fixtures.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  const service = ValidationExportService();
  for (final kind in ['event', 'discovery', 'battery', 'export']) {
    test('rejects $kind evidence owned by another session and run', () async {
      final h = await DatabaseMigrationTestHarness.create();
      addTearDown(h.dispose);
      final db = await h.openCurrentDatabase();
      addTearDown(db.close);
      final repo = SqliteValidationMetricsRepository(database: db);
      final a = runFixture(telemetry: false);
      final b = runFixture(id: 'other', runId: 'OTHER-RUN');
      await repo.importSessionData(a);
      await repo.importSessionData(
        runFixture(id: 'other', runId: 'OTHER-RUN', telemetry: false),
      );
      final bad = ValidationSessionData(
        session: a.session,
        events: kind == 'event' ? b.events : [],
        discoveryAttempts: kind == 'discovery' ? b.discoveryAttempts : [],
        batterySamples: kind == 'battery' ? b.batterySamples : [],
        exportRecords: kind == 'export'
            ? [
                ValidationExportRecord(
                  id: 'other-export',
                  sessionId: 'other',
                  createdAt: DateTime.utc(2026, 10, 26),
                  destination: 'clipboard_json',
                  result: 'exported',
                  retryCount: 0,
                  payloadHash: 'hash',
                ),
              ]
            : [],
      );
      await expectLater(repo.importSessionData(bad), throwsFormatException);
      expect((await repo.getSessionData('session')).telemetryRecordCount, 0);
      final restored = await repo.getSessionData('other');
      expect(restored.telemetryRecordCount, 0);
      expect(restored.exportRecords, isEmpty);
    });
  }
  test(
    'schema-1 JSON preserves grouping and accepts missing legacy identity',
    () {
      final data = runFixture();
      expect(
        service.decodeJson(service.encodeJson(data)).session.testRunId,
        'RUN-001',
      );
      final legacy = data.toJson();
      (legacy['session'] as Map).remove('test_run_id');
      expect(service.decodeJson(jsonEncode(legacy)).session.testRunId, isNull);
      for (final invalid in ['bad code', 123]) {
        final changed = data.toJson();
        (changed['session'] as Map)['test_run_id'] = invalid;
        expect(
          () => service.decodeJson(jsonEncode(changed)),
          throwsFormatException,
        );
      }
    },
  );
  test('CSV correlates every record and zero-telemetry sessions', () {
    final csv = service.encodeCsv(runFixture());
    final rows = csv.split('\r\n');
    expect(rows.first, endsWith(',transfer_id,test_run_id'));
    expect(rows, hasLength(5));
    expect(rows[1], startsWith('session,session,session,'));
    for (final row in rows.skip(1)) {
      expect(row, endsWith(',RUN-001'));
    }
    expect(rows[2], contains('envelopeAcknowledged'));
    expect(rows[3], startsWith('discovery_attempt,'));
    expect(rows[4], startsWith('battery_sample,'));
    final empty = service.encodeCsv(runFixture(telemetry: false)).split('\r\n');
    expect(empty, hasLength(2));
    expect(empty.last, endsWith(',RUN-001'));
    expect(
      service
          .encodeCsv(runFixture(runId: null, telemetry: false))
          .split('\r\n')
          .last,
      endsWith(','),
    );
  });
  for (final conflict in ['OTHER-RUN', null]) {
    test('conflicting run $conflict rolls back the complete import', () async {
      final h = await DatabaseMigrationTestHarness.create();
      addTearDown(h.dispose);
      final db = await h.openCurrentDatabase();
      addTearDown(db.close);
      final repo = SqliteValidationMetricsRepository(database: db);
      await repo.importSessionData(runFixture(telemetry: false));
      await expectLater(
        repo.importSessionData(runFixture(runId: conflict)),
        throwsFormatException,
      );
      final actual = await repo.getSessionData('session');
      expect(actual.session.testRunId, 'RUN-001');
      expect(actual.telemetryRecordCount, 0);
    });
  }
  test(
    'matching run import stays duplicate-safe and normalizes constructor input',
    () async {
      final h = await DatabaseMigrationTestHarness.create();
      addTearDown(h.dispose);
      final db = await h.openCurrentDatabase();
      addTearDown(db.close);
      final repo = SqliteValidationMetricsRepository(database: db);
      await repo.importSessionData(runFixture(runId: ' run-001 '));
      await repo.importSessionData(runFixture());
      final actual = await repo.getSessionData('session');
      expect(actual.session.testRunId, 'RUN-001');
      expect(actual.telemetryRecordCount, 3);
    },
  );
}
