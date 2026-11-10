import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/peer.dart';

final nearbyPeerSightingsProvider =
    NotifierProvider<NearbyPeerSightings, List<Peer>>(NearbyPeerSightings.new);

class NearbyPeerSightings extends Notifier<List<Peer>> {
  NearbyPeerSightings({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  Timer? _expiryTimer;

  @override
  List<Peer> build() {
    ref.onDispose(() => _expiryTimer?.cancel());
    return const [];
  }

  void replace(List<Peer> snapshot) {
    _expiryTimer?.cancel();
    final now = _now();
    final recent = snapshot.where((peer) => peer.wasSeenRecently(now)).toList()
      ..sort((a, b) {
        if (a.isConnected != b.isConnected) return a.isConnected ? -1 : 1;
        return b.lastSeenAt!.compareTo(a.lastSeenAt!);
      });
    state = List.unmodifiable(recent);
    if (recent.isEmpty) return;
    final earliest = recent
        .map((peer) => peer.lastSeenAt!)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    _expiryTimer = Timer(
      earliest.add(Peer.sightingLifetime).difference(now),
      () => replace(state),
    );
  }
}
