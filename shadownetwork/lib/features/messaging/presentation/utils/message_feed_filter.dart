import '../../domain/entities/conversation.dart';
import '../../domain/entities/category.dart';
import '../../domain/entities/message_moderation_status.dart';
import '../../domain/entities/sos_message.dart';
import '../../../trust/domain/entities/device_trust_status.dart';

bool shouldShowSosMessageForFilter({
  required SosMessage message,
  required String messageType,
  required String activeFilter,
}) {
  final isSpam = message.moderationStatus == MessageModerationStatus.spam;
  final isRevoked = message.trustStatus == DeviceTrustStatus.revoked;
  return switch (activeFilter) {
    'ALL' => !isSpam && !isRevoked,
    'SPAM' => isSpam && !isRevoked,
    'QUARANTINE' => isRevoked,
    _ => messageType == activeFilter && !isSpam && !isRevoked,
  };
}

bool shouldShowConversationForFilter({
  required Conversation conversation,
  required String activeFilter,
}) {
  final isSpam =
      conversation.latestModerationStatus == MessageModerationStatus.spam;
  final isRevoked = conversation.latestTrustStatus == DeviceTrustStatus.revoked;
  return switch (activeFilter) {
    'ALL' => !isSpam && !isRevoked,
    'SPAM' => isSpam && !isRevoked,
    'QUARANTINE' => isRevoked,
    _ => false,
  };
}

bool shouldShowSosMessageOnMap({
  required SosMessage message,
  required Set<Category> visibleCategories,
}) {
  return message.moderationStatus != MessageModerationStatus.spam &&
      message.trustStatus != DeviceTrustStatus.revoked &&
      visibleCategories.contains(message.category) &&
      message.latitude != null &&
      message.longitude != null;
}
