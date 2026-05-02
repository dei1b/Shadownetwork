import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/models/sos_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/services/mock_scf_transport.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_relay_service.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_service.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/scf_peer_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('relays SCF envelopes between mock peers', () async {
    final nodeADatabase = await _openTestDatabase('mock-relay-a.db');
    final nodeBDatabase = await _openTestDatabase('mock-relay-b.db');
    addTearDown(nodeADatabase.close);
    addTearDown(nodeBDatabase.close);

    const nodeA = Peer(
      id: 'node-a',
      name: 'Node A',
      type: PeerType.civilian,
      isConnected: true,
    );
    const nodeB = Peer(
      id: 'node-b',
      name: 'Node B',
      type: PeerType.relay,
      isConnected: true,
    );

    final network = MockScfTransportNetwork();
    final transportA = network.registerPeer(nodeA);
    final transportB = network.registerPeer(nodeB);
    final scfA = ScfService(database: nodeADatabase);
    final scfB = ScfService(database: nodeBDatabase);
    final relayA = ScfRelayService(scfService: scfA, transport: transportA);
    final relayB = ScfRelayService(scfService: scfB, transport: transportB);
    final now = DateTime.utc(2026, 5, 2, 6);
    final message = _message(sender: nodeA);
    final hash = SosMessagePayload.messageHash(message);

    await scfA.storeMessage(message, receivedAt: now);

    final peersFromA = await relayA.discoverPeers();
    final result = await relayA.relayToPeer(
      peersFromA.single,
      now: now.add(const Duration(minutes: 1)),
    );
    final ingestedByB = await relayB.ingestIncoming(
      now: now.add(const Duration(minutes: 2)),
    );
    final storedAtB = await scfB.getStoredEnvelopes(
      now: now.add(const Duration(minutes: 3)),
    );
    final statusAtA = await scfA.getPeerStatus(
      messageHash: hash,
      peerId: nodeB.id,
    );

    expect(result.sentCount, 1);
    expect(result.failedCount, 0);
    expect(ingestedByB, 1);
    expect(storedAtB, hasLength(1));
    expect(storedAtB.single.messageHash, hash);
    expect(storedAtB.single.hopCount, 1);
    expect(statusAtA?.status, ScfPeerStatus.sent);
  });

  test('deduplicates a returned mock relay payload', () async {
    final nodeADatabase = await _openTestDatabase('mock-dedupe-a.db');
    final nodeBDatabase = await _openTestDatabase('mock-dedupe-b.db');
    addTearDown(nodeADatabase.close);
    addTearDown(nodeBDatabase.close);

    const nodeA = Peer(
      id: 'node-a',
      name: 'Node A',
      type: PeerType.civilian,
      isConnected: true,
    );
    const nodeB = Peer(
      id: 'node-b',
      name: 'Node B',
      type: PeerType.relay,
      isConnected: true,
    );

    final network = MockScfTransportNetwork();
    final transportA = network.registerPeer(nodeA);
    final transportB = network.registerPeer(nodeB);
    final scfA = ScfService(database: nodeADatabase);
    final scfB = ScfService(database: nodeBDatabase);
    final relayA = ScfRelayService(scfService: scfA, transport: transportA);
    final relayB = ScfRelayService(scfService: scfB, transport: transportB);
    final now = DateTime.utc(2026, 5, 2, 6);
    final message = _message(sender: nodeA);

    await scfA.storeMessage(message, receivedAt: now);
    await relayA.relayToPeer(nodeB, now: now.add(const Duration(minutes: 1)));
    await relayB.ingestIncoming(now: now.add(const Duration(minutes: 2)));
    await relayB.relayToPeer(nodeA, now: now.add(const Duration(minutes: 3)));

    final ingestedByA = await relayA.ingestIncoming(
      now: now.add(const Duration(minutes: 4)),
    );
    final storedAtA = await scfA.getStoredEnvelopes(
      now: now.add(const Duration(minutes: 5)),
    );

    expect(ingestedByA, 0);
    expect(storedAtA, hasLength(1));
  });
}

Future<Database> _openTestDatabase(String name) async {
  final databasePath = path.join(
    await databaseFactoryFfi.getDatabasesPath(),
    name,
  );
  await databaseFactoryFfi.deleteDatabase(databasePath);
  return LocalMessagingDatabase.open(
    databasePath: databasePath,
    factory: databaseFactoryFfi,
  );
}

SosMessage _message({required Peer sender}) {
  return SosMessage(
    id: 'sos-1',
    sender: sender,
    body: 'Need medical assistance.',
    category: Category.medical,
    status: MessageStatus.queued,
    createdAt: DateTime.utc(2026, 5, 2, 5, 30),
    latitude: 7.3026,
    longitude: 125.6888,
  );
}
