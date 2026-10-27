import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/repositories/sqlite_sos_message_repository.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/database_migration_test_harness.dart';

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
      'fireElectrical',
      'safetyThreat',
      'publicHazard',
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
    final columnNames = sosColumns.map((row) => row['name']).toSet();

    expect(columnNames, contains('message_hash'));
    expect(columnNames, contains('gps_accuracy_meters'));
    expect(columnNames, contains('hop_count'));
    expect(columnNames, contains('ttl_seconds'));
    expect(columnNames, contains('moderation_status'));
    expect(columnNames, contains('moderation_reason'));
    expect(columnNames, contains('moderation_score'));
    expect(columnNames, contains('recipient_peer_id'));
    expect(columnNames, contains('is_encrypted'));
    expect(columnNames, contains('trust_status'));
    expect(columnNames, contains('trust_role'));
    expect(columnNames, contains('trust_owner_name'));
    expect(
      columnNames,
      containsAll([
        'received_at',
        'received_from_peer_id',
        'received_transport',
        'transfer_id',
      ]),
    );
    expect(
      sosColumns.singleWhere(
        (row) => row['name'] == 'moderation_status',
      )['dflt_value'],
      "'normal'",
    );

    final chatTables = await database.query(
      'sqlite_master',
      columns: ['name'],
      where: 'type = ? AND name IN (?, ?)',
      whereArgs: [
        'table',
        LocalMessagingDatabase.conversationsTable,
        LocalMessagingDatabase.chatMessagesTable,
      ],
      orderBy: 'name ASC',
    );
    expect(chatTables.map((row) => row['name']), [
      LocalMessagingDatabase.chatMessagesTable,
      LocalMessagingDatabase.conversationsTable,
    ]);

    final relayColumns = await database.rawQuery(
      'PRAGMA table_info(${LocalMessagingDatabase.scfMessagesTable})',
    );
    expect(relayColumns.map((row) => row['name']), contains('payload_type'));
    expect(
      relayColumns.map((row) => row['name']),
      contains('origin_trust_status'),
    );

    final chatColumns = await database.rawQuery(
      'PRAGMA table_info(${LocalMessagingDatabase.chatMessagesTable})',
    );
    final chatColumnNames = chatColumns.map((row) => row['name']).toSet();

    expect(chatColumnNames, contains('moderation_status'));
    expect(chatColumnNames, contains('moderation_reason'));
    expect(chatColumnNames, contains('moderation_score'));
    expect(chatColumnNames, contains('trust_status'));
    expect(chatColumnNames, contains('trust_role'));
    expect(chatColumnNames, contains('trust_owner_name'));
    expect(
      chatColumns.singleWhere(
        (row) => row['name'] == 'moderation_status',
      )['dflt_value'],
      "'normal'",
    );

    final trustTables = await database.query(
      'sqlite_master',
      columns: ['name'],
      where: 'type = ? AND name IN (?, ?)',
      whereArgs: [
        'table',
        LocalMessagingDatabase.trustedDevicesTable,
        LocalMessagingDatabase.trustBundleMetadataTable,
      ],
      orderBy: 'name ASC',
    );
    expect(trustTables.map((row) => row['name']), [
      LocalMessagingDatabase.trustBundleMetadataTable,
      LocalMessagingDatabase.trustedDevicesTable,
    ]);

    final validationTables = await database.query(
      'sqlite_master',
      columns: ['name'],
      where: 'type = ? AND name IN (?, ?, ?, ?, ?)',
      whereArgs: [
        'table',
        LocalMessagingDatabase.validationSessionsTable,
        LocalMessagingDatabase.messageEventsTable,
        LocalMessagingDatabase.discoveryAttemptsTable,
        LocalMessagingDatabase.batterySamplesTable,
        LocalMessagingDatabase.metricSyncBatchesTable,
      ],
      orderBy: 'name ASC',
    );
    expect(validationTables.map((row) => row['name']), [
      LocalMessagingDatabase.batterySamplesTable,
      LocalMessagingDatabase.discoveryAttemptsTable,
      LocalMessagingDatabase.messageEventsTable,
      LocalMessagingDatabase.metricSyncBatchesTable,
      LocalMessagingDatabase.validationSessionsTable,
    ]);
  });

  test(
    'version 8 upgrade preserves SOS records and accepts new categories',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      final original = await harness.openCurrentDatabase();
      await _removeReceiptColumns(original);
      await _removeRunIdentity(original);
      await _removeTransferEventColumn(original);
      await original.execute(
        'ALTER TABLE trusted_devices DROP COLUMN signing_public_key',
      );

      // Versions 8 and 9 share a schema; reconstruct the eight original lookup rows.
      await original.delete(
        LocalMessagingDatabase.categoriesTable,
        where: 'id > ?',
        whereArgs: [8],
      );
      await original.setVersion(8);
      await original.insert(LocalMessagingDatabase.peersTable, {
        'id': 'existing-resident',
        'display_name': 'Resident',
        'peer_type_code': 'civilian',
        'created_at': '2026-10-01T08:00:00.000Z',
      });
      for (final category in Category.values.take(8)) {
        await original.insert(LocalMessagingDatabase.sosMessagesTable, {
          'id': 'existing-${category.name}',
          'sender_peer_id': 'existing-resident',
          'body': 'Saved ${category.name} request',
          'category_code': category.name,
          'message_hash': 'hash-${category.name}',
          'status': 'queued',
          'created_at': '2026-10-01T08:00:00.000Z',
          'hop_count': 2,
        });
      }
      final before = await original.query(
        LocalMessagingDatabase.sosMessagesTable,
        orderBy: 'id',
      );
      await original.close();

      final upgraded = await harness.openCurrentDatabase();
      addTearDown(upgraded.close);
      expect(
        await upgraded.getVersion(),
        LocalMessagingDatabase.databaseVersion,
      );
      expect(
        await upgraded.query(
          LocalMessagingDatabase.sosMessagesTable,
          orderBy: 'id',
        ),
        before
            .map(
              (row) => {
                ...row,
                'received_at': null,
                'received_from_peer_id': null,
                'received_transport': null,
                'transfer_id': null,
              },
            )
            .toList(),
      );
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      final repository = SqliteSosMessageRepository(database: upgraded);
      final messages = await repository.getMessages();
      expect(
        messages.map((message) => message.category),
        unorderedEquals(Category.values.take(8)),
      );
      for (final category in Category.sosCategories) {
        await repository.saveMessage(
          messages.first.copyWith(
            id: 'new-${category.name}',
            messageHash: 'new-hash-${category.name}',
            category: category,
          ),
        );
      }
      final newMessages = (await repository.getMessages()).where(
        (message) => message.id.startsWith('new-'),
      );
      expect(
        newMessages.map((message) => message.category),
        unorderedEquals(Category.sosCategories),
      );
    },
  );

  test('migrates populated version 5 data to the current version', () async {
    final harness = await DatabaseMigrationTestHarness.create();
    addTearDown(harness.dispose);

    final legacyDatabase = await harness.createLegacyDatabase(
      version: 5,
      onCreate: _createVersion5FixtureSchema,
    );
    await legacyDatabase.insert(LocalMessagingDatabase.peerTypesTable, {
      'id': 1,
      'code': 'civilian',
      'label': 'Civilian',
      'sort_order': 0,
    });
    await legacyDatabase.insert(LocalMessagingDatabase.categoriesTable, {
      'id': 1,
      'code': 'rescue',
      'label': 'Rescue',
      'sort_order': 0,
    });
    await legacyDatabase.insert(LocalMessagingDatabase.peersTable, {
      'id': 'legacy-sender',
      'display_name': 'Legacy Sender',
      'peer_type_code': 'civilian',
      'is_connected': 0,
      'created_at': '2026-07-01T08:00:00.000Z',
    });
    await legacyDatabase.insert(LocalMessagingDatabase.sosMessagesTable, {
      'id': 'legacy-sos-1',
      'sender_peer_id': 'legacy-sender',
      'body': 'Legacy SOS must survive migration.',
      'category_code': 'rescue',
      'status': 'queued',
      'latitude': 7.3026,
      'longitude': 125.6888,
      'created_at': '2026-07-01T08:05:00.000Z',
      'message_hash': 'legacy-hash-1',
      'gps_accuracy_meters': 8.5,
      'hop_count': 2,
      'ttl_seconds': 7200,
      'moderation_status': 'normal',
    });
    await legacyDatabase.close();

    final migratedDatabase = await harness.openCurrentDatabase();
    addTearDown(migratedDatabase.close);

    expect(
      await migratedDatabase.getVersion(),
      LocalMessagingDatabase.databaseVersion,
    );
    final rows = await migratedDatabase.query(
      LocalMessagingDatabase.sosMessagesTable,
      where: 'id = ?',
      whereArgs: ['legacy-sos-1'],
    );
    expect(rows, hasLength(1));
    expect(rows.single['body'], 'Legacy SOS must survive migration.');
    expect(rows.single['message_hash'], 'legacy-hash-1');
    expect(rows.single['hop_count'], 2);
    expect(rows.single['ttl_seconds'], 7200);
    expect(rows.single['recipient_peer_id'], isNull);
    expect(rows.single['is_encrypted'], 0);
    expect(rows.single['trust_status'], 'unknown');
    expect(rows.single['trust_role'], isNull);
    expect(rows.single['trust_owner_name'], isNull);
    expect(rows.single['received_at'], isNull);
  });

  test(
    'version 10 upgrade preserves receipts and adds nullable event transfer IDs',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      final original = await harness.openCurrentDatabase();
      await _removeTransferEventColumn(original);
      await _removeRunIdentity(original);
      await original.execute(
        'ALTER TABLE trusted_devices DROP COLUMN signing_public_key',
      );
      await original.setVersion(10);
      await original.insert(LocalMessagingDatabase.peersTable, {
        'id': 'victim',
        'display_name': 'Resident',
        'peer_type_code': 'civilian',
        'created_at': '2026-10-13T02:00:00.000Z',
      });
      await original.insert(LocalMessagingDatabase.sosMessagesTable, {
        'id': 'receipt',
        'sender_peer_id': 'victim',
        'body': 'Need help',
        'category_code': 'medical',
        'status': 'received',
        'message_hash': 'hash',
        'created_at': '2026-10-13T02:00:00.000Z',
        'received_at': '2026-10-13T02:01:00.000Z',
        'received_from_peer_id': 'relay',
        'received_transport': 'bluetooth',
        'transfer_id': 'receipt-transfer',
        'hop_count': 2,
      });
      await original.insert(LocalMessagingDatabase.validationSessionsTable, {
        'id': 'session',
        'name': 'Test',
        'environment': 'Mock',
        'device_id': 'rescuer',
        'device_role': 'responder',
        'started_at': '2026-10-13T02:00:00.000Z',
        'status': 'active',
      });
      await original.insert(LocalMessagingDatabase.messageEventsTable, {
        'event_id': 'old-event',
        'session_id': 'session',
        'event_type': 'envelopeReceived',
        'message_hash': 'hash',
        'occurred_at': '2026-10-13T02:01:00.000Z',
      });
      final receipts = await original.query(
        LocalMessagingDatabase.sosMessagesTable,
      );
      final events = await original.query(
        LocalMessagingDatabase.messageEventsTable,
      );
      await original.close();
      final upgraded = await harness.openCurrentDatabase();
      addTearDown(upgraded.close);
      expect(
        await upgraded.getVersion(),
        LocalMessagingDatabase.databaseVersion,
      );
      expect(
        await upgraded.query(LocalMessagingDatabase.sosMessagesTable),
        receipts,
      );
      expect(
        await upgraded.query(LocalMessagingDatabase.messageEventsTable),
        events.map((row) => {...row, 'transfer_id': null}).toList(),
      );
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(
        await upgraded.rawQuery(
          "SELECT name FROM sqlite_master WHERE name = 'idx_message_events_transfer'",
        ),
        hasLength(1),
      );
    },
  );

  test(
    'version 11 migration preserves messages and quarantines while removing unsupported verified labels',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      final original = await harness.openCurrentDatabase();
      await _removeRunIdentity(original);
      await original.execute(
        'ALTER TABLE trusted_devices DROP COLUMN signing_public_key',
      );
      await original.setVersion(11);
      await original.insert(LocalMessagingDatabase.peersTable, {
        'id': 'resident',
        'display_name': 'Resident',
        'peer_type_code': 'civilian',
        'created_at': '2026-10-20T00:00:00Z',
      });
      for (final trust in ['approved', 'unknown', 'revoked']) {
        await original.insert(LocalMessagingDatabase.sosMessagesTable, {
          'id': trust,
          'sender_peer_id': 'resident',
          'body': 'Existing SOS',
          'category_code': 'rescue',
          'status': 'received',
          'message_hash': trust,
          'created_at': '2026-10-20T00:00:00Z',
          'trust_status': trust,
          'trust_role': 'civilian',
          'trust_owner_name': 'Resident',
        });
      }
      await original.close();
      final upgraded = await harness.openCurrentDatabase();
      addTearDown(upgraded.close);
      final rows = await upgraded.query(
        LocalMessagingDatabase.sosMessagesTable,
      );
      expect(rows, hasLength(3));
      final priorApproved = rows.singleWhere((row) => row['id'] == 'approved');
      expect(priorApproved['trust_status'], 'unknown');
      expect(priorApproved['trust_owner_name'], isNull);
      expect(priorApproved['body'], 'Existing SOS');
      expect(
        rows.singleWhere((row) => row['id'] == 'revoked')['trust_status'],
        'revoked',
      );
      final columns = await upgraded.rawQuery(
        'PRAGMA table_info(trusted_devices)',
      );
      expect(columns.any((row) => row['name'] == 'signing_public_key'), isTrue);
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test('version 9 migration preserves SOS and validation records', () async {
    final harness = await DatabaseMigrationTestHarness.create();
    addTearDown(harness.dispose);
    final original = await harness.openCurrentDatabase();
    await _removeReceiptColumns(original);
    await _removeRunIdentity(original);
    await _removeTransferEventColumn(original);
    await original.execute(
      'ALTER TABLE trusted_devices DROP COLUMN signing_public_key',
    );
    await original.setVersion(9);
    await original.insert(LocalMessagingDatabase.peersTable, {
      'id': 'resident',
      'display_name': 'Resident',
      'peer_type_code': 'civilian',
      'created_at': '2026-10-13T02:00:00.000Z',
    });
    await original.insert(LocalMessagingDatabase.sosMessagesTable, {
      'id': 'existing-sos',
      'sender_peer_id': 'resident',
      'body': 'Need medical help',
      'category_code': 'medical',
      'status': 'received',
      'message_hash': 'existing-hash',
      'created_at': '2026-10-13T02:00:00.000Z',
      'hop_count': 3,
    });
    await original.insert(LocalMessagingDatabase.validationSessionsTable, {
      'id': 'existing-session',
      'name': 'Field test',
      'environment': 'Outdoor',
      'device_id': 'rescuer',
      'device_role': 'responder',
      'started_at': '2026-10-13T02:00:00.000Z',
      'status': 'active',
    });
    await original.insert(LocalMessagingDatabase.messageEventsTable, {
      'event_id': 'existing-event',
      'session_id': 'existing-session',
      'message_hash': 'existing-hash',
      'event_type': 'envelopeReceived',
      'occurred_at': '2026-10-13T02:02:00.000Z',
      'hop_count': 3,
    });
    final sessions = await original.query(
      LocalMessagingDatabase.validationSessionsTable,
    );
    final events = await original.query(
      LocalMessagingDatabase.messageEventsTable,
    );
    await original.close();

    final upgraded = await harness.openCurrentDatabase();
    addTearDown(upgraded.close);
    expect(await upgraded.getVersion(), LocalMessagingDatabase.databaseVersion);
    expect(
      await upgraded.query(LocalMessagingDatabase.validationSessionsTable),
      sessions.map((row) => {...row, 'test_run_id': null}).toList(),
    );
    expect(
      await upgraded.query(LocalMessagingDatabase.messageEventsTable),
      events.map((row) => {...row, 'transfer_id': null}).toList(),
    );
    expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    final message = (await SqliteSosMessageRepository(
      database: upgraded,
    ).getMessages()).single;
    expect(message.id, 'existing-sos');
    expect(message.body, 'Need medical help');
    expect(message.messageHash, 'existing-hash');
    expect(message.hopCount, 3);
    expect(message.receivedAt, isNull);
    expect(message.receivedFromPeerId, isNull);
    expect(message.receivedTransport, isNull);
    expect(message.transferId, isNull);
    expect(message.propagationDuration, isNull);
  });
}

