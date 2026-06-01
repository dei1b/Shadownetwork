import 'dart:io';

import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_cache_file_store/http_cache_file_store.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/datasources/local_messaging_database.dart';
import '../../data/repositories/sqlite_peer_repository.dart';
import '../../data/repositories/sqlite_sos_message_repository.dart';
import '../../data/repositories/sqlite_chat_repository.dart';
import '../../data/services/android_scf_transport.dart';
import '../../data/services/mock_scf_transport.dart';
import '../../data/services/scf_relay_service.dart';
import '../../data/services/scf_service.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/entities/message_moderation_status.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer_type.dart';
import '../../domain/entities/sos_message.dart';
import '../../domain/entities/spam_detection_result.dart';
import '../../domain/repositories/peer_repository.dart';
import '../../domain/repositories/chat_repository.dart';
import '../../domain/repositories/sos_message_repository.dart';
import '../../domain/services/scf_transport.dart';
import '../../domain/services/spam_detection_service.dart';

final localMessagingDatabaseProvider = FutureProvider<Database>((ref) async {
  final database = await LocalMessagingDatabase.open();
  ref.onDispose(database.close);
  return database;
});

final peerRepositoryProvider = FutureProvider<PeerRepository>((ref) async {
  final database = await ref.watch(localMessagingDatabaseProvider.future);
  return SqlitePeerRepository(database: database);
});

final sosMessageRepositoryProvider = FutureProvider<SosMessageRepository>((
  ref,
) async {
  final database = await ref.watch(localMessagingDatabaseProvider.future);
  return SqliteSosMessageRepository(database: database);
});

final chatRepositoryProvider = FutureProvider<ChatRepository>((ref) async {
  final database = await ref.watch(localMessagingDatabaseProvider.future);
  return SqliteChatRepository(database: database);
});

final scfServiceProvider = FutureProvider<ScfService>((ref) async {
  final database = await ref.watch(localMessagingDatabaseProvider.future);
  return ScfService(database: database);
});

final mockScfTransportNetworkProvider = Provider<MockScfTransportNetwork>(
  (ref) => MockScfTransportNetwork(),
);

final localPeerProvider = FutureProvider<Peer>((ref) async {
  final transport = ref.watch(scfTransportProvider);
  return transport.getLocalPeer();
});

final scfTransportProvider = Provider<ScfTransport>((ref) {
  if (Platform.isAndroid) {
    return AndroidScfTransport();
  }

  final network = ref.watch(mockScfTransportNetworkProvider);
  return network.registerPeer(_defaultDesktopLocalPeer());
});

final scfRelayServiceProvider = FutureProvider<ScfRelayService>((ref) async {
  final scfService = await ref.watch(scfServiceProvider.future);
  final transport = ref.watch(scfTransportProvider);
  return ScfRelayService(scfService: scfService, transport: transport);
});

final spamDetectionServiceProvider = Provider<SpamDetectionService>(
  (ref) => const SpamDetectionService(),
);

final mapTileCacheStoreProvider = FutureProvider<CacheStore>((ref) async {
  final directory = await getApplicationSupportDirectory();
  final store = FileCacheStore(path.join(directory.path, 'map_tiles'));
  ref.onDispose(store.close);
  return store;
});

final nearbyPeersProvider = FutureProvider<List<Peer>>((ref) async {
  final repository = await ref.watch(peerRepositoryProvider.future);
  final localPeer = await ref.watch(localPeerProvider.future);
  return repository.getNearbyPeers(excludingPeerId: localPeer.id);
});

final sosMessagesProvider = FutureProvider<List<SosMessage>>((ref) async {
  final repository = await ref.watch(sosMessageRepositoryProvider.future);
  return repository.getMessages();
});

final conversationsProvider = FutureProvider<List<Conversation>>((ref) async {
  final localPeer = await ref.watch(localPeerProvider.future);
  final repository = await ref.watch(chatRepositoryProvider.future);
  return repository.getConversations(localPeer.id);
});

final chatMessagesProvider = FutureProvider.family<List<ChatMessage>, String>((
  ref,
  conversationId,
) async {
  final repository = await ref.watch(chatRepositoryProvider.future);
  return repository.getMessages(conversationId);
});

typedef OpenConversation =
    Future<Conversation> Function({
      required Peer remotePeer,
      String? relatedSosMessageHash,
    });

