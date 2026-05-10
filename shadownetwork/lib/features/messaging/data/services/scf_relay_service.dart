import '../../domain/entities/peer.dart';
import '../../domain/entities/scf_envelope.dart';
import '../../domain/entities/scf_peer_status.dart';
import '../../domain/services/scf_transport.dart';
import 'scf_service.dart';

class ScfRelayResult {
  const ScfRelayResult({
    required this.peerId,
    required this.sentCount,
    required this.failedCount,
    this.lastError,
  });

  final String peerId;
  final int sentCount;
  final int failedCount;
  final String? lastError;
}

class ScfRelayService {
  const ScfRelayService({
    required ScfService scfService,
    required ScfTransport transport,
  }) : _scfService = scfService,
       _transport = transport;

  final ScfService _scfService;
  final ScfTransport _transport;

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
      final stored = await _scfService.storeEnvelope(envelope, now: now);
      if (stored) {
        storedEnvelopes.add(envelope);
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

    for (final envelope in outbound) {
      try {
        await _transport.sendEnvelope(peer: peer, envelope: envelope);
        await _scfService.updatePeerStatus(
          messageHash: envelope.messageHash,
          peerId: peer.id,
          status: ScfPeerStatus.sent,
          updatedAt: now,
        );
        sentCount++;
      } catch (error) {
        lastError = error.toString();
        failedCount++;
        await _scfService.updatePeerStatus(
          messageHash: envelope.messageHash,
          peerId: peer.id,
          status: ScfPeerStatus.failed,
          updatedAt: now,
          lastError: lastError,
        );
      }
    }

    return ScfRelayResult(
      peerId: peer.id,
      sentCount: sentCount,
      failedCount: failedCount,
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
