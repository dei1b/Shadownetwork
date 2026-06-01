import '../../domain/entities/conversation.dart';
import '../../domain/entities/category.dart';
import '../../domain/entities/message_moderation_status.dart';
import '../../domain/entities/sos_message.dart';

bool shouldShowSosMessageForFilter({
  required SosMessage message,
  required String messageType,
  required String activeFilter,
}) {
  final isSpam = message.moderationStatus == MessageModerationStatus.spam;
  return switch (activeFilter) {
    'ALL' => !isSpam,
    'SPAM' => isSpam,
    _ => messageType == activeFilter && !isSpam,
  };
}

bool shouldShowConversationForFilter({
  required Conversation conversation,
  required String activeFilter,
}) {
  final isSpam =
      conversation.latestModerationStatus == MessageModerationStatus.spam;
  return switch (activeFilter) {
    'ALL' => !isSpam,
    'SPAM' => isSpam,
    _ => false,
  };
}

bool shouldShowSosMessageOnMap({
  required SosMessage message,
  required Set<Category> visibleCategories,
}) {
  return message.moderationStatus != MessageModerationStatus.spam &&
      visibleCategories.contains(message.category) &&
      message.latitude != null &&
      message.longitude != null;
}
