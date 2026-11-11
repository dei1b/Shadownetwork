import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/sos_message_payload.dart';
import '../../data/models/chat_message_payload.dart';
import '../../data/models/relay_payload_codec.dart';
import '../../data/models/secure_chat_message_payload.dart';
import '../../data/models/secure_sos_message_payload.dart';
import '../../data/services/scf_service.dart';
import '../../data/services/android_scf_transport.dart';
import '../../data/services/incoming_message_notifications.dart';
import '../../domain/services/relay_power_policy.dart';
import '../../../validation/presentation/providers/validation_session_provider.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/message_moderation_status.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_location_share.dart';
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
import '../../../trust/domain/repositories/trust_repository.dart';
import '../../../trust/domain/entities/device_trust_status.dart';
import '../../../trust/presentation/providers/device_access_provider.dart';
import '../../../validation/domain/entities/validation_event.dart';
import '../../../validation/domain/repositories/validation_metrics_repository.dart';
import 'local_messaging_providers.dart';
import 'nearby_peer_sightings_provider.dart';
import 'peer_location_providers.dart';

final incomingMessageNotificationsProvider =
    Provider<IncomingMessageNotifications?>((ref) {
      return Platform.isAndroid ? const IncomingMessageNotifications() : null;
    });

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
  StreamSubscription<void>? _relayStopSubscription;
  int _epoch = 0;
  bool _syncInFlight = false;
  Future<int>? _receiveTask;
  bool _receiveRequested = false;
  bool _enabled = false;
  bool _background = true;
  Duration _syncInterval = const Duration(seconds: 12);

  void setBackground(bool value) {
    _background = value;
    if (_enabled && !_syncInFlight) unawaited(syncNow());
  }

  void _scheduleNextSync() {
    _syncTimer?.cancel();
    if (_enabled) {
      _syncTimer = Timer(_syncInterval, () => unawaited(syncNow(force: false)));
    }
  }

  @override
  RelayRuntimeState build() {
    ref.onDispose(_dispose);
    return const RelayRuntimeState.initial();
  }

  Future<void> start() async {
    if (_enabled) {
      await syncNow(force: false);
      return;
    }

    _enabled = true;
    final transport = ref.read(scfTransportProvider);
    final transportStatus = await transport.getStatus();
    state = state.copyWith(
      isRunning: transportStatus.isRunning,
      permissionsGranted: transportStatus.permissionsGranted,
      discoveredPeers: transportStatus.discoveredPeerCount,
      connectedPeers: transportStatus.connectedPeerCount,
      localPeer: transportStatus.localPeer,
      lastError: null,
    );
    _syncTimer?.cancel();

    _relayEventSubscription?.cancel();
    _relayStopSubscription?.cancel();
    if (transport is AndroidScfTransport) {
      _relayStopSubscription = transport.stopRequests.listen(
        (_) => stop(stopTransport: false),
      );
    }
    _relayEventSubscription = transport.relayEvents.listen((_) {
      // An outbound ACK wait must not prevent us acknowledging inbound data.
      unawaited(
        receiveIncoming().catchError((Object error) {
          state = state.copyWith(lastError: error.toString());
          return 0;
        }),
      );
      _scheduleEmergencyCellBroadcastSync();
    });
    await syncNow(force: true);
  }

  void stop({bool stopTransport = true}) {
    _epoch++;
    _enabled = false;
    _relayStopSubscription?.cancel();
    _relayStopSubscription = null;
    if (stopTransport) {
      final transport = ref.read(scfTransportProvider);
      if (transport is AndroidScfTransport) {
        unawaited(
          transport.stop().catchError((Object error) {
            state = state.copyWith(lastError: error.toString());
          }),
        );
      }
    }
    _syncTimer?.cancel();
    _syncTimer = null;
    _ecbDebounceTimer?.cancel();
    _ecbDebounceTimer = null;
    _relayEventSubscription?.cancel();
    _relayEventSubscription = null;
    ref.read(nearbyPeerSightingsProvider.notifier).replace(const []);
    state = state.copyWith(
      isRunning: false,
      isSyncing: false,
      discoveredPeers: 0,
      connectedPeers: 0,
    );
  }

  void _scheduleEmergencyCellBroadcastSync() {
    if (!_enabled) return;

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
    if (_syncInFlight || (!force && !_enabled)) {
      return;
    }

    _syncInFlight = true;
    final epoch = _epoch;
    state = state.copyWith(isSyncing: true, lastError: null);
    final now = DateTime.now();

    try {
      final transport = ref.read(scfTransportProvider);
      final relayService = await ref.read(scfRelayServiceProvider.future);
      final peerRepository = await ref.read(peerRepositoryProvider.future);
      final chatRepository = await ref.read(chatRepositoryProvider.future);
      final scfService = await ref.read(scfServiceProvider.future);
      final localPeer = await transport.getLocalPeer();
      final metrics = await ref.read(
        validationMetricsRepositoryProvider.future,
      );

      final receivedCount = await receiveIncoming();

      final expiredHashes = await scfService.pruneExpiredHashes(now: now);
      for (final messageHash in expiredHashes) {
        await metrics.captureEvent(
          type: ValidationEventType.envelopeExpired,
          occurredAt: now,
          messageHash: messageHash,
        );
      }

      final hasQueuedMessages = await scfService.hasRecentQueuedEnvelopes();
      final battery = await ref.read(batterySamplerProvider).sample();
      final power = RelayPowerPolicy.resolve(
        background: _background,
        hasQueuedMessages: hasQueuedMessages,
        batteryPercent: battery?.percent,
        charging: battery?.isCharging ?? false,
      );
      _syncInterval = power.syncInterval;
      if (transport is AndroidScfTransport) {
        await transport.setPowerProfile(power.profile);
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
      if (epoch != _epoch) return;
      ref.read(nearbyPeerSightingsProvider.notifier).replace(discoveredPeers);
      await _persistPeerSnapshot(peerRepository, discoveredPeers, now);

      var relayedCount = 0;
      for (final peer in discoveredPeers) {
        if (epoch != _epoch) return;
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
        lastError: !transportStatus.permissionsGranted
            ? 'Bluetooth, location, and nearby device permissions are required.'
            : !transportStatus.isRunning
            ? 'Relay is paused. Open the app and check Bluetooth and Wi-Fi.'
            : null,
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
      _scheduleNextSync();
    }
  }

  Future<int> receiveIncoming() {
    _receiveRequested = true;
    return _receiveTask ??= _drainIncoming().whenComplete(
      () => _receiveTask = null,
    );
  }

  Future<int> _drainIncoming() async {
    var count = 0;
    do {
      _receiveRequested = false;
      final relayService = await ref.read(scfRelayServiceProvider.future);
      await relayService.ingestIncomingEnvelopes();
      final scfService = await ref.read(scfServiceProvider.future);
      final envelopes = await scfService.getPendingInbox();
      if (envelopes.isEmpty) continue;
      count += await _persistIncomingMessages(
        messageRepository: await ref.read(sosMessageRepositoryProvider.future),
        chatRepository: await ref.read(chatRepositoryProvider.future),
        scfService: scfService,
        spamDetectionService: ref.read(spamDetectionServiceProvider),
        peerRepository: await ref.read(peerRepositoryProvider.future),
        localPeer: await ref.read(scfTransportProvider).getLocalPeer(),
        localIdentity: await ref.read(deviceCryptoIdentityProvider.future),
        encryptionService: ref.read(messageEncryptionServiceProvider),
        trustRepository: await ref.read(trustRepositoryProvider.future),
        metrics: await ref.read(validationMetricsRepositoryProvider.future),
        envelopes: envelopes,
      );
    } while (_receiveRequested);
    if (count > 0) {
      state = state.copyWith(lastReceivedCount: count);
      _invalidateViews();
    }
    return count;
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
    final notifications = ref.read(incomingMessageNotificationsProvider);
    bool? canReceiveSos;
    for (final envelope in envelopes) {
      try {
        final isChat = await RelayPayloadCodec.decodeFields(
          () =>
              RelayPayloadCodec.payloadType(envelope.payloadJson) ==
              ChatMessagePayload.payloadType,
        );
        final senderTrust = await RelayPayloadCodec.decodeFields(
          () => ref
              .read(messageAuthenticationServiceProvider)
              .authenticate(envelope.payloadJson, trustRepository),
        );
        await scfService.updateOriginTrustStatus(
          messageHash: envelope.messageHash,
          status: senderTrust.status,
        );
        final payload = await RelayPayloadCodec.decodeFields(
          () => jsonDecode(envelope.payloadJson) as Map<String, Object?>,
        );
        final targetPeerId = await RelayPayloadCodec.decodeFields(
          () => SosMessagePayload.targetPeerId(envelope.payloadJson),
        );
        if (targetPeerId != null && targetPeerId != localPeer.id) {
          await scfService.discardPendingMessage(envelope.messageHash);
          continue;
        }
        if (isChat) {
          final chat = await RelayPayloadCodec.decodeFields(
            () async =>
                SecureChatMessagePayload.supportsVersion(
                  payload['schema_version'],
                )
                ? await SecureChatMessagePayload.decode(
                    payload,
                    localPeerId: localPeer.id,
                    encryptionService: encryptionService,
                    localIdentity: localIdentity,
                  )
                : ChatMessagePayload.fromPayload(payload),
          );
          if (chat.conversationId == PeerLocationShare.conversationId) {
            if (payload['schema_version'] != PeerLocationShare.schemaVersion ||
                senderTrust.status != DeviceTrustStatus.approved ||
                chat.sender.id.toLowerCase() == localPeer.id.toLowerCase() ||
                (await trustRepository.getDevice(localPeer.id)).status !=
                    DeviceTrustStatus.approved) {
              await scfService.consumeDeliveredPayload(envelope.messageHash);
              continue;
            }
            final approval = await trustRepository.getMetadata();
            if (approval == null || !approval.signatureVerified) {
              await scfService.consumeDeliveredPayload(envelope.messageHash);
              continue;
            }
            final share = PeerLocationShare.fromChat(
              chat,
              ownerName: senderTrust.ownerName,
              now: DateTime.now().toUtc(),
              expiresAt: approval.expiresAt.isBefore(envelope.expiresAt)
                  ? approval.expiresAt
                  : envelope.expiresAt,
            );
            ref.read(sharedPeerLocationsProvider.notifier).record(share);
            await scfService.consumeDeliveredPayload(envelope.messageHash);
            storedCount++;
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
          final inserted = await chatRepository.saveMessage(
            _withChatModeration(candidate, moderation),
            incrementUnread: true,
          );
          if (inserted && senderTrust.status != DeviceTrustStatus.revoked) {
            if (chat.sender.id != localPeer.id &&
                moderation.status == MessageModerationStatus.normal) {
              await notifications?.show(
                messageHash: envelope.messageHash,
                isSos: false,
              );
            }
            await metrics.captureEvent(
              type: ValidationEventType.envelopeDelivered,
              messageHash: envelope.messageHash,
              transferId: envelope.transferId,
              payloadType: envelope.payloadType,
              peerId: localPeer.id,
              hopCount: envelope.hopCount,
            );
          }
          await scfService.consumeDeliveredPayload(envelope.messageHash);
          if (!inserted) continue;
          ref.invalidate(chatMessagesProvider(conversation.id));
          storedCount++;
          continue;
        }
        canReceiveSos ??= await ref.read(canReceiveSosProvider)();
        if (!canReceiveSos) {
          // Keep the forwarding copy so a rescuer can receive it later.
          await scfService.discardPendingMessage(envelope.messageHash);
          continue;
        }
        final isSecureSos = SecureSosMessagePayload.supportsVersion(
          payload['schema_version'],
        );
        final incoming = await RelayPayloadCodec.decodeFields(
          () async => isSecureSos
              ? await SecureSosMessagePayload.decode(
                  payload,
                  localPeerId: localPeer.id,
                  encryptionService: encryptionService,
                  localIdentity: localIdentity,
                )
              : SosMessagePayload.fromPayload(
                  payload,
                  localPeerId: localPeer.id,
                ),
        );
        final isLocalOrigin = incoming.sender.id == localPeer.id;
        final decoded = incoming.copyWith(
          status: MessageStatus.received,
          receivedAt: isLocalOrigin ? null : envelope.receivedAt,
          receivedFromPeerId: isLocalOrigin
              ? null
              : envelope.receivedFromPeerId,
          receivedTransport: isLocalOrigin ? null : envelope.receivedTransport,
          transferId: isLocalOrigin ? null : envelope.transferId,
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
        final inserted = await messageRepository.saveMessage(
          _withSosModeration(decoded, moderation),
        );
        if (senderTrust.status != DeviceTrustStatus.revoked) {
          if (inserted &&
              !isLocalOrigin &&
              moderation.status == MessageModerationStatus.normal) {
            await notifications?.show(
              messageHash: envelope.messageHash,
              isSos: true,
            );
          }
          await metrics.captureEvent(
            type: ValidationEventType.envelopeDelivered,
            messageHash: envelope.messageHash,
            transferId: envelope.transferId,
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
        await scfService.discardPendingMessage(envelope.messageHash);
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
    _epoch++;
    _enabled = false;
    _relayStopSubscription?.cancel();
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

const _ecbDebounceDelay = Duration(milliseconds: 350);
