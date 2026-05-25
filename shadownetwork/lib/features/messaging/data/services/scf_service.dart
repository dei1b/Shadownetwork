import 'package:sqflite/sqflite.dart';

import '../../domain/entities/scf_envelope.dart';
import '../../domain/entities/scf_peer_delivery.dart';
import '../../domain/entities/scf_peer_status.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/sos_message.dart';
import '../datasources/local_messaging_database.dart';
import '../models/scf_envelope_model.dart';
import '../models/scf_peer_delivery_model.dart';
import '../models/sos_message_payload.dart';
import '../models/chat_message_payload.dart';
import '../models/relay_payload_codec.dart';

class ScfService {
  const ScfService({
    required Database database,
    this.defaultTtl = const Duration(hours: 24),
  }) : _database = database;

  final Database _database;
  final Duration defaultTtl;

  Future<bool> storeMessage(
    SosMessage message, {
    DateTime? receivedAt,
    Duration? ttl,
    int? hopCount,
  }) {
    final payloadJson = SosMessagePayload.canonicalJson(
      message.copyWith(hopCount: hopCount ?? message.hopCount),
    );
    return storePayload(
      payloadJson: payloadJson,
      receivedAt: receivedAt,
      ttl: ttl ?? message.ttl,
      hopCount: hopCount ?? message.hopCount,
    );
  }

  Future<bool> storeChatMessage(
    ChatMessage message, {
    DateTime? receivedAt,
    Duration? ttl,
    int? hopCount,
  }) {
    return storePayload(
      payloadJson: ChatMessagePayload.canonicalJson(
        message.copyWith(hopCount: hopCount ?? message.hopCount),
      ),
      receivedAt: receivedAt,
      ttl: ttl ?? message.ttl,
      hopCount: hopCount ?? message.hopCount,
    );
  }

  Future<bool> storePayload({
    required String payloadJson,
    DateTime? receivedAt,
    Duration? ttl,
    int hopCount = 0,
  }) async {
    if (hopCount < 0) {
      throw ArgumentError.value(hopCount, 'hopCount', 'Must not be negative.');
    }

    final now = (receivedAt ?? DateTime.now()).toUtc();
    final expiresAt = now.add(ttl ?? defaultTtl);
    final messageHash = RelayPayloadCodec.hashPayload(payloadJson);
    final envelope = ScfEnvelope(
      messageHash: messageHash,
      payloadJson: payloadJson,
      hopCount: hopCount,
      receivedAt: now,
      expiresAt: expiresAt,
      payloadType: RelayPayloadCodec.payloadType(payloadJson),
    );

    return _database.transaction((transaction) async {
      return _insertEnvelope(transaction, envelope: envelope, now: now);
    });
  }

  Future<bool> storeEnvelope(ScfEnvelope envelope, {DateTime? now}) async {
    if (RelayPayloadCodec.hashPayload(envelope.payloadJson) !=
        envelope.messageHash) {
      throw const FormatException('SCF envelope hash does not match payload.');
    }

    final timestamp = (now ?? DateTime.now()).toUtc();
    if (envelope.isExpired(timestamp)) {
      return false;
    }

    return _database.transaction((transaction) async {
      return _insertEnvelope(transaction, envelope: envelope, now: timestamp);
    });
  }

  Future<int> pruneExpired({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).toUtc().toIso8601String();
    return _database.delete(
      LocalMessagingDatabase.scfMessagesTable,
      where: 'expires_at <= ?',
      whereArgs: [cutoff],
    );
  }

  Future<void> consumeDeliveredPayload(String messageHash) {
    return _database.delete(
      LocalMessagingDatabase.scfMessagesTable,
      where: 'message_hash = ?',
      whereArgs: [messageHash],
    );
  }

