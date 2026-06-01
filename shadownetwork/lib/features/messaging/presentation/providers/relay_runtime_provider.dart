import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/sos_message_payload.dart';
import '../../data/models/chat_message_payload.dart';
import '../../data/models/relay_payload_codec.dart';
import '../../data/services/scf_service.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/message_moderation_status.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';
import '../../domain/entities/scf_envelope.dart';
import '../../domain/entities/sos_message.dart';
import '../../domain/entities/spam_detection_result.dart';
import '../../domain/repositories/peer_repository.dart';
import '../../domain/repositories/chat_repository.dart';
import '../../domain/repositories/sos_message_repository.dart';
import '../../domain/services/spam_detection_service.dart';
import 'local_messaging_providers.dart';

class RelayRuntimeState {
  const RelayRuntimeState({
    required this.isRunning,
    required this.isSyncing,
    required this.permissionsGranted,
    required this.discoveredPeers,
    required this.connectedPeers,
    required this.lastUpdated,
    this.localPeer,
    this.lastError,
    this.lastReceivedCount = 0,
    this.lastRelayedCount = 0,
  });

  const RelayRuntimeState.initial()
    : isRunning = false,
      isSyncing = false,
      permissionsGranted = true,
      discoveredPeers = 0,
      connectedPeers = 0,
      lastUpdated = null,
      localPeer = null,
      lastError = null,
      lastReceivedCount = 0,
      lastRelayedCount = 0;

  final bool isRunning;
  final bool isSyncing;
  final bool permissionsGranted;
  final int discoveredPeers;
  final int connectedPeers;
  final DateTime? lastUpdated;
  final Peer? localPeer;
  final String? lastError;
  final int lastReceivedCount;
  final int lastRelayedCount;

  RelayRuntimeState copyWith({
    bool? isRunning,
    bool? isSyncing,
    bool? permissionsGranted,
    int? discoveredPeers,
    int? connectedPeers,
    DateTime? lastUpdated,
    Object? localPeer = _sentinel,
    Object? lastError = _sentinel,
    int? lastReceivedCount,
    int? lastRelayedCount,
  }) {
    return RelayRuntimeState(
      isRunning: isRunning ?? this.isRunning,
      isSyncing: isSyncing ?? this.isSyncing,
      permissionsGranted: permissionsGranted ?? this.permissionsGranted,
      discoveredPeers: discoveredPeers ?? this.discoveredPeers,
      connectedPeers: connectedPeers ?? this.connectedPeers,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      localPeer: identical(localPeer, _sentinel)
          ? this.localPeer
          : localPeer as Peer?,
      lastError: identical(lastError, _sentinel)
          ? this.lastError
          : lastError as String?,
      lastReceivedCount: lastReceivedCount ?? this.lastReceivedCount,
      lastRelayedCount: lastRelayedCount ?? this.lastRelayedCount,
    );
  }
}

const _sentinel = Object();

class RelayRuntimeController extends Notifier<RelayRuntimeState> {
  Timer? _syncTimer;
  Timer? _ecbDebounceTimer;
  StreamSubscription<void>? _relayEventSubscription;
  bool _syncInFlight = false;

  @override
  RelayRuntimeState build() {
    ref.onDispose(_dispose);
    return const RelayRuntimeState.initial();
  }

  Future<void> start() async {
    if (state.isRunning) {
      await syncNow(force: false);
      return;
    }

    final transport = ref.read(scfTransportProvider);
    final transportStatus = await transport.getStatus();
    state = state.copyWith(
      isRunning: true,
      permissionsGranted: transportStatus.permissionsGranted,
      discoveredPeers: transportStatus.discoveredPeerCount,
      connectedPeers: transportStatus.connectedPeerCount,
      localPeer: transportStatus.localPeer,
      lastError: null,
    );
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(_syncInterval, (_) {
      unawaited(syncNow(force: false));
    });
    _relayEventSubscription?.cancel();
    _relayEventSubscription = transport.relayEvents.listen((_) {
      _scheduleEmergencyCellBroadcastSync();
    });
    await syncNow(force: true);
  }

