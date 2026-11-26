import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';

class _SnapshotSkewApi extends RegistrationReviewApi {
  _SnapshotSkewApi({
    required this.applications,
    required this.campusRegistrations,
  }) : super(
         Uri.https(
           'firestore.googleapis.com',
           '/v1/projects/test/databases/(default)/documents/pilotApplications',
         ),
       );

  final List<ReviewApplication> applications;
  final List<ReviewApplication> campusRegistrations;

  @override
  Future<List<ReviewApplication>> list(String token) async => applications;

  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async =>
      name == 'campusRegistrations' ? campusRegistrations : const [];

  @override
  Future<({int version, String bundle, String updateTime})?> readDirectory(
    String token,
  ) async => null;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'R12: newer campusRegistrations replacement snapshot overrides older pilotApplications keys and identity atomically while keeping pending replacement separate',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final oldQr = await _signedQr('phone-r12-old');
      final newQr = await _signedQr('phone-r12-new');
      final nextPendingQr = await _signedQr('phone-r12-next');

      // Older pilotApplications snapshot still carries old phone keys & old displayName,
      // plus a separate submitted replacementRequest.
      final staleApp = ReviewApplication.fromCache(
        id: 'uid-r12-1',
        updateTime: '2026-11-26T10:00:00Z',
        fields: {
          'registrationId': 'reg-r12-1',
          'affiliation': 'student',
          'displayName': 'Stale App Name',
          'studentNumber': '2026-1200',
          'course': 'BSIT',
          'yearLevel': '2',
          'sectionSet': 'A',
          'status': 'published',
          'revision': 1,
          'deviceRegistration': jsonEncode(oldQr.toJson()),
          'replacementRequest': {
            'status': 'submitted',
            'deviceRegistration': jsonEncode(nextPendingQr.toJson()),
          },
        },
      );

      // Newer campusRegistrations snapshot from concurrent replacement commit.
      final freshReg = ReviewApplication.fromCache(
        id: 'reg-r12-1',
        updateTime: '2026-11-26T10:05:00Z',
        fields: {
          'registrationId': 'reg-r12-1',
          'accountUid': 'uid-r12-1',
          'affiliation': 'student',
          'displayName': 'Fresh Replaced Name',
          'studentNumber': '2026-1201',
          'course': 'BSIT',
          'yearLevel': '3',
          'sectionSet': 'B',
          'status': 'published',
          'role': 'responder',
          'revision': 2,
          'deviceId': newQr.deviceId,
          'publicKey': newQr.publicKey,
          'signingPublicKey': newQr.signingPublicKey,
          'keyVersion': 2,
          'deviceRegistration': jsonEncode(newQr.toJson()),
        },
      );

      final api = _SnapshotSkewApi(
        applications: [staleApp],
        campusRegistrations: [freshReg],
      );

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: Scaffold(
            body: UnifiedRegistrationsWorkspace(
              reviewApi: api,
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

      // Queue card must display the fresh authoritative name and active phone ID.
      expect(find.text('Fresh Replaced Name'), findsOneWidget);
      expect(find.text('Stale App Name'), findsNothing);
      expect(find.textContaining('Phone: phone-r12-new'), findsOneWidget);

      await tester.tap(find.text('Fresh Replaced Name'));
      await tester.pumpAndSettle();

      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Device ID: phone-r12-new'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Key version: v2'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Encryption key: ${newQr.publicKey}'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Signing key: ${newQr.signingPublicKey}'),
        ),
        findsOneWidget,
      );
      // Old keys must NOT be shown in Verified phone keys!
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining(oldQr.publicKey),
        ),
        findsNothing,
      );
      // Pending replacement stays visually separate under Proposed replacement phone keys.
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Proposed replacement phone keys'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Device ID: phone-r12-next'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
