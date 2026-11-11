import 'package:sqflite/sqflite.dart';

import '../../domain/entities/message_status.dart';
import '../../domain/entities/scf_peer_status.dart';
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
        CASE WHEN messages.status = '${MessageStatus.queued.name}'
          AND EXISTS (
            SELECT 1 FROM ${LocalMessagingDatabase.scfPeerStatusesTable} AS relay
            WHERE relay.message_hash = messages.message_hash
              AND relay.status IN ('${ScfPeerStatus.sent.name}', '${ScfPeerStatus.delivered.name}')
          )
          THEN '${MessageStatus.relayed.name}'
          ELSE messages.status
        END AS feed_status,
        peers.id AS sender_peer_id,
        peers.display_name AS sender_display_name,
        peers.peer_type_code AS sender_peer_type,
        peers.is_connected AS sender_is_connected,
        peers.signal_strength AS sender_signal_strength,
        peers.last_seen_at AS sender_last_seen_at,
        peers.latitude AS sender_latitude,
        peers.longitude AS sender_longitude,
        recipient.id AS recipient_peer_id,
        recipient.display_name AS recipient_display_name,
        recipient.peer_type_code AS recipient_peer_type,
        recipient.is_connected AS recipient_is_connected,
        recipient.signal_strength AS recipient_signal_strength,
        recipient.last_seen_at AS recipient_last_seen_at,
        recipient.latitude AS recipient_latitude,
        recipient.longitude AS recipient_longitude
      FROM ${LocalMessagingDatabase.sosMessagesTable} AS messages
      INNER JOIN ${LocalMessagingDatabase.peersTable} AS peers
        ON peers.id = messages.sender_peer_id
      LEFT JOIN ${LocalMessagingDatabase.peersTable} AS recipient
        ON recipient.id = messages.recipient_peer_id
      ORDER BY messages.created_at DESC
    ''');

    return rows
        .map((row) {
          final message = SosMessageModel.fromMap(row);
          return message.copyWith(
            status: MessageStatus.values.byName(row['feed_status']! as String),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<List<SosMessage>> getRecentMessagesBySender({
    required String senderPeerId,
    required DateTime since,
  }) async {
    final rows = await _database.rawQuery(
      '''
      SELECT
        messages.*,
        peers.id AS sender_peer_id,
        peers.display_name AS sender_display_name,
        peers.peer_type_code AS sender_peer_type,
        peers.is_connected AS sender_is_connected,
        peers.signal_strength AS sender_signal_strength,
        peers.last_seen_at AS sender_last_seen_at,
        peers.latitude AS sender_latitude,
        peers.longitude AS sender_longitude,
        recipient.id AS recipient_peer_id,
        recipient.display_name AS recipient_display_name,
        recipient.peer_type_code AS recipient_peer_type,
        recipient.is_connected AS recipient_is_connected,
        recipient.signal_strength AS recipient_signal_strength,
        recipient.last_seen_at AS recipient_last_seen_at,
        recipient.latitude AS recipient_latitude,
        recipient.longitude AS recipient_longitude
      FROM ${LocalMessagingDatabase.sosMessagesTable} AS messages
      INNER JOIN ${LocalMessagingDatabase.peersTable} AS peers
        ON peers.id = messages.sender_peer_id
      LEFT JOIN ${LocalMessagingDatabase.peersTable} AS recipient
        ON recipient.id = messages.recipient_peer_id
      WHERE messages.sender_peer_id = ?
        AND messages.created_at >= ?
      ORDER BY messages.created_at DESC
    ''',
      [senderPeerId, since.toUtc().toIso8601String()],
    );

    return rows.map(SosMessageModel.fromMap).toList(growable: false);
  }

  @override
  Future<bool> saveMessage(SosMessage message) {
    return _database.transaction((transaction) async {
      await PeerModel.upsert(
        transaction,
        message.sender,
        timestamp: message.createdAt,
      );
      final recipient = message.recipient;
      if (recipient != null) {
        await PeerModel.upsert(
          transaction,
          recipient,
          timestamp: message.createdAt,
        );
      }
      final row = SosMessageModel.toMap(message);
      final existing = await transaction.query(
        LocalMessagingDatabase.sosMessagesTable,
        columns: [
          'received_at',
          'received_from_peer_id',
          'received_transport',
          'transfer_id',
          'responded_at',
        ],
        where: 'id = ?',
        whereArgs: [message.id],
        limit: 1,
      );
      // Keep the first accepted receipt and its matching last-hop metadata.
      // Status changes and repeated deliveries must not reset propagation time.
      if (existing.isNotEmpty && existing.single['received_at'] != null) {
        row.addAll(existing.single);
      }
      // Replayed envelopes cannot reopen an alert closed on this phone.
      row['responded_at'] = existing.firstOrNull?['responded_at'];
      await transaction.insert(
        LocalMessagingDatabase.sosMessagesTable,
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await transaction.delete(
        LocalMessagingDatabase.pendingInboxTable,
        where: 'message_hash = ?',
        whereArgs: [row['message_hash']],
      );
      return existing.isEmpty;
    });
  }

  @override
  Future<bool> setResponded({
    required String messageId,
    required String localPeerId,
    required bool responded,
  }) async {
    final changed = await _database.update(
      LocalMessagingDatabase.sosMessagesTable,
      {
        'responded_at': responded
            ? DateTime.now().toUtc().toIso8601String()
            : null,
      },
      where:
          '''
        id = ? AND lower(sender_peer_id) != lower(?)
        AND (received_at IS NOT NULL OR status = ?)
        AND trust_status != 'revoked'
        AND ${responded ? "moderation_status = 'normal' AND responded_at IS NULL" : "responded_at IS NOT NULL"}
      ''',
      whereArgs: [messageId, localPeerId, MessageStatus.received.name],
    );
    return changed == 1;
  }
}
