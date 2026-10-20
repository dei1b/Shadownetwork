import 'dart:math';

import '../../domain/entities/envelope_transfer_result.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/scf_envelope.dart';
import '../../domain/entities/scf_peer_status.dart';
import '../../domain/services/scf_transport.dart';
import '../../../trust/domain/entities/device_trust_status.dart';
import '../../../validation/domain/entities/validation_event.dart';
import '../../../validation/domain/repositories/validation_metrics_repository.dart';
import '../models/relay_payload_codec.dart';
import 'scf_service.dart';

class ScfRelayResult {
  const ScfRelayResult({
    required this.peerId,
    required this.sentCount,
    required this.failedCount,
    required this.sentMessageHashes,
    this.lastError,
  });

  final String peerId;
  final int sentCount;
  final int failedCount;
  final List<String> sentMessageHashes;
  final String? lastError;
}

class ScfRelayService {
  const ScfRelayService({
    required ScfService scfService,
    required ScfTransport transport,
    this.originTrustResolver,
    this.metricsRecorder,
  }) : _scfService = scfService,
       _transport = transport;

  final ScfService _scfService;
  final ScfTransport _transport;
  final Future<DeviceTrustStatus> Function(String payloadJson)?
  originTrustResolver;
  final ValidationMetricsRepository? metricsRecorder;

  Future<List<Peer>> discoverPeers() {
    return _transport.discoverPeers();
  }

  Future<int> ingestIncoming({DateTime? now}) async {
    final envelopes = await ingestIncomingEnvelopes(now: now);
    return envelopes.length;
  }

  Future<List<ScfEnvelope>> ingestIncomingEnvelopes({DateTime? now}) async {
    final envelopes = await _transport.receiveEnvelopes();
    final storedEnvelopes = <ScfEnvelope>[];

    for (final envelope in envelopes) {
      var accepted = false;
      try {
        final messageCreatedAt = RelayPayloadCodec.createdAt(
          envelope.payloadJson,
        );
        await metricsRecorder?.captureEvent(
          type: ValidationEventType.envelopeReceived,
          occurredAt: now,
          messageHash: envelope.messageHash,
          transferId: envelope.transferId,
          peerId: envelope.receivedFromPeerId,
          transport: envelope.receivedTransport,
          payloadType: envelope.payloadType,
          hopCount: envelope.hopCount,
          metadata: {
            if (messageCreatedAt != null)
              'message_created_at': messageCreatedAt.toIso8601String(),
          },
        );
        // Authenticate before writing or acknowledging. Invalid signatures never enter the relay queue.
        final trustStatus = await originTrustResolver?.call(
          envelope.payloadJson,
        );
        final stored = await _scfService.storeEnvelope(envelope, now: now);
        final activeDuplicate =
            !stored &&
            !envelope.isExpired((now ?? DateTime.now()).toUtc()) &&
            await _scfService.containsActiveEnvelope(
              envelope.messageHash,
              now: now,
            );
        if (stored || activeDuplicate) {
          accepted = true;
          if (trustStatus != null) {
            await _scfService.updateOriginTrustStatus(
              messageHash: envelope.messageHash,
              status: trustStatus,
            );
            if (trustStatus == DeviceTrustStatus.revoked) {
              accepted = false;
              await metricsRecorder?.captureEvent(
                type: ValidationEventType.envelopeRejected,
                occurredAt: now,
                messageHash: envelope.messageHash,
                transferId: envelope.transferId,
                payloadType: envelope.payloadType,
                hopCount: envelope.hopCount,
                error: 'Origin device is revoked; retained in quarantine.',
              );
            }
          }
          // Quarantined records still need to reach the runtime's local view.
          if (stored) storedEnvelopes.add(envelope);
        } else {
          await metricsRecorder?.captureEvent(
            type: ValidationEventType.envelopeRejected,
            occurredAt: now,
            messageHash: envelope.messageHash,
            transferId: envelope.transferId,
            payloadType: envelope.payloadType,
            hopCount: envelope.hopCount,
            error: 'Expired SCF envelope.',
          );
        }
      } catch (error) {
        accepted = false;
        await metricsRecorder?.captureEvent(
          type: ValidationEventType.envelopeRejected,
          messageHash: envelope.messageHash,
          transferId: envelope.transferId,
          peerId: envelope.receivedFromPeerId,
          transport: envelope.receivedTransport,
          error: error.toString(),
          metadata: const {'phase': 'receive'},
        );
      }
      // ACK delivery failure must not discard an already-persisted receipt.
      // The sender may retry; an active duplicate will be acknowledged again.
      try {
        await _transport.acknowledgeEnvelope(
          envelope: envelope,
          accepted: accepted,
        );
      } catch (error) {
        await metricsRecorder?.captureEvent(
          type: ValidationEventType.envelopeRejected,
          messageHash: envelope.messageHash,
          transferId: envelope.transferId,
          peerId: envelope.receivedFromPeerId,
          transport: envelope.receivedTransport,
          error: error.toString(),
          metadata: const {'phase': 'ack_send'},
        );
      }
    }

    return storedEnvelopes;
  }

