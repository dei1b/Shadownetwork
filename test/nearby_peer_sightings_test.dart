import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/nearby_peer_sightings_provider.dart';

void main() {
  testWidgets(
    'cached scans cannot extend a sighting and a new sighting restores it',
    (tester) async {
      var now = DateTime.utc(2026, 11, 10, 12);
      final container = ProviderContainer(
        overrides: [
          nearbyPeerSightingsProvider.overrideWith(
            () => NearbyPeerSightings(now: () => now),
          ),
        ],
      );
      addTearDown(container.dispose);
      final sightings = container.read(nearbyPeerSightingsProvider.notifier);
      const peer = Peer(
        id: 'phone',
        name: 'Phone',
        type: PeerType.civilian,
        isConnected: true,
        signalStrength: 95,
      );

      sightings.replace([peer]);
      expect(container.read(nearbyPeerSightingsProvider), isEmpty);
      final observed = peer.copyWith(lastSeenAt: now);
      sightings.replace([observed]);
      expect(container.read(nearbyPeerSightingsProvider).single.id, 'phone');

      now = now.add(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 60));
      sightings.replace([observed]);
      now = now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      expect(container.read(nearbyPeerSightingsProvider), isEmpty);

      sightings.replace([peer.copyWith(lastSeenAt: now)]);
      expect(container.read(nearbyPeerSightingsProvider).single.id, 'phone');
      sightings.replace(const []);
    },
  );
}
