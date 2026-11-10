import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/models/sos_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/models/chat_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/repositories/sqlite_chat_repository.dart';
import 'package:shadownetwork/features/messaging/data/services/mock_scf_transport.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_service.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_relay_service.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/chat_message.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/domain/entities/scf_envelope.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/relay_runtime_provider.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'support/database_migration_test_harness.dart';

const sender = Peer(
  id: 'sender',
  name: 'Sender',
  type: PeerType.civilian,
  isConnected: true,
);
const receiver = Peer(
  id: 'receiver',
  name: 'Receiver',
  type: PeerType.responder,
  isConnected: true,
);

ProviderContainer runtimeContainer(
  Database db,
  MockScfTransportEndpoint transport,
) {
  final container = ProviderContainer(
    overrides: [
      localMessagingDatabaseProvider.overrideWith((ref) async => db),
      scfTransportProvider.overrideWithValue(transport),
      deviceIdentityStoreProvider.overrideWithValue(
        DeviceIdentityStore(secretStore: InMemorySecretValueStore()),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

ChatMessage chat(String id, DateTime time, String conversation) => ChatMessage(
  id: id,
  conversationId: conversation,
  sender: sender,
  recipient: receiver,
  body: id,
  status: MessageStatus.received,
  createdAt: time,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'accepted chat survives restart before the conversation write',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      var db = await harness.openCurrentDatabase();
      addTearDown(() => db.close());
      final network = MockScfTransportNetwork();
      final from = network.registerPeer(sender);
      final to = network.registerPeer(receiver);
      final now = DateTime.now().toUtc();
      final message = chat('accepted-reply', now, 'conversation');
      final envelope = ScfEnvelope(
        messageHash: ChatMessagePayload.messageHash(message),
        payloadJson: ChatMessagePayload.canonicalJson(message),
        hopCount: 1,
        receivedAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
        payloadType: 'chat_message',
        transferId: 'accepted-attempt',
      );
      final arrival = to.relayEvents.first;
      final sending = from.sendEnvelope(peer: receiver, envelope: envelope);
      await arrival;
      expect(
        await ScfRelayService(
          scfService: ScfService(database: db),
          transport: to,
        ).ingestIncoming(),
        1,
      );
      expect((await sending).acknowledged, isTrue);
      expect(await db.query(LocalMessagingDatabase.chatMessagesTable), isEmpty);
      await db.close();
      db = await harness.openCurrentDatabase();
      expect(await ScfService(database: db).getStoredEnvelopes(), hasLength(1));
      // Local inbox work survives expiry of the forwarding copy.
      await ScfService(database: db).pruneExpired(now: envelope.expiresAt);
      final container = runtimeContainer(
        db,
        MockScfTransportNetwork().registerPeer(receiver),
      );
      final runtime = container.read(relayRuntimeProvider.notifier);
      await runtime.start();
      runtime.stop();
      expect(await ScfService(database: db).getStoredEnvelopes(), isEmpty);
      expect(
        await db.query(LocalMessagingDatabase.chatMessagesTable),
        hasLength(1),
      );
      expect(await ScfService(database: db).getPendingInbox(), isEmpty);
      expect(await runtime.receiveIncoming(), 0);
      expect(
        (await db.query(
          LocalMessagingDatabase.conversationsTable,
        )).single['unread_count'],
        1,
      );
    },
  );

  test(
    'malformed SOS does not block a following valid SOS on every sync',
    () async {
      final db = await LocalMessagingDatabase.open(
        databasePath: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(db.close);
      final network = MockScfTransportNetwork();
      final to = network.registerPeer(receiver);
      final now = DateTime.now().toUtc();
      SosMessage message(String id) => SosMessage(
        id: id,
        sender: sender,
        body: 'Need assistance',
        category: Category.medical,
        status: MessageStatus.queued,
        createdAt: now,
      );
      final bad = SosMessagePayload.toPayload(message('bad'));
      bad['category'] = 'unsupported-category';
      bad['message_hash'] = SosMessagePayload.hashPayload(jsonEncode(bad));
      final good = SosMessagePayload.toPayload(message('good'));
      final wrongType = SosMessagePayload.toPayload(message('wrong-type'));
      wrongType['category'] = 17;
      wrongType['message_hash'] = SosMessagePayload.hashPayload(
        jsonEncode(wrongType),
      );
      for (final payload in [bad, wrongType, good]) {
        network.send(
          fromPeerId: sender.id,
          toPeerId: receiver.id,
          envelope: ScfEnvelope(
            messageHash: payload['message_hash']! as String,
            payloadJson: jsonEncode(payload),
            hopCount: 1,
            receivedAt: now,
            expiresAt: now.add(const Duration(hours: 1)),
          ),
        );
      }
      final container = runtimeContainer(db, to);
      final runtime = container.read(relayRuntimeProvider.notifier);
      await runtime.syncNow();
      await runtime.syncNow();
      final repository = await container.read(
        sosMessageRepositoryProvider.future,
      );
      expect(
        (await repository.getMessages()).map((m) => m.id),
        contains('good'),
        reason:
            'Runtime error: ${container.read(relayRuntimeProvider).lastError}',
      );
      expect(await ScfService(database: db).getPendingInbox(), isEmpty);
      expect(container.read(relayRuntimeProvider).lastError, isNull);
    },
  );

  test(
    'version 14 upgrade recovers only missing active chat and preserves SOS',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      var db = await harness.openCurrentDatabase();
      addTearDown(() => db.close());
      final scf = ScfService(database: db);
      final repository = SqliteChatRepository(database: db);
      final conversation = await repository.openConversation(
        localPeer: receiver,
        remotePeer: sender,
      );
      final now = DateTime.now().toUtc();
      final saved = chat('already-saved', now, conversation.id);
      await repository.saveMessage(saved, incrementUnread: true);
      await scf.storeChatMessage(saved);
      final missing = chat('missing', now, conversation.id);
      await scf.storeChatMessage(missing);
      await scf.storeChatMessage(
        chat('expired', now.subtract(const Duration(days: 2)), conversation.id),
        receivedAt: now.subtract(const Duration(days: 2)),
      );
      final sos = SosMessage(
        id: 'pending-sos',
        sender: sender,
        body: 'Help',
        category: Category.medical,
        status: MessageStatus.queued,
        createdAt: now,
      );
      await scf.storeEnvelope(
        ScfEnvelope(
          messageHash: SosMessagePayload.messageHash(sos),
          payloadJson: SosMessagePayload.canonicalJson(sos),
          hopCount: 1,
          receivedAt: now,
          expiresAt: now.add(const Duration(hours: 1)),
          transferId: 'sos-receipt',
        ),
      );
      await db.setVersion(14);
      await db.close();
      db = await harness.openCurrentDatabase();
      final pending = await ScfService(database: db).getPendingInbox();
      expect(
        pending.map((e) => e.messageHash),
        unorderedEquals([
          ChatMessagePayload.messageHash(missing),
          SosMessagePayload.messageHash(sos),
        ]),
      );
      expect(
        pending
            .singleWhere(
              (e) => e.messageHash == SosMessagePayload.messageHash(sos),
            )
            .transferId,
        'sos-receipt',
      );
      final container = runtimeContainer(
        db,
        MockScfTransportNetwork().registerPeer(receiver),
      );
      await container.read(relayRuntimeProvider.notifier).receiveIncoming();
      expect(
        await db.query(LocalMessagingDatabase.chatMessagesTable),
        hasLength(2),
      );
      expect(await ScfService(database: db).getPendingInbox(), isEmpty);
    },
  );

  test(
    'chat for another recipient stays available for forwarding only',
    () async {
      final db = await LocalMessagingDatabase.open(
        databasePath: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(db.close);
      final now = DateTime.now().toUtc();
      final message = chat('relay-only', now, 'conversation');
      final scf = ScfService(database: db);
      await scf.storeEnvelope(
        ScfEnvelope(
          messageHash: ChatMessagePayload.messageHash(message),
          payloadJson: ChatMessagePayload.canonicalJson(message),
          hopCount: 1,
          receivedAt: now,
          expiresAt: now.add(const Duration(hours: 1)),
          payloadType: 'chat_message',
        ),
      );
      const relay = Peer(
        id: 'relay',
        name: 'Relay',
        type: PeerType.relay,
        isConnected: true,
      );
      final container = runtimeContainer(
        db,
        MockScfTransportNetwork().registerPeer(relay),
      );
      expect(
        await container.read(relayRuntimeProvider.notifier).receiveIncoming(),
        0,
      );
      expect(await scf.getPendingInbox(), isEmpty);
      expect(await scf.prepareOutboundForPeer(receiver.id), hasLength(1));
      expect(await db.query(LocalMessagingDatabase.chatMessagesTable), isEmpty);
    },
  );

  test('failed conversation update keeps pending chat for retry', () async {
    final db = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(db.close);
    final repository = SqliteChatRepository(database: db);
    final conversation = await repository.openConversation(
      localPeer: receiver,
      remotePeer: sender,
    );
    final now = DateTime.now().toUtc();
    final message = chat('retry', now, conversation.id);
    final scf = ScfService(database: db);
    await scf.storeEnvelope(
      ScfEnvelope(
        messageHash: ChatMessagePayload.messageHash(message),
        payloadJson: ChatMessagePayload.canonicalJson(message),
        hopCount: 1,
        receivedAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
        payloadType: 'chat_message',
      ),
    );
    await db.execute(
      '''CREATE TRIGGER fail_conversation_update BEFORE UPDATE ON conversations
      BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END''',
    );
    await expectLater(
      repository.saveMessage(message, incrementUnread: true),
      throwsA(isA<DatabaseException>()),
    );
    expect(await scf.getPendingInbox(), hasLength(1));
    expect(await db.query(LocalMessagingDatabase.chatMessagesTable), isEmpty);
    await db.execute('DROP TRIGGER fail_conversation_update');
    expect(
      await repository.saveMessage(message, incrementUnread: true),
      isTrue,
    );
    expect(await scf.getPendingInbox(), isEmpty);
  });

  test('a delayed reply keeps the latest conversation timestamp', () async {
    final db = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(db.close);
    final repository = SqliteChatRepository(database: db);
    final conversation = await repository.openConversation(
      localPeer: receiver,
      remotePeer: sender,
    );
    final newer = DateTime.now().toUtc();
    final older = newer.subtract(const Duration(minutes: 30));
    await repository.saveMessage(
      chat('newer', newer, conversation.id),
      incrementUnread: true,
    );
    await repository.saveMessage(
      chat('older', older, conversation.id),
      incrementUnread: true,
    );
    final rows = await db.query(
      LocalMessagingDatabase.conversationsTable,
      where: 'id = ?',
      whereArgs: [conversation.id],
    );
    expect(rows.single['last_message_at'], newer.toIso8601String());
    // ISO strings with optional microseconds must be compared as instants.
    final boundary = DateTime.utc(2030, 1, 1, 0, 0, 0, 123);
    final later = boundary.add(const Duration(microseconds: 1));
    await repository.saveMessage(chat('microsecond', later, conversation.id));
    await repository.saveMessage(
      chat('millisecond', boundary, conversation.id),
    );
    expect(
      (await db.query(
        LocalMessagingDatabase.conversationsTable,
      )).single['last_message_at'],
      later.toIso8601String(),
    );
  });
}
