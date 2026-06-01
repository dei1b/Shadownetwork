import 'message_moderation_status.dart';

class SpamDetectionResult {
  const SpamDetectionResult({
    required this.status,
    required this.score,
    this.reason,
    this.matchedMessageId,
    this.matchedMessageHash,
  });

  const SpamDetectionResult.normal()
    : status = MessageModerationStatus.normal,
      score = 0,
      reason = null,
      matchedMessageId = null,
      matchedMessageHash = null;

  const SpamDetectionResult.spam({
    required double score,
    required String reason,
    String? matchedMessageId,
    String? matchedMessageHash,
  }) : this(
         status: MessageModerationStatus.spam,
         score: score,
         reason: reason,
         matchedMessageId: matchedMessageId,
         matchedMessageHash: matchedMessageHash,
       );

  final MessageModerationStatus status;
  final double score;
  final String? reason;
  final String? matchedMessageId;
  final String? matchedMessageHash;
}