  void stop() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _ecbDebounceTimer?.cancel();
    _ecbDebounceTimer = null;
    _relayEventSubscription?.cancel();
    _relayEventSubscription = null;
    state = state.copyWith(
      isRunning: false,
      isSyncing: false,
      discoveredPeers: 0,
      connectedPeers: 0,
    );
  }

  void _scheduleEmergencyCellBroadcastSync() {
    if (!state.isRunning) return;

    _ecbDebounceTimer?.cancel();
    _ecbDebounceTimer = Timer(_ecbDebounceDelay, () {
      unawaited(syncNow(force: true));
    });
  }

  Future<bool> connectToPeer(Peer peer) async {
    final now = DateTime.now();
    try {
      final transport = ref.read(scfTransportProvider);
      final repository = await ref.read(peerRepositoryProvider.future);
      final connectedPeer = await transport.connectPeer(peer);
      await repository.upsertPeer(
        connectedPeer.copyWith(isConnected: true, lastSeenAt: now),
      );
      state = state.copyWith(lastUpdated: now, lastError: null);
      _invalidateViews();
      await syncNow(force: true);
      return true;
    } catch (error) {
      state = state.copyWith(lastUpdated: now, lastError: error.toString());
      return false;
    }
  }

  Future<void> syncNow({bool force = true}) async {
    if (_syncInFlight || (!force && !state.isRunning)) {
      return;
    }

    _syncInFlight = true;
    state = state.copyWith(isSyncing: true, lastError: null);
    final now = DateTime.now();

    try {
      final transport = ref.read(scfTransportProvider);
      final relayService = await ref.read(scfRelayServiceProvider.future);
      final peerRepository = await ref.read(peerRepositoryProvider.future);
      final messageRepository = await ref.read(
        sosMessageRepositoryProvider.future,
      );
      final chatRepository = await ref.read(chatRepositoryProvider.future);
      final scfService = await ref.read(scfServiceProvider.future);
      final spamDetectionService = ref.read(spamDetectionServiceProvider);
      final localPeer = await transport.getLocalPeer();

      final discoveredPeers = await relayService.discoverPeers();
      await _persistPeerSnapshot(peerRepository, discoveredPeers, now);

      final inboundEnvelopes = await relayService.ingestIncomingEnvelopes(
        now: now,
      );
      final receivedCount = await _persistIncomingMessages(
        messageRepository: messageRepository,
        chatRepository: chatRepository,
        scfService: scfService,
        spamDetectionService: spamDetectionService,
        peerRepository: peerRepository,
        localPeer: localPeer,
        envelopes: inboundEnvelopes,
      );

      var relayedCount = 0;
      for (final peer in discoveredPeers) {
        final result = await relayService.relayToPeer(peer, now: now);
        relayedCount += result.sentCount;
        for (final hash in result.sentMessageHashes) {
          await chatRepository.updateOutgoingMessageStatus(
            messageHash: hash,
            localPeerId: localPeer.id,
            status: MessageStatus.relayed,
          );
        }
      }

      final transportStatus = await transport.getStatus();

      state = state.copyWith(
        isRunning: transportStatus.isRunning,
        isSyncing: false,
        permissionsGranted: transportStatus.permissionsGranted,
        discoveredPeers: transportStatus.discoveredPeerCount,
        connectedPeers: transportStatus.connectedPeerCount,
        lastUpdated: now,
        localPeer: transportStatus.localPeer,
        lastError: transportStatus.permissionsGranted
            ? null
            : 'Bluetooth, location, and nearby device permissions are required.',
        lastReceivedCount: receivedCount,
        lastRelayedCount: relayedCount,
      );
      _invalidateViews();
    } catch (error) {
      state = state.copyWith(
        isSyncing: false,
        lastUpdated: now,
        lastError: error.toString(),
      );
    } finally {
      _syncInFlight = false;
    }
  }

  Future<void> _persistPeerSnapshot(
    PeerRepository repository,
    List<Peer> peers,
    DateTime timestamp,
  ) async {
    await repository.markAllDisconnected(timestamp: timestamp);
    for (final peer in peers) {
      await repository.upsertPeer(
        peer.copyWith(
          isConnected: peer.isConnected,
          type: peer.type == PeerType.unknown ? PeerType.relay : peer.type,
          lastSeenAt: timestamp,
        ),
      );
    }
  }

  Future<int> _persistIncomingMessages({
    required SosMessageRepository messageRepository,
    required ChatRepository chatRepository,
    required ScfService scfService,
    required SpamDetectionService spamDetectionService,
    required PeerRepository peerRepository,
    required Peer localPeer,
    required List<ScfEnvelope> envelopes,
  }) async {
    var storedCount = 0;
    for (final envelope in envelopes) {
      try {
        final payload =
            jsonDecode(envelope.payloadJson) as Map<String, Object?>;
        if (RelayPayloadCodec.payloadType(envelope.payloadJson) ==
            ChatMessagePayload.payloadType) {
          final chat = ChatMessagePayload.fromPayload(payload);
          if (chat.recipient.id != localPeer.id) {
            continue;
          }
          final conversation = await chatRepository.openConversation(
            localPeer: localPeer,
            remotePeer: chat.sender,
            relatedSosMessageHash: chat.relatedSosMessageHash,
          );
          final candidate = chat.copyWith(conversationId: conversation.id);
          final recentMessages = await chatRepository.getRecentMessagesBySender(
            senderPeerId: candidate.sender.id,
            since: candidate.createdAt.toUtc().subtract(
              spamDetectionService.window,
            ),
          );
          final moderation = spamDetectionService.classify(
            candidate: _chatSimilaritySample(candidate),
            priorMessages: recentMessages.map(_chatSimilaritySample),
          );
          await chatRepository.saveMessage(
            _withChatModeration(candidate, moderation),
            incrementUnread: true,
          );
          await scfService.consumeDeliveredPayload(envelope.messageHash);
          ref.invalidate(chatMessagesProvider(conversation.id));
          storedCount++;
          continue;
        }
        final decoded = SosMessagePayload.fromPayload(
          payload,
        ).copyWith(status: MessageStatus.received);
        await peerRepository.upsertPeer(
          decoded.sender.copyWith(
            isConnected: false,
            type: decoded.sender.type == PeerType.unknown
                ? PeerType.civilian
                : decoded.sender.type,
          ),
        );
        final recentMessages = await messageRepository
            .getRecentMessagesBySender(
              senderPeerId: decoded.sender.id,
              since: decoded.createdAt.toUtc().subtract(
                spamDetectionService.window,
              ),
            );
        final moderation = spamDetectionService.classify(
          candidate: _sosSimilaritySample(decoded),
          priorMessages: recentMessages.map(_sosSimilaritySample),
        );
        await messageRepository.saveMessage(
          _withSosModeration(decoded, moderation),
        );
        storedCount++;
      } on FormatException {
        continue;
      }
    }

    return storedCount;
  }

  void _invalidateViews() {
    ref.invalidate(nearbyPeersProvider);
    ref.invalidate(sosMessagesProvider);
    ref.invalidate(conversationsProvider);
  }

  void _dispose() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _ecbDebounceTimer?.cancel();
    _ecbDebounceTimer = null;
    _relayEventSubscription?.cancel();
    _relayEventSubscription = null;
  }
}

