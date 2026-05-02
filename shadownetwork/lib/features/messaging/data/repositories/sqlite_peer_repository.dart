import 'package:sqflite/sqflite.dart';

import '../../domain/entities/peer.dart';
import '../../domain/repositories/peer_repository.dart';
import '../datasources/local_messaging_database.dart';
import '../models/peer_model.dart';

class SqlitePeerRepository implements PeerRepository {
  const SqlitePeerRepository({required Database database})
    : _database = database;

  final Database _database;

  @override
  Future<List<Peer>> getNearbyPeers() async {
    final rows = await _database.query(
      LocalMessagingDatabase.peersTable,
      orderBy: 'is_connected DESC, last_seen_at DESC, display_name ASC',
    );

    return rows.map(PeerModel.fromMap).toList(growable: false);
  }

  @override
  Future<void> upsertPeer(Peer peer) async {
    await _database.insert(
      LocalMessagingDatabase.peersTable,
      PeerModel.toMap(peer),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
