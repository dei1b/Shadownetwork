import 'dart:async';

import '../../domain/entities/peer.dart';
import '../../domain/entities/scf_envelope.dart';
import '../../domain/entities/transport_status.dart';
import '../../domain/entities/envelope_transfer_result.dart';
import '../../domain/services/scf_transport.dart';

class MockScfTransportNetwork {
  MockScfTransportNetwork({
    this.acknowledgementTimeout = const Duration(seconds: 10),
  });

  final Duration acknowledgementTimeout;
  final Map<String, _PendingMockTransfer> _pending = {};
  final Map<String, _MockNode> _nodes = {};
  final StreamController<void> _relayEvents =
      StreamController<void>.broadcast();

  MockScfTransportEndpoint registerPeer(Peer peer) {
    final node = _nodes.putIfAbsent(peer.id, () => _MockNode(peer));
    node.peer = peer;
    return MockScfTransportEndpoint._(network: this, localPeerId: peer.id);
  }

  List<Peer> discoverPeers(String localPeerId) {
    return _nodes.values
        .where((node) => node.peer.id != localPeerId)
        .map((node) => node.peer)
        .toList(growable: false);
  }

  Peer connectPeer(String peerId) {
    final node = _nodes[peerId];
    if (node == null) {
      throw StateError('Mock peer $peerId is not registered.');
    }
    node.peer = node.peer.copyWith(isConnected: true);
    return node.peer;
  }

  void send({
    required String fromPeerId,
    required String toPeerId,
    required ScfEnvelope envelope,
  }) {
    final recipient = _nodes[toPeerId];
    if (recipient == null) {
      throw StateError('Mock peer $toPeerId is not registered.');
    }

    recipient.inbox.add(
      envelope.copyWith(
        receivedFromPeerId: fromPeerId,
        receivedTransport: 'mock',
      ),
    );
    _relayEvents.add(null);
  }

  List<ScfEnvelope> drainInbox(String peerId) {
    final node = _nodes[peerId];
    if (node == null) {
      throw StateError('Mock peer $peerId is not registered.');
    }

    final envelopes = List<ScfEnvelope>.unmodifiable(node.inbox);
    node.inbox.clear();
    return envelopes;
  }

  Peer localPeer(String peerId) {
    final node = _nodes[peerId];
    if (node == null) {
      throw StateError('Mock peer $peerId is not registered.');
    }

    return node.peer;
  }

  Future<EnvelopeTransferResult> sendAndWait({
    required String fromPeerId,
    required String toPeerId,
    required ScfEnvelope envelope,
  }) async {
    final id = envelope.transferId;
    if (id == null || id.isEmpty || _pending.containsKey(id)) {
      throw ArgumentError('A unique transferId is required.');
    }
    final pending = _PendingMockTransfer(toPeerId, envelope.messageHash);
    _pending[id] = pending;
    try {
      send(fromPeerId: fromPeerId, toPeerId: toPeerId, envelope: envelope);
      final accepted = await pending.completion.future.timeout(
        acknowledgementTimeout,
        onTimeout: () => throw EnvelopeAcknowledgementTimeout(
          transferId: id,
          message: 'Peer $toPeerId did not acknowledge storage.',
          transport: 'mock',
          sentAt: pending.sentAt,
          latencyMs: pending.stopwatch.elapsedMilliseconds,
        ),
      );
      if (!accepted) {
        throw EnvelopeTransferException(
          transferId: id,
          message: 'Peer $toPeerId rejected the envelope.',
          code: 'receiver_rejected',
          transport: 'mock',
          sentAt: pending.sentAt,
          latencyMs: pending.stopwatch.elapsedMilliseconds,
        );
      }
      return EnvelopeTransferResult(
        transport: 'mock',
        transferId: id,
        acknowledged: true,
        sentAt: pending.sentAt,
        acknowledgedAt: pending.acknowledgedAt,
        latencyMs: pending.stopwatch.elapsedMilliseconds,
      );
    } finally {
      pending.stopwatch.stop();
      _pending.remove(id);
    }
  }

  void acknowledge(String receiverPeerId, ScfEnvelope envelope, bool accepted) {
    final pending = _pending[envelope.transferId];
    if (pending == null ||
        pending.completion.isCompleted ||
        pending.peerId != receiverPeerId ||
        pending.hash != envelope.messageHash) {
      return;
    }
    pending.stopwatch.stop();
    pending.acknowledgedAt = DateTime.now().toUtc();
    pending.completion.complete(accepted);
  }

  int get pendingTransferCount => _pending.length;
}

class MockScfTransportEndpoint implements ScfTransport {
  const MockScfTransportEndpoint._({
    required MockScfTransportNetwork network,
    required this.localPeerId,
  }) : _network = network;

  final MockScfTransportNetwork _network;

  @override
  final String localPeerId;

  @override
  Stream<void> get relayEvents => _network._relayEvents.stream;

  @override
  Future<Peer> getLocalPeer() async {
    return _network.localPeer(localPeerId);
  }

  @override
  Future<TransportStatus> getStatus() async {
    final localPeer = _network.localPeer(localPeerId);
    final discoveredPeers = _network.discoverPeers(localPeerId);
    final connectedPeerCount = discoveredPeers
        .where((peer) => peer.isConnected)
        .length;

    return TransportStatus(
      localPeer: localPeer,
      permissionsGranted: true,
      isRunning: true,
      discoveredPeerCount: discoveredPeers.length,
      connectedPeerCount: connectedPeerCount,
    );
  }

  @override
  Future<List<Peer>> discoverPeers() async {
    return _network.discoverPeers(localPeerId);
  }

  @override
  Future<Peer> connectPeer(Peer peer) async {
    return _network.connectPeer(peer.id);
  }

  @override
  Future<EnvelopeTransferResult> sendEnvelope({
    required Peer peer,
    required ScfEnvelope envelope,
  }) async {
    return _network.sendAndWait(
      fromPeerId: localPeerId,
      toPeerId: peer.id,
      envelope: envelope,
    );
  }

  @override
  Future<List<ScfEnvelope>> receiveEnvelopes() async {
    return _network.drainInbox(localPeerId);
  }

  @override
  Future<void> acknowledgeEnvelope({
    required ScfEnvelope envelope,
    bool accepted = true,
  }) async {
    _network.acknowledge(localPeerId, envelope, accepted);
  }
}

class _PendingMockTransfer {
  _PendingMockTransfer(this.peerId, this.hash);
  final String peerId;
  final String hash;
  final completion = Completer<bool>();
  final stopwatch = Stopwatch()..start();
  final sentAt = DateTime.now().toUtc();
  DateTime? acknowledgedAt;
}

class _MockNode {
  _MockNode(this.peer);

  Peer peer;
  final List<ScfEnvelope> inbox = [];
}
