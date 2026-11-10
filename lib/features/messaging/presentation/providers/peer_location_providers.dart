import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../trust/domain/entities/device_trust_status.dart';
import '../../data/models/secure_chat_message_payload.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/message_status.dart';
import '../../domain/entities/peer_location_share.dart';
import 'local_messaging_providers.dart';

typedef QueuePeerLocation =
    Future<int> Function({
      required double latitude,
      required double longitude,
      required DateTime capturedAt,
    });

final queuePeerLocationProvider = Provider<QueuePeerLocation>((ref) {
  return ({required latitude, required longitude, required capturedAt}) async {
    final body = PeerLocationShare.encodePosition(latitude, longitude);
    final now = DateTime.now().toUtc();
    final captured = capturedAt.toUtc();
    if (captured.isAfter(now) ||
        now.difference(captured) > PeerLocationShare.maxAge) {
      throw const FormatException('Get a fresh GPS position before sharing.');
    }

    final transport = ref.read(scfTransportProvider);
    final sender = await ref.read(localPeerProvider.future);
    final trust = await ref.read(trustRepositoryProvider.future);
    final signingIdentity = await ref.read(
      deviceSigningIdentityProvider.future,
    );
    final senderRecord = await trust.getDevice(sender.id);
    final approval = await trust.getMetadata();
    if (approval?.signatureVerified != true ||
        senderRecord.status != DeviceTrustStatus.approved ||
        senderRecord.signingPublicKey?.replaceAll('=', '') !=
            signingIdentity.encodedPublicKey.replaceAll('=', '')) {
      throw const FormatException(
        'This phone needs current approval before it can share a location.',
      );
    }

    final queue = await ref.read(scfServiceProvider.future);
    final encryption = ref.read(messageEncryptionServiceProvider);
    final seen = <String>{sender.id.toLowerCase()};
    var queued = 0;
    for (final peer in await transport.discoverPeers()) {
      if (!peer.wasSeenRecently(DateTime.now()) ||
          !seen.add(peer.id.toLowerCase())) {
        continue;
      }
      final recipient = await trust.getDevice(peer.id);
      final key = recipient.publicKey;
      if (recipient.status != DeviceTrustStatus.approved ||
          key == null ||
          key.trim().isEmpty ||
          recipient.signingPublicKey == null) {
        continue;
      }
      final prepared = await SecureChatMessagePayload.prepare(
        ChatMessage(
          id: 'location-${now.microsecondsSinceEpoch}',
          conversationId: PeerLocationShare.conversationId,
          sender: sender,
          recipient: peer,
          body: body,
          status: MessageStatus.queued,
          createdAt: captured,
          ttl: PeerLocationShare.lifetime,
        ),
        encryptionService: encryption,
        recipientPublicKey: key,
        recipientKeyVersion: recipient.keyVersion,
        signingIdentity: signingIdentity,
      );
      if (await queue.storePayload(payloadJson: prepared.payloadJson)) queued++;
    }
    return queued;
  };
});

final sharedPeerLocationsProvider =
    NotifierProvider<SharedPeerLocations, Map<String, PeerLocationShare>>(
      SharedPeerLocations.new,
    );

class SharedPeerLocations extends Notifier<Map<String, PeerLocationShare>> {
  Timer? _expiryTimer;

  @override
  Map<String, PeerLocationShare> build() {
    ref.onDispose(() => _expiryTimer?.cancel());
    return const {};
  }

  void record(PeerLocationShare share) {
    final id = share.peerId.toLowerCase();
    final existing = state[id];
    if (!share.expiresAt.isAfter(DateTime.now()) ||
        (existing != null && !share.sharedAt.isAfter(existing.sharedAt))) {
      return;
    }
    state = Map.unmodifiable({...state, id: share});
    _scheduleExpiry();
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    if (state.isEmpty) return;
    final next = state.values
        .map((share) => share.expiresAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    _expiryTimer = Timer(next.difference(DateTime.now()), () {
      final now = DateTime.now();
      state = Map.unmodifiable({
        for (final entry in state.entries)
          if (entry.value.expiresAt.isAfter(now)) entry.key: entry.value,
      });
      _scheduleExpiry();
    });
  }
}
