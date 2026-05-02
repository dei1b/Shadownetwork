import '../entities/peer.dart';
import '../entities/scf_envelope.dart';

abstract class ScfTransport {
  String get localPeerId;

  Future<List<Peer>> discoverPeers();

  Future<void> sendEnvelope({
    required Peer peer,
    required ScfEnvelope envelope,
  });

  Future<List<ScfEnvelope>> receiveEnvelopes();
}
