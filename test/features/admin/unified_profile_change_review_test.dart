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

class _FakeProfileChangeApi extends RegistrationReviewApi {
  _FakeProfileChangeApi(this.apps)
    : super(
        Uri.https(
          'firestore.googleapis.com',
          '/v1/projects/test/databases/(default)/documents/pilotApplications',
        ),
      );

  List<ReviewApplication> apps;

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

class _CapturingProfileChangePublisher extends HostedPublisherClient {
  _CapturingProfileChangePublisher(this.signer)
    : super(endpoint: Uri.parse('https://admin.test/api/publish-approval'));

  final TestTrustBundleSigner signer;
  final List<Map<String, Object?>> payloads = [];

  @override
  Future<HostedPublishResult> publishDecision({
    required String token,
    required Map<String, Object?> payload,
  }) async {
    payloads.add(payload);
    final isDecline = payload['action'] == 'decline_profile_change';
    if (isDecline) {
      return HostedPublishResult(
        status: 'rejected',
        version: 1,
        decisionId: payload['decisionId'] as String,
        idempotent: false,
      );
    }
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
    'unified queue shows Profile change chip, current vs proposed diff, and dispatches approve/decline actions',
    (tester) async {
      final signer = await TestTrustBundleSigner.create();
      final secrets = InMemorySecretValueStore();
      final crypto = await DeviceIdentityStore(
        secretStore: secrets,
      ).loadOrCreate();
      final signing = await DeviceSigningIdentityStore(
        secretStore: secrets,
      ).loadOrCreate();
      final staffQr = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-pc-staff',
        identity: crypto,
        signingIdentity: signing,
      );

      final app = ReviewApplication.fromCache(
        id: 'uid-prof-change',
        updateTime: '2026-11-26T09:00:00Z',
        fields: {
          'affiliation': 'staff',
          'displayName': 'Original Officer',
          'employeeId': 'EMP-400',
          'unit': 'Security Desk',
          'status': 'published',
          'revision': 1,
          'registrationId': 'reg-prof-change',
          'deviceRegistration': jsonEncode(staffQr.toJson()),
          'reviewHistory': [
            {'role': 'responder', 'status': 'published'},
          ],
          'profileChange': {
            'affiliation': 'staff',
            'displayName': 'Updated Officer',
            'employeeId': 'EMP-401',
            'unit': 'Emergency Dispatch',
            'status': 'submitted',
          },
        },
      );

      final publisher = _CapturingProfileChangePublisher(signer);
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: Scaffold(
            body: UnifiedRegistrationsWorkspace(
              reviewApi: _FakeProfileChangeApi([app]),
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

      expect(find.text('Profile change'), findsOneWidget);

      await tester.tap(find.text('Original Officer'));
      await tester.pumpAndSettle();

      expect(find.text('Proposed profile change'), findsOneWidget);
      expect(find.textContaining('Updated Officer'), findsOneWidget);
      expect(find.textContaining('Emergency Dispatch'), findsOneWidget);

      // Decline requires reason; once entered it dispatches decline_profile_change.
      final declineBtn = find.widgetWithText(
        OutlinedButton,
        'Decline profile change',
      );
      await tester.ensureVisible(declineBtn);
      await tester.tap(declineBtn);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Enter a reason for the applicant.'),
        findsOneWidget,
      );
      expect(publisher.payloads, isEmpty);

      await tester.enterText(
        find.widgetWithText(TextField, 'Review note / reason'),
        'ID document blurred',
      );
      await tester.tap(declineBtn);
      await tester.pumpAndSettle();

      expect(publisher.payloads, hasLength(1));
      expect(publisher.payloads.single['action'], 'decline_profile_change');
      expect(publisher.payloads.single['reason'], 'ID document blurred');

      // Open again and approve profile change -> dispatches approve_profile_change with proposed fields.
      await tester.tap(find.text('Original Officer'));
      await tester.pumpAndSettle();
      final approveBtn = find.widgetWithText(
        FilledButton,
        'Approve profile change',
      );
      await tester.ensureVisible(approveBtn);
      await tester.tap(approveBtn);
      await tester.pumpAndSettle();

      expect(publisher.payloads, hasLength(2));
      expect(publisher.payloads.last['action'], 'approve_profile_change');
      final sentFields =
          publisher.payloads.last['reviewedFields'] as Map<String, Object?>;
      expect(sentFields['displayName'], 'Updated Officer');
      expect(sentFields['employeeId'], 'EMP-401');
      expect(sentFields['unit'], 'Emergency Dispatch');
    },
  );

