import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/validation/data/repositories/sqlite_validation_metrics_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/database_migration_test_harness.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'run identity survives stop and reopen and is reusable across sessions',
    () async {
      final h = await DatabaseMigrationTestHarness.create();
      addTearDown(h.dispose);
      final db = await h.openCurrentDatabase();
      final repo = SqliteValidationMetricsRepository(database: db);
      final first = await repo.startSession(
        name: 'First',
        environment: 'Lab',
        deviceId: 'local',
        deviceRole: 'responder',
        testRunId: ' run-001 ',
      );
      expect(first.testRunId, 'RUN-001');
      expect((await repo.stopActiveSession())!.testRunId, 'RUN-001');
      await db.close();
      final reopened = await h.openCurrentDatabase();
      addTearDown(reopened.close);
      final restored = SqliteValidationMetricsRepository(database: reopened);
      expect(
        (await restored.getSessionData(first.id)).session.testRunId,
        'RUN-001',
      );
      final second = await restored.startSession(
        name: 'Second',
        environment: 'Lab',
        deviceId: 'local',
        deviceRole: 'responder',
        testRunId: 'RUN-001',
      );
      expect(second.id, isNot(first.id));
      expect(second.testRunId, first.testRunId);
      await expectLater(
        restored.startSession(
          name: 'Duplicate active',
          environment: 'Lab',
          deviceId: 'local',
          deviceRole: 'responder',
          testRunId: 'OTHER-001',
        ),
        throwsStateError,
      );
      expect((await restored.getActiveSession())!.testRunId, 'RUN-001');
    },
  );

  test('invalid new run never inserts a validation session', () async {
    final h = await DatabaseMigrationTestHarness.create();
    addTearDown(h.dispose);
    final db = await h.openCurrentDatabase();
    addTearDown(db.close);
    final repo = SqliteValidationMetricsRepository(database: db);
    await expectLater(
      repo.startSession(
        name: 'Invalid',
        environment: 'Lab',
        deviceId: 'local',
        deviceRole: 'responder',
        testRunId: 'bad code',
      ),
      throwsFormatException,
    );
    expect(await repo.getSessions(), isEmpty);
  });

  test('concurrent session starts cannot change the winning run', () async {
    final h = await DatabaseMigrationTestHarness.create();
    addTearDown(h.dispose);
    final db = await h.openCurrentDatabase();
    addTearDown(db.close);
    final repo = SqliteValidationMetricsRepository(database: db);
    final outcomes = await Future.wait(
      ['RUN-ONE', 'RUN-TWO'].map((code) async {
        try {
          await repo.startSession(
            name: code,
            environment: 'Lab',
            deviceId: 'local',
            deviceRole: 'responder',
            testRunId: code,
          );
          return true;
        } on StateError {
          return false;
        }
      }),
    );
    expect(outcomes.where((success) => success), hasLength(1));
    expect(await repo.getSessions(), hasLength(1));
  });

  test(
    'migration 12 to 13 preserves evidence, receipts, queue and signing keys',
    () async {
      final h = await DatabaseMigrationTestHarness.create();
      addTearDown(h.dispose);
      final original = await h.openCurrentDatabase();
      final columns = await original.rawQuery(
        'PRAGMA table_info(validation_sessions)',
      );
      if (columns.any((row) => row['name'] == 'test_run_id')) {
        await original.execute('DROP INDEX idx_validation_sessions_test_run');
        await original.execute(
          'ALTER TABLE validation_sessions DROP COLUMN test_run_id',
        );
      }
      await original.setVersion(12);
      const stamp = '2026-10-26T02:00:00.000Z';
      await original.insert('peers', {
        'id': 'victim',
        'display_name': 'Resident',
        'peer_type_code': 'civilian',
        'created_at': stamp,
      });
      await original.insert('sos_messages', {
        'id': 'sos',
        'sender_peer_id': 'victim',
        'body': 'Preserve this SOS',
        'category_code': 'medical',
        'status': 'received',
        'created_at': stamp,
        'message_hash': 'hash',
        'received_at': stamp,
        'received_from_peer_id': 'relay',
        'received_transport': 'bluetooth',
        'transfer_id': 'hop-attempt',
      });
      await original.insert('scf_messages', {
        'message_hash': 'hash',
        'payload_json': '{}',
        'received_at': stamp,
        'expires_at': '2026-10-27T02:00:00.000Z',
      });
      await original.insert('trusted_devices', {
        'device_id': 'trusted',
        'owner_name': 'Rescuer',
        'role': 'responder',
        'status': 'approved',
        'bundle_version': 1,
        'bundle_hash': 'bundle',
        'admin_updated_at': stamp,
        'imported_at': stamp,
        'public_key': 'encryption-key',
        'signing_public_key': 'signing-key',
      });
      await original.insert('validation_sessions', {
        'id': 'legacy',
        'name': 'Existing',
        'environment': 'Lab',
        'device_id': 'local',
        'device_role': 'responder',
        'started_at': stamp,
        'status': 'active',
      });
      await original.insert('message_events', {
        'event_id': 'event',
        'session_id': 'legacy',
        'event_type': 'envelopeAcknowledged',
        'occurred_at': stamp,
        'message_hash': 'hash',
        'transfer_id': 'hop-attempt',
        'latency_ms': 123,
      });
      final before = <String, List<Map<String, Object?>>>{};
      for (final table in [
        'sos_messages',
        'scf_messages',
        'trusted_devices',
        'message_events',
      ]) {
        before[table] = await original.query(table);
      }
      await original.close();
      final upgraded = await h.openCurrentDatabase();
      addTearDown(upgraded.close);
      expect(await upgraded.getVersion(), 13);
      for (final entry in before.entries) {
        expect(await upgraded.query(entry.key), entry.value);
      }
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(
        (await upgraded.rawQuery(
          'PRAGMA index_list(validation_sessions)',
        )).singleWhere(
          (row) => row['name'] == 'idx_validation_sessions_test_run',
        )['unique'],
        0,
      );
      final repo = SqliteValidationMetricsRepository(database: upgraded);
      expect((await repo.getActiveSession())!.testRunId, isNull);
      expect((await repo.stopActiveSession())!.testRunId, isNull);
      expect((await repo.getSessionData('legacy')).session.testRunId, isNull);
    },
  );
}
