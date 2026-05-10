import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/repositories/sqlite_peer_repository.dart';
import 'package:shadownetwork/features/messaging/data/repositories/sqlite_sos_message_repository.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('stores peers and messages through repositories', () async {
    final database = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(database.close);

    final peerRepository = SqlitePeerRepository(database: database);
    final messageRepository = SqliteSosMessageRepository(database: database);
    final now = DateTime(2026, 5, 2, 13, 30);
    const peer = Peer(
      id: 'peer-1',
      name: 'Responder 1',
      type: PeerType.responder,
      isConnected: true,
      signalStrength: 88,
    );

    await peerRepository.upsertPeer(peer);
    await messageRepository.saveMessage(
      SosMessage(
        id: 'sos-1',
        sender: peer,
        body: 'Need medical assistance.',
        category: Category.medical,
        status: MessageStatus.queued,
        createdAt: now,
        latitude: 7.3026,
        longitude: 125.6888,
        gpsAccuracyMeters: 8.2,
        hopCount: 2,
        ttl: const Duration(hours: 4),
      ),
    );

    final peers = await peerRepository.getNearbyPeers();
    final messages = await messageRepository.getMessages();

    expect(peers, hasLength(1));
    expect(peers.single.name, 'Responder 1');
    expect(messages, hasLength(1));
    expect(messages.single.sender.id, 'peer-1');
    expect(messages.single.category, Category.medical);
    expect(messages.single.status, MessageStatus.queued);
    expect(messages.single.messageHash, isNotNull);
    expect(messages.single.gpsAccuracyMeters, 8.2);
    expect(messages.single.hopCount, 2);
    expect(messages.single.ttl, const Duration(hours: 4));
  });
}
