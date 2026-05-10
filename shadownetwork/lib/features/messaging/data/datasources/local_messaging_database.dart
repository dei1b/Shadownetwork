import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../domain/entities/category.dart';
import '../../domain/entities/peer_type.dart';

typedef DatabaseMigration = Future<void> Function(Database database);

class LocalMessagingDatabase {
  const LocalMessagingDatabase._();

  static const databaseName = 'shadownetwork.db';
  static const databaseVersion = 3;

  static const categoriesTable = 'categories';
  static const peerTypesTable = 'peer_types';
  static const peersTable = 'peers';
  static const sosMessagesTable = 'sos_messages';
  static const scfMessagesTable = 'scf_messages';
  static const scfPeerStatusesTable = 'scf_peer_statuses';

  static final Map<int, DatabaseMigration> _migrations = {
    1: _createInitialSchema,
    2: _createScfSchema,
    3: _addSosRoutingMetadata,
  };

  static Future<Database> open({
    String? databasePath,
    DatabaseFactory? factory,
  }) async {
    final databaseFactory = factory ?? databaseFactorySqflitePlugin;
    final resolvedPath =
        databasePath ??
        path.join(await databaseFactory.getDatabasesPath(), databaseName);

    return databaseFactory.openDatabase(
      resolvedPath,
      options: OpenDatabaseOptions(
        version: databaseVersion,
        onConfigure: _configure,
        onCreate: _create,
        onUpgrade: _upgrade,
      ),
    );
  }

