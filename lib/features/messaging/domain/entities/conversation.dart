import 'message_moderation_status.dart';
import 'message_status.dart';
import 'peer.dart';
import '../../../trust/domain/entities/device_trust_status.dart';

class Conversation {
  const Conversation({
    required this.id,
    required this.localPeerId,
    required this.remotePeer,
    required this.createdAt,
    required this.updatedAt,
    required this.unreadCount,
    this.relatedSosMessageHash,
    this.lastMessageAt,
    this.latestBody,
    this.latestStatus,
    this.latestModerationStatus,
    this.latestTrustStatus,
  });

  final String id;
  final String localPeerId;
  final Peer remotePeer;
  final String? relatedSosMessageHash;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastMessageAt;
  final int unreadCount;
  final String? latestBody;
  final MessageStatus? latestStatus;
  final MessageModerationStatus? latestModerationStatus;
  final DeviceTrustStatus? latestTrustStatus;
}
