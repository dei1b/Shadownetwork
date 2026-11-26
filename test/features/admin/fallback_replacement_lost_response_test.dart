import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

import '../../support/signed_trust_bundle_fixture.dart';

class _LostResponseFallbackApi extends RegistrationReviewApi {
  _LostResponseFallbackApi({
    required this.directoryBundle,
    required this.directoryVersion,
    required this.applications,
    required this.campusRegistrations,
  }) : super(
         Uri.https(
           'firestore.googleapis.com',
           '/v1/projects/test/databases/(default)/documents/pilotApplications',
         ),
       );

  String directoryBundle;
  int directoryVersion;
  List<ReviewApplication> applications;
  List<ReviewApplication> campusRegistrations;

  int publishReplacementCalls = 0;
  int approveRecoveryCalls = 0;
  int publishCampusCalls = 0;

  @override
  Future<List<ReviewApplication>> list(String token) async => applications;

  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async => name == 'campusRegistrations' ? campusRegistrations : const [];

  @override
  Future<({int version, String bundle, String updateTime})?> readDirectory(
    String token,
  ) async => (
    version: directoryVersion,
    bundle: directoryBundle,
    updateTime: '2026-11-26T12:00:00Z',
  );

  @override
  Future<void> publishPhoneReplacement(
    String token, {
    required ReviewApplication application,
    required CampusRegistration registration,
    required String newDeviceRegistrationJson,
    required int version,
    required String bundle,
    required String? directoryUpdateTime,
    String? remoteRegistrationUpdateTime,
  }) async {
    publishReplacementCalls++;
    directoryVersion = version;
    directoryBundle = bundle;
  }

  @override
  Future<void> approveRecoveryAndPublish(
    String token, {
    required String reviewerUid,
    required String verificationMethod,
    required CampusRegistration registration,
    required ReviewApplication recoveryRequest,
    required ReviewApplication? existingApplication,
    required String newDeviceRegistrationJson,
    required int version,
    required String bundle,
    required String? directoryUpdateTime,
    String? remoteRegistrationUpdateTime,
  }) async {
    approveRecoveryCalls++;
  }

  @override
  Future<void> publishCampusRegistration(
    String token, {
    required CampusRegistration registration,
    required int version,
    required String bundle,
    required String? directoryUpdateTime,
    String? remoteRegistrationUpdateTime,
  }) async {
    publishCampusCalls++;
  }
}

class _InMemoryFallbackRegistry implements DesktopAdminRegistryRepository {
  _InMemoryFallbackRegistry(this.registrations, this.pendingSync, this.signer);

  final List<CampusRegistration> registrations;
  final List<PendingSyncOperation> pendingSync;
  final TestTrustBundleSigner signer;
  TrustBundle? lastSavedRoster;
  int buildMergedCalls = 0;

  @override
  Future<List<CampusRegistration>> loadRegistrations() async =>
      List.of(registrations);

  @override
  Future<List<PendingSyncOperation>> loadPendingSync() async =>
      List.of(pendingSync);

  @override
  Future<ReviewerProfile?> loadReviewerProfile() async =>
      const ReviewerProfile(uid: 'admin-1', email: 'admin@dnsc.edu.ph');

  @override
  Future<void> saveLastPublishedRoster(
    TrustBundle bundle,
    String rawJson,
  ) async {
    lastSavedRoster = bundle;
  }

  @override
  Future<void> saveRegistration(
    CampusRegistration registration, {
    PendingSyncOperation? pendingSync,
    bool removePendingForRegistration = false,
    bool syncDeviceList = true,
  }) async {
    final idx = registrations.indexWhere(
      (r) => r.registrationId == registration.registrationId,
    );
    if (idx >= 0) registrations[idx] = registration;
    if (removePendingForRegistration) {
      this.pendingSync.removeWhere(
        (op) => op.registrationId == registration.registrationId,
      );
    }
  }

  @override
  Future<void> removePendingSync(String decisionId) async {
    pendingSync.removeWhere((op) => op.decisionId == decisionId);
  }

