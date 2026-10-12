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
      final messageCreatedAt = RelayPayloadCodec.createdAt(
        envelope.payloadJson,
      );
      await metricsRecorder?.captureEvent(
        type: ValidationEventType.envelopeReceived,
        occurredAt: now,
        messageHash: envelope.messageHash,
        payloadType: envelope.payloadType,
        hopCount: envelope.hopCount,
        metadata: {
          if (messageCreatedAt != null)
            'message_created_at': messageCreatedAt.toIso8601String(),
        },
      );
      final stored = await _scfService.storeEnvelope(envelope, now: now);
      if (stored) {
        final resolver = originTrustResolver;
        if (resolver != null) {
          final trustStatus = await resolver(envelope.payloadJson);
          await _scfService.updateOriginTrustStatus(
            messageHash: envelope.messageHash,
            status: trustStatus,
          );
          if (trustStatus == DeviceTrustStatus.revoked) {
            await metricsRecorder?.captureEvent(
              type: ValidationEventType.envelopeRejected,
              occurredAt: now,
              messageHash: envelope.messageHash,
              payloadType: envelope.payloadType,
              hopCount: envelope.hopCount,
              error: 'Origin device is revoked; retained in quarantine.',
            );
          }
        }
        storedEnvelopes.add(envelope);
      } else {
        await metricsRecorder?.captureEvent(
          type: ValidationEventType.envelopeRejected,
          occurredAt: now,
          messageHash: envelope.messageHash,
          payloadType: envelope.payloadType,
          hopCount: envelope.hopCount,
          error: 'Duplicate or expired SCF envelope.',
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

    for (final envelope in outbound) {
      await metricsRecorder?.captureEvent(
        type: ValidationEventType.envelopeOffered,
        occurredAt: now,
        messageHash: envelope.messageHash,
        payloadType: envelope.payloadType,
        peerId: peer.id,
        transport: peer.transport,
        hopCount: envelope.hopCount,
      );
      final stopwatch = Stopwatch()..start();
      try {
        final transfer = await _transport.sendEnvelope(
          peer: peer,
          envelope: envelope,
        );
        stopwatch.stop();
        await _scfService.updatePeerStatus(
          messageHash: envelope.messageHash,
          peerId: peer.id,
          status: ScfPeerStatus.sent,
          updatedAt: now,
        );
        sentCount++;
        sentMessageHashes.add(envelope.messageHash);
        await metricsRecorder?.captureEvent(
          type: ValidationEventType.envelopeSent,
          occurredAt: now,
          messageHash: envelope.messageHash,
          payloadType: envelope.payloadType,
          peerId: peer.id,
          transport: transfer.transport,
          hopCount: envelope.hopCount,
          fallbackUsed: transfer.fallbackUsed,
          latencyMs: stopwatch.elapsedMilliseconds,
        );
        if (RelayPayloadCodec.senderPeerId(envelope.payloadJson) !=
            _transport.localPeerId) {
          await metricsRecorder?.captureEvent(
            type: ValidationEventType.envelopeRelayed,
            occurredAt: now,
            messageHash: envelope.messageHash,
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
            occurredAt: now,
            messageHash: envelope.messageHash,
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
        await _scfService.updatePeerStatus(
          messageHash: envelope.messageHash,
          peerId: peer.id,
          status: ScfPeerStatus.failed,
          updatedAt: now,
          lastError: lastError,
        );
        await metricsRecorder?.captureEvent(
          type: ValidationEventType.envelopeRejected,
          occurredAt: now,
          messageHash: envelope.messageHash,
          payloadType: envelope.payloadType,
          peerId: peer.id,
          transport: peer.transport,
          hopCount: envelope.hopCount,
          latencyMs: stopwatch.elapsedMilliseconds,
          error: lastError,
          metadata: const {'phase': 'send'},
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