  static Future<void> _configure(Database database) async {
    await database.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _create(Database database, int version) async {
    await _runMigrations(database, fromVersion: 0, toVersion: version);
    await seedLookupTables(database);
  }

  static Future<void> _upgrade(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    await _runMigrations(
      database,
      fromVersion: oldVersion,
      toVersion: newVersion,
    );
    await seedLookupTables(database);
  }

  static Future<void> _runMigrations(
    Database database, {
    required int fromVersion,
    required int toVersion,
  }) async {
    for (var version = fromVersion + 1; version <= toVersion; version++) {
      final migration = _migrations[version];
      if (migration == null) {
        throw StateError('Missing database migration for version $version.');
      }

      await migration(database);
    }
  }

  static Future<void> _createInitialSchema(Database database) async {
    await database.execute('''
      CREATE TABLE $categoriesTable (
        id INTEGER PRIMARY KEY,
        code TEXT NOT NULL UNIQUE,
        label TEXT NOT NULL,
        sort_order INTEGER NOT NULL
      )
    ''');

    await database.execute('''
      CREATE TABLE $peerTypesTable (
        id INTEGER PRIMARY KEY,
        code TEXT NOT NULL UNIQUE,
        label TEXT NOT NULL,
        sort_order INTEGER NOT NULL
      )
    ''');

    await database.execute('''
      CREATE TABLE $peersTable (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        peer_type_code TEXT NOT NULL,
        is_connected INTEGER NOT NULL DEFAULT 0
          CHECK (is_connected IN (0, 1)),
        signal_strength INTEGER
          CHECK (signal_strength IS NULL OR signal_strength BETWEEN 0 AND 100),
        last_seen_at TEXT,
        latitude REAL,
        longitude REAL,
        created_at TEXT NOT NULL,
        updated_at TEXT,
        FOREIGN KEY (peer_type_code)
          REFERENCES $peerTypesTable (code)
          ON UPDATE CASCADE
      )
    ''');

    await database.execute('''
      CREATE TABLE $sosMessagesTable (
        id TEXT PRIMARY KEY,
        sender_peer_id TEXT NOT NULL,
        body TEXT NOT NULL,
        category_code TEXT NOT NULL,
        status TEXT NOT NULL,
        latitude REAL,
        longitude REAL,
        created_at TEXT NOT NULL,
        updated_at TEXT,
        FOREIGN KEY (sender_peer_id)
          REFERENCES $peersTable (id)
          ON UPDATE CASCADE
          ON DELETE CASCADE,
        FOREIGN KEY (category_code)
          REFERENCES $categoriesTable (code)
          ON UPDATE CASCADE
      )
    ''');

    await database.execute(
      'CREATE INDEX idx_peers_peer_type ON $peersTable (peer_type_code)',
    );
    await database.execute(
      'CREATE INDEX idx_sos_messages_category '
      'ON $sosMessagesTable (category_code)',
    );
    await database.execute(
      'CREATE INDEX idx_sos_messages_status '
      'ON $sosMessagesTable (status)',
    );
    await database.execute(
      'CREATE INDEX idx_sos_messages_created_at '
      'ON $sosMessagesTable (created_at)',
    );
  }

  static Future<void> _createScfSchema(Database database) async {
    await database.execute('''
      CREATE TABLE $scfMessagesTable (
        message_hash TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        hop_count INTEGER NOT NULL DEFAULT 0
          CHECK (hop_count >= 0),
        received_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
      )
    ''');

    await database.execute('''
      CREATE TABLE $scfPeerStatusesTable (
        message_hash TEXT NOT NULL,
        peer_id TEXT NOT NULL,
        status TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0
          CHECK (attempt_count >= 0),
        updated_at TEXT NOT NULL,
        last_error TEXT,
        PRIMARY KEY (message_hash, peer_id),
        FOREIGN KEY (message_hash)
          REFERENCES $scfMessagesTable (message_hash)
          ON UPDATE CASCADE
          ON DELETE CASCADE
      )
    ''');

    await database.execute(
      'CREATE INDEX idx_scf_messages_expires_at '
      'ON $scfMessagesTable (expires_at)',
    );
    await database.execute(
      'CREATE INDEX idx_scf_peer_status_peer '
      'ON $scfPeerStatusesTable (peer_id, status)',
    );
  }

  static Future<void> _addSosRoutingMetadata(Database database) async {
    await database.execute(
      'ALTER TABLE $sosMessagesTable '
      'ADD COLUMN message_hash TEXT',
    );
    await database.execute(
      'ALTER TABLE $sosMessagesTable '
      'ADD COLUMN gps_accuracy_meters REAL',
    );
    await database.execute(
      'ALTER TABLE $sosMessagesTable '
      'ADD COLUMN hop_count INTEGER NOT NULL DEFAULT 0 '
      'CHECK (hop_count >= 0)',
    );
    await database.execute(
      'ALTER TABLE $sosMessagesTable '
      'ADD COLUMN ttl_seconds INTEGER NOT NULL DEFAULT 86400 '
      'CHECK (ttl_seconds > 0)',
    );
    await database.execute(
      'CREATE INDEX idx_sos_messages_message_hash '
      'ON $sosMessagesTable (message_hash)',
    );
  }

  static Future<void> seedLookupTables(Database database) async {
    final batch = database.batch();

    for (final category in Category.values) {
      batch.insert(categoriesTable, {
        'id': category.index + 1,
        'code': category.name,
        'label': _categoryLabel(category),
        'sort_order': category.index,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    for (final peerType in PeerType.values) {
      batch.insert(peerTypesTable, {
        'id': peerType.index + 1,
        'code': peerType.name,
        'label': _peerTypeLabel(peerType),
        'sort_order': peerType.index,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit(noResult: true);
  }

  static String _categoryLabel(Category category) {
    return switch (category) {
      Category.rescue => 'Rescue',
      Category.food => 'Food',
      Category.water => 'Water',
      Category.medical => 'Medical',
      Category.shelter => 'Shelter',
      Category.transport => 'Transport',
      Category.information => 'Information',
      Category.other => 'Other',
    };
  }

  static String _peerTypeLabel(PeerType peerType) {
    return switch (peerType) {
      PeerType.civilian => 'Civilian',
      PeerType.responder => 'Responder',
      PeerType.relay => 'Relay',
      PeerType.authority => 'Authority',
      PeerType.unknown => 'Unknown',
    };
  }
}
