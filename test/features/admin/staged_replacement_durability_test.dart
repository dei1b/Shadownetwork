import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/hosted_publisher_client.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

import '../../support/signed_trust_bundle_fixture.dart';

class _MemKeys implements AdminSigningKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}

class _NoopReviewApi extends RegistrationReviewApi {
  _NoopReviewApi()
    : super(
        Uri.https(
          'firestore.googleapis.com',
          '/v1/projects/test/databases/(default)/documents/pilotApplications',
        ),
      );

  @override
  Future<List<ReviewApplication>> list(String token) async => const [];

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

class _InMemorySyncRegistry implements DesktopAdminRegistryRepository {
  _InMemorySyncRegistry(this.registrations, this.pendingSync);

  final List<CampusRegistration> registrations;
  final List<PendingSyncOperation> pendingSync;

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
  ) async {}

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'staged phone replacement persists durable PendingSyncOperation across SQLite restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp(
        'staged-replace-durability-',
      );
      var db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
      final keys = _MemKeys();
      try {
        var repo = DesktopAdminRegistryRepository(
          database: db,
          keyStore: keys,
        );
        await repo.initializeIdentity();

        const reviewer = ReviewerProfile(
          uid: 'admin-1',
          email: 'admin@dnsc.edu.ph',
        );
        final initialReg = CampusRegistration(
          registrationId: 'reg-replace-1',
          source: CampusRegistrationSource.qr,
          status: CampusRegistrationStatus.submitted,
          syncState: CampusSyncState.waitingToSync,
          accountUid: 'uid-user-1',
          identity: const CampusIdentityFields(
            affiliation: CampusAffiliation.student,
            displayName: 'Sofia Replace',
            studentNumber: '2026-6001',
            course: 'BSIT',
            yearLevel: '3',
            sectionSet: 'A',
          ),
          role: RegisteredDeviceRole.civilian,
          activePhone: RegistrationPhoneBinding(
            deviceId: 'phone-old',
            publicKey: base64UrlEncode(List.filled(32, 1)),
            signingPublicKey: base64UrlEncode(List.filled(32, 2)),
            keyVersion: 1,
          ),
          createdAt: DateTime.utc(2026, 11, 26),
          updatedAt: DateTime.utc(2026, 11, 26),
        );
        final approved = await repo.approveOfflineRegistration(
          registration: initialReg,
          reviewer: reviewer,
          role: RegisteredDeviceRole.civilian,
          reviewedIdentity: initialReg.identity,
          directoryProject: 'dnsc-pilot',
        );
        await repo.removePendingSync(
          (await repo.loadPendingSync()).single.decisionId,
        );

        final staged = await repo.stagePhoneReplacement(
          registration: approved.registration,
          newPhone: RegistrationPhoneBinding(
            deviceId: 'phone-new',
            publicKey: base64UrlEncode(List.filled(32, 9)),
            signingPublicKey: base64UrlEncode(List.filled(32, 10)),
            keyVersion: 1,
            deviceRegistrationJson: '{"synthetic":"qr"}',
          ),
          reviewer: reviewer,
          directoryProject: 'dnsc-pilot',
          previousVersion: 1,
          syncKind: PendingSyncKind.publishReplacement,
          accountUid: 'uid-user-1',
          reason: 'Lost phone',
        );

        // Reopen SQLite to simulate restart before sync completes.
        await db.close();
        db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
        repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);

        final loadedRegs = await repo.loadRegistrations();
        final pending = await repo.loadPendingSync();
        expect(loadedRegs.single.activePhone.deviceId, 'phone-new');
        expect(loadedRegs.single.syncState, CampusSyncState.waitingToSync);
        expect(pending, hasLength(1));
        expect(pending.single.kind, PendingSyncKind.publishReplacement);
        expect(
          pending.single.decisionId,
          staged.registration.pendingDecisionId,
        );
        final payload =
            jsonDecode(pending.single.payloadJson) as Map<String, dynamic>;
        expect(payload['old_device_id'], 'phone-old');
        expect(payload['new_device_id'], 'phone-new');
        expect(payload['account_uid'], 'uid-user-1');
        expect(payload['new_device_registration'], '{"synthetic":"qr"}');
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'pending publishReplacement drains via hosted publisher approve_replacement action',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final signer = await TestTrustBundleSigner.create();
      final reg = CampusRegistration(
        registrationId: 'reg-rep-2',
        source: CampusRegistrationSource.qr,
        status: CampusRegistrationStatus.approvedLocal,
        syncState: CampusSyncState.waitingToSync,
        accountUid: 'uid-rep-2',
        identity: const CampusIdentityFields(
          affiliation: CampusAffiliation.student,
          displayName: 'Sofia Replace',
          studentNumber: '2026-6001',
          course: 'BSIT',
          yearLevel: '3',
          sectionSet: 'A',
        ),
        role: RegisteredDeviceRole.civilian,
        activePhone: RegistrationPhoneBinding(
          deviceId: 'phone-new',
          publicKey: base64UrlEncode(List.filled(32, 9)),
          signingPublicKey: base64UrlEncode(List.filled(32, 10)),
          keyVersion: 1,
          deviceRegistrationJson: '{"synthetic":"qr-2"}',
        ),
        createdAt: DateTime.utc(2026, 11, 26),
        updatedAt: DateTime.utc(2026, 11, 26),
      );
      final pendingOp = PendingSyncOperation(
        decisionId: 'dec-rep-durable',
        registrationId: 'reg-rep-2',
        kind: PendingSyncKind.publishReplacement,
        payloadJson: jsonEncode({
          'account_uid': 'uid-rep-2',
          'new_device_registration': '{"synthetic":"qr-2"}',
          'reason': 'Damaged screen',
        }),
        createdAt: DateTime.utc(2026, 11, 26),
      );
      final registry = _InMemorySyncRegistry([reg], [pendingOp]);
      final publisher = _CapturingPublisher(signer);

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: Scaffold(
            body: UnifiedRegistrationsWorkspace(
              registry: registry,
              reviewApi: _NoopReviewApi(),
              publisherClient: publisher,
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

      expect(publisher.payloads, hasLength(1));
      expect(publisher.payloads.single['action'], 'approve_replacement');
      expect(publisher.payloads.single['decisionId'], 'dec-rep-durable');
      expect(
        publisher.payloads.single['deviceRegistration'],
        '{"synthetic":"qr-2"}',
      );
      expect(registry.pendingSync, isEmpty);
      expect(
        registry.registrations.single.status,
        CampusRegistrationStatus.published,
      );
    },
  );
}
