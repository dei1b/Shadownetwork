import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/presentation/pages/chat_recipient_page.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/presentation/providers/device_access_provider.dart';

class _TestTrustStore extends TrustBundleStore {
  _TestTrustStore(this.bundle);

  final TrustBundle bundle;

  @override
  Future<TrustBundle?> loadBundle() async => bundle;
}

void main() {
  testWidgets('find and select registered contacts without nearby discovery', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    TrustedDevice device(
      String id,
      String name,
      String role, {
      String? key = 'registered-public-key',
    }) => TrustedDevice(
      deviceId: id,
      ownerName: name,
      role: role,
      status: 'approved',
      updatedAt: now,
      publicKey: key,
    );
    Peer? selected;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localPeerProvider.overrideWith(
            (ref) async => const Peer(
              id: 'self',
              name: 'My phone',
              type: PeerType.responder,
              isConnected: false,
            ),
          ),
          trustBundleStoreProvider.overrideWithValue(
            _TestTrustStore(
              TrustBundle(
                schemaVersion: 2,
                generatedAt: now,
                expiresAt: now.add(const Duration(hours: 1)),
                isSignatureVerified: true,
                approvedDevices: [
                  device('SELF', 'My phone', 'responder'),
                  device('civilian', 'Ana Santos', 'civilian'),
                  device('rescuer', 'Ben Cruz', 'rescuer'),
                  device('no-key', 'No key', 'civilian', key: null),
                ],
                revokedDevices: [
                  device('revoked', 'Revoked phone', 'civilian'),
                ],
              ),
            ),
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await Navigator.of(context).push<Peer>(
                    MaterialPageRoute(
                      builder: (_) => const ChatRecipientPage(),
                    ),
                  );
                },
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    expect(find.text('Ana Santos'), findsOneWidget);
    expect(find.text('Ben Cruz'), findsOneWidget);
    expect(find.text('My phone'), findsNothing);
    expect(find.text('No key'), findsNothing);
    expect(find.text('Revoked phone'), findsNothing);
    await tester.enterText(find.byType(TextField), 'SANTOS');
    await tester.pumpAndSettle();
    expect(find.text('Ben Cruz'), findsNothing);
    await tester.tap(find.text('Ana Santos'));
    await tester.pumpAndSettle();
    expect(selected?.id, 'civilian');
    expect(selected?.type, PeerType.civilian);
    expect(selected?.isConnected, isFalse);
  });
}
