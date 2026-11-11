import '../entities/chat_message.dart';
import '../entities/conversation.dart';
import '../entities/message_status.dart';
import '../entities/peer.dart';

abstract class ChatRepository {
  Future<Conversation> openConversation({
    required Peer localPeer,
    required Peer remotePeer,
    String? relatedSosMessageHash,
  });

  /// Lists conversations that contain at least one saved chat message.
  Future<List<Conversation>> getConversations(String localPeerId);

  Future<List<ChatMessage>> getMessages(String conversationId);

  Future<List<ChatMessage>> getRecentMessagesBySender({
    required String senderPeerId,
    required DateTime since,
  });

  /// Returns whether a new message was inserted.
  Future<bool> saveMessage(ChatMessage message, {bool incrementUnread = false});

  Future<void> updateOutgoingMessageStatus({
    required String messageHash,
    required String localPeerId,
    required MessageStatus status,
  });

  Future<void> markConversationRead(String conversationId);
}
