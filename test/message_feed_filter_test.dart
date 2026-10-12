import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/conversation.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_moderation_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/presentation/utils/message_feed_filter.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_trust_status.dart';

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
    DeviceTrustStatus trustStatus = DeviceTrustStatus.unknown,
  }) {
    return SosMessage(
      id: id,
      sender: sender,
      body: 'Need water',
      category: Category.water,
      status: MessageStatus.received,
      createdAt: now,
      moderationStatus: moderationStatus,
      trustStatus: trustStatus,
    );
  }

  Conversation conversation({
    required MessageModerationStatus latestModerationStatus,
    DeviceTrustStatus latestTrustStatus = DeviceTrustStatus.unknown,
  }) {
    return Conversation(
      id: 'conversation-a',
      localPeerId: 'local',
      remotePeer: sender,
      createdAt: now,
      updatedAt: now,
      unreadCount: 0,
      latestModerationStatus: latestModerationStatus,
      latestTrustStatus: latestTrustStatus,
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
    final revoked = sosMessage(
      id: 'revoked',
      trustStatus: DeviceTrustStatus.revoked,
    ).copyWith(latitude: 7.3026, longitude: 125.6888);

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
        message: revoked,
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

  test('retired categories remain visible under the Other map filter', () {
    final legacy = sosMessage(
      id: 'legacy-water',
    ).copyWith(latitude: 7.3026, longitude: 125.6888);
    expect(
      shouldShowSosMessageOnMap(
        message: legacy,
        visibleCategories: {Category.other},
      ),
      isTrue,
    );
    for (final category in Category.sosCategories) {
      final message = legacy.copyWith(category: category);
      expect(
        shouldShowSosMessageOnMap(
          message: message,
          visibleCategories: {category},
        ),
        isTrue,
      );
      expect(
        shouldShowSosMessageOnMap(message: message, visibleCategories: {}),
        isFalse,
      );
    }
  });

  test('unknown messages remain visible as unverified', () {
    final unknown = sosMessage(
      id: 'unknown',
    ).copyWith(latitude: 7.3026, longitude: 125.6888);

    expect(
      shouldShowSosMessageForFilter(
        message: unknown,
        messageType: 'REQUEST',
        activeFilter: 'ALL',
      ),
      isTrue,
    );
    expect(
      shouldShowSosMessageOnMap(
        message: unknown,
        visibleCategories: {Category.water},
      ),
      isTrue,
    );
  });

  test('revoked messages are shown only in quarantine', () {
    final revokedSos = sosMessage(
      id: 'revoked',
      trustStatus: DeviceTrustStatus.revoked,
    );
    final revokedConversation = conversation(
      latestModerationStatus: MessageModerationStatus.normal,
      latestTrustStatus: DeviceTrustStatus.revoked,
    );

    expect(
      shouldShowSosMessageForFilter(
        message: revokedSos,
        messageType: 'REQUEST',
        activeFilter: 'ALL',
      ),
      isFalse,
    );
    expect(
      shouldShowSosMessageForFilter(
        message: revokedSos,
        messageType: 'REQUEST',
        activeFilter: 'QUARANTINE',
      ),
      isTrue,
    );
    expect(
      shouldShowConversationForFilter(
        conversation: revokedConversation,
        activeFilter: 'ALL',
      ),
      isFalse,
    );
    expect(
      shouldShowConversationForFilter(
        conversation: revokedConversation,
        activeFilter: 'QUARANTINE',
      ),
      isTrue,
    );
  });
}
