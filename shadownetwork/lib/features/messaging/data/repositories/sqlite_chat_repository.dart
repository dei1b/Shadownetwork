import 'package:sqflite/sqflite.dart';

import '../../domain/entities/chat_message.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/repositories/chat_repository.dart';
import '../datasources/local_messaging_database.dart';
import '../models/chat_message_model.dart';
import '../models/conversation_model.dart';
import '../models/peer_model.dart';

class SqliteChatRepository implements ChatRepository {
  const SqliteChatRepository({required Database database})
    : _database = database;

  final Database _database;

  @override
  Future<Conversation> openConversation({
    required Peer localPeer,
    required Peer remotePeer,
    String? relatedSosMessageHash,
  }) async {
    final now = DateTime.now().toUtc();
    final id = 'conversation-${localPeer.id}-${remotePeer.id}';
    await _database.transaction((transaction) async {
      await PeerModel.upsert(transaction, localPeer, timestamp: now);
      await PeerModel.upsert(transaction, remotePeer, timestamp: now);
      final existing = await transaction.query(
        LocalMessagingDatabase.conversationsTable,
        columns: ['id', 'related_sos_message_hash'],
        where: 'local_peer_id = ? AND remote_peer_id = ?',
        whereArgs: [localPeer.id, remotePeer.id],
        limit: 1,
      );
      if (existing.isEmpty) {
        await transaction.insert(LocalMessagingDatabase.conversationsTable, {
          'id': id,
          'local_peer_id': localPeer.id,
          'remote_peer_id': remotePeer.id,
          'related_sos_message_hash': relatedSosMessageHash,
          'unread_count': 0,
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        });
      } else if (relatedSosMessageHash != null) {
        await transaction.update(
          LocalMessagingDatabase.conversationsTable,
          {
            'related_sos_message_hash': relatedSosMessageHash,
            'updated_at': now.toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [existing.single['id']],
        );
      }
    });
    final conversations = await getConversations(localPeer.id);
    return conversations.firstWhere(
      (item) => item.remotePeer.id == remotePeer.id,
    );
  }

  @override
  Future<List<Conversation>> getConversations(String localPeerId) async {
    final rows = await _database.rawQuery(
      '''
      SELECT conversations.*,
        peers.display_name AS remote_display_name,
        peers.peer_type_code AS remote_peer_type,
        peers.is_connected AS remote_is_connected,
        peers.signal_strength AS remote_signal_strength,
        peers.last_seen_at AS remote_last_seen_at,
        peers.latitude AS remote_latitude,
        peers.longitude AS remote_longitude,
        latest.body AS latest_body,
        latest.status AS latest_status,
        latest.moderation_status AS latest_moderation_status
      FROM ${LocalMessagingDatabase.conversationsTable} AS conversations
      INNER JOIN ${LocalMessagingDatabase.peersTable} AS peers
        ON peers.id = conversations.remote_peer_id
      LEFT JOIN ${LocalMessagingDatabase.chatMessagesTable} AS latest
        ON latest.id = (
          SELECT messages.id FROM ${LocalMessagingDatabase.chatMessagesTable} AS messages
          WHERE messages.conversation_id = conversations.id
          ORDER BY messages.created_at DESC LIMIT 1
        )
      WHERE conversations.local_peer_id = ?
      ORDER BY conversations.last_message_at DESC, conversations.updated_at DESC
    ''',
      [localPeerId],
    );
    return rows.map(ConversationModel.fromMap).toList(growable: false);
  }

  @override
  Future<List<ChatMessage>> getMessages(String conversationId) async {
    final rows = await _database.rawQuery(
      '''
      SELECT messages.*,
        sender.display_name AS sender_display_name,
        sender.peer_type_code AS sender_peer_type,
        sender.is_connected AS sender_is_connected,
        sender.signal_strength AS sender_signal_strength,
        sender.last_seen_at AS sender_last_seen_at,
        recipient.display_name AS recipient_display_name,
        recipient.peer_type_code AS recipient_peer_type,
        recipient.is_connected AS recipient_is_connected,
        recipient.signal_strength AS recipient_signal_strength,
        recipient.last_seen_at AS recipient_last_seen_at
      FROM ${LocalMessagingDatabase.chatMessagesTable} AS messages
      INNER JOIN ${LocalMessagingDatabase.peersTable} AS sender ON sender.id = messages.sender_peer_id
      INNER JOIN ${LocalMessagingDatabase.peersTable} AS recipient ON recipient.id = messages.recipient_peer_id
      WHERE messages.conversation_id = ?
      ORDER BY messages.created_at ASC
    ''',
      [conversationId],
    );
    return rows.map(ChatMessageModel.fromMap).toList(growable: false);
  }

  @override
  Future<List<ChatMessage>> getRecentMessagesBySender({
    required String senderPeerId,
    required DateTime since,
  }) async {
    final rows = await _database.rawQuery(
      '''
      SELECT messages.*,
        sender.display_name AS sender_display_name,
        sender.peer_type_code AS sender_peer_type,
        sender.is_connected AS sender_is_connected,
        sender.signal_strength AS sender_signal_strength,
        sender.last_seen_at AS sender_last_seen_at,
        recipient.display_name AS recipient_display_name,
        recipient.peer_type_code AS recipient_peer_type,
        recipient.is_connected AS recipient_is_connected,
        recipient.signal_strength AS recipient_signal_strength,
        recipient.last_seen_at AS recipient_last_seen_at
      FROM ${LocalMessagingDatabase.chatMessagesTable} AS messages
      INNER JOIN ${LocalMessagingDatabase.peersTable} AS sender ON sender.id = messages.sender_peer_id
      INNER JOIN ${LocalMessagingDatabase.peersTable} AS recipient ON recipient.id = messages.recipient_peer_id
      WHERE messages.sender_peer_id = ?
        AND messages.created_at >= ?
      ORDER BY messages.created_at DESC
    ''',
      [senderPeerId, since.toUtc().toIso8601String()],
    );
    return rows.map(ChatMessageModel.fromMap).toList(growable: false);
  }

  @override
  Future<void> saveMessage(
    ChatMessage message, {
    bool incrementUnread = false,
  }) async {
    await _database.transaction((transaction) async {
      await PeerModel.upsert(
        transaction,
        message.sender,
        timestamp: message.createdAt,
      );
      await PeerModel.upsert(
        transaction,
        message.recipient,
        timestamp: message.createdAt,
      );
      await transaction.insert(
        LocalMessagingDatabase.chatMessagesTable,
        ChatMessageModel.toMap(message),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      await transaction.rawUpdate(
        '''
        UPDATE ${LocalMessagingDatabase.conversationsTable}
        SET last_message_at = ?, updated_at = ?,
            unread_count = unread_count + ?
        WHERE id = ?
      ''',
        [
          message.createdAt.toUtc().toIso8601String(),
          DateTime.now().toUtc().toIso8601String(),
          incrementUnread ? 1 : 0,
          message.conversationId,
        ],
      );
    });
  }

  @override
  Future<void> updateOutgoingMessageStatus({
    required String messageHash,
    required String localPeerId,
    required MessageStatus status,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _database.update(
      LocalMessagingDatabase.chatMessagesTable,
      {'status': status.name, 'updated_at': now},
      where: 'message_hash = ? AND sender_peer_id = ?',
      whereArgs: [messageHash, localPeerId],
    );
  }

  @override
  Future<void> markConversationRead(String conversationId) {
    return _database.update(
      LocalMessagingDatabase.conversationsTable,
      {
        'unread_count': 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }
}
