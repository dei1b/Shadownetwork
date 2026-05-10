import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../messaging/presentation/providers/relay_runtime_provider.dart';

enum PeerConnectionState {
  permissionsRequired,
  disconnected,
  discovering,
  connected,
}

class ConnectionStatusViewModel {
  const ConnectionStatusViewModel({
    required this.connectionState,
    required this.discoveredPeers,
    required this.connectedPeers,
    required this.lastUpdated,
    this.localPeerName,
    this.errorText,
  });

  final PeerConnectionState connectionState;
  final int discoveredPeers;
  final int connectedPeers;
  final DateTime lastUpdated;
  final String? localPeerName;
  final String? errorText;
}

final connectionStatusProvider = Provider<ConnectionStatusViewModel>((ref) {
  final runtime = ref.watch(relayRuntimeProvider);
  final connectionState = !runtime.permissionsGranted
      ? PeerConnectionState.permissionsRequired
      : runtime.isSyncing
      ? PeerConnectionState.discovering
      : runtime.connectedPeers > 0
      ? PeerConnectionState.connected
      : PeerConnectionState.disconnected;

  return ConnectionStatusViewModel(
    connectionState: connectionState,
    discoveredPeers: runtime.discoveredPeers,
    connectedPeers: runtime.connectedPeers,
    lastUpdated: runtime.lastUpdated ?? DateTime.now(),
    localPeerName: runtime.localPeer?.name,
    errorText: runtime.lastError,
  );
});
