import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Independent from Android messages and the administrator identity/registry.
Future<Database> openDesktopValidationDatabase(String path) {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (database, version) => database.execute('''
      CREATE TABLE validation_datasets (
        id TEXT PRIMARY KEY,
        canonical_source TEXT NOT NULL,
        original_source TEXT NOT NULL,
        filename TEXT NOT NULL,
        schema_version INTEGER NOT NULL,
        run_id TEXT,
        session_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        role TEXT NOT NULL,
        exported_at TEXT,
        imported_at TEXT NOT NULL,
        event_count INTEGER NOT NULL,
        receipt_count INTEGER NOT NULL,
        discovery_count INTEGER NOT NULL,
        battery_count INTEGER NOT NULL
      )
    '''),
    ),
  );
}
