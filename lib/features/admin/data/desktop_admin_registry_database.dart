import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openDesktopAdminRegistryDatabase(String path) async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (database, version) async {
        await database.execute(
          'CREATE TABLE admin_identity (id INTEGER PRIMARY KEY CHECK (id = 1), fingerprint TEXT NOT NULL, bundle_version INTEGER NOT NULL CHECK (bundle_version >= 0))',
        );
        await database.execute(
          'CREATE TABLE admin_devices (device_id TEXT PRIMARY KEY, record_json TEXT NOT NULL)',
        );
      },
    ),
  );
}
