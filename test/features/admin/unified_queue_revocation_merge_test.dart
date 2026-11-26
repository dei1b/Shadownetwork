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

class _FakeMergeReviewApi extends RegistrationReviewApi {
  _FakeMergeReviewApi({
    required this.applications,
    required this.remoteRegistrations,
  }) : super(
         Uri.https(
           'firestore.googleapis.com',
           '/v1/projects/test/databases/(default)/documents/pilotApplications',
         ),
       );

  final List<ReviewApplication> applications;
  final List<ReviewApplication> remoteRegistrations;

  @override
  Future<List<ReviewApplication>> list(String token) async => applications;

  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async {
    if (name == 'campusRegistrations') return remoteRegistrations;
    return const [];
  }

  @override
  Future<({int version, String bundle, String updateTime})?> readDirectory(
    String token,
  ) async => null;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'remote campusRegistrations revoked status and responder role merge over stale published pilotApplication in browser mode',
    (tester) async {
      final secrets = InMemorySecretValueStore();
      final crypto = await DeviceIdentityStore(
        secretStore: secrets,
      ).loadOrCreate();
      final signing = await DeviceSigningIdentityStore(
        secretStore: secrets,
      ).loadOrCreate();
      final qr = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-revoked-merge',
        identity: crypto,
        signingIdentity: signing,
      );

      final app = ReviewApplication.fromCache(
        id: 'uid-merge-1',
        updateTime: '2026-11-26T09:00:00Z',
        fields: {
          'affiliation': 'staff',
          'displayName': 'Merged Revoked Responder',
          'employeeId': 'DNSC-5501',
          'unit': 'Security Office',
          'status': 'published',
          'revision': 2,
          'registrationId': 'reg-merge-1',
          'deviceRegistration': jsonEncode(qr.toJson()),
          'reviewHistory': [
            {
              'reviewerUid': 'admin-prev',
              'status': 'published',
              'reason': 'Initial approval',
              'revision': 2,
              'role': 'civilian',
            },
          ],
        },
      );

      final remoteReg = ReviewApplication.fromCache(
        id: 'reg-merge-1',
        updateTime: '2026-11-26T10:30:00Z',
        fields: {
          'registrationId': 'reg-merge-1',
          'accountUid': 'uid-merge-1',
          'affiliation': 'staff',
          'displayName': 'Merged Revoked Responder',
          'employeeId': 'DNSC-5501',
          'unit': 'Security Office',
          'source': 'online',
          'status': 'revoked',
          'role': 'responder',
          'deviceId': 'phone-revoked-merge',
          'publicKey': qr.publicKey,
          'signingPublicKey': qr.signingPublicKey,
          'keyVersion': qr.keyVersion,
        },
      );

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: Scaffold(
            body: UnifiedRegistrationsWorkspace(
              reviewApi: _FakeMergeReviewApi(
                applications: [app],
                remoteRegistrations: [remoteReg],
              ),
              publisherClient: HostedPublisherClient(
                endpoint: Uri.parse('https://admin.test/api/publish-approval'),
              ),
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

      // Should not appear under Published when campusRegistrations says revoked.
      await tester.tap(find.widgetWithText(FilterChip, 'Published'));
      await tester.pumpAndSettle();
      expect(find.text('Merged Revoked Responder'), findsNothing);

      // Should appear under Revoked with merged DNSC Responder role.
      await tester.tap(find.widgetWithText(FilterChip, 'Revoked'));
      await tester.pumpAndSettle();
      expect(find.text('Merged Revoked Responder'), findsOneWidget);
      expect(find.text('DNSC Responder'), findsOneWidget);
      expect(find.text('Revoked'), findsAtLeastNWidgets(2));

      // Opening editor preserves attached online application data & status.
      await tester.tap(find.text('Merged Revoked Responder'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Status: Revoked'), findsOneWidget);
      expect(find.textContaining('DNSC-5501'), findsAtLeastNWidgets(1));
    },
  );
}
