import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';
import '../providers/local_messaging_providers.dart';

class ChatRecipientPage extends ConsumerStatefulWidget {
  const ChatRecipientPage({super.key});

  @override
  ConsumerState<ChatRecipientPage> createState() => _ChatRecipientPageState();
}

class _ChatRecipientPageState extends ConsumerState<ChatRecipientPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final peers = ref.watch(registeredChatPeersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('New message')),
      body: SafeArea(
        child: peers.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => Center(
            child: TextButton.icon(
              onPressed: () => ref.invalidate(registeredChatPeersProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Couldn’t load registered phones. Retry'),
            ),
          ),
          data: (devices) {
            if (devices.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No registered phones available. Ask your barangay admin for a current approval code.',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            final matches = devices
                .where((device) {
                  return device.ownerName.toLowerCase().contains(_query) ||
                      device.deviceId.toLowerCase().contains(_query);
                })
                .toList(growable: false);
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    onChanged: (value) =>
                        setState(() => _query = value.trim().toLowerCase()),
                    decoration: const InputDecoration(
                      labelText: 'Find a registered person',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                Expanded(
                  child: matches.isEmpty
                      ? const Center(child: Text('No matching people'))
                      : ListView.builder(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: matches.length,
                          itemBuilder: (context, index) {
                            final device = matches[index];
                            final (type, role) = switch (device.role
                                .trim()
                                .toLowerCase()) {
                              'rescuer' ||
                              'responder' => (PeerType.responder, 'Rescuer'),
                              'relay' => (PeerType.relay, 'Relay'),
                              'admin' => (PeerType.authority, 'Admin'),
                              _ => (PeerType.civilian, 'Civilian'),
                            };
                            return ListTile(
                              leading: Icon(
                                type == PeerType.responder
                                    ? Icons.health_and_safety_outlined
                                    : Icons.person_outline,
                              ),
                              title: Text(device.ownerName),
                              subtitle: Text('$role · ${device.deviceId}'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => Navigator.of(context).pop(
                                Peer(
                                  id: device.deviceId,
                                  name: device.ownerName,
                                  type: type,
                                  isConnected: false,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
