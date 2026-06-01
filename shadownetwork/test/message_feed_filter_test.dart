import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/conversation.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_moderation_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/presentation/utils/message_feed_filter.dart';

void main() {
  const sender = Peer(
    id: 'peer-a',
    name: 'Peer A',
    type: PeerType.civilian,
    isConnected: false,
  );
  final now = DateTime.utc(2026, 6, 1, 10);

  SosMessage sosMessage({
    required String id,
    MessageModerationStatus moderationStatus = MessageModerationStatus.normal,
  }) {
    return SosMessage(
      id: id,
      sender: sender,
      body: 'Need water',
      category: Category.water,
      status: MessageStatus.received,
      createdAt: now,
      moderationStatus: moderationStatus,
    );
  }

  Conversation conversation({
    required MessageModerationStatus latestModerationStatus,
  }) {
    return Conversation(
      id: 'conversation-a',
      localPeerId: 'local',
      remotePeer: sender,
      createdAt: now,
      updatedAt: now,
      unreadCount: 0,
      latestModerationStatus: latestModerationStatus,
    );
  }

  test('All filter excludes spam and Spam filter includes only spam SOS', () {
    final normal = sosMessage(id: 'normal');
    final spam = sosMessage(
      id: 'spam',
      moderationStatus: MessageModerationStatus.spam,
    );

    expect(
      shouldShowSosMessageForFilter(
        message: normal,
        messageType: 'REQUEST',
        activeFilter: 'ALL',
      ),
      isTrue,
    );
    expect(
      shouldShowSosMessageForFilter(
        message: spam,
        messageType: 'SPAM',
        activeFilter: 'ALL',
      ),
      isFalse,
    );
    expect(
      shouldShowSosMessageForFilter(
        message: spam,
        messageType: 'SPAM',
        activeFilter: 'SPAM',
      ),
      isTrue,
    );
    expect(
      shouldShowSosMessageForFilter(
        message: normal,
        messageType: 'REQUEST',
        activeFilter: 'SPAM',
      ),
      isFalse,
    );
  });

  test('All filter excludes spam and Spam filter includes only spam chats', () {
    final normalConversation = conversation(
      latestModerationStatus: MessageModerationStatus.normal,
    );
    final spamConversation = conversation(
      latestModerationStatus: MessageModerationStatus.spam,
    );

    expect(
      shouldShowConversationForFilter(
        conversation: normalConversation,
        activeFilter: 'ALL',
      ),
      isTrue,
    );
    expect(
      shouldShowConversationForFilter(
        conversation: spamConversation,
        activeFilter: 'ALL',
      ),
      isFalse,
    );
    expect(
      shouldShowConversationForFilter(
        conversation: spamConversation,
        activeFilter: 'SPAM',
      ),
      isTrue,
    );
    expect(
      shouldShowConversationForFilter(
        conversation: normalConversation,
        activeFilter: 'SPAM',
      ),
      isFalse,
    );
  });

  test('map markers include only non-spam messages with visible locations', () {
    final normal = sosMessage(
      id: 'normal',
    ).copyWith(latitude: 7.3026, longitude: 125.6888);
    final spam = sosMessage(
      id: 'spam',
      moderationStatus: MessageModerationStatus.spam,
    ).copyWith(latitude: 7.3026, longitude: 125.6888);
    final noLocation = sosMessage(id: 'no-location');

    expect(
      shouldShowSosMessageOnMap(
        message: normal,
        visibleCategories: {Category.water},
      ),
      isTrue,
    );
    expect(
      shouldShowSosMessageOnMap(
        message: spam,
        visibleCategories: {Category.water},
      ),
      isFalse,
    );
    expect(
      shouldShowSosMessageOnMap(
        message: noLocation,
        visibleCategories: {Category.water},
      ),
      isFalse,
    );
    expect(
      shouldShowSosMessageOnMap(
        message: normal,
        visibleCategories: {Category.medical},
      ),
      isFalse,
    );
  });
}
