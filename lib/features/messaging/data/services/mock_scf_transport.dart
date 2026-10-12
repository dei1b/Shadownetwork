import 'dart:async';

import '../../domain/entities/peer.dart';
import '../../domain/entities/scf_envelope.dart';
import '../../domain/entities/transport_status.dart';
import '../../domain/entities/envelope_transfer_result.dart';
import '../../domain/services/scf_transport.dart';

class MockScfTransportNetwork {
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

    recipient.inbox.add(envelope);
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
    _network.send(
      fromPeerId: localPeerId,
      toPeerId: peer.id,
      envelope: envelope,
    );
    return const EnvelopeTransferResult(transport: 'mock');
  }

  @override
  Future<List<ScfEnvelope>> receiveEnvelopes() async {
    return _network.drainInbox(localPeerId);
  }
}

class _MockNode {
  _MockNode(this.peer);

  Peer peer;
  final List<ScfEnvelope> inbox = [];
}
