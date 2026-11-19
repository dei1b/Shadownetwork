import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../registration/data/pilot_registration.dart';
import '../../../trust/domain/entities/device_access_profile.dart';
import '../../../trust/presentation/providers/device_access_provider.dart';
import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';
import '../providers/local_messaging_providers.dart';

final chatRegistrationOpenerProvider =
    Provider<Future<PilotRegistration> Function()?>(
      (ref) => pilotRegistrationEnabled ? PilotRegistration.open : null,
    );

const _checkRegistration =
    'Open Profile to check your registration and phone access.';

final _chatRegistrationGuidanceProvider = FutureProvider.autoDispose<String>((
  ref,
) async {
  final openRegistration = ref.watch(chatRegistrationOpenerProvider);
  if (openRegistration == null) {
    return 'In Profile, open Settings, then Advanced and Backup registration.';
  }
  final registration = await openRegistration();
  final user = registration.auth.currentUser;
  if (user == null) {
    return 'Open Profile to sign in or register with DNSC when online.';
  }

  final profile = await registration.readCachedProfile(user);
  final status = profile?.status;
  final draft = status == null || status == 'changes_requested'
      ? await registration.loadDraft(user.uid)
      : null;
  if (registration.auth.currentUser?.uid != user.uid) return _checkRegistration;
  final draftSubmitted = draft?['submitted'] == true;

  return switch (status) {
    'submitted' =>
      'Your application is pending review. Check its status in Profile when online.',
    'approved_pending_publication' =>
      'Your application was approved and is waiting for access to be published. Check Profile for updates.',
    'changes_requested'
        when !draftSubmitted ||
            draft?['correctionRevision'] != profile?.updateTime =>
      'DNSC requested changes. Open Profile to update your application.',
    'published' =>
      'Your account was approved. Open Profile to check access on this phone.',
    'rejected' =>
      'Your application was declined. Open Profile to review the decision.',
    _ when draftSubmitted =>
      'You have a saved submission. Check its review status in Profile when online.',
    null => 'Open Profile to finish your DNSC registration when online.',
    _ => _checkRegistration,
  };
});

class ChatRecipientPage extends ConsumerStatefulWidget {
  const ChatRecipientPage({super.key, this.onOpenProfile});

  /// Called after the picker closes without returning a recipient.
  final VoidCallback? onOpenProfile;

  @override
  ConsumerState<ChatRecipientPage> createState() => _ChatRecipientPageState();
}

class _ChatRecipientPageState extends ConsumerState<ChatRecipientPage> {
  String _query = '';

  Widget _buildEmptyDirectory(BuildContext context) {
    final phone = ref.watch(deviceAccessProfileProvider);
    final level = phone.valueOrNull?.level;
    final approved = phone.valueOrNull?.isApproved == true;
    final guidance = switch (level) {
      _ when approved =>
        'This phone has access. Check again after the campus directory is updated.',
      DeviceAccessLevel.outdatedBundle =>
        'This phone’s approval has expired. Check its status in Profile when online.',
      DeviceAccessLevel.keyMismatch || DeviceAccessLevel.revoked =>
        'This phone needs help from a campus administrator. Check phone access in Profile.',
      _ when phone.isLoading => 'Checking access on this phone…',
      _ =>
        ref.watch(_chatRegistrationGuidanceProvider).valueOrNull ??
            _checkRegistration,
    };
    final onOpenProfile = widget.onOpenProfile;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No registered people available.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(guidance, textAlign: TextAlign.center),
            ),
            if (!approved && !phone.isLoading && onOpenProfile != null)
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop<Peer>();
                  onOpenProfile();
                },
                child: const Text('Open Profile'),
              ),
          ],
        ),
      ),
    );
  }

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
              return _buildEmptyDirectory(context);
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
                              'rescuer' || 'responder' => (
                                PeerType.responder,
                                'Campus responder',
                              ),
                              'relay' => (PeerType.relay, 'Relay'),
                              'admin' => (PeerType.authority, 'Admin'),
                              _ => (PeerType.civilian, 'Student'),
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