MessageSimilaritySample _sosSimilaritySample(SosMessage message) {
  return MessageSimilaritySample(
    senderPeerId: message.sender.id,
    body: message.body,
    createdAt: message.createdAt,
    messageId: message.id,
    messageHash: message.messageHash,
  );
}

MessageSimilaritySample _chatSimilaritySample(ChatMessage message) {
  return MessageSimilaritySample(
    senderPeerId: message.sender.id,
    body: message.body,
    createdAt: message.createdAt,
    messageId: message.id,
    messageHash: message.messageHash,
  );
}

SosMessage _withSosModeration(SosMessage message, SpamDetectionResult result) {
  return message.copyWith(
    moderationStatus: result.status,
    moderationReason: result.reason,
    moderationScore: result.status == MessageModerationStatus.spam
        ? result.score
        : null,
  );
}

ChatMessage _withChatModeration(
  ChatMessage message,
  SpamDetectionResult result,
) {
  return message.copyWith(
    moderationStatus: result.status,
    moderationReason: result.reason,
    moderationScore: result.status == MessageModerationStatus.spam
        ? result.score
        : null,
  );
}

final relayRuntimeProvider =
    NotifierProvider<RelayRuntimeController, RelayRuntimeState>(
      RelayRuntimeController.new,
    );

const _syncInterval = Duration(seconds: 4);
const _ecbDebounceDelay = Duration(milliseconds: 350);