  Future<List<ScfEnvelope>> prepareOutboundForPeer(
    String peerId, {
    DateTime? now,
    int limit = 50,
  }) async {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'Must be greater than zero.');
    }

    final timestamp = (now ?? DateTime.now()).toUtc();
    await pruneExpired(now: timestamp);

    return _database.transaction((transaction) async {
      final rows = await transaction.rawQuery(
        '''
        SELECT messages.*
        FROM ${LocalMessagingDatabase.scfMessagesTable} AS messages
        LEFT JOIN ${LocalMessagingDatabase.scfPeerStatusesTable} AS statuses
          ON statuses.message_hash = messages.message_hash
          AND statuses.peer_id = ?
        WHERE messages.expires_at > ?
          AND (
            statuses.status IS NULL
            OR statuses.status IN (?, ?)
          )
        ORDER BY messages.received_at ASC
        LIMIT ?
        ''',
        [
          peerId,
          timestamp.toIso8601String(),
          ScfPeerStatus.pending.name,
          ScfPeerStatus.failed.name,
          limit,
        ],
      );

      final envelopes = rows
          .map(ScfEnvelopeModel.fromMap)
          .toList(growable: false);

      for (final envelope in envelopes) {
        await _upsertPeerStatus(
          transaction,
          messageHash: envelope.messageHash,
          peerId: peerId,
          status: ScfPeerStatus.offered,
          updatedAt: timestamp,
          incrementAttempt: true,
        );
      }

      return envelopes
          .map(
            (envelope) => envelope.copyWith(
              hopCount: envelope.hopCount + 1,
              payloadJson: RelayPayloadCodec.payloadJsonForRelay(
                envelope.payloadJson,
                hopCount: envelope.hopCount + 1,
              ),
            ),
          )
          .toList(growable: false);
    });
  }

  Future<void> updatePeerStatus({
    required String messageHash,
    required String peerId,
    required ScfPeerStatus status,
    DateTime? updatedAt,
    String? lastError,
  }) async {
    final timestamp = (updatedAt ?? DateTime.now()).toUtc();
    await _database.transaction((transaction) async {
      await _upsertPeerStatus(
        transaction,
        messageHash: messageHash,
        peerId: peerId,
        status: status,
        updatedAt: timestamp,
        lastError: lastError,
      );
    });
  }

  Future<ScfPeerDelivery?> getPeerStatus({
    required String messageHash,
    required String peerId,
  }) async {
    final rows = await _database.query(
      LocalMessagingDatabase.scfPeerStatusesTable,
      where: 'message_hash = ? AND peer_id = ?',
      whereArgs: [messageHash, peerId],
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }

    return ScfPeerDeliveryModel.fromMap(rows.single);
  }

  Future<List<ScfEnvelope>> getStoredEnvelopes({DateTime? now}) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    final rows = await _database.query(
      LocalMessagingDatabase.scfMessagesTable,
      where: 'expires_at > ?',
      whereArgs: [timestamp.toIso8601String()],
      orderBy: 'received_at ASC',
    );

    return rows.map(ScfEnvelopeModel.fromMap).toList(growable: false);
  }

  Future<void> _upsertPeerStatus(
    Transaction transaction, {
    required String messageHash,
    required String peerId,
    required ScfPeerStatus status,
    required DateTime updatedAt,
    bool incrementAttempt = false,
    String? lastError,
  }) async {
    final existing = await transaction.query(
      LocalMessagingDatabase.scfPeerStatusesTable,
      columns: ['attempt_count'],
      where: 'message_hash = ? AND peer_id = ?',
      whereArgs: [messageHash, peerId],
      limit: 1,
    );
    final existingAttempts = existing.isEmpty
        ? 0
        : existing.single['attempt_count']! as int;
    final attemptCount = incrementAttempt
        ? existingAttempts + 1
        : existingAttempts;

    await transaction.insert(
      LocalMessagingDatabase.scfPeerStatusesTable,
      {
        'message_hash': messageHash,
        'peer_id': peerId,
        'status': status.name,
        'attempt_count': attemptCount,
        'updated_at': updatedAt.toIso8601String(),
        'last_error': lastError,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> _insertEnvelope(
    Transaction transaction, {
    required ScfEnvelope envelope,
    required DateTime now,
  }) async {
    final existing = await transaction.query(
      LocalMessagingDatabase.scfMessagesTable,
      columns: ['message_hash', 'expires_at'],
      where: 'message_hash = ?',
      whereArgs: [envelope.messageHash],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      final existingExpiry = DateTime.parse(
        existing.single['expires_at']! as String,
      );
      if (existingExpiry.isAfter(now)) {
        return false;
      }

      await transaction.delete(
        LocalMessagingDatabase.scfMessagesTable,
        where: 'message_hash = ?',
        whereArgs: [envelope.messageHash],
      );
    }

    await transaction.insert(
      LocalMessagingDatabase.scfMessagesTable,
      ScfEnvelopeModel.toMap(envelope),
    );
    return true;
  }
}