  testWidgets(
    'R10: approved_pending_publication student and staff profile changes resume cleanly as Publish profile change',
    (tester) async {
      final signer = await TestTrustBundleSigner.create();
      Future<DeviceRegistrationQr> makeQr(String id) async {
        final secrets = InMemorySecretValueStore();
        final crypto = await DeviceIdentityStore(
          secretStore: secrets,
        ).loadOrCreate();
        final signing = await DeviceSigningIdentityStore(
          secretStore: secrets,
        ).loadOrCreate();
        return DeviceRegistrationQr.createSigned(
          deviceId: id,
          identity: crypto,
          signingIdentity: signing,
        );
      }

      final stuQr = await makeQr('phone-r10-stu');
      final staffQr = await makeQr('phone-r10-staff');
      final api = _FakeProfileChangeApi([
        ReviewApplication.fromCache(
          id: 'uid-r10-stu',
          updateTime: '2026-11-26T09:00:00Z',
          fields: {
            'affiliation': 'student',
            'displayName': 'R10 Student Old',
            'studentNumber': '2026-8801',
            'course': 'BSIT',
            'yearLevel': '3',
            'sectionSet': 'A',
            'status': 'published',
            'revision': 3,
            'registrationId': 'reg-r10-stu',
            'deviceRegistration': jsonEncode(stuQr.toJson()),
            'profileChange': {
              'status': 'approved_pending_publication',
              'reviewerUid': 'earlier-admin',
              'affiliation': 'student',
              'displayName': 'R10 Student Updated',
              'studentNumber': '2026-8802',
              'course': 'BSIT',
              'yearLevel': '4',
              'sectionSet': 'B',
            },
          },
        ),
        ReviewApplication.fromCache(
          id: 'uid-r10-staff',
          updateTime: '2026-11-26T09:05:00Z',
          fields: {
            'affiliation': 'staff',
            'displayName': 'R10 Staff Old',
            'employeeId': 'EMP-500',
            'unit': 'Ops',
            'status': 'published',
            'revision': 2,
            'registrationId': 'reg-r10-staff',
            'deviceRegistration': jsonEncode(staffQr.toJson()),
            'profileChange': {
              'status': 'approved_pending_publication',
              'reviewerUid': 'earlier-admin',
              'affiliation': 'staff',
              'displayName': 'R10 Staff Updated',
              'employeeId': 'EMP-501',
              'unit': 'DRRM Operations',
            },
          },
        ),
      ]);
      final publisher = _CapturingProfileChangePublisher(signer);

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
                token: 'tok',
                uid: 'admin-resume',
                email: 'admin@dnsc.edu.ph',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Profile change · ready to publish'),
        findsNWidgets(2),
      );

      // Publish Student change.
      await tester.tap(find.text('R10 Student Old'));
      await tester.pumpAndSettle();
      expect(find.text('Proposed profile change'), findsOneWidget);
      expect(find.text('Decline profile change'), findsNothing);
      final publishBtn = find.widgetWithText(
        FilledButton,
        'Publish profile change',
      );
      expect(publishBtn, findsOneWidget);
      await tester.ensureVisible(publishBtn);
      await tester.tap(publishBtn);
      await tester.pumpAndSettle();

      expect(publisher.payloads, hasLength(1));
      expect(publisher.payloads[0]['action'], 'approve_profile_change');
      expect(publisher.payloads[0]['accountUid'], 'uid-r10-stu');
      expect(publisher.payloads[0]['expectedRevision'], 3);
      final stuSent =
          publisher.payloads[0]['reviewedFields'] as Map<String, Object?>;
      expect(stuSent['displayName'], 'R10 Student Updated');
      expect(stuSent['studentNumber'], '2026-8802');

      // Publish Staff change.
      await tester.ensureVisible(find.text('R10 Staff Old'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('R10 Staff Old'));
      await tester.pumpAndSettle();
      final publishStaffBtn = find.widgetWithText(
        FilledButton,
        'Publish profile change',
      );
      await tester.ensureVisible(publishStaffBtn);
      await tester.tap(publishStaffBtn);
      await tester.pumpAndSettle();

      expect(publisher.payloads, hasLength(2));
      expect(publisher.payloads[1]['action'], 'approve_profile_change');
      expect(publisher.payloads[1]['accountUid'], 'uid-r10-staff');
      expect(publisher.payloads[1]['expectedRevision'], 2);
      final staffSent =
          publisher.payloads[1]['reviewedFields'] as Map<String, Object?>;
      expect(staffSent['displayName'], 'R10 Staff Updated');
      expect(staffSent['employeeId'], 'EMP-501');
      expect(staffSent['unit'], 'DRRM Operations');
      expect(tester.takeException(), isNull);
    },
  );
}
