import 'category.dart';
import 'message_moderation_status.dart';
import 'message_status.dart';
import 'peer.dart';
import '../../../trust/domain/entities/device_trust_status.dart';

class SosMessage {
  const SosMessage({
    required this.id,
    required this.sender,
    required this.body,
    required this.category,
    required this.status,
    required this.createdAt,
    this.updatedAt,
    this.messageHash,
    this.latitude,
    this.longitude,
    this.gpsAccuracyMeters,
    this.hopCount = 0,
    this.ttl = const Duration(hours: 24),
    this.recipient,
    this.isEncrypted = false,
    this.moderationStatus = MessageModerationStatus.normal,
    this.moderationReason,
    this.moderationScore,
    this.trustStatus = DeviceTrustStatus.unknown,
    this.trustRole,
    this.trustOwnerName,
  });

  final String id;
  final Peer sender;
  final String body;
  final Category category;
  final MessageStatus status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String? messageHash;
  final double? latitude;
  final double? longitude;
  final double? gpsAccuracyMeters;
  final int hopCount;
  final Duration ttl;
  final Peer? recipient;
  final bool isEncrypted;
  final MessageModerationStatus moderationStatus;
  final String? moderationReason;
  final double? moderationScore;
  final DeviceTrustStatus trustStatus;
  final String? trustRole;
  final String? trustOwnerName;

  SosMessage copyWith({
    String? id,
    Peer? sender,
    String? body,
    Category? category,
    MessageStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? messageHash,
    double? latitude,
    double? longitude,
    double? gpsAccuracyMeters,
    int? hopCount,
    Duration? ttl,
    Object? recipient = _sentinel,
    bool? isEncrypted,
    MessageModerationStatus? moderationStatus,
    String? moderationReason,
    double? moderationScore,
    DeviceTrustStatus? trustStatus,
    String? trustRole,
    String? trustOwnerName,
  }) {
    return SosMessage(
      id: id ?? this.id,
      sender: sender ?? this.sender,
      body: body ?? this.body,
      category: category ?? this.category,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messageHash: messageHash ?? this.messageHash,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      gpsAccuracyMeters: gpsAccuracyMeters ?? this.gpsAccuracyMeters,
      hopCount: hopCount ?? this.hopCount,
      ttl: ttl ?? this.ttl,
      recipient: identical(recipient, _sentinel)
          ? this.recipient
          : recipient as Peer?,
      isEncrypted: isEncrypted ?? this.isEncrypted,
      moderationStatus: moderationStatus ?? this.moderationStatus,
      moderationReason: moderationReason ?? this.moderationReason,
      moderationScore: moderationScore ?? this.moderationScore,
      trustStatus: trustStatus ?? this.trustStatus,
      trustRole: trustRole ?? this.trustRole,
      trustOwnerName: trustOwnerName ?? this.trustOwnerName,
    );
  }
}

const _sentinel = Object();
