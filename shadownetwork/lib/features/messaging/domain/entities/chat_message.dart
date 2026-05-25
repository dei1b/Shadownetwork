import 'message_status.dart';
import 'peer.dart';

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
    );
  }
}
