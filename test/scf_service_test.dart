import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/messaging/data/models/sos_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/models/chat_message_payload.dart';
import 'package:shadownetwork/features/messaging/data/services/scf_service.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/chat_message.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/scf_peer_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_trust_status.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late ScfService service;

  Future<void> openService() async {
    final database = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(database.close);
    service = ScfService(database: database);
  }

  test('deduplicates active payloads by deterministic message hash', () async {
    await openService();
    final message = _message();
    final now = DateTime.utc(2026, 5, 2, 5);

    final firstStore = await service.storeMessage(message, receivedAt: now);
    final duplicateStore = await service.storeMessage(
      message.copyWith(status: MessageStatus.delivered),
      receivedAt: now.add(const Duration(minutes: 1)),
    );

    final envelopes = await service.getStoredEnvelopes(now: now);

    expect(firstStore, isTrue);
    expect(duplicateStore, isFalse);
    expect(envelopes, hasLength(1));
    expect(
      envelopes.single.messageHash,
      SosMessagePayload.messageHash(message),
    );
  });

  test('expires payloads by TTL and allows re-store after expiry', () async {
    await openService();
    final message = _message();
    final now = DateTime.utc(2026, 5, 2, 5);

    await service.storeMessage(
      message,
      receivedAt: now,
      ttl: const Duration(minutes: 5),
    );

    final expiredCount = await service.pruneExpired(
      now: now.add(const Duration(minutes: 6)),
    );
    final storedAfterExpiry = await service.storeMessage(
      message,
      receivedAt: now.add(const Duration(minutes: 7)),
      ttl: const Duration(minutes: 5),
    );

    expect(expiredCount, 1);
    expect(storedAfterExpiry, isTrue);
  });

  test('increments hop count when preparing outbound payloads', () async {
    await openService();
    final message = _message();
    final now = DateTime.utc(2026, 5, 2, 5);

    await service.storeMessage(message, receivedAt: now, hopCount: 2);

    final outbound = await service.prepareOutboundForPeer(
      'peer-2',
      now: now.add(const Duration(minutes: 1)),
    );
    final status = await service.getPeerStatus(
      messageHash: SosMessagePayload.messageHash(message),
      peerId: 'peer-2',
    );
    final relayedMessage = SosMessagePayload.fromPayload(
      jsonDecode(outbound.single.payloadJson) as Map<String, Object?>,
    );

    expect(outbound, hasLength(1));
    expect(outbound.single.hopCount, 3);
    expect(status?.status, ScfPeerStatus.offered);
    expect(status?.attemptCount, 1);
    expect(relayedMessage.hopCount, 3);
    expect(relayedMessage.messageHash, SosMessagePayload.messageHash(message));
  });

  test('updates per-peer status and skips delivered peers', () async {
    await openService();
    final message = _message();
    final now = DateTime.utc(2026, 5, 2, 5);
    final hash = SosMessagePayload.messageHash(message);

    await service.storeMessage(message, receivedAt: now);
    await service.prepareOutboundForPeer(
      'peer-2',
      now: now.add(const Duration(minutes: 1)),
    );
    await service.updatePeerStatus(
      messageHash: hash,
      peerId: 'peer-2',
      status: ScfPeerStatus.delivered,
      updatedAt: now.add(const Duration(minutes: 2)),
    );

    final outbound = await service.prepareOutboundForPeer(
      'peer-2',
      now: now.add(const Duration(minutes: 3)),
    );
    final status = await service.getPeerStatus(
      messageHash: hash,
      peerId: 'peer-2',
    );

    expect(outbound, isEmpty);
    expect(status?.status, ScfPeerStatus.delivered);
    expect(status?.attemptCount, 1);
  });

  test('failed peer status can be retried and increments attempts', () async {
    await openService();
    final message = _message();
    final now = DateTime.utc(2026, 5, 2, 5);
    final hash = SosMessagePayload.messageHash(message);

    await service.storeMessage(message, receivedAt: now);
    await service.prepareOutboundForPeer('peer-2', now: now);
    await service.updatePeerStatus(
      messageHash: hash,
      peerId: 'peer-2',
      status: ScfPeerStatus.failed,
      updatedAt: now.add(const Duration(minutes: 1)),
      lastError: 'connection lost',
    );
    await service.prepareOutboundForPeer(
      'peer-2',
      now: now.add(const Duration(minutes: 2)),
    );

    final status = await service.getPeerStatus(
      messageHash: hash,
      peerId: 'peer-2',
    );

    expect(status?.status, ScfPeerStatus.offered);
    expect(status?.attemptCount, 2);
  });

  test(
    'queues and relays targeted chat payloads without changing recipient',
    () async {
      await openService();
      final now = DateTime.utc(2026, 5, 25, 10);
      final chat = ChatMessage(
        id: 'chat-1',
        conversationId: 'conversation-peer-1-peer-2',
        sender: _message().sender,
        recipient: const Peer(
          id: 'peer-2',
          name: 'Recipient',
          type: PeerType.responder,
          isConnected: false,
        ),
        body: 'Proceed to the covered court.',
        status: MessageStatus.queued,
        createdAt: now,
        ttl: const Duration(hours: 2),
      );

      await service.storeChatMessage(chat, receivedAt: now);
      final outbound = await service.prepareOutboundForPeer(
        'relay-peer',
        now: now.add(const Duration(minutes: 1)),
      );
      final relayedChat = ChatMessagePayload.fromPayload(
        jsonDecode(outbound.single.payloadJson) as Map<String, Object?>,
      );

      expect(outbound.single.payloadType, ChatMessagePayload.payloadType);
      expect(relayedChat.recipient.id, 'peer-2');
      expect(relayedChat.hopCount, 1);
      expect(relayedChat.messageHash, ChatMessagePayload.messageHash(chat));

      await service.consumeDeliveredPayload(relayedChat.messageHash!);
      expect(
        await service.getStoredEnvelopes(
          now: now.add(const Duration(minutes: 2)),
        ),
        isEmpty,
      );
    },
  );

  test('does not relay payloads originating from a revoked device', () async {
    await openService();
    final message = _message();
    final now = DateTime.utc(2026, 5, 2, 5);
    final hash = SosMessagePayload.messageHash(message);

    await service.storeMessage(message, receivedAt: now);
    await service.updateOriginTrustStatus(
      messageHash: hash,
      status: DeviceTrustStatus.revoked,
    );

    final outbound = await service.prepareOutboundForPeer(
      'peer-2',
      now: now.add(const Duration(minutes: 1)),
    );
    final retained = await service.getStoredEnvelopes(
      now: now.add(const Duration(minutes: 1)),
    );

    expect(outbound, isEmpty);
    expect(retained, hasLength(1));
  });
}

SosMessage _message() {
  return SosMessage(
    id: 'sos-1',
    sender: const Peer(
      id: 'peer-1',
      name: 'Responder 1',
      type: PeerType.responder,
      isConnected: true,
    ),
    body: 'Need medical assistance.',
    category: Category.medical,
    status: MessageStatus.queued,
    createdAt: DateTime.utc(2026, 5, 2, 5, 30),
    latitude: 7.3026,
    longitude: 125.6888,
    gpsAccuracyMeters: 6.5,
    ttl: const Duration(hours: 6),
  );
}
