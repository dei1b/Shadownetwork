import 'package:flutter_riverpod/flutter_riverpod.dart';

enum PeerConnectionState { disconnected, discovering, connected }

class ConnectionStatusViewModel {
  const ConnectionStatusViewModel({
    required this.connectionState,
    required this.connectedPeers,
    required this.lastUpdated,
    this.errorText,
  });

  final PeerConnectionState connectionState;
  final int connectedPeers;
  final DateTime lastUpdated;
  final String? errorText;
}

final connectionStatusProvider = Provider<ConnectionStatusViewModel>((ref) {
  return ConnectionStatusViewModel(
    connectionState: PeerConnectionState.discovering,
    connectedPeers: 2,
    lastUpdated: DateTime.now(),
    errorText: null,
  );
});