  @override
  Future<List<CampusRegistration>> reconcileWithPublishedRoster(
    TrustBundle published,
    String project,
  ) async => List.of(registrations);

  @override
  Future<String> buildMergedTrustBundleJson({
    required TrustBundle? publishedBundle,
    required List<RegisteredDevice> localChanges,
    String? directoryProject,
    int minimumPreviousVersion = 0,
  }) async {
    buildMergedCalls++;
    return signer.sign(
      bundleVersion: minimumPreviousVersion + 1,
      issuedAt: DateTime.utc(2026, 11, 26, 12, 10),
      approvedDevices: [
        for (final d in localChanges)
          if (d.status == RegisteredDeviceStatus.approved)
            TrustedDevice.fromJson(d.toJson()),
      ],
      revokedDevices: [
        for (final d in localChanges)
          if (d.status == RegisteredDeviceStatus.revoked)
            TrustedDevice.fromJson(d.toJson()),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
    'R11: Windows fallback acknowledges already-committed replacement without replaying or failing on Retry',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final signer = await TestTrustBundleSigner.create();
      final oldQr = await _signedQr('phone-r11-old');
      final newQr = await _signedQr('phone-r11-new');

      // Remote directory v2 already reflects the replacement (new approved, old revoked).
      final committedBundleJson = await signer.sign(
        bundleVersion: 2,
        issuedAt: DateTime.utc(2026, 11, 26, 12),
        approvedDevices: [
          TrustedDevice(
            deviceId: newQr.deviceId,
            ownerName: 'Lia Replaced',
            role: 'civilian',
            status: 'approved',
            publicKey: newQr.publicKey,
            signingPublicKey: newQr.signingPublicKey,
            keyVersion: newQr.keyVersion,
            updatedAt: DateTime.utc(2026, 11, 26, 12),
          ),
        ],
        revokedDevices: [
          TrustedDevice(
            deviceId: oldQr.deviceId,
            ownerName: 'Lia Replaced',
            role: 'civilian',
            status: 'revoked',
            publicKey: oldQr.publicKey,
            signingPublicKey: oldQr.signingPublicKey,
            keyVersion: oldQr.keyVersion,
            updatedAt: DateTime.utc(2026, 11, 26, 12),
          ),
        ],
      );

      final reg = CampusRegistration(
        registrationId: 'reg-r11-1',
        source: CampusRegistrationSource.online,
        status: CampusRegistrationStatus.approvedLocal,
        syncState: CampusSyncState.waitingToSync,
        accountUid: 'uid-r11-1',
        identity: const CampusIdentityFields(
          affiliation: CampusAffiliation.student,
          displayName: 'Lia Replaced',
          studentNumber: '2026-1101',
          course: 'BSIT',
          yearLevel: '3',
          sectionSet: 'A',
        ),
        role: RegisteredDeviceRole.civilian,
        activePhone: RegistrationPhoneBinding(
          deviceId: newQr.deviceId,
          publicKey: newQr.publicKey,
          signingPublicKey: newQr.signingPublicKey,
          keyVersion: newQr.keyVersion,
          deviceRegistrationJson: jsonEncode(newQr.toJson()),
        ),
        createdAt: DateTime.utc(2026, 11, 26),
        updatedAt: DateTime.utc(2026, 11, 26),
      );
      final pendingOp = PendingSyncOperation(
        decisionId: 'dec-r11-1',
        registrationId: 'reg-r11-1',
        kind: PendingSyncKind.publishReplacement,
        payloadJson: jsonEncode({
          'old_device_id': oldQr.deviceId,
          'old_public_key': oldQr.publicKey,
          'old_signing_public_key': oldQr.signingPublicKey,
          'expected_request_update_time': '2026-11-26T11:00:00Z',
          'new_device_id': newQr.deviceId,
          'account_uid': 'uid-r11-1',
          'new_device_registration': jsonEncode(newQr.toJson()),
          'reason': 'Lost old handset',
        }),
        createdAt: DateTime.utc(2026, 11, 26),
      );

      final api = _LostResponseFallbackApi(
        directoryBundle: committedBundleJson,
        directoryVersion: 2,
        applications: [
          ReviewApplication.fromCache(
            id: 'uid-r11-1',
            updateTime: '2026-11-26T12:00:00Z',
            fields: {
              'registrationId': 'reg-r11-1',
              'affiliation': 'student',
              'displayName': 'Lia Replaced',
              'studentNumber': '2026-1101',
              'course': 'BSIT',
              'yearLevel': '3',
              'sectionSet': 'A',
              'status': 'published',
              'deviceRegistration': jsonEncode(newQr.toJson()),
              'replacementRequest': {'status': 'published'},
            },
          ),
        ],
        campusRegistrations: [
          ReviewApplication.fromCache(
            id: 'reg-r11-1',
            updateTime: '2026-11-26T12:00:00Z',
            fields: {
              'registrationId': 'reg-r11-1',
              'accountUid': 'uid-r11-1',
              'affiliation': 'student',
              'displayName': 'Lia Replaced',
              'studentNumber': '2026-1101',
              'course': 'BSIT',
              'yearLevel': '3',
              'sectionSet': 'A',
              'status': 'published',
              'role': 'civilian',
              'deviceId': newQr.deviceId,
              'publicKey': newQr.publicKey,
              'signingPublicKey': newQr.signingPublicKey,
              'keyVersion': newQr.keyVersion,
              'deviceRegistration': jsonEncode(newQr.toJson()),
            },
          ),
        ],
      );
      final registry = _InMemoryFallbackRegistry([reg], [pendingOp], signer);

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: Scaffold(
            body: UnifiedRegistrationsWorkspace(
              registry: registry,
              reviewApi: api,
              initialSessionForTesting: (
                token: 'tok',
                uid: 'admin-1',
                email: 'admin@dnsc.edu.ph',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sync 1 pending'));
      await tester.pumpAndSettle();

      expect(api.publishReplacementCalls, 0);
      expect(api.approveRecoveryCalls, 0);
      expect(api.publishCampusCalls, 0);
      expect(api.directoryVersion, 2);
      expect(registry.buildMergedCalls, 0);
      expect(registry.pendingSync, isEmpty);
      expect(
        registry.registrations.single.status,
        CampusRegistrationStatus.published,
      );
      expect(registry.registrations.single.syncState, CampusSyncState.synced);
      expect(registry.lastSavedRoster?.bundleVersion, 2);
      expect(find.text('Sync 1 pending'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in ['same', 'changed_binding', 'missing_request']) {
    final changedBinding = scenario == 'changed_binding';
    final missingRequest = scenario == 'missing_request';
    testWidgets(
      'S1/R11: fallback checks reviewed old binding before pending replay ($scenario)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final signer = await TestTrustBundleSigner.create();
        final oldQr = await _signedQr('phone-r11-old-2');
        final newQr = await _signedQr('phone-r11-new-2');

        // Remote still only has old phone approved at v1.
        final uncommittedBundleJson = await signer.sign(
          bundleVersion: 1,
          issuedAt: DateTime.utc(2026, 11, 26, 11),
          approvedDevices: [
            TrustedDevice(
              deviceId: oldQr.deviceId,
              ownerName: 'Lia Pending',
              role: 'civilian',
              status: 'approved',
              publicKey: oldQr.publicKey,
              signingPublicKey: oldQr.signingPublicKey,
              keyVersion: oldQr.keyVersion,
              updatedAt: DateTime.utc(2026, 11, 26, 11),
            ),
          ],
        );

        final reg = CampusRegistration(
          registrationId: 'reg-r11-2',
          source: CampusRegistrationSource.online,
          status: CampusRegistrationStatus.approvedLocal,
          syncState: CampusSyncState.waitingToSync,
          accountUid: 'uid-r11-2',
          identity: const CampusIdentityFields(
            affiliation: CampusAffiliation.student,
            displayName: 'Lia Pending',
            studentNumber: '2026-1102',
            course: 'BSIT',
            yearLevel: '3',
            sectionSet: 'A',
          ),
          role: RegisteredDeviceRole.civilian,
          activePhone: RegistrationPhoneBinding(
            deviceId: newQr.deviceId,
            publicKey: newQr.publicKey,
            signingPublicKey: newQr.signingPublicKey,
            keyVersion: newQr.keyVersion,
            deviceRegistrationJson: jsonEncode(newQr.toJson()),
          ),
          createdAt: DateTime.utc(2026, 11, 26),
          updatedAt: DateTime.utc(2026, 11, 26),
        );
        final pendingOp = PendingSyncOperation(
          decisionId: 'dec-r11-2',
          registrationId: 'reg-r11-2',
          kind: PendingSyncKind.publishReplacement,
          payloadJson: jsonEncode({
            'old_device_id': oldQr.deviceId,
            'old_public_key': oldQr.publicKey,
            'old_signing_public_key': oldQr.signingPublicKey,
            'expected_request_update_time': '2026-11-26T11:00:00Z',
            'new_device_id': newQr.deviceId,
            'account_uid': 'uid-r11-2',
            'new_device_registration': jsonEncode(newQr.toJson()),
            'reason': 'Lost old handset',
          }),
          createdAt: DateTime.utc(2026, 11, 26),
        );

        final api = _LostResponseFallbackApi(
          directoryBundle: uncommittedBundleJson,
          directoryVersion: 1,
          applications: [
            ReviewApplication.fromCache(
              id: 'uid-r11-2',
              updateTime: '2026-11-26T11:00:00Z',
              fields: {
                'registrationId': 'reg-r11-2',
                'affiliation': 'student',
                'displayName': 'Lia Pending',
                'studentNumber': '2026-1102',
                'course': 'BSIT',
                'yearLevel': '3',
                'sectionSet': 'A',
                'status': 'published',
                'deviceRegistration': jsonEncode(oldQr.toJson()),
                'replacementRequest': {
                  'status': 'submitted',
                  'deviceRegistration': jsonEncode(newQr.toJson()),
                },
              },
            ),
          ],
          campusRegistrations: [
            ReviewApplication.fromCache(
              id: 'reg-r11-2',
              updateTime: '2026-11-26T11:00:00Z',
              fields: {
                'registrationId': 'reg-r11-2',
                'accountUid': 'uid-r11-2',
                'affiliation': 'student',
                'displayName': 'Lia Pending',
                'studentNumber': '2026-1102',
                'course': 'BSIT',
                'yearLevel': '3',
                'sectionSet': 'A',
                'status': 'published',
                'role': 'civilian',
                'deviceId': oldQr.deviceId,
                'publicKey': changedBinding ? newQr.publicKey : oldQr.publicKey,
                'signingPublicKey': oldQr.signingPublicKey,
                'keyVersion': oldQr.keyVersion,
                'deviceRegistration': jsonEncode(oldQr.toJson()),
              },
            ),
          ],
        );
        if (missingRequest) api.applications.clear();
        final registry = _InMemoryFallbackRegistry([reg], [pendingOp], signer);

        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: AdminTheme.light,
            home: Scaffold(
              body: UnifiedRegistrationsWorkspace(
                registry: registry,
                reviewApi: api,
                initialSessionForTesting: (
                  token: 'tok',
                  uid: 'admin-1',
                  email: 'admin@dnsc.edu.ph',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Sync 1 pending'));
        await tester.pumpAndSettle();

        if (changedBinding || missingRequest) {
          expect(api.publishReplacementCalls, 0);
          expect(api.publishCampusCalls, 0);
          expect(registry.pendingSync, hasLength(1));
          return;
        }
        expect(api.publishReplacementCalls, 1);
        expect(api.directoryVersion, 2);
        expect(registry.pendingSync, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