Future<void> _removeRunIdentity(Database database) async {
  await database.execute('DROP INDEX idx_validation_sessions_test_run');
  await database.execute(
    'ALTER TABLE validation_sessions DROP COLUMN test_run_id',
  );
}

Future<void> _removeReceiptColumns(Database database) async {
  // Reconstruct the actual version 9 schema before exercising migration 10.
  for (final column in [
    'received_at',
    'received_from_peer_id',
    'received_transport',
    'transfer_id',
  ]) {
    await database.execute(
      'ALTER TABLE ${LocalMessagingDatabase.sosMessagesTable} DROP COLUMN $column',
    );
  }
}

Future<void> _removeTransferEventColumn(Database database) async {
  await database.execute('DROP INDEX idx_message_events_transfer');
  await database.execute('ALTER TABLE message_events DROP COLUMN transfer_id');
}

Future<void> _createVersion5FixtureSchema(
  Database database,
  int version,
) async {
  expect(version, 5);
  await database.execute('''
    CREATE TABLE ${LocalMessagingDatabase.categoriesTable} (
      id INTEGER PRIMARY KEY,
      code TEXT NOT NULL UNIQUE,
      label TEXT NOT NULL,
      sort_order INTEGER NOT NULL
    )
  ''');
  await database.execute('''
    CREATE TABLE ${LocalMessagingDatabase.peerTypesTable} (
      id INTEGER PRIMARY KEY,
      code TEXT NOT NULL UNIQUE,
      label TEXT NOT NULL,
      sort_order INTEGER NOT NULL
    )
  ''');
  await database.execute('''
    CREATE TABLE ${LocalMessagingDatabase.peersTable} (
      id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      peer_type_code TEXT NOT NULL,
      is_connected INTEGER NOT NULL DEFAULT 0,
      signal_strength INTEGER,
      last_seen_at TEXT,
      latitude REAL,
      longitude REAL,
      created_at TEXT NOT NULL,
      updated_at TEXT,
      FOREIGN KEY (peer_type_code)
        REFERENCES ${LocalMessagingDatabase.peerTypesTable} (code)
        ON UPDATE CASCADE
    )
  ''');
  await database.execute('''
    CREATE TABLE ${LocalMessagingDatabase.sosMessagesTable} (
      id TEXT PRIMARY KEY,
      sender_peer_id TEXT NOT NULL,
      body TEXT NOT NULL,
      category_code TEXT NOT NULL,
      status TEXT NOT NULL,
      latitude REAL,
      longitude REAL,
      created_at TEXT NOT NULL,
      updated_at TEXT,
      message_hash TEXT,
      gps_accuracy_meters REAL,
      hop_count INTEGER NOT NULL DEFAULT 0,
      ttl_seconds INTEGER NOT NULL DEFAULT 86400,
      moderation_status TEXT NOT NULL DEFAULT 'normal',
      moderation_reason TEXT,
      moderation_score REAL,
      FOREIGN KEY (sender_peer_id)
        REFERENCES ${LocalMessagingDatabase.peersTable} (id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
      FOREIGN KEY (category_code)
        REFERENCES ${LocalMessagingDatabase.categoriesTable} (code)
        ON UPDATE CASCADE
    )
  ''');
  await database.execute('''
    CREATE TABLE ${LocalMessagingDatabase.scfMessagesTable} (
      message_hash TEXT PRIMARY KEY,
      payload_json TEXT NOT NULL,
      hop_count INTEGER NOT NULL DEFAULT 0,
      received_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      payload_type TEXT NOT NULL DEFAULT 'sos_message'
    )
  ''');
  await database.execute('''
    CREATE TABLE ${LocalMessagingDatabase.scfPeerStatusesTable} (
      message_hash TEXT NOT NULL,
      peer_id TEXT NOT NULL,
      status TEXT NOT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL,
      last_error TEXT,
      PRIMARY KEY (message_hash, peer_id),
      FOREIGN KEY (message_hash)
        REFERENCES ${LocalMessagingDatabase.scfMessagesTable} (message_hash)
        ON UPDATE CASCADE
        ON DELETE CASCADE
    )
  ''');
  await database.execute('''
    CREATE TABLE ${LocalMessagingDatabase.conversationsTable} (
      id TEXT PRIMARY KEY,
      local_peer_id TEXT NOT NULL,
      remote_peer_id TEXT NOT NULL,
      related_sos_message_hash TEXT,
      last_message_at TEXT,
      unread_count INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (local_peer_id, remote_peer_id),
      FOREIGN KEY (local_peer_id)
        REFERENCES ${LocalMessagingDatabase.peersTable} (id)
        ON UPDATE CASCADE,
      FOREIGN KEY (remote_peer_id)
        REFERENCES ${LocalMessagingDatabase.peersTable} (id)
        ON UPDATE CASCADE
    )
  ''');
  await database.execute('''
    CREATE TABLE ${LocalMessagingDatabase.chatMessagesTable} (
      id TEXT PRIMARY KEY,
      message_hash TEXT NOT NULL UNIQUE,
      conversation_id TEXT NOT NULL,
      sender_peer_id TEXT NOT NULL,
      recipient_peer_id TEXT NOT NULL,
      body TEXT NOT NULL,
      status TEXT NOT NULL,
      related_sos_message_hash TEXT,
      hop_count INTEGER NOT NULL DEFAULT 0,
      ttl_seconds INTEGER NOT NULL DEFAULT 86400,
      created_at TEXT NOT NULL,
      updated_at TEXT,
      moderation_status TEXT NOT NULL DEFAULT 'normal',
      moderation_reason TEXT,
      moderation_score REAL,
      FOREIGN KEY (conversation_id)
        REFERENCES ${LocalMessagingDatabase.conversationsTable} (id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
      FOREIGN KEY (sender_peer_id)
        REFERENCES ${LocalMessagingDatabase.peersTable} (id)
        ON UPDATE CASCADE,
      FOREIGN KEY (recipient_peer_id)
        REFERENCES ${LocalMessagingDatabase.peersTable} (id)
        ON UPDATE CASCADE
    )
  ''');
}