final openConversationProvider = Provider<OpenConversation>((ref) {
  return ({required remotePeer, relatedSosMessageHash}) async {
    final localPeer = await ref.read(localPeerProvider.future);
    final repository = await ref.read(chatRepositoryProvider.future);
    final conversation = await repository.openConversation(
      localPeer: localPeer,
      remotePeer: remotePeer,
      relatedSosMessageHash: relatedSosMessageHash,
    );
    ref.invalidate(conversationsProvider);
    return conversation;
  };
});

typedef SendChatMessage =
    Future<void> Function(Conversation conversation, String body);

final sendChatMessageProvider = Provider<SendChatMessage>((ref) {
  return (conversation, body) async {
    final trimmedBody = body.trim();
    if (trimmedBody.isEmpty) {
      return;
    }
    final localPeer = await ref.read(localPeerProvider.future);
    final repository = await ref.read(chatRepositoryProvider.future);
    final scfService = await ref.read(scfServiceProvider.future);
    final spamDetectionService = ref.read(spamDetectionServiceProvider);
    final now = DateTime.now().toUtc();
    final message = ChatMessage(
      id: 'chat-${now.microsecondsSinceEpoch}',
      conversationId: conversation.id,
      sender: localPeer,
      recipient: conversation.remotePeer,
      body: trimmedBody,
      status: MessageStatus.queued,
      createdAt: now,
      relatedSosMessageHash: conversation.relatedSosMessageHash,
    );
    final recentMessages = await repository.getRecentMessagesBySender(
      senderPeerId: localPeer.id,
      since: now.subtract(spamDetectionService.window),
    );
    final moderation = spamDetectionService.classify(
      candidate: _chatSimilaritySample(message),
      priorMessages: recentMessages.map(_chatSimilaritySample),
    );
    final moderatedMessage = _withChatModeration(message, moderation);
    await repository.saveMessage(moderatedMessage);
    await scfService.storeChatMessage(moderatedMessage);
    ref.invalidate(conversationsProvider);
    ref.invalidate(chatMessagesProvider(conversation.id));
  };
});

final markConversationReadProvider = Provider<Future<void> Function(String)>((
  ref,
) {
  return (conversationId) async {
    final repository = await ref.read(chatRepositoryProvider.future);
    await repository.markConversationRead(conversationId);
    ref.invalidate(conversationsProvider);
  };
});

final saveSosMessageProvider = Provider<Future<void> Function(SosMessage)>((
  ref,
) {
  return (message) async {
    final repository = await ref.read(sosMessageRepositoryProvider.future);
    final scfService = await ref.read(scfServiceProvider.future);
    final spamDetectionService = ref.read(spamDetectionServiceProvider);
    final recentMessages = await repository.getRecentMessagesBySender(
      senderPeerId: message.sender.id,
      since: message.createdAt.toUtc().subtract(spamDetectionService.window),
    );
    final moderation = spamDetectionService.classify(
      candidate: _sosSimilaritySample(message),
      priorMessages: recentMessages.map(_sosSimilaritySample),
    );
    final moderatedMessage = _withSosModeration(message, moderation);
    await repository.saveMessage(moderatedMessage);
    await scfService.storeMessage(moderatedMessage);
    ref.invalidate(sosMessagesProvider);
    ref.invalidate(nearbyPeersProvider);
  };
});

MessageSimilaritySample _sosSimilaritySample(SosMessage message) {
  return MessageSimilaritySample(
    senderPeerId: message.sender.id,
    body: message.body,
    createdAt: message.createdAt,
    messageId: message.id,
    messageHash: message.messageHash,
  );
}

MessageSimilaritySample _chatSimilaritySample(ChatMessage message) {
  return MessageSimilaritySample(
    senderPeerId: message.sender.id,
    body: message.body,
    createdAt: message.createdAt,
    messageId: message.id,
    messageHash: message.messageHash,
  );
}

SosMessage _withSosModeration(SosMessage message, SpamDetectionResult result) {
  return message.copyWith(
    moderationStatus: result.status,
    moderationReason: result.reason,
    moderationScore: result.status == MessageModerationStatus.spam
        ? result.score
        : null,
  );
}

ChatMessage _withChatModeration(
  ChatMessage message,
  SpamDetectionResult result,
) {
  return message.copyWith(
    moderationStatus: result.status,
    moderationReason: result.reason,
    moderationScore: result.status == MessageModerationStatus.spam
        ? result.score
        : null,
  );
}

Peer _defaultDesktopLocalPeer() {
  final hostName = Platform.localHostname.trim();
  final displayName = hostName.isEmpty ? 'Desktop Node' : hostName;
  final slug = displayName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  return Peer(
    id: 'desktop-${slug.isEmpty ? 'node' : slug}',
    name: displayName,
    type: PeerType.civilian,
    isConnected: true,
  );
}
