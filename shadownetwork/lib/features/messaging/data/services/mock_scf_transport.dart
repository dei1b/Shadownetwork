import '../../domain/entities/peer.dart';
import '../../domain/entities/scf_envelope.dart';
import '../../domain/services/scf_transport.dart';

class MockScfTransportNetwork {
  final Map<String, _MockNode> _nodes = {};

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
  Future<List<Peer>> discoverPeers() async {
    return _network.discoverPeers(localPeerId);
  }

  @override
  Future<void> sendEnvelope({
    required Peer peer,
    required ScfEnvelope envelope,
  }) async {
    _network.send(
      fromPeerId: localPeerId,
      toPeerId: peer.id,
      envelope: envelope,
    );
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
