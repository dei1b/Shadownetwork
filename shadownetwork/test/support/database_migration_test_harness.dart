import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

typedef LegacyDatabaseBuilder =
    Future<void> Function(Database database, int version);

class DatabaseMigrationTestHarness {
  DatabaseMigrationTestHarness._({
    required this.directory,
    required this.databasePath,
  });

  final Directory directory;
  final String databasePath;

  static Future<DatabaseMigrationTestHarness> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'shadow-network-migration-',
    );
    return DatabaseMigrationTestHarness._(
      directory: directory,
      databasePath: path.join(directory.path, 'migration.db'),
    );
  }

  Future<Database> createLegacyDatabase({
    required int version,
    required LegacyDatabaseBuilder onCreate,
  }) {
    return databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: version,
        onConfigure: (database) => database.execute('PRAGMA foreign_keys = ON'),
        onCreate: onCreate,
      ),
    );
  }

  Future<Database> openCurrentDatabase() {
    return LocalMessagingDatabase.open(
      databasePath: databasePath,
      factory: databaseFactoryFfi,
    );
  }

  Future<void> dispose() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
