import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shadownetwork/admin_web_main.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/hosted_publisher_client.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';

import 'support/signed_trust_bundle_fixture.dart';

class _FakeReviewApi extends RegistrationReviewApi {
  _FakeReviewApi()
    : super(
        Uri.https(
          'firestore.googleapis.com',
          '/v1/projects/test/databases/(default)/documents/pilotApplications',
        ),
      );

  List<ReviewApplication> applications = [];
  List<ReviewApplication> remoteRegistrations = [];

  @override
  Future<List<ReviewApplication>> list(String token) async => applications;

  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async => switch (name) {
    'campusRegistrations' => remoteRegistrations,
    _ => [],
  };
}

class _FakeHostedPublisher extends HostedPublisherClient {
  _FakeHostedPublisher({this.failOnce = false}) : super(endpoint: Uri.parse('https://admin.test/api/publish-approval'));

  final bool failOnce;
  int calls = 0;
  final List<Map<String, Object?>> payloads = [];

  @override
  Future<HostedPublishResult> publishDecision({
    required String token,
    required Map<String, Object?> payload,
  }) async {
    calls++;
    payloads.add(payload);
    if (failOnce && calls == 1) {
      throw StateError('Temporary mobile connection drop');
    }
    return HostedPublishResult(
      status: 'published',
      version: 1,
      bundle: '{}',
      registrationId: payload['registrationId'] as String?,
      decisionId: payload['decisionId'] as String? ?? 'dec',
      idempotent: calls > 1,
    );
  }
}

void main() {
  test('HostedPublisherClient posts decisionId and parses response or error', () async {
    final signer = await TestTrustBundleSigner.create();
    final signedBundleV7 = await signer.sign(
      bundleVersion: 7,
      issuedAt: DateTime.utc(2026, 11, 26, 12),
    );
    var count = 0;
    final client = HostedPublisherClient(
      endpoint: Uri.parse('https://example.test/api/publish-approval'),
      client: MockClient((request) async {
        count++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(request.headers['authorization'], 'Bearer reviewer-token');
        if (count == 3) {
          return http.Response(
            jsonEncode({'ok': false, 'error': 'Self review forbidden'}),
            403,
          );
        }
        expect(body['decisionId'], 'dec-fixed-1');
        return http.Response(
          jsonEncode({
            'ok': true,
            'status': 'published',
            'version': 7,
            'bundle': signedBundleV7,
            'registrationId': 'reg-1',
            'decisionId': 'dec-fixed-1',
            'idempotent': count > 1,
          }),
          200,
        );
      }),
    );

    final first = await client.publishDecision(
      token: 'reviewer-token',
      payload: {'action': 'approve_online', 'decisionId': 'dec-fixed-1'},
    );
    expect(first.version, 7);
    expect(first.idempotent, isFalse);

    final retry = await client.publishDecision(
      token: 'reviewer-token',
      payload: {'action': 'approve_online', 'decisionId': 'dec-fixed-1'},
    );
    expect(retry.idempotent, isTrue);

    await expectLater(
      client.publishDecision(
        token: 'reviewer-token',
        payload: {'action': 'approve_online', 'decisionId': 'dec-fixed-2'},
      ),
      throwsStateError,
    );
  });

  testWidgets('mobile web workspace approves online via hosted publisher, shows Approval published, and reuses decisionId on retry', (
    tester,
  ) async {
    final secrets = InMemorySecretValueStore();
    final crypto = await DeviceIdentityStore(secretStore: secrets).loadOrCreate();
    final signing = await DeviceSigningIdentityStore(secretStore: secrets).loadOrCreate();
    final qr = await DeviceRegistrationQr.createSigned(
      deviceId: 'phone-browser-test',
      identity: crypto,
      signingIdentity: signing,
    );

    final api = _FakeReviewApi()
      ..applications = [
        ReviewApplication.fromCache(
          id: 'uid-student-9',
          updateTime: '2026-11-26T10:00:00Z',
          fields: {
            'affiliation': 'student',
            'displayName': 'Elena Mobile',
            'studentNumber': '2026-8888',
            'course': 'BSIT',
            'yearLevel': 'Year 3',
            'sectionSet': 'Set C',
            'status': 'submitted',
            'revision': 0,
            'deviceRegistration': jsonEncode(qr.toJson()),
          },
        ),
      ];
    final publisher = _FakeHostedPublisher(failOnce: true);

    await tester.binding.setSurfaceSize(const Size(390, 844));
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

    expect(find.text('Scan phone QR'), findsNothing);
    expect(find.text('Elena Mobile'), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elena Mobile'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Approve & publish'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve & publish'));
    await tester.pumpAndSettle();

    // First attempt failed after sending decisionId #1.
    expect(publisher.calls, 1);
    final firstDecisionId = publisher.payloads.single['decisionId'];
    expect(find.textContaining('Temporary mobile connection drop'), findsOneWidget);

    // Retry must send the EXACT same decisionId and show Approval published.
    // Error feedback stays visible until dismissed and can cover this row on
    // a phone-sized viewport after the session status card changes its height.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Elena Mobile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elena Mobile'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Approve & publish'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve & publish'));
    await tester.pumpAndSettle();

    expect(publisher.calls, 2);
    expect(publisher.payloads[1]['decisionId'], firstDecisionId);
    expect(find.text('Approval published'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ShadowNetworkAdminWebApp opens shared registration workspace cleanly at phone width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ShadowNetworkAdminWebApp(
        reviewApi: _FakeReviewApi(),
        publisherClient: _FakeHostedPublisher(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Registrations'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Scan phone QR'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
