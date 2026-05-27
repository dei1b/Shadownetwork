import '../entities/peer.dart';
import '../entities/scf_envelope.dart';
import '../entities/transport_status.dart';

abstract class ScfTransport {
  String get localPeerId;

  Future<Peer> getLocalPeer();

  Future<TransportStatus> getStatus();

  Future<List<Peer>> discoverPeers();

  Future<Peer> connectPeer(Peer peer);

  Future<void> sendEnvelope({
    required Peer peer,
    required ScfEnvelope envelope,
  });

  Future<List<ScfEnvelope>> receiveEnvelopes();
}
