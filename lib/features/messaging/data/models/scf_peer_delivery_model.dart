import '../../domain/entities/scf_peer_delivery.dart';
import '../../domain/entities/scf_peer_status.dart';

class ScfPeerDeliveryModel {
  const ScfPeerDeliveryModel._();

  static ScfPeerDelivery fromMap(Map<String, Object?> map) {
    return ScfPeerDelivery(
      messageHash: map['message_hash']! as String,
      peerId: map['peer_id']! as String,
      status: ScfPeerStatus.values.byName(map['status']! as String),
      attemptCount: map['attempt_count']! as int,
      updatedAt: DateTime.parse(map['updated_at']! as String),
      lastError: map['last_error'] as String?,
    );
  }

  static Map<String, Object?> toMap(ScfPeerDelivery delivery) {
    return {
      'message_hash': delivery.messageHash,
      'peer_id': delivery.peerId,
      'status': delivery.status.name,
      'attempt_count': delivery.attemptCount,
      'updated_at': delivery.updatedAt.toUtc().toIso8601String(),
      'last_error': delivery.lastError,
    };
  }
}
