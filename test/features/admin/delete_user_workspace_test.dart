// Regression coverage for registration/profile interactions found in S5–S7.
import 'dart:convert';
import '../../support/signed_trust_bundle_fixture.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/hosted_publisher_client.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';

final _collection = Uri.parse(
  'https://firestore.googleapis.com/v1/projects/test/databases/(default)/documents/pilotApplications',
);

const _original = CampusIdentityFields(
  displayName: 'Verified Student',
  studentNumber: '2026-1001',
  course: 'BSIT',
  yearLevel: '3',
  sectionSet: 'A',
  phone: '09170000001',
  address: 'Old address',
);

class _Api extends RegistrationReviewApi {
  _Api(this.app, this.registration) : super(_collection);
  final ReviewApplication app;
  final ReviewApplication registration;
  @override
  Future<List<ReviewApplication>> list(String token) async => [app];
  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async => name == 'campusRegistrations' ? [registration] : [];
  @override
  Future<({int version, String bundle, String updateTime})?> readDirectory(
    String token,
  ) async => null;
}

class _Publisher extends HostedPublisherClient {
  _Publisher() : super(endpoint: Uri.parse('https://review.test/publish'));
  final payloads = <Map<String, Object?>>[];
  @override
  Future<HostedPublishResult> publishDecision({
    required String token,
    required Map<String, Object?> payload,
  }) async {
    payloads.add(payload);
    return HostedPublishResult(
      status: 'published',
      version: 3,
      decisionId: payload['decisionId'] as String,
      idempotent: false,
    );
  }
}

Future<DeviceRegistrationQr> _qr() async {
  final secrets = InMemorySecretValueStore();
  final identity = await DeviceIdentityStore(
    secretStore: secrets,
  ).loadOrCreate();
  final signing = await DeviceSigningIdentityStore(
    secretStore: secrets,
  ).loadOrCreate();
  return DeviceRegistrationQr.createSigned(
    deviceId: 'phone-reviewed',
    identity: identity,
    signingIdentity: signing,
  );
}

ReviewApplication _app(
  DeviceRegistrationQr qr, {
  int revision = 1,
  String time = '2026-11-26T09:00:00Z',
  Map<String, dynamic> extra = const {},
}) => ReviewApplication.fromCache(
  id: 'uid-applicant',
  updateTime: time,
  fields: {
    ..._original.toFirestoreFields(),
    'status': 'published',
    'registrationId': 'reg-reviewed',
    'revision': revision,
    'deviceRegistration': jsonEncode(qr.toJson()),
    'reviewHistory': [
      {'role': 'civilian', 'status': 'published'},
    ],
    ...extra,
  },
);

ReviewApplication _registration(
  DeviceRegistrationQr qr, {
  int revision = 1,
  String status = 'published',
}) => ReviewApplication.fromCache(
  id: 'reg-reviewed',
  updateTime: '2026-11-26T10:00:00Z',
  fields: {
    ..._original.toFirestoreFields(),
    'registrationId': 'reg-reviewed',
    'accountUid': 'uid-applicant',
    'status': status,
    'revision': revision,
    'source': 'online',
    'role': 'civilian',
    'deviceId': qr.deviceId,
    'publicKey': qr.publicKey,
    'signingPublicKey': qr.signingPublicKey,
    'keyVersion': qr.keyVersion,
    'deviceRegistration': jsonEncode(qr.toJson()),
  },
);

Future<void> _mount(
  WidgetTester tester,
  _Api api,
  _Publisher publisher, {
  String reviewerUid = 'reviewer',
}) async {
  SharedPreferences.setMockInitialValues({});
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
            token: 'test-token',
            uid: reviewerUid,
            email: 'reviewer@dnsc.edu.ph',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('deleted Firebase registration stays hidden after reopening', (
    tester,
  ) async {
    final qr = await _qr();
    await _mount(
      tester,
      _Api(_app(qr), _registration(qr, status: 'deleted')),
      _Publisher(),
    );
    expect(find.text('Verified Student'), findsNothing);
  });
  testWidgets('reviewer cannot delete own linked registration', (tester) async {
    final qr = await _qr();
    final publisher = _Publisher();
    await _mount(
      tester,
      _Api(_app(qr), _registration(qr)),
      publisher,
      reviewerUid: 'uid-applicant',
    );
    await tester.tap(find.text('Verified Student'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Delete user'))
          .onPressed,
      isNull,
    );
    expect(publisher.payloads, isEmpty);
  });

  for (final fail in [false, true]) {
    testWidgets(
      'delete user confirms and syncs without deleting login ($fail)',
      (tester) async {
        final qr = await _qr();
        final api = _Api(_app(qr), _registration(qr));
        final signer = await TestTrustBundleSigner.create();
        final publisher = _DeletePublisher(qr, signer, fail);
        await _mount(tester, api, publisher);
        await tester.tap(find.text('Verified Student'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.widgetWithText(TextButton, 'Delete user'),
        );
        await tester.tap(find.widgetWithText(TextButton, 'Delete user'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('login account will be kept'),
          findsOneWidget,
        );
        expect(publisher.payloads, isEmpty);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(publisher.payloads, isEmpty);
        await tester.tap(find.text('Verified Student'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.widgetWithText(TextButton, 'Delete user'),
        );
        await tester.tap(find.widgetWithText(TextButton, 'Delete user'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete user and revoke access'));
        await tester.pumpAndSettle();
        expect(publisher.payloads, hasLength(1));
        expect(publisher.payloads.single['action'], 'delete_registration');
        expect(publisher.payloads.single['accountUid'], 'uid-applicant');
        expect(publisher.payloads.single['registrationId'], 'reg-reviewed');
        if (fail)
          expect(find.text('Verified Student'), findsOneWidget);
        else
          expect(find.text('Verified Student'), findsNothing);
      },
    );
  }
}

class _DeletePublisher extends _Publisher {
  _DeletePublisher(this.qr, this.signer, this.fail);
  final DeviceRegistrationQr qr;
  final TestTrustBundleSigner signer;
  final bool fail;
  @override
  Future<HostedPublishResult> publishDecision({
    required String token,
    required Map<String, Object?> payload,
  }) async {
    payloads.add(payload);
    if (fail) throw StateError('Deletion failed');
    final bundle = await signer.sign(
      bundleVersion: 2,
      issuedAt: DateTime.now().toUtc(),
      revokedDevices: [
        TrustedDevice(
          deviceId: qr.deviceId,
          ownerName: 'Verified Student',
          role: 'civilian',
          status: 'revoked',
          publicKey: qr.publicKey,
          signingPublicKey: qr.signingPublicKey,
          keyVersion: qr.keyVersion,
          updatedAt: DateTime.now().toUtc(),
        ),
      ],
    );
    return HostedPublishResult(
      status: 'published',
      version: 2,
      bundle: bundle,
      decisionId: payload['decisionId'] as String,
      idempotent: false,
    );
  }
}
