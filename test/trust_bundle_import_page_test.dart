import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/security/domain/entities/device_crypto_identity.dart';
import 'package:shadownetwork/features/security/domain/entities/device_signing_identity.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/domain/repositories/trust_repository.dart';
import 'package:shadownetwork/features/trust/presentation/pages/trust_bundle_import_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/signed_trust_bundle_fixture.dart';

class _TrustRepository implements TrustRepository {
  @override
  Future<void> replaceFromBundle(TrustBundle bundle) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'saved approval shows whether the signed code covers this phone',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final key = List<int>.generate(32, (index) => index);
      final identity = DeviceCryptoIdentity(
        keyId: 'test',
        keyVersion: 1,
        privateKeyBytes: key,
        publicKeyBytes: key,
      );
      final signingIdentity = DeviceSigningIdentity(
        privateKeyBytes: key,
        publicKeyBytes: key,
      );
      const peer = Peer(
        id: 'SN-RESIDENT-01',
        name: 'Resident',
        type: PeerType.civilian,
        isConnected: false,
      );
      final signer = await TestTrustBundleSigner.create();
      final now = DateTime.now().toUtc();
      var code = await signer.sign(bundleVersion: 1, issuedAt: now);
      final approvedCode = await signer.sign(
        bundleVersion: 2,
        issuedAt: now,
        approvedDevices: [
          TrustedDevice(
            deviceId: peer.id,
            ownerName: peer.name,
            role: 'civilian',
            status: 'approved',
            updatedAt: now,
            publicKey: identity.encodedPublicKey,
            signingPublicKey: signingIdentity.encodedPublicKey,
            keyVersion: identity.keyVersion,
          ),
        ],
      );
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        return call.method == 'Clipboard.getData' ? {'text': code} : null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localPeerProvider.overrideWith((ref) async => peer),
            deviceCryptoIdentityProvider.overrideWith((ref) async => identity),
            deviceSigningIdentityProvider.overrideWith(
              (ref) async => signingIdentity,
            ),
            trustRepositoryProvider.overrideWith(
              (ref) async => _TrustRepository(),
            ),
          ],
          child: const MaterialApp(home: TrustBundleImportPage()),
        ),
      );
      await tester.pumpAndSettle();
      final paste = find.text('Paste copied code');
      await tester.ensureVisible(paste);
      await tester.tap(paste);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trust administrator'));
      await tester.pumpAndSettle();
      expect(find.text('This phone is still unregistered'), findsOneWidget);

      code = approvedCode;
      await tester.ensureVisible(paste);
      await tester.tap(paste);
      await tester.pumpAndSettle();
      expect(find.text('This phone is approved'), findsOneWidget);
      expect(find.text('This phone is still unregistered'), findsNothing);
    },
  );
}
