import 'peer.dart';

class TransportStatus {
  const TransportStatus({
    required this.localPeer,
    required this.permissionsGranted,
    required this.isRunning,
    required this.discoveredPeerCount,
    required this.connectedPeerCount,
  });

  final Peer localPeer;
  final bool permissionsGranted;
  final bool isRunning;
  final int discoveredPeerCount;
  final int connectedPeerCount;
}
