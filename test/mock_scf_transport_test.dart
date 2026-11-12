import 'dart:convert';

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

  test('reports live mock transport status from registered peers', () async {
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
      isConnected: false,
    );
    const nodeC = Peer(
      id: 'node-c',
      name: 'Node C',
      type: PeerType.responder,
      isConnected: true,
    );

    final network = MockScfTransportNetwork();
    final transportA = network.registerPeer(nodeA);
    network.registerPeer(nodeB);
    network.registerPeer(nodeC);

    final localPeer = await transportA.getLocalPeer();
    final status = await transportA.getStatus();
    final discoveredPeers = await transportA.discoverPeers();

    expect(localPeer.id, nodeA.id);
    expect(localPeer.name, nodeA.name);
    expect(status.localPeer.id, nodeA.id);
    expect(status.permissionsGranted, isTrue);
    expect(status.isRunning, isTrue);
    expect(status.discoveredPeerCount, discoveredPeers.length);
    expect(status.connectedPeerCount, 1);
  });

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
    final sending = relayA.relayToPeer(
      peersFromA.single,
      now: now.add(const Duration(minutes: 1)),
    );
    await transportB.relayEvents.first;
    final ingestedByB = await relayB.ingestIncoming(
      now: now.add(const Duration(minutes: 2)),
    );
    final result = await sending;
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
    expect(
      SosMessagePayload.fromPayload(
        jsonDecode(storedAtB.single.payloadJson) as Map<String, Object?>,
      ).hopCount,
      1,
    );
    expect(statusAtA?.status, ScfPeerStatus.sent);
  });

  test(
    'middle phone skips the origin and forwards the SOS at hop two',
    () async {
      final nodeADatabase = await _openTestDatabase('mock-dedupe-a.db');
      final nodeBDatabase = await _openTestDatabase('mock-dedupe-b.db');
      final nodeCDatabase = await _openTestDatabase('mock-relay-c.db');
      addTearDown(nodeCDatabase.close);
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
      final nodeC = nodeB.copyWith(id: 'node-c', type: PeerType.responder);
      final transportC = network.registerPeer(nodeC);
      final scfC = ScfService(database: nodeCDatabase);
      final relayC = ScfRelayService(scfService: scfC, transport: transportC);
      final scfA = ScfService(database: nodeADatabase);
      final scfB = ScfService(database: nodeBDatabase);
      final relayA = ScfRelayService(scfService: scfA, transport: transportA);
      final relayB = ScfRelayService(scfService: scfB, transport: transportB);
      final now = DateTime.utc(2026, 5, 2, 6);
      final message = _message(sender: nodeA);

      await scfA.storeMessage(message, receivedAt: now);
      final sendingA = relayA.relayToPeer(
        nodeB,
        now: now.add(const Duration(minutes: 1)),
      );
      await transportB.relayEvents.first;
      await relayB.ingestIncoming(now: now.add(const Duration(minutes: 2)));
      expect((await sendingA).sentCount, 1);
      final returnToOrigin = await relayB.relayToPeer(nodeA, now: now);
      expect(returnToOrigin.sentCount, 0);
      expect(await transportA.receiveEnvelopes(), isEmpty);

      final receivedAtC = transportC.relayEvents.first;
      final onward = relayB.relayToPeer(nodeC, now: now);
      await receivedAtC;
      expect(await relayC.ingestIncoming(now: now), 1);
      expect((await onward).sentCount, 1);
      final stored = (await scfC.getStoredEnvelopes(now: now)).single;
      expect(stored.messageHash, SosMessagePayload.messageHash(message));
      expect(stored.hopCount, 2);
    },
  );

  test(
    'a new SOS jumps ahead of remaining backlog during the same relay pass',
    () async {
      final db = await _openTestDatabase('mock-sos-priority.db');
      addTearDown(db.close);
      const sender = Peer(
        id: 'sender',
        name: 'Sender',
        type: PeerType.civilian,
        isConnected: true,
      );
      final relay = sender.copyWith(id: 'relay');
      final network = MockScfTransportNetwork();
      final origin = network.registerPeer(sender);
      final middle = network.registerPeer(relay);
      final service = ScfService(database: db);
      final relayService = ScfRelayService(
        scfService: service,
        transport: origin,
      );
      final now = DateTime.utc(2026, 5, 2, 6);
      final old = _message(sender: sender);
      final newer = old.copyWith(id: 'newer', body: 'Newer');
      final newest = old.copyWith(id: 'newest', body: 'Newest');
      await service.storeMessage(
        old,
        receivedAt: now.subtract(const Duration(seconds: 2)),
      );
      await service.storeMessage(
        newer,
        receivedAt: now.subtract(const Duration(seconds: 1)),
      );

      final firstReady = middle.relayEvents.first;
      final sending = relayService.relayToPeer(relay, now: now, limit: 2);
      await firstReady;
      final first = (await middle.receiveEnvelopes()).single;
      expect(first.messageHash, SosMessagePayload.messageHash(newer));
      await service.storeMessage(newest, receivedAt: now);
      final nextReady = middle.relayEvents.first;
      await middle.acknowledgeEnvelope(envelope: first);
      await nextReady;
      final next = (await middle.receiveEnvelopes()).single;
      expect(next.messageHash, SosMessagePayload.messageHash(newest));
      await middle.acknowledgeEnvelope(envelope: next);
      expect((await sending).sentCount, 2);
    },
  );
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
    ttl: const Duration(hours: 6),
  );
}
