import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/sos_message_payload.dart';
import '../../data/models/chat_message_payload.dart';
import '../../data/models/relay_payload_codec.dart';
import '../../data/models/secure_chat_message_payload.dart';
import '../../data/models/secure_sos_message_payload.dart';
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
import '../../../security/data/services/message_encryption_service.dart';
import '../../../security/domain/entities/device_crypto_identity.dart';
import '../../../trust/domain/entities/device_trust_record.dart';
import '../../../trust/domain/repositories/trust_repository.dart';
import '../../../trust/domain/entities/device_trust_status.dart';
import '../../../validation/domain/entities/validation_event.dart';
import '../../../validation/domain/repositories/validation_metrics_repository.dart';
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
    final now = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();
    try {
      final transport = ref.read(scfTransportProvider);
      final repository = await ref.read(peerRepositoryProvider.future);
      final metrics = await ref.read(
        validationMetricsRepositoryProvider.future,
      );
      await metrics.captureEvent(
        type: ValidationEventType.connectionStarted,
        occurredAt: now,
        peerId: peer.id,
        transport: peer.transport,
      );
      final connectedPeer = await transport.connectPeer(peer);
      stopwatch.stop();
      await repository.upsertPeer(
        connectedPeer.copyWith(isConnected: true, lastSeenAt: now),
      );
      await metrics.captureEvent(
        type: ValidationEventType.connectionSucceeded,
        peerId: peer.id,
        transport: connectedPeer.transport ?? peer.transport,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
      state = state.copyWith(lastUpdated: now, lastError: null);
      _invalidateViews();
      await syncNow(force: true);
      return true;
    } catch (error) {
      stopwatch.stop();
      final metrics = await ref.read(
        validationMetricsRepositoryProvider.future,
      );
      await metrics.captureEvent(
        type: ValidationEventType.connectionFailed,
        peerId: peer.id,
        transport: peer.transport,
        latencyMs: stopwatch.elapsedMilliseconds,
        error: error.toString(),
      );
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
      final localIdentity = await ref.read(deviceCryptoIdentityProvider.future);
      final encryptionService = ref.read(messageEncryptionServiceProvider);
      final trustRepository = await ref.read(trustRepositoryProvider.future);
      final metrics = await ref.read(
        validationMetricsRepositoryProvider.future,
      );

      final expiredHashes = await scfService.pruneExpiredHashes(now: now);
      for (final messageHash in expiredHashes) {
        await metrics.captureEvent(
          type: ValidationEventType.envelopeExpired,
          occurredAt: now,
          messageHash: messageHash,
        );
      }

      final discoveryStartedAt = DateTime.now().toUtc();
      late final List<Peer> discoveredPeers;
      try {
        discoveredPeers = await relayService.discoverPeers();
        final discoveryEndedAt = DateTime.now().toUtc();
        await metrics.captureDiscoveryAttempt(
          startedAt: discoveryStartedAt,
          endedAt: discoveryEndedAt,
          discoveredCount: discoveredPeers.length,
          success: discoveredPeers.isNotEmpty,
        );
        for (final peer in discoveredPeers) {
          await metrics.captureEvent(
            type: ValidationEventType.peerDiscovered,
            occurredAt: discoveryEndedAt,
            peerId: peer.id,
            transport: peer.transport,
            metadata: {'signal_strength': peer.signalStrength},
          );
        }
      } catch (error) {
        await metrics.captureDiscoveryAttempt(
          startedAt: discoveryStartedAt,
          endedAt: DateTime.now().toUtc(),
          discoveredCount: 0,
          success: false,
          error: error.toString(),
        );
        rethrow;
      }
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
        localIdentity: localIdentity,
        encryptionService: encryptionService,
        trustRepository: trustRepository,
        metrics: metrics,
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
    required DeviceCryptoIdentity localIdentity,
    required MessageEncryptionService encryptionService,
    required TrustRepository trustRepository,
    required ValidationMetricsRepository metrics,
    required List<ScfEnvelope> envelopes,
  }) async {
    var storedCount = 0;
    for (final envelope in envelopes) {
      try {
        final senderPeerId = RelayPayloadCodec.senderPeerId(
          envelope.payloadJson,
        );
        final senderTrust = senderPeerId == null
            ? const DeviceTrustRecord.unknown('unknown')
            : await trustRepository.getDevice(senderPeerId);
        await scfService.updateOriginTrustStatus(
          messageHash: envelope.messageHash,
          status: senderTrust.status,
        );
        final payload =
            jsonDecode(envelope.payloadJson) as Map<String, Object?>;
        if (RelayPayloadCodec.payloadType(envelope.payloadJson) ==
            ChatMessagePayload.payloadType) {
          final chat =
              payload['schema_version'] ==
                  SecureChatMessagePayload.schemaVersion
              ? await SecureChatMessagePayload.decode(
                  payload,
                  localPeerId: localPeer.id,
                  encryptionService: encryptionService,
                  localIdentity: localIdentity,
                )
              : ChatMessagePayload.fromPayload(payload);
          if (chat.recipient.id != localPeer.id) {
            continue;
          }
          final conversation = await chatRepository.openConversation(
            localPeer: localPeer,
            remotePeer: chat.sender,
            relatedSosMessageHash: chat.relatedSosMessageHash,
          );
          final candidate = chat.copyWith(
            conversationId: conversation.id,
            trustStatus: senderTrust.status,
            trustRole: senderTrust.role,
            trustOwnerName: senderTrust.ownerName,
          );
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
          if (senderTrust.status != DeviceTrustStatus.revoked) {
            await metrics.captureEvent(
              type: ValidationEventType.envelopeDelivered,
              messageHash: envelope.messageHash,
              payloadType: envelope.payloadType,
              peerId: localPeer.id,
              hopCount: envelope.hopCount,
            );
          }
          await scfService.consumeDeliveredPayload(envelope.messageHash);
          ref.invalidate(chatMessagesProvider(conversation.id));
          storedCount++;
          continue;
        }
        final isSecureSos =
            payload['schema_version'] == SecureSosMessagePayload.schemaVersion;
        final targetPeerId = isSecureSos
            ? SecureSosMessagePayload.targetPeerId(envelope.payloadJson)
            : SosMessagePayload.targetPeerId(envelope.payloadJson);
        if (targetPeerId != null && targetPeerId != localPeer.id) {
          continue;
        }
        final decoded =
            (isSecureSos
                    ? await SecureSosMessagePayload.decode(
                        payload,
                        localPeerId: localPeer.id,
                        encryptionService: encryptionService,
                        localIdentity: localIdentity,
                      )
                    : SosMessagePayload.fromPayload(
                        payload,
                        localPeerId: localPeer.id,
                      ))
                .copyWith(
                  status: MessageStatus.received,
                  trustStatus: senderTrust.status,
                  trustRole: senderTrust.role,
                  trustOwnerName: senderTrust.ownerName,
                );
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
        if (senderTrust.status != DeviceTrustStatus.revoked) {
          await metrics.captureEvent(
            type: ValidationEventType.envelopeDelivered,
            messageHash: envelope.messageHash,
            payloadType: envelope.payloadType,
            peerId: localPeer.id,
            hopCount: envelope.hopCount,
          );
        }
        if (decoded.recipient?.id == localPeer.id) {
          await scfService.consumeDeliveredPayload(envelope.messageHash);
        }
        storedCount++;
      } on FormatException catch (error) {
        await metrics.captureEvent(
          type: ValidationEventType.envelopeRejected,
          messageHash: envelope.messageHash,
          payloadType: envelope.payloadType,
          hopCount: envelope.hopCount,
          error: error.message.toString(),
          metadata: const {'phase': 'decode'},
        );
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
