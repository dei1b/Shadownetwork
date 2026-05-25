import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/repositories/sqlite_chat_repository.dart';
import 'package:shadownetwork/features/messaging/domain/entities/chat_message.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

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
    await repository.saveMessage(
      ChatMessage(
        id: 'chat-inbound',
        conversationId: conversation.id,
        sender: remote,
        recipient: local,
        body: 'Rescue team is on the way.',
        status: MessageStatus.received,
        createdAt: DateTime.utc(2026, 5, 25, 10),
      ),
      incrementUnread: true,
    );

    final threads = await repository.getConversations(local.id);
    final messages = await repository.getMessages(conversation.id);

    expect(threads, hasLength(1));
    expect(threads.single.unreadCount, 1);
    expect(threads.single.latestBody, 'Rescue team is on the way.');
    expect(messages.single.recipient.id, local.id);
    expect(messages.single.status, MessageStatus.received);

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
  });
}
