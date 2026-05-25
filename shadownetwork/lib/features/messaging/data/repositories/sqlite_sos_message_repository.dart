import 'package:sqflite/sqflite.dart';

import '../../domain/entities/sos_message.dart';
import '../../domain/repositories/sos_message_repository.dart';
import '../datasources/local_messaging_database.dart';
import '../models/peer_model.dart';
import '../models/sos_message_model.dart';

class SqliteSosMessageRepository implements SosMessageRepository {
  const SqliteSosMessageRepository({required Database database})
    : _database = database;

  final Database _database;

  @override
  Future<List<SosMessage>> getMessages() async {
    final rows = await _database.rawQuery('''
      SELECT
        messages.*,
        peers.id AS sender_peer_id,
        peers.display_name AS sender_display_name,
        peers.peer_type_code AS sender_peer_type,
        peers.is_connected AS sender_is_connected,
        peers.signal_strength AS sender_signal_strength,
        peers.last_seen_at AS sender_last_seen_at,
        peers.latitude AS sender_latitude,
        peers.longitude AS sender_longitude
      FROM ${LocalMessagingDatabase.sosMessagesTable} AS messages
      INNER JOIN ${LocalMessagingDatabase.peersTable} AS peers
        ON peers.id = messages.sender_peer_id
      ORDER BY messages.created_at DESC
    ''');

    return rows.map(SosMessageModel.fromMap).toList(growable: false);
  }

  @override
  Future<void> saveMessage(SosMessage message) async {
    await _database.transaction((transaction) async {
      await PeerModel.upsert(
        transaction,
        message.sender,
        timestamp: message.createdAt,
      );
      await transaction.insert(
        LocalMessagingDatabase.sosMessagesTable,
        SosMessageModel.toMap(message),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }
}
