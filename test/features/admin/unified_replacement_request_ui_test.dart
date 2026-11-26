import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/hosted_publisher_client.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';

import '../../support/signed_trust_bundle_fixture.dart';

class _FakeReviewApi extends RegistrationReviewApi {
  _FakeReviewApi(this.apps)
    : super(
        Uri.https(
          'firestore.googleapis.com',
          '/v1/projects/test/databases/(default)/documents/pilotApplications',
        ),
      );

  final List<ReviewApplication> apps;

  @override
  Future<List<ReviewApplication>> list(String token) async => apps;

  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async => const [];

  @override
  Future<({int version, String bundle, String updateTime})?> readDirectory(
    String token,
  ) async => null;
}

class _CapturingPublisher extends HostedPublisherClient {
  _CapturingPublisher(this.signer)
    : super(endpoint: Uri.parse('https://admin.test/api/publish-approval'));

  final TestTrustBundleSigner signer;
  final List<Map<String, Object?>> payloads = [];

  @override
  Future<HostedPublishResult> publishDecision({
    required String token,
    required Map<String, Object?> payload,
  }) async {
    payloads.add(payload);
    final bundleJson = await signer.sign(
      bundleVersion: 2,
      issuedAt: DateTime.utc(2026, 11, 26, 12),
    );
    return HostedPublishResult(
      status: 'published',
      version: 2,
      bundle: bundleJson,
      registrationId: payload['registrationId'] as String?,
      decisionId: payload['decisionId'] as String,
      idempotent: false,
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'online replacementRequest parses proposed phone QR into key diff and enables Approve replacement; malformed QR shows error',
    (tester) async {
      final signer = await TestTrustBundleSigner.create();
      final validOldSecrets = InMemorySecretValueStore();
      final validOldCrypto = await DeviceIdentityStore(
        secretStore: validOldSecrets,
      ).loadOrCreate();
      final validOldSigning = await DeviceSigningIdentityStore(
        secretStore: validOldSecrets,
      ).loadOrCreate();
      final validOldQr = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-rep-valid',
        identity: validOldCrypto,
        signingIdentity: validOldSigning,
      );

      final badOldSecrets = InMemorySecretValueStore();
      final badOldCrypto = await DeviceIdentityStore(
        secretStore: badOldSecrets,
      ).loadOrCreate();
      final badOldSigning = await DeviceSigningIdentityStore(
        secretStore: badOldSecrets,
      ).loadOrCreate();
      final badOldQr = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-rep-bad',
        identity: badOldCrypto,
        signingIdentity: badOldSigning,
      );

      final newSecrets = InMemorySecretValueStore();
      final newCrypto = await DeviceIdentityStore(
        secretStore: newSecrets,
      ).loadOrCreate();
      final newSigning = await DeviceSigningIdentityStore(
        secretStore: newSecrets,
      ).loadOrCreate();
      final newQr = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-rep-valid',
        identity: newCrypto,
        signingIdentity: newSigning,
      );
      final newQrJson = jsonEncode(newQr.toJson());

      final validApp = ReviewApplication.fromCache(
        id: 'uid-valid-rep',
        updateTime: '2026-11-26T10:00:00Z',
        fields: {
          'affiliation': 'student',
          'displayName': 'Valid Replacement Student',
          'studentNumber': '2026-8101',
          'course': 'BSIT',
          'yearLevel': '4',
          'sectionSet': 'A',
          'status': 'published',
          'revision': 1,
          'registrationId': 'reg-valid-rep',
          'deviceRegistration': jsonEncode(validOldQr.toJson()),
          'replacementRequest': {
            'status': 'submitted',
            'reason': 'Cleared app data',
            'deviceRegistration': newQrJson,
          },
        },
      );
      final badQrApp = ReviewApplication.fromCache(
        id: 'uid-bad-rep',
        updateTime: '2026-11-26T10:01:00Z',
        fields: {
          'affiliation': 'student',
          'displayName': 'Bad Replacement QR Student',
          'studentNumber': '2026-8102',
          'course': 'BSIT',
          'yearLevel': '4',
          'sectionSet': 'B',
          'status': 'published',
          'revision': 1,
          'registrationId': 'reg-bad-rep',
          'deviceRegistration': jsonEncode(badOldQr.toJson()),
          'replacementRequest': {
            'status': 'submitted',
            'reason': 'Broken payload',
            'deviceRegistration': '{not-valid-json',
          },
        },
      );

      final publisher = _CapturingPublisher(signer);
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: Scaffold(
            body: UnifiedRegistrationsWorkspace(
              reviewApi: _FakeReviewApi([validApp, badQrApp]),
              publisherClient: publisher,
              initialSessionForTesting: (
                token: 'tok',
                uid: 'admin-uid',
                email: 'admin@dnsc.edu.ph',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Bad QR item surfaces readable error and keeps Approve replacement disabled/absent.
      await tester.tap(find.text('Bad Replacement QR Student'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Replacement registration payload is unreadable'),
        findsOneWidget,
      );
      final disabledApproveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Approve replacement'),
      );
      expect(disabledApproveBtn.onPressed, isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // Valid replacement shows proposed keys side-by-side and dispatches approve_replacement.
      await tester.tap(find.text('Valid Replacement Student'));
      await tester.pumpAndSettle();
      expect(find.text('Proposed replacement phone keys'), findsOneWidget);
      expect(find.textContaining(newQr.publicKey), findsOneWidget);

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Approve replacement'),
      );
      await tester.tap(
        find.widgetWithText(FilledButton, 'Approve replacement'),
      );
      await tester.pumpAndSettle();

      expect(publisher.payloads, hasLength(1));
      expect(publisher.payloads.single['action'], 'approve_replacement');
      expect(publisher.payloads.single['deviceRegistration'], newQrJson);
      expect(
        publisher.payloads.single['expectedRequestUpdateTime'],
        validApp.updateTime,
      );
      expect(publisher.payloads.single['expectedOldPhone'], {
        'deviceId': validOldQr.deviceId,
        'publicKey': validOldQr.publicKey,
        'signingPublicKey': validOldQr.signingPublicKey,
        'keyVersion': validOldQr.keyVersion,
      });
    },
  );
}
