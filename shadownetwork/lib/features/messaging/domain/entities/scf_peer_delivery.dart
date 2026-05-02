import 'scf_peer_status.dart';

class ScfPeerDelivery {
  const ScfPeerDelivery({
    required this.messageHash,
    required this.peerId,
    required this.status,
    required this.attemptCount,
    required this.updatedAt,
    this.lastError,
  });

  final String messageHash;
  final String peerId;
  final ScfPeerStatus status;
  final int attemptCount;
  final DateTime updatedAt;
  final String? lastError;
}
