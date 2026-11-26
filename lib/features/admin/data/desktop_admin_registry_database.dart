import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/entities/campus_registration.dart';
import '../domain/entities/registered_device.dart';

Future<Database> openDesktopAdminRegistryDatabase(String path) async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 3,
      onCreate: (database, version) async {
        await database.execute(
          'CREATE TABLE admin_identity (id INTEGER PRIMARY KEY CHECK (id = 1), fingerprint TEXT NOT NULL, bundle_version INTEGER NOT NULL CHECK (bundle_version >= 0))',
        );
        await database.execute(
          'CREATE TABLE admin_devices (device_id TEXT PRIMARY KEY, record_json TEXT NOT NULL)',
        );
        await _createUnifiedTables(database);
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createUnifiedTables(database);
          final deviceRows = await database.query(
            'admin_devices',
            orderBy: 'rowid',
          );
          for (final row in deviceRows) {
            final device = RegisteredDevice.fromJson(
              Map<String, Object?>.from(
                jsonDecode(row['record_json']! as String) as Map,
              ),
            );
            final registration = CampusRegistration.fromLegacyDevice(device);
            await database.insert('admin_registrations', {
              'registration_id': registration.registrationId,
              'device_id': registration.activePhone.deviceId,
              'account_uid': registration.accountUid,
              'status': registration.status.code,
              'sync_state': registration.syncState.code,
              'record_json': jsonEncode(registration.toJson()),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        if (oldVersion < 3) {
          await _createRosterTable(database);
        }
      },
    ),
  );
}

Future<void> _createUnifiedTables(DatabaseExecutor database) async {
  await database.execute(
    'CREATE TABLE IF NOT EXISTS admin_registrations ('
    'registration_id TEXT PRIMARY KEY, '
    'device_id TEXT, '
    'account_uid TEXT, '
    'status TEXT NOT NULL, '
    'sync_state TEXT NOT NULL, '
    'record_json TEXT NOT NULL)',
  );
  await database.execute(
    'CREATE TABLE IF NOT EXISTS admin_pending_sync ('
    'decision_id TEXT PRIMARY KEY, '
    'registration_id TEXT NOT NULL, '
    'kind TEXT NOT NULL, '
    'payload_json TEXT NOT NULL, '
    'created_at TEXT NOT NULL)',
  );
  await database.execute(
    'CREATE TABLE IF NOT EXISTS admin_reviewer_profile ('
    'id INTEGER PRIMARY KEY CHECK (id = 1), '
    'reviewer_uid TEXT NOT NULL, '
    'reviewer_email TEXT NOT NULL)',
  );
  await _createRosterTable(database);
}

Future<void> _createRosterTable(DatabaseExecutor database) async {
  await database.execute(
    'CREATE TABLE IF NOT EXISTS admin_published_roster ('
    'id INTEGER PRIMARY KEY CHECK (id = 1), '
    'version INTEGER NOT NULL, '
    'bundle_json TEXT NOT NULL, '
    'synced_at TEXT NOT NULL)',
  );
}