  Future<ScfRelayResult> relayToPeer(
    Peer peer, {
    DateTime? now,
    int limit = 50,
  }) async {
    final outbound = await _scfService.prepareOutboundForPeer(
      peer.id,
      now: now,
      limit: limit,
    );

    var sentCount = 0;
    var failedCount = 0;
    String? lastError;
    final sentMessageHashes = <String>[];

    for (final queuedEnvelope in outbound) {
      // A retry of the same SOS is a new attempt, not a new logical message.
      final envelope = queuedEnvelope.copyWith(transferId: _newTransferId());
      await metricsRecorder?.captureEvent(
        type: ValidationEventType.envelopeOffered,
        occurredAt: now,
        messageHash: envelope.messageHash,
        transferId: envelope.transferId,
        payloadType: envelope.payloadType,
        peerId: peer.id,
        transport: peer.transport,
        hopCount: envelope.hopCount,
      );
      final stopwatch = Stopwatch()..start();
      var sentRecorded = false;
      try {
        final trustStatus = await originTrustResolver?.call(
          envelope.payloadJson,
        );
        if (trustStatus != null) {
          await _scfService.updateOriginTrustStatus(
            messageHash: envelope.messageHash,
            status: trustStatus,
          );
          if (trustStatus == DeviceTrustStatus.revoked) {
            throw const FormatException(
              'Origin device is revoked; retained in quarantine.',
            );
          }
        }
        final transfer = await _transport.sendEnvelope(
          peer: peer,
          envelope: envelope,
        );
        stopwatch.stop();
        if (transfer.transferId != envelope.transferId ||
            !transfer.acknowledged ||
            transfer.latencyMs < 0) {
          throw EnvelopeTransferException(
            transferId: envelope.transferId!,
            message: 'Transport did not confirm storage for this transfer.',
            code: 'invalid_ack',
            transport: transfer.transport,
            sentAt: transfer.sentAt,
            latencyMs: stopwatch.elapsedMilliseconds,
          );
        }
        await _scfService.updatePeerStatus(
          messageHash: envelope.messageHash,
          peerId: peer.id,
          status: ScfPeerStatus.sent,
          updatedAt: transfer.acknowledgedAt,
        );
        sentCount++;
        sentMessageHashes.add(envelope.messageHash);
        await metricsRecorder?.captureEvent(
          type: ValidationEventType.envelopeSent,
          occurredAt: transfer.sentAt,
          messageHash: envelope.messageHash,
          transferId: envelope.transferId,
          payloadType: envelope.payloadType,
          peerId: peer.id,
          transport: transfer.transport,
          hopCount: envelope.hopCount,
          fallbackUsed: transfer.fallbackUsed,
        );
        sentRecorded = true;
        await metricsRecorder?.captureEvent(
          type: ValidationEventType.envelopeAcknowledged,
          occurredAt: transfer.acknowledgedAt,
          messageHash: envelope.messageHash,
          transferId: envelope.transferId,
          payloadType: envelope.payloadType,
          peerId: peer.id,
          transport: transfer.transport,
          hopCount: envelope.hopCount,
          fallbackUsed: transfer.fallbackUsed,
          latencyMs: transfer.latencyMs,
        );
        if (RelayPayloadCodec.senderPeerId(envelope.payloadJson) !=
            _transport.localPeerId) {
          await metricsRecorder?.captureEvent(
            type: ValidationEventType.envelopeRelayed,
            occurredAt: transfer.acknowledgedAt,
            messageHash: envelope.messageHash,
            transferId: envelope.transferId,
            payloadType: envelope.payloadType,
            peerId: peer.id,
            transport: transfer.transport,
            hopCount: envelope.hopCount,
            fallbackUsed: transfer.fallbackUsed,
          );
        }
        if (transfer.fallbackUsed) {
          await metricsRecorder?.captureEvent(
            type: ValidationEventType.transportFallback,
            occurredAt: transfer.acknowledgedAt,
            messageHash: envelope.messageHash,
            transferId: envelope.transferId,
            payloadType: envelope.payloadType,
            peerId: peer.id,
            transport: transfer.transport,
            hopCount: envelope.hopCount,
          );
        }
      } catch (error) {
        stopwatch.stop();
        lastError = error.toString();
        failedCount++;
        final failure = error is EnvelopeTransferException ? error : null;
        if (!sentRecorded && failure?.sentAt != null) {
          await metricsRecorder?.captureEvent(
            type: ValidationEventType.envelopeSent,
            occurredAt: failure!.sentAt,
            messageHash: envelope.messageHash,
            transferId: envelope.transferId,
            payloadType: envelope.payloadType,
            peerId: peer.id,
            transport: failure.transport ?? peer.transport,
            hopCount: envelope.hopCount,
            fallbackUsed: failure.fallbackUsed,
          );
        }
        await _scfService.updatePeerStatus(
          messageHash: envelope.messageHash,
          peerId: peer.id,
          status: ScfPeerStatus.failed,
          updatedAt: DateTime.now().toUtc(),
          lastError: lastError,
        );
        await metricsRecorder?.captureEvent(
          type: ValidationEventType.envelopeRejected,
          messageHash: envelope.messageHash,
          transferId: envelope.transferId,
          payloadType: envelope.payloadType,
          peerId: peer.id,
          transport: failure?.transport ?? peer.transport,
          hopCount: envelope.hopCount,
          latencyMs: failure?.latencyMs ?? stopwatch.elapsedMilliseconds,
          error: lastError,
          metadata: {
            'phase': 'send',
            'failure_code': failure?.code ?? 'transport_failed',
          },
        );
      }
    }

    return ScfRelayResult(
      peerId: peer.id,
      sentCount: sentCount,
      failedCount: failedCount,
      sentMessageHashes: sentMessageHashes,
      lastError: lastError,
    );
  }

  static String _newTransferId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<List<ScfRelayResult>> relayToDiscoveredPeers({
    DateTime? now,
    int perPeerLimit = 50,
  }) async {
    final peers = await discoverPeers();
    final results = <ScfRelayResult>[];

    for (final peer in peers) {
      results.add(await relayToPeer(peer, now: now, limit: perPeerLimit));
    }

    return results;
  }
}
