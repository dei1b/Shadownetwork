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
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

import '../../support/signed_trust_bundle_fixture.dart';

class _RecoveryReviewApi extends RegistrationReviewApi {
  _RecoveryReviewApi({
    required this.campusRegistrations,
    required this.recoveryRequests,
  }) : super(
         Uri.https(
           'firestore.googleapis.com',
           '/v1/projects/test/databases/(default)/documents/pilotApplications',
         ),
       );

  List<ReviewApplication> campusRegistrations;
  List<ReviewApplication> recoveryRequests;

  @override
  Future<List<ReviewApplication>> list(String token) async => const [];

  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async {
    if (name == 'campusRegistrations') return campusRegistrations;
    if (name == 'registrationRecoveryRequests') return recoveryRequests;
    return const [];
  }

  @override
  Future<({int version, String bundle, String updateTime})?> readDirectory(
    String token,
  ) async => null;
}

class _RecoveryPublisher extends HostedPublisherClient {
  _RecoveryPublisher(this.signer)
    : super(endpoint: Uri.parse('https://admin.test/api/publish-approval'));

  final TestTrustBundleSigner signer;
  final List<Map<String, Object?>> payloads = [];

  @override
  Future<HostedPublishResult> publishDecision({
    required String token,
    required Map<String, Object?> payload,
  }) async {
    payloads.add(payload);
    final qr = DeviceRegistrationQr.fromJsonString(
      payload['deviceRegistration']! as String,
    );
    final bundleJson = await signer.sign(
      bundleVersion: 2,
      issuedAt: DateTime.utc(2026, 11, 26, 12),
      approvedDevices: [
        TrustedDevice(
          deviceId: qr.deviceId,
          ownerName: 'Recovered User',
          role: payload['role'] as String? ?? 'civilian',
          status: 'approved',
          publicKey: qr.publicKey,
          signingPublicKey: qr.signingPublicKey,
          keyVersion: qr.keyVersion,
          updatedAt: DateTime.utc(2026, 11, 26, 12),
        ),
      ],
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

Future<DeviceRegistrationQr> _signedQr(String deviceId) async {
  final secrets = InMemorySecretValueStore();
  final crypto = await DeviceIdentityStore(secretStore: secrets).loadOrCreate();
  final signing = await DeviceSigningIdentityStore(
    secretStore: secrets,
  ).loadOrCreate();
  return DeviceRegistrationQr.createSigned(
    deviceId: deviceId,
    identity: crypto,
    signingIdentity: signing,
  );
}

ReviewApplication _remoteRegDoc({
  required String regId,
  required String affiliation,
  required String displayName,
  required String schoolId,
  required DeviceRegistrationQr qr,
}) {
  return ReviewApplication.fromCache(
    id: regId,
    updateTime: '2026-11-26T10:00:00Z',
    fields: {
      'registrationId': regId,
      'affiliation': affiliation,
      'displayName': displayName,
      if (affiliation == 'student') 'studentNumber': schoolId,
      if (affiliation == 'student') 'course': 'BSIT',
      if (affiliation == 'student') 'yearLevel': '3',
      if (affiliation == 'student') 'sectionSet': 'A',
      if (affiliation == 'staff') 'employeeId': schoolId,
      if (affiliation == 'staff') 'unit': 'DRRM',
      'status': 'published',
      'role': 'civilian',
      'revision': 1,
      'deviceId': qr.deviceId,
      'publicKey': qr.publicKey,
      'signingPublicKey': qr.signingPublicKey,
      'keyVersion': qr.keyVersion,
      'deviceRegistration': jsonEncode(qr.toJson()),
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final reverseOrder in [false, true]) {
    testWidgets(
      'R7: unlinked recovery matches normalized affiliation + schoolId even when Student and Staff share 2026-1001 (reverseOrder=$reverseOrder)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final signer = await TestTrustBundleSigner.create();
        final stuOldQr = await _signedQr('phone-stu-old');
        final staffOldQr = await _signedQr('phone-staff-old');
        final newStaffQr = await _signedQr('phone-staff-new');

        final stuDoc = _remoteRegDoc(
          regId: 'reg-stu-1001',
          affiliation: 'student',
          displayName: 'Anna Student',
          schoolId: '2026-1001',
          qr: stuOldQr,
        );
        final staffDoc = _remoteRegDoc(
          regId: 'reg-staff-1001',
          affiliation: 'staff',
          displayName: 'Bernadette Staff',
          schoolId: '2026-1001',
          qr: staffOldQr,
        );
        final rows = reverseOrder ? [staffDoc, stuDoc] : [stuDoc, staffDoc];
        final recDoc = ReviewApplication.fromCache(
          id: 'uid-staff-recover',
          updateTime: '2026-11-26T11:00:00Z',
          fields: {
            'accountUid': 'uid-staff-recover',
            'affiliation': 'staff',
            'schoolId': '2026-1001',
            'displayName': 'Bernadette Staff',
            'email': 'bernadette@dnsc.edu.ph',
            'deviceRegistration': jsonEncode(newStaffQr.toJson()),
            'status': 'submitted',
          },
        );
        final api = _RecoveryReviewApi(
          campusRegistrations: rows,
          recoveryRequests: [recDoc],
        );
        final publisher = _RecoveryPublisher(signer);

        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: AdminTheme.light,
            home: Scaffold(
              body: UnifiedRegistrationsWorkspace(
                reviewApi: api,
                publisherClient: publisher,
                initialSessionForTesting: (
                  token: 'tok-admin',
                  uid: 'uid-admin',
                  email: 'admin@dnsc.edu.ph',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Only the Staff row should carry the recovery request badge.
        expect(find.text('Lost phone recovery'), findsOneWidget);
        expect(find.text('Bernadette Staff'), findsOneWidget);

        await tester.tap(find.text('Bernadette Staff'));
        await tester.pumpAndSettle();

        expect(find.text('Device ID: phone-staff-old'), findsOneWidget);
        expect(find.text('Device ID: phone-staff-new'), findsOneWidget);

        await tester.ensureVisible(find.text('Approve replacement'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Approve replacement'));
        await tester.pumpAndSettle();

        expect(publisher.payloads, hasLength(1));
        expect(publisher.payloads.single['action'], 'approve_recovery');
        expect(
          publisher.payloads.single['registrationId'],
          'reg-staff-1001',
        );
        expect(
          publisher.payloads.single['accountUid'],
          'uid-staff-recover',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'R7: duplicate same-affiliation same-ID candidates stay unresolved until admin selects exact target',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final signer = await TestTrustBundleSigner.create();
      final qrA = await _signedQr('phone-dup-a');
      final qrB = await _signedQr('phone-dup-b');
      final newQr = await _signedQr('phone-dup-new');

      final regA = _remoteRegDoc(
        regId: 'reg-dup-a',
        affiliation: 'student',
        displayName: 'Student Alpha',
        schoolId: '2026-1001',
        qr: qrA,
      );
      final regB = _remoteRegDoc(
        regId: 'reg-dup-b',
        affiliation: 'student',
        displayName: 'Student Beta',
        schoolId: '2026-1001',
        qr: qrB,
      );
      final recDoc = ReviewApplication.fromCache(
        id: 'uid-rec-dup',
        updateTime: '2026-11-26T11:30:00Z',
        fields: {
          'accountUid': 'uid-rec-dup',
          'affiliation': 'student',
          'schoolId': '2026-1001',
          'displayName': 'Student Beta',
          'email': 'beta@dnsc.edu.ph',
          'deviceRegistration': jsonEncode(newQr.toJson()),
          'status': 'submitted',
        },
      );
      final api = _RecoveryReviewApi(
        campusRegistrations: [regA, regB],
        recoveryRequests: [recDoc],
      );
      final publisher = _RecoveryPublisher(signer);

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: Scaffold(
            body: UnifiedRegistrationsWorkspace(
              reviewApi: api,
              publisherClient: publisher,
              initialSessionForTesting: (
                token: 'tok-admin',
                uid: 'uid-admin',
                email: 'admin@dnsc.edu.ph',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ambiguous recovery (2 matches)'), findsOneWidget);
      await tester.tap(find.text('Ambiguous recovery (2 matches)'));
      await tester.pumpAndSettle();

      // Approve replacement must remain disabled until admin picks a candidate.
      final dialogFinder = find.byType(AlertDialog);
      final approveBtnFinder = find.descendant(
        of: dialogFinder,
        matching: find.widgetWithText(FilledButton, 'Approve replacement'),
      );
      expect(tester.widget<FilledButton>(approveBtnFinder).onPressed, isNull);
      final candAFinder = find.descendant(
        of: dialogFinder,
        matching: find.textContaining('reg-dup-a'),
      );
      final candBFinder = find.descendant(
        of: dialogFinder,
        matching: find.textContaining('reg-dup-b'),
      );
      expect(candAFinder, findsOneWidget);
      expect(candBFinder, findsOneWidget);

      await tester.ensureVisible(candBFinder);
      await tester.pumpAndSettle();
      await tester.tap(candBFinder);
      await tester.pumpAndSettle();

      expect(tester.widget<FilledButton>(approveBtnFinder).onPressed, isNotNull);
      await tester.ensureVisible(approveBtnFinder);
      await tester.pumpAndSettle();
      await tester.tap(approveBtnFinder);
      await tester.pumpAndSettle();

      expect(publisher.payloads, hasLength(1));
      expect(publisher.payloads.single['action'], 'approve_recovery');
      expect(publisher.payloads.single['registrationId'], 'reg-dup-b');
      expect(publisher.payloads.single['accountUid'], 'uid-rec-dup');
      expect(tester.takeException(), isNull);
    },
  );
}
