import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/registration/data/pilot_registration.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/presentation/pilot_registration_page.dart';
import 'package:shadownetwork/features/registration/presentation/profile_section.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/approval_receipt.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/presentation/providers/device_access_provider.dart';

import '../../support/signed_trust_bundle_fixture.dart';

class _Student extends Fake implements User {
  @override
  String get uid => 'student-link-retry';

  @override
  String get email => 'student@dnsc.edu.ph';
}

class _Auth extends Fake implements FirebaseAuth {
  _Auth(this.currentUser);

  @override
  final User? currentUser;
}

class _ReceiptStore extends TrustBundleStore {
  _ReceiptStore(this.receipt);

  final SignedApprovalReceipt receipt;

  @override
  Future<SignedApprovalReceipt?> loadReceipt() async => receipt;
}

class _LinkRetryRegistration extends PilotRegistration {
  _LinkRetryRegistration() : super(_Auth(_Student()));

  ReviewApplication? serverApp;
  ReviewApplication? serverLinkRequest;
  int submitCount = 0;

  @override
  Future<Map<String, dynamic>> loadDraft(String uid) async => const {};

  @override
  Future<ReviewApplication?> readCachedProfile(User user) async => null;

  @override
  Future<ReviewApplication?> refreshProfile(User user) async => serverApp;

  @override
  Future<ReviewApplication?> readLinkRequest(User user) async =>
      serverLinkRequest;

  @override
  Future<ReviewApplication?> readRecoveryRequest(User user) async => null;

