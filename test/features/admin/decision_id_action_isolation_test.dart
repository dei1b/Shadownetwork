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

class _MutableReviewApi extends RegistrationReviewApi {
  _MutableReviewApi()
    : super(
        Uri.https(
          'firestore.googleapis.com',
          '/v1/projects/test/databases/(default)/documents/pilotApplications',
        ),
      );

  List<ReviewApplication> applications = [];
  List<ReviewApplication> campusRegistrations = [];

  @override
  Future<List<ReviewApplication>> list(String token) async =>
      List.of(applications);

  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async =>
      name == 'campusRegistrations' ? List.of(campusRegistrations) : const [];

  @override
  Future<({int version, String bundle, String updateTime})?> readDirectory(
    String token,
  ) async => null;
}

class _LostResponseThenRevokePublisher extends HostedPublisherClient {
  _LostResponseThenRevokePublisher({
    required this.signer,
    required this.api,
    required this.qr,
    required this.dropFirstApproveResponseAfterCommit,
    this.dropFirstPreCommit = false,
  }) : super(endpoint: Uri.parse('https://admin.test/api/publish-approval'));

  final TestTrustBundleSigner signer;
  final _MutableReviewApi api;
  final DeviceRegistrationQr qr;
  final bool dropFirstApproveResponseAfterCommit;
  final bool dropFirstPreCommit;
  final List<Map<String, Object?>> payloads = [];
  int calls = 0;

  @override
  Future<HostedPublishResult> publishDecision({
    required String token,
    required Map<String, Object?> payload,
  }) async {
    calls++;
    payloads.add(payload);
    if (dropFirstPreCommit && calls == 1) {
      throw StateError('Transient timeout before server write');
    }
    if (dropFirstApproveResponseAfterCommit && calls == 1) {
      final regId = payload['registrationId'] as String? ?? 'reg-r6-ui';
      final uid = payload['accountUid'] as String? ?? 'uid-r6-ui';
      final rawQr = jsonEncode(qr.toJson());
      api.applications = [
        ReviewApplication.fromCache(
          id: uid,
          updateTime: '2026-11-26T12:05:00Z',
          fields: {
            'affiliation': 'student',
            'displayName': 'Elena Isolation',
            'studentNumber': '2026-9901',
            'course': 'BSIT',
            'yearLevel': 'Year 3',
            'sectionSet': 'Set A',
            'status': 'published',
            'publicationStatus': 'published',
            'registrationId': regId,
            'revision': 1,
            'deviceRegistration': rawQr,
          },
        ),
      ];
      api.campusRegistrations = [
        ReviewApplication.fromCache(
          id: regId,
          updateTime: '2026-11-26T12:05:00Z',
          fields: {
            'registrationId': regId,
            'accountUid': uid,
            'affiliation': 'student',
            'displayName': 'Elena Isolation',
            'studentNumber': '2026-9901',
            'course': 'BSIT',
            'yearLevel': 'Year 3',
            'sectionSet': 'Set A',
            'status': 'published',
            'role': 'civilian',
            'revision': 1,
            'deviceId': qr.deviceId,
            'publicKey': qr.publicKey,
            'signingPublicKey': qr.signingPublicKey,
            'keyVersion': qr.keyVersion,
            'deviceRegistration': rawQr,
          },
        ),
      ];
      throw StateError('HTTP response dropped after remote approval commit');
    }

    final isRevoke = payload['targetStatus'] == 'revoked';
    final entry = TrustedDevice(
      deviceId: qr.deviceId,
      ownerName: 'Elena Isolation',
      role: 'civilian',
      status: isRevoke ? 'revoked' : 'approved',
      publicKey: qr.publicKey,
      signingPublicKey: qr.signingPublicKey,
      keyVersion: qr.keyVersion,
      updatedAt: DateTime.utc(2026, 11, 26, 12, 10),
    );
    final bundleJson = await signer.sign(
      bundleVersion: isRevoke ? 2 : 1,
      issuedAt: DateTime.utc(2026, 11, 26, 12, 10),
      approvedDevices: isRevoke ? const [] : [entry],
      revokedDevices: isRevoke ? [entry] : const [],
    );
    return HostedPublishResult(
      status: 'published',
      version: isRevoke ? 2 : 1,
      bundle: bundleJson,
      registrationId: payload['registrationId'] as String?,
      decisionId: payload['decisionId'] as String,
      idempotent: false,
    );
  }
}

