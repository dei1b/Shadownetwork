import 'message_moderation_status.dart';
import 'message_status.dart';
import 'peer.dart';
import '../../../trust/domain/entities/device_trust_status.dart';

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.sender,
    required this.recipient,
    required this.body,
    required this.status,
    required this.createdAt,
    this.updatedAt,
    this.messageHash,
    this.relatedSosMessageHash,
    this.hopCount = 0,
    this.ttl = const Duration(hours: 24),
    this.moderationStatus = MessageModerationStatus.normal,
    this.moderationReason,
    this.moderationScore,
    this.trustStatus = DeviceTrustStatus.unknown,
    this.trustRole,
    this.trustOwnerName,
  });

  final String id;
  final String conversationId;
  final Peer sender;
  final Peer recipient;
  final String body;
  final MessageStatus status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String? messageHash;
  final String? relatedSosMessageHash;
  final int hopCount;
  final Duration ttl;
  final MessageModerationStatus moderationStatus;
  final String? moderationReason;
  final double? moderationScore;
  final DeviceTrustStatus trustStatus;
  final String? trustRole;
  final String? trustOwnerName;

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    Peer? sender,
    Peer? recipient,
    String? body,
    MessageStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? messageHash,
    String? relatedSosMessageHash,
    int? hopCount,
    Duration? ttl,
    MessageModerationStatus? moderationStatus,
    String? moderationReason,
    double? moderationScore,
    DeviceTrustStatus? trustStatus,
    String? trustRole,
    String? trustOwnerName,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      sender: sender ?? this.sender,
      recipient: recipient ?? this.recipient,
      body: body ?? this.body,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messageHash: messageHash ?? this.messageHash,
      relatedSosMessageHash:
          relatedSosMessageHash ?? this.relatedSosMessageHash,
      hopCount: hopCount ?? this.hopCount,
      ttl: ttl ?? this.ttl,
      moderationStatus: moderationStatus ?? this.moderationStatus,
      moderationReason: moderationReason ?? this.moderationReason,
      moderationScore: moderationScore ?? this.moderationScore,
      trustStatus: trustStatus ?? this.trustStatus,
      trustRole: trustRole ?? this.trustRole,
      trustOwnerName: trustOwnerName ?? this.trustOwnerName,
    );
  }
}