  @override
  Future<void> submitLinkRequest(User user, AccountLinkProof proof) async {
    submitCount++;
    serverLinkRequest = ReviewApplication.fromCache(
      id: user.uid,
      updateTime: 'link-$submitCount',
      fields: {
        'accountUid': user.uid,
        'registrationId': proof.registrationId,
        'deviceId': proof.deviceId,
        'publicKey': proof.publicKey,
        'signingPublicKey': proof.signingPublicKey,
        'keyVersion': proof.keyVersion,
        'status': 'pending',
      },
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('firestore.rules restricts owner link updates to pending status', () {
    final rules = File('firestore.rules').readAsStringSync();
    final blockStart = rules.indexOf('match /registrationLinkRequests/{uid}');
    expect(blockStart, isNot(-1));
    final blockEnd = rules.indexOf(
      'match /registrationRecoveryRequests/{uid}',
      blockStart,
    );
    final linkRules = rules.substring(blockStart, blockEnd);
    expect(linkRules, contains('allow create:'));
    expect(linkRules, contains('allow update:'));
    expect(linkRules, contains("resource.data.status == 'pending'"));
  });

  testWidgets(
    'ProfileSection link retry skips redundant write on pending proof and transitions on linked/rejected',
    (tester) async {
      final signer = await TestTrustBundleSigner.create();
      const peer = Peer(
        id: 'phone-retry-1',
        name: 'phone-retry-1',
        type: PeerType.civilian,
        isConnected: false,
      );
      final secrets = InMemorySecretValueStore();
      final crypto = await DeviceIdentityStore(
        secretStore: secrets,
      ).loadOrCreate();
      final signing = await DeviceSigningIdentityStore(
        secretStore: secrets,
      ).loadOrCreate();
      final now = DateTime.now().toUtc();
      final receipt = await SignedApprovalReceipt.createSigned(
        registrationId: 'reg-retry-1',
        deviceId: peer.id,
        publicKey: crypto.encodedPublicKey,
        signingPublicKey: signing.encodedPublicKey,
        keyVersion: crypto.keyVersion,
        issuer: TrustBundleIssuer(
          issuerId: signer.issuerId,
          signingKeyId: 'k1',
          signatureAlgorithm: 'ed25519',
          publicKey: base64UrlEncode(signer.publicKeyBytes),
        ),
        issuerKeyPair: signer.keyPair as SimpleKeyPair,
        issuedAt: now,
        expiresAt: now.add(const Duration(days: 30)),
      );
      final store = _ReceiptStore(receipt);

      final reg = _LinkRetryRegistration();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localPeerProvider.overrideWith((ref) async => peer),
            deviceCryptoIdentityProvider.overrideWith((ref) async => crypto),
            deviceSigningIdentityProvider.overrideWith((ref) async => signing),
            trustBundleStoreProvider.overrideWithValue(store),
            deviceAccessProfileProvider.overrideWith(
              (ref) async => const DeviceAccessProfile(
                deviceId: 'phone-retry-1',
                level: DeviceAccessLevel.civilian,
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProfileSection(
                  active: true,
                  access: const DeviceAccessProfile(
                    deviceId: 'phone-retry-1',
                    level: DeviceAccessLevel.civilian,
                  ),
                  openRegistration: () async => reg,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // First tap submits proof cleanly.
      final firstBtn = find.widgetWithText(
        FilledButton,
        'Link this phone to my account',
      );
      await tester.ensureVisible(firstBtn);
      await tester.tap(firstBtn);
      await tester.pumpAndSettle();
      expect(reg.submitCount, 1);

      // Tapping Retry while matching proof is still pending does not overwrite.
      final retryBtn = find.widgetWithText(
        FilledButton,
        'Waiting for campus sync · Retry',
      );
      await tester.tap(retryBtn);
      await tester.pumpAndSettle();
      expect(reg.submitCount, 1);
      expect(
        find.text('Link request is already pending campus admin approval.'),
        findsOneWidget,
      );

      // Server transitions linkRequest to rejected -> retry surfaces outcome without submitting.
      reg.serverLinkRequest = ReviewApplication.fromCache(
        id: 'student-link-retry',
        updateTime: 'link-2',
        fields: {
          'registrationId': 'reg-retry-1',
          'status': 'rejected',
        },
      );
      await tester.tap(find.byType(FilledButton).first);
      await tester.pumpAndSettle();
      expect(reg.submitCount, 1);
      expect(
        find.text('Phone link request was rejected by campus admin.'),
        findsOneWidget,
      );

      // Server transitions to linked -> retry transitions state without submitting.
      reg.serverLinkRequest = ReviewApplication.fromCache(
        id: 'student-link-retry',
        updateTime: 'link-3',
        fields: {
          'registrationId': 'reg-retry-1',
          'status': 'linked',
        },
      );
      await tester.tap(find.byType(FilledButton).first);
      await tester.pumpAndSettle();
      expect(reg.submitCount, 1);
      expect(
        find.text('This phone is already linked to your account.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'PilotRegistrationPage link retry handles completed link without overwriting server request',
    (tester) async {
      final signer = await TestTrustBundleSigner.create();
      const peer = Peer(
        id: 'phone-retry-2',
        name: 'phone-retry-2',
        type: PeerType.civilian,
        isConnected: false,
      );
      final secrets = InMemorySecretValueStore();
      final crypto = await DeviceIdentityStore(
        secretStore: secrets,
      ).loadOrCreate();
      final signing = await DeviceSigningIdentityStore(
        secretStore: secrets,
      ).loadOrCreate();
      final now = DateTime.now().toUtc();
      final receipt = await SignedApprovalReceipt.createSigned(
        registrationId: 'reg-retry-2',
        deviceId: peer.id,
        publicKey: crypto.encodedPublicKey,
        signingPublicKey: signing.encodedPublicKey,
        keyVersion: crypto.keyVersion,
        issuer: TrustBundleIssuer(
          issuerId: signer.issuerId,
          signingKeyId: 'k1',
          signatureAlgorithm: 'ed25519',
          publicKey: base64UrlEncode(signer.publicKeyBytes),
        ),
        issuerKeyPair: signer.keyPair as SimpleKeyPair,
        issuedAt: now,
        expiresAt: now.add(const Duration(days: 30)),
      );
      final store = _ReceiptStore(receipt);

      final reg = _LinkRetryRegistration()
        ..serverLinkRequest = ReviewApplication.fromCache(
          id: 'student-link-retry',
          updateTime: 'link-pending',
          fields: {
            'registrationId': 'reg-retry-2',
            'deviceId': peer.id,
            'publicKey': crypto.encodedPublicKey,
            'signingPublicKey': signing.encodedPublicKey,
            'keyVersion': crypto.keyVersion,
            'status': 'pending',
          },
        );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localPeerProvider.overrideWith((ref) async => peer),
            deviceCryptoIdentityProvider.overrideWith((ref) async => crypto),
            deviceSigningIdentityProvider.overrideWith((ref) async => signing),
            trustBundleStoreProvider.overrideWithValue(store),
            deviceAccessProfileProvider.overrideWith(
              (ref) async => const DeviceAccessProfile(
                deviceId: 'phone-retry-2',
                level: DeviceAccessLevel.civilian,
              ),
            ),
          ],
          child: MaterialApp(
            home: PilotRegistrationPage(openRegistration: () async => reg),
          ),
        ),
      );
      await tester.pumpAndSettle();

      reg.serverLinkRequest = ReviewApplication.fromCache(
        id: 'student-link-retry',
        updateTime: 'link-linked',
        fields: {
          'registrationId': 'reg-retry-2',
          'status': 'linked',
        },
      );
      final retryBtn = find.widgetWithText(
        FilledButton,
        'Waiting for campus sync · Retry',
      );
      await tester.ensureVisible(retryBtn);
      await tester.tap(retryBtn);
      await tester.pumpAndSettle();
      expect(reg.submitCount, 0);
      expect(
        find.text('This phone is already linked to your account.'),
        findsOneWidget,
      );
    },
  );
}