Future<DeviceRegistrationQr> _makeQr(String deviceId) async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'R6: switching to revoke after a lost-response approval allocates a distinct decisionId',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final signer = await TestTrustBundleSigner.create();
      final qr = await _makeQr('phone-r6-switch');
      final api = _MutableReviewApi()
        ..applications = [
          ReviewApplication.fromCache(
            id: 'uid-r6-ui',
            updateTime: '2026-11-26T12:00:00Z',
            fields: {
              'affiliation': 'student',
              'displayName': 'Elena Isolation',
              'studentNumber': '2026-9901',
              'course': 'BSIT',
              'yearLevel': 'Year 3',
              'sectionSet': 'Set A',
              'status': 'submitted',
              'revision': 0,
              'deviceRegistration': jsonEncode(qr.toJson()),
            },
          ),
        ];
      final publisher = _LostResponseThenRevokePublisher(
        signer: signer,
        api: api,
        qr: qr,
        dropFirstApproveResponseAfterCommit: true,
      );

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

      await tester.tap(find.text('Elena Isolation'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Approve & publish'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve & publish'));
      await tester.pumpAndSettle();

      expect(publisher.payloads, hasLength(1));
      final approvalDecisionId = publisher.payloads.single['decisionId'];
      expect(
        find.textContaining('HTTP response dropped after remote approval commit'),
        findsOneWidget,
      );

      // Refresh picks up the published state from remote; switch status filter to see Published rows.
      await tester.ensureVisible(find.text('Refresh'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('All'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Elena Isolation'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Revoke'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();

      expect(publisher.payloads, hasLength(2));
      expect(publisher.payloads[1]['action'], 'sync_offline_decision');
      expect(publisher.payloads[1]['targetStatus'], 'revoked');
      expect(
        publisher.payloads[1]['decisionId'],
        isNot(equals(approvalDecisionId)),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'R6: retrying the exact same failed action reuses its original decisionId',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final signer = await TestTrustBundleSigner.create();
      final qr = await _makeQr('phone-r6-retry');
      final api = _MutableReviewApi()
        ..applications = [
          ReviewApplication.fromCache(
            id: 'uid-r6-retry',
            updateTime: '2026-11-26T12:00:00Z',
            fields: {
              'affiliation': 'student',
              'displayName': 'Marco Retry',
              'studentNumber': '2026-9902',
              'course': 'BSIT',
              'yearLevel': 'Year 2',
              'sectionSet': 'B',
              'status': 'submitted',
              'revision': 0,
              'deviceRegistration': jsonEncode(qr.toJson()),
            },
          ),
        ];
      final publisher = _LostResponseThenRevokePublisher(
        signer: signer,
        api: api,
        qr: qr,
        dropFirstApproveResponseAfterCommit: false,
        dropFirstPreCommit: true,
      );

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

      await tester.tap(find.text('Marco Retry'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Approve & publish'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve & publish'));
      await tester.pumpAndSettle();

      final firstId = publisher.payloads.single['decisionId'];
      expect(
        find.textContaining('Transient timeout before server write'),
        findsOneWidget,
      );

      await tester.tap(find.text('Marco Retry'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Approve & publish'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve & publish'));
      await tester.pumpAndSettle();

      expect(publisher.payloads, hasLength(2));
      expect(publisher.payloads[1]['decisionId'], firstId);
      expect(find.text('Approval published'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
