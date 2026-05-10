import '../entities/peer.dart';

abstract class PeerRepository {
  Future<List<Peer>> getNearbyPeers();
  Future<void> markAllDisconnected({DateTime? timestamp});
  Future<void> upsertPeer(Peer peer);
}
