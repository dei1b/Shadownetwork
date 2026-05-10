import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('creates schema and seeds lookup tables', () async {
    final database = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(database.close);

    final categories = await database.query(
      LocalMessagingDatabase.categoriesTable,
      orderBy: 'sort_order ASC',
    );
    final peerTypes = await database.query(
      LocalMessagingDatabase.peerTypesTable,
      orderBy: 'sort_order ASC',
    );

    expect(categories.map((row) => row['code']), [
      'rescue',
      'food',
      'water',
      'medical',
      'shelter',
      'transport',
      'information',
      'other',
    ]);
    expect(peerTypes.map((row) => row['code']), [
      'civilian',
      'responder',
      'relay',
      'authority',
      'unknown',
    ]);

    final scfTables = await database.query(
      'sqlite_master',
      columns: ['name'],
      where: 'type = ? AND name IN (?, ?)',
      whereArgs: [
        'table',
        LocalMessagingDatabase.scfMessagesTable,
        LocalMessagingDatabase.scfPeerStatusesTable,
      ],
      orderBy: 'name ASC',
    );

    expect(scfTables.map((row) => row['name']), [
      LocalMessagingDatabase.scfMessagesTable,
      LocalMessagingDatabase.scfPeerStatusesTable,
    ]);

    final sosColumns = await database.rawQuery(
      'PRAGMA table_info(${LocalMessagingDatabase.sosMessagesTable})',
    );
    final columnNames = sosColumns
        .map((row) => row['name'])
        .toSet();

    expect(columnNames, contains('message_hash'));
    expect(columnNames, contains('gps_accuracy_meters'));
    expect(columnNames, contains('hop_count'));
    expect(columnNames, contains('ttl_seconds'));
  });
}
