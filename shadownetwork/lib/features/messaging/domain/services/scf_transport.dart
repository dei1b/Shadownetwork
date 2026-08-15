import '../entities/peer.dart';
import '../entities/scf_envelope.dart';
import '../entities/transport_status.dart';
import '../entities/envelope_transfer_result.dart';

abstract class ScfTransport {
  String get localPeerId;

  Stream<void> get relayEvents;

  Future<Peer> getLocalPeer();

  Future<TransportStatus> getStatus();

  Future<List<Peer>> discoverPeers();

  Future<Peer> connectPeer(Peer peer);

  Future<EnvelopeTransferResult> sendEnvelope({
    required Peer peer,
    required ScfEnvelope envelope,
  });

  Future<List<ScfEnvelope>> receiveEnvelopes();
}
