import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../domain/entities/category.dart';
import '../../domain/entities/peer_type.dart';

typedef DatabaseMigration = Future<void> Function(Database database);

class LocalMessagingDatabase {
  const LocalMessagingDatabase._();

  static const databaseName = 'shadownetwork.db';
  static const databaseVersion = 9;

  static const categoriesTable = 'categories';
  static const peerTypesTable = 'peer_types';
  static const peersTable = 'peers';
  static const sosMessagesTable = 'sos_messages';
  static const scfMessagesTable = 'scf_messages';
  static const scfPeerStatusesTable = 'scf_peer_statuses';
  static const conversationsTable = 'conversations';
  static const chatMessagesTable = 'chat_messages';
  static const trustedDevicesTable = 'trusted_devices';
  static const trustBundleMetadataTable = 'trust_bundle_metadata';
  static const validationSessionsTable = 'validation_sessions';
  static const messageEventsTable = 'message_events';
  static const discoveryAttemptsTable = 'discovery_attempts';
  static const batterySamplesTable = 'battery_samples';
  static const metricSyncBatchesTable = 'metric_sync_batches';

  static final Map<int, DatabaseMigration> _migrations = {
    1: _createInitialSchema,
    2: _createScfSchema,
    3: _addSosRoutingMetadata,
    4: _createChatSchema,
    5: _addModerationMetadata,
    6: _addTargetedSosMetadata,
    7: _addTrustEnforcementSchema,
    8: _addValidationMetricsSchema,
    // Version 9 changes lookup data only; existing SOS rows retain their codes.
    9: seedLookupTables,
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

  static Future<void> _createChatSchema(Database database) async {
    await database.execute(
      "ALTER TABLE $scfMessagesTable ADD COLUMN payload_type TEXT NOT NULL DEFAULT 'sos_message'",
    );
    await database.execute('''
      CREATE TABLE $conversationsTable (
        id TEXT PRIMARY KEY,
        local_peer_id TEXT NOT NULL,
        remote_peer_id TEXT NOT NULL,
        related_sos_message_hash TEXT,
        last_message_at TEXT,
        unread_count INTEGER NOT NULL DEFAULT 0 CHECK (unread_count >= 0),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE (local_peer_id, remote_peer_id),
        FOREIGN KEY (local_peer_id) REFERENCES $peersTable (id) ON UPDATE CASCADE,
        FOREIGN KEY (remote_peer_id) REFERENCES $peersTable (id) ON UPDATE CASCADE
      )
    ''');
    await database.execute('''
      CREATE TABLE $chatMessagesTable (
        id TEXT PRIMARY KEY,
        message_hash TEXT NOT NULL UNIQUE,
        conversation_id TEXT NOT NULL,
        sender_peer_id TEXT NOT NULL,
        recipient_peer_id TEXT NOT NULL,
        body TEXT NOT NULL,
        status TEXT NOT NULL,
        related_sos_message_hash TEXT,
        hop_count INTEGER NOT NULL DEFAULT 0 CHECK (hop_count >= 0),
        ttl_seconds INTEGER NOT NULL DEFAULT 86400 CHECK (ttl_seconds > 0),
        created_at TEXT NOT NULL,
        updated_at TEXT,
        FOREIGN KEY (conversation_id) REFERENCES $conversationsTable (id) ON UPDATE CASCADE ON DELETE CASCADE,
        FOREIGN KEY (sender_peer_id) REFERENCES $peersTable (id) ON UPDATE CASCADE,
        FOREIGN KEY (recipient_peer_id) REFERENCES $peersTable (id) ON UPDATE CASCADE
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_conversations_timeline ON $conversationsTable (local_peer_id, last_message_at DESC)',
    );
    await database.execute(
      'CREATE INDEX idx_chat_messages_timeline ON $chatMessagesTable (conversation_id, created_at ASC)',
    );
    await database.execute(
      'CREATE INDEX idx_chat_messages_hash ON $chatMessagesTable (message_hash)',
    );
  }

  static Future<void> _addModerationMetadata(Database database) async {
    for (final table in [sosMessagesTable, chatMessagesTable]) {
      await database.execute(
        'ALTER TABLE $table '
        "ADD COLUMN moderation_status TEXT NOT NULL DEFAULT 'normal' "
        "CHECK (moderation_status IN ('normal', 'spam'))",
      );
      await database.execute(
        'ALTER TABLE $table ADD COLUMN moderation_reason TEXT',
      );
      await database.execute(
        'ALTER TABLE $table ADD COLUMN moderation_score REAL',
      );
      await database.execute(
        'CREATE INDEX idx_${table}_moderation_status '
        'ON $table (moderation_status)',
      );
    }
  }

  static Future<void> _addTargetedSosMetadata(Database database) async {
    await database.execute(
      'ALTER TABLE $sosMessagesTable ADD COLUMN recipient_peer_id TEXT',
    );
    await database.execute(
      'ALTER TABLE $sosMessagesTable '
      'ADD COLUMN is_encrypted INTEGER NOT NULL DEFAULT 0 '
      'CHECK (is_encrypted IN (0, 1))',
    );
    await database.execute(
      'CREATE INDEX idx_sos_messages_recipient_peer '
      'ON $sosMessagesTable (recipient_peer_id)',
    );
  }

  static Future<void> _addTrustEnforcementSchema(Database database) async {
    await database.execute('''
      CREATE TABLE $trustedDevicesTable (
        device_id TEXT PRIMARY KEY,
        owner_name TEXT NOT NULL,
        role TEXT NOT NULL,
        status TEXT NOT NULL
          CHECK (status IN ('approved', 'revoked', 'unknown')),
        public_key TEXT,
        key_version INTEGER NOT NULL DEFAULT 1 CHECK (key_version > 0),
        bundle_version INTEGER NOT NULL CHECK (bundle_version > 0),
        bundle_hash TEXT NOT NULL,
        admin_updated_at TEXT NOT NULL,
        imported_at TEXT NOT NULL
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_trusted_devices_status '
      'ON $trustedDevicesTable (status, role)',
    );
    await database.execute('''
      CREATE TABLE $trustBundleMetadataTable (
        singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
        bundle_version INTEGER NOT NULL CHECK (bundle_version > 0),
        bundle_hash TEXT NOT NULL,
        issuer_id TEXT NOT NULL,
        signing_key_id TEXT NOT NULL,
        issued_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        imported_at TEXT NOT NULL,
        signature_verified INTEGER NOT NULL DEFAULT 1
          CHECK (signature_verified IN (0, 1))
      )
    ''');

    for (final table in [sosMessagesTable, chatMessagesTable]) {
      await database.execute(
        'ALTER TABLE $table '
        "ADD COLUMN trust_status TEXT NOT NULL DEFAULT 'unknown' "
        "CHECK (trust_status IN ('approved', 'unknown', 'revoked'))",
      );
      await database.execute('ALTER TABLE $table ADD COLUMN trust_role TEXT');
      await database.execute(
        'ALTER TABLE $table ADD COLUMN trust_owner_name TEXT',
      );
      await database.execute(
        'CREATE INDEX idx_${table}_trust_status '
        'ON $table (trust_status)',
      );
    }

    await database.execute(
      'ALTER TABLE $scfMessagesTable '
      "ADD COLUMN origin_trust_status TEXT NOT NULL DEFAULT 'unknown' "
      "CHECK (origin_trust_status IN ('approved', 'unknown', 'revoked'))",
    );
    await database.execute(
      'CREATE INDEX idx_scf_messages_origin_trust '
      'ON $scfMessagesTable (origin_trust_status, expires_at)',
    );
  }

  static Future<void> _addValidationMetricsSchema(Database database) async {
    await database.execute('''
      CREATE TABLE $validationSessionsTable (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        environment TEXT NOT NULL,
        device_id TEXT NOT NULL,
        device_role TEXT NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        status TEXT NOT NULL
          CHECK (status IN ('active', 'completed')),
        notes TEXT
      )
    ''');
    await database.execute(
      'CREATE UNIQUE INDEX idx_validation_sessions_one_active '
      'ON $validationSessionsTable (status) WHERE status = \'active\'',
    );
    await database.execute(
      'CREATE INDEX idx_validation_sessions_started '
      'ON $validationSessionsTable (started_at DESC)',
    );

    await database.execute('''
      CREATE TABLE $messageEventsTable (
        event_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        message_hash TEXT,
        payload_type TEXT,
        event_type TEXT NOT NULL,
        peer_id TEXT,
        transport TEXT,
        hop_count INTEGER CHECK (hop_count IS NULL OR hop_count >= 0),
        occurred_at TEXT NOT NULL,
        error TEXT,
        fallback_used INTEGER NOT NULL DEFAULT 0
          CHECK (fallback_used IN (0, 1)),
        latency_ms INTEGER CHECK (latency_ms IS NULL OR latency_ms >= 0),
        metadata_json TEXT,
        FOREIGN KEY (session_id)
          REFERENCES $validationSessionsTable (id)
          ON UPDATE CASCADE
          ON DELETE CASCADE
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_message_events_session_time '
      'ON $messageEventsTable (session_id, occurred_at)',
    );
    await database.execute(
      'CREATE INDEX idx_message_events_hash_type '
      'ON $messageEventsTable (message_hash, event_type)',
    );

    await database.execute('''
      CREATE TABLE $discoveryAttemptsTable (
        attempt_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        transport TEXT NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT NOT NULL,
        discovered_count INTEGER NOT NULL DEFAULT 0
          CHECK (discovered_count >= 0),
        success INTEGER NOT NULL DEFAULT 0 CHECK (success IN (0, 1)),
        error TEXT,
        FOREIGN KEY (session_id)
          REFERENCES $validationSessionsTable (id)
          ON UPDATE CASCADE
          ON DELETE CASCADE
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_discovery_attempts_session '
      'ON $discoveryAttemptsTable (session_id, started_at)',
    );

    await database.execute('''
      CREATE TABLE $batterySamplesTable (
        sample_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        battery_percent REAL NOT NULL
          CHECK (battery_percent BETWEEN 0 AND 100),
        is_charging INTEGER NOT NULL DEFAULT 0 CHECK (is_charging IN (0, 1)),
        sampled_at TEXT NOT NULL,
        runtime_mode TEXT NOT NULL,
        FOREIGN KEY (session_id)
          REFERENCES $validationSessionsTable (id)
          ON UPDATE CASCADE
          ON DELETE CASCADE
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_battery_samples_session '
      'ON $batterySamplesTable (session_id, sampled_at)',
    );

    await database.execute('''
      CREATE TABLE $metricSyncBatchesTable (
        batch_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        destination TEXT NOT NULL,
        result TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
        payload_hash TEXT NOT NULL,
        FOREIGN KEY (session_id)
          REFERENCES $validationSessionsTable (id)
          ON UPDATE CASCADE
          ON DELETE CASCADE
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_metric_sync_batches_session '
      'ON $metricSyncBatchesTable (session_id, created_at)',
    );
  }

  static Future<void> seedLookupTables(Database database) async {
    final batch = database.batch();

    for (final category in Category.values) {
      batch.insert(categoriesTable, {
        'id': category.index + 1,
        'code': category.name,
        'label': category.label,
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
