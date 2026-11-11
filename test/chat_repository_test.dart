import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/models/chat_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/repositories/sqlite_chat_repository.dart';
import 'package:shadownetwork/features/messaging/domain/entities/chat_message.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_moderation_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/nearby_peer_sightings_provider.dart';
import 'package:shadownetwork/features/messaging/presentation/utils/message_feed_filter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'outbound queue failure rolls back the chat and its conversation timestamp',
    () async {
      final database = await LocalMessagingDatabase.open(
        databasePath: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(database.close);
      final repository = SqliteChatRepository(database: database);
      const local = Peer(
        id: 'local',
        name: 'Local',
        type: PeerType.civilian,
        isConnected: true,
      );
      final remote = local.copyWith(id: 'remote');
      final conversation = await repository.openConversation(
        localPeer: local,
        remotePeer: remote,
      );
      final chat = ChatMessage(
        id: 'outgoing',
        conversationId: conversation.id,
        sender: local,
        recipient: remote,
        body: 'Need help',
        status: MessageStatus.queued,
        createdAt: DateTime.now().toUtc(),
      );
      final payload = ChatMessagePayload.canonicalJson(chat);
      await database.execute("""
      CREATE TRIGGER fail_outbound_chat BEFORE INSERT ON scf_messages
      BEGIN SELECT RAISE(ABORT, 'injected queue failure'); END
    """);
      await expectLater(
        repository.saveMessage(chat, outgoingPayloadJson: payload),
        throwsA(isA<DatabaseException>()),
      );
      expect(await repository.getMessages(conversation.id), isEmpty);
      expect(await repository.getConversations(local.id), isEmpty);
      final rows = await database.query(
        LocalMessagingDatabase.conversationsTable,
      );
      expect(rows.single['last_message_at'], isNull);
    },
  );

  test('persists conversation history and unread inbound chat', () async {
    final database = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(database.close);
    final repository = SqliteChatRepository(database: database);
    const local = Peer(
      id: 'node-a',
      name: 'Resident A',
      type: PeerType.civilian,
      isConnected: true,
    );
    const remote = Peer(
      id: 'responder-1',
      name: 'Responder 1',
      type: PeerType.responder,
      isConnected: false,
    );

    final conversation = await repository.openConversation(
      localPeer: local,
      remotePeer: remote,
      relatedSosMessageHash: 'sos-hash',
    );
    final directChat = await repository.openConversation(
      localPeer: local,
      remotePeer: remote.copyWith(id: 'node-b', name: 'Resident B'),
    );
    expect(conversation.relatedSosMessageHash, 'sos-hash');
    expect(await repository.getConversations(local.id), isEmpty);
    await expectLater(
      repository.openConversation(
        localPeer: local,
        remotePeer: local.copyWith(id: local.id.toUpperCase()),
      ),
      throwsFormatException,
    );
    final savedAt = DateTime.utc(2026, 5, 25).toIso8601String();
    await database.insert(LocalMessagingDatabase.conversationsTable, {
      'id': 'legacy-self-chat',
      'local_peer_id': local.id,
      'remote_peer_id': local.id,
      'created_at': savedAt,
      'updated_at': savedAt,
    });
    await repository.saveMessage(
      ChatMessage(
        id: 'chat-inbound',
        conversationId: conversation.id,
        sender: remote,
        recipient: local,
        body: 'Rescue team is on the way.',
        status: MessageStatus.received,
        createdAt: DateTime.utc(2026, 5, 25, 10),
        moderationStatus: MessageModerationStatus.spam,
        moderationReason: 'levenshtein_similarity',
        moderationScore: 0.92,
      ),
      incrementUnread: true,
    );

    final threads = await repository.getConversations(local.id);
    final messages = await repository.getMessages(conversation.id);

    expect(threads, hasLength(1));
    expect(threads.single.unreadCount, 1);
    expect(threads.single.latestBody, 'Rescue team is on the way.');
    expect(threads.single.latestModerationStatus, MessageModerationStatus.spam);
    expect(messages.single.recipient.id, local.id);
    expect(messages.single.status, MessageStatus.received);
    expect(messages.single.moderationStatus, MessageModerationStatus.spam);
    expect(messages.single.moderationReason, 'levenshtein_similarity');
    expect(messages.single.moderationScore, 0.92);

    await repository.updateOutgoingMessageStatus(
      messageHash: messages.single.messageHash!,
      localPeerId: local.id,
      status: MessageStatus.relayed,
    );
    expect(
      (await repository.getMessages(conversation.id)).single.status,
      MessageStatus.received,
    );

    await repository.markConversationRead(conversation.id);
    expect((await repository.getConversations(local.id)).single.unreadCount, 0);

    expect(
      await repository.saveMessage(messages.single, incrementUnread: true),
      isFalse,
    );
    expect(await repository.getMessages(conversation.id), hasLength(1));
    expect((await repository.getConversations(local.id)).single.unreadCount, 0);

    await database.insert(LocalMessagingDatabase.trustedDevicesTable, {
      'device_id': remote.id,
      'owner_name': 'Registered Rescuer',
      'role': 'responder',
      'status': 'approved',
      'key_version': 1,
      'bundle_version': 1,
      'bundle_hash': 'test-bundle',
      'admin_updated_at': DateTime.utc(2026, 11, 6).toIso8601String(),
      'imported_at': DateTime.utc(2026, 11, 6).toIso8601String(),
    });
    expect(
      (await repository.getConversations(local.id)).single.remotePeer.name,
      'Registered Rescuer',
    );
    final container = ProviderContainer(
      overrides: [
        localMessagingDatabaseProvider.overrideWith((ref) async => database),
        localPeerProvider.overrideWith((ref) async => local),
      ],
    );
    addTearDown(container.dispose);
    expect(await container.read(nearbyPeersProvider.future), isEmpty);
    container.read(nearbyPeerSightingsProvider.notifier).replace([
      remote.copyWith(lastSeenAt: DateTime.now()),
    ]);
    final nearby = await container.read(nearbyPeersProvider.future);
    expect(nearby.single.name, 'Registered Rescuer');
    expect(nearby.single.type, PeerType.responder);
    await database.update(
      LocalMessagingDatabase.trustedDevicesTable,
      {'status': 'revoked'},
      where: 'device_id = ?',
      whereArgs: [remote.id],
    );
    container.invalidate(nearbyPeersProvider);
    expect(
      (await container.read(nearbyPeersProvider.future)).single.name,
      remote.name,
    );
    expect(
      (await repository.getConversations(local.id)).single.remotePeer.name,
      remote.name,
    );

    await repository.saveMessage(
      ChatMessage(
        id: 'chat-outbound',
        conversationId: conversation.id,
        sender: local,
        recipient: remote,
        body: 'I am still here.',
        status: MessageStatus.queued,
        createdAt: DateTime.utc(2026, 5, 25, 10, 1),
        moderationStatus: MessageModerationStatus.spam,
      ),
    );
    final outgoingThread = (await repository.getConversations(local.id)).single;
    expect(outgoingThread.latestBody, 'I am still here.');
    expect(
      shouldShowConversationForFilter(
        conversation: outgoingThread,
        activeFilter: 'ALL',
      ),
      isTrue,
    );
    expect(
      shouldShowConversationForFilter(
        conversation: outgoingThread,
        activeFilter: 'SPAM',
      ),
      isFalse,
    );

    await repository.saveMessage(
      ChatMessage(
        id: 'first-direct-message',
        conversationId: directChat.id,
        sender: local,
        recipient: directChat.remotePeer,
        body: 'First message',
        status: MessageStatus.queued,
        createdAt: DateTime.utc(2026, 5, 25, 10, 2),
      ),
    );
    final visible = await repository.getConversations(local.id);
    expect(visible.map((thread) => thread.id), [
      directChat.id,
      conversation.id,
    ]);
    expect(visible.first.latestBody, 'First message');
  });
}
