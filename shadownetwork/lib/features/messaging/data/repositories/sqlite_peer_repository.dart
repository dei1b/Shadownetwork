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
  Future<List<Peer>> getNearbyPeers({String? excludingPeerId}) async {
    final where = <String>["id NOT LIKE 'wifi:%'"];
    final whereArgs = <Object?>[];
    if (excludingPeerId != null) {
      where.add('id != ?');
      whereArgs.add(excludingPeerId);
    }
    final rows = await _database.query(
      LocalMessagingDatabase.peersTable,
      // Older builds persisted every raw Wi-Fi Direct device as wifi:<address>.
      // Verified Shadow Network Wi-Fi peers now use their advertised app peer id.
      where: where.join(' AND '),
      whereArgs: whereArgs,
      orderBy: 'is_connected DESC, last_seen_at DESC, display_name ASC',
    );

    return rows.map(PeerModel.fromMap).toList(growable: false);
  }

  @override
  Future<void> markAllDisconnected({DateTime? timestamp}) async {
    final now = (timestamp ?? DateTime.now()).toIso8601String();
    await _database.update(LocalMessagingDatabase.peersTable, {
      'is_connected': 0,
      'updated_at': now,
    });
  }

  @override
  Future<void> upsertPeer(Peer peer) async {
    await PeerModel.upsert(_database, peer);
  }
}
