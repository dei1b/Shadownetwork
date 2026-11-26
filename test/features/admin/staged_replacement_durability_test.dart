import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  _CapturingPublisher(this.signer, {this.approvedDevices = const []})
    : super(endpoint: Uri.parse('https://admin.test/api/publish-approval'));

  final TestTrustBundleSigner signer;
  final List<TrustedDevice> approvedDevices;
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
      approvedDevices: approvedDevices,
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
      final publisher = _CapturingPublisher(
        signer,
        approvedDevices: [
          TrustedDevice(
            deviceId: reg.activePhone.deviceId,
            ownerName: reg.identity.displayName,
            role: reg.role.name,
            status: 'approved',
            publicKey: reg.activePhone.publicKey,
            signingPublicKey: reg.activePhone.signingPublicKey,
            keyVersion: reg.activePhone.keyVersion,
            updatedAt: DateTime.utc(2026, 11, 26, 12),
          ),
        ],
      );

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

  test(
    'same-ID staged replacement survives SQLite reopen and reconcileWithPublishedRoster while conflicting third keypair preserves pending replacement op',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp(
        'staged-same-id-reconcile-',
      );
      final thirdDir = await Directory.systemTemp.createTemp(
        'staged-same-id-third-',
      );
      var db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
      var thirdDb = await openDesktopAdminRegistryDatabase(
        '${thirdDir.path}/reg.sqlite',
      );
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
        final otherReg = CampusRegistration(
          registrationId: 'reg-other-1',
          source: CampusRegistrationSource.qr,
          status: CampusRegistrationStatus.submitted,
          syncState: CampusSyncState.waitingToSync,
          accountUid: 'uid-other-1',
          identity: const CampusIdentityFields(
            affiliation: CampusAffiliation.student,
            displayName: 'Unrelated Student',
            studentNumber: '2026-7001',
            course: 'BSIT',
            yearLevel: '2',
            sectionSet: 'B',
          ),
          role: RegisteredDeviceRole.civilian,
          activePhone: RegistrationPhoneBinding(
            deviceId: 'phone-other',
            publicKey: base64UrlEncode(List.filled(32, 31)),
            signingPublicKey: base64UrlEncode(List.filled(32, 32)),
            keyVersion: 1,
          ),
          createdAt: DateTime.utc(2026, 11, 26),
          updatedAt: DateTime.utc(2026, 11, 26),
        );
        await repo.approveOfflineRegistration(
          registration: otherReg,
          reviewer: reviewer,
          role: RegisteredDeviceRole.civilian,
          reviewedIdentity: otherReg.identity,
          directoryProject: 'dnsc-pilot',
        );
        await repo.removePendingSync(
          (await repo.loadPendingSync()).single.decisionId,
        );

        final oldPub = base64UrlEncode(List.filled(32, 1));
        final oldSign = base64UrlEncode(List.filled(32, 2));
        final sameReg = CampusRegistration(
          registrationId: 'reg-same-id-1',
          source: CampusRegistrationSource.qr,
          status: CampusRegistrationStatus.submitted,
          syncState: CampusSyncState.waitingToSync,
          accountUid: 'uid-same-1',
          identity: const CampusIdentityFields(
            affiliation: CampusAffiliation.student,
            displayName: 'Same ID Student',
            studentNumber: '2026-7002',
            course: 'BSIT',
            yearLevel: '4',
            sectionSet: 'A',
          ),
          role: RegisteredDeviceRole.civilian,
          activePhone: RegistrationPhoneBinding(
            deviceId: 'phone-same',
            publicKey: oldPub,
            signingPublicKey: oldSign,
            keyVersion: 1,
          ),
          createdAt: DateTime.utc(2026, 11, 26),
          updatedAt: DateTime.utc(2026, 11, 26),
        );
        final approvedSame = await repo.approveOfflineRegistration(
          registration: sameReg,
          reviewer: reviewer,
          role: RegisteredDeviceRole.civilian,
          reviewedIdentity: sameReg.identity,
          directoryProject: 'dnsc-pilot',
        );
        await repo.removePendingSync(
          (await repo.loadPendingSync()).single.decisionId,
        );
        final initialBundleJson = await repo.buildTrustBundleJson(
          await repo.loadDevices(),
          directoryProject: 'dnsc-pilot',
        );
        final publishedOld = TrustBundle.fromJsonString(initialBundleJson);
        expect(
          publishedOld.approvedDevices.map((d) => d.deviceId),
          containsAll(['phone-other', 'phone-same']),
        );

        final newPub = base64UrlEncode(List.filled(32, 9));
        final newSign = base64UrlEncode(List.filled(32, 10));
        await repo.stagePhoneReplacement(
          registration: approvedSame.registration,
          newPhone: RegistrationPhoneBinding(
            deviceId: 'phone-same',
            publicKey: newPub,
            signingPublicKey: newSign,
            keyVersion: 2,
            deviceRegistrationJson: '{"synthetic":"same-id-new"}',
          ),
          reviewer: reviewer,
          directoryProject: 'dnsc-pilot',
          previousVersion: publishedOld.bundleVersion,
          syncKind: PendingSyncKind.publishReplacement,
          accountUid: 'uid-same-1',
          reason: 'Reinstalled app keeping device ID',
        );

        // Reopen SQLite and reconcile against the prior published roster.
        await db.close();
        db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
        repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);

        final reconciled = await repo.reconcileWithPublishedRoster(
          publishedOld,
          'dnsc-pilot',
        );
        final updatedSame = reconciled.firstWhere(
          (r) => r.registrationId == 'reg-same-id-1',
        );
        expect(updatedSame.status, CampusRegistrationStatus.approvedLocal);
        expect(updatedSame.syncState, CampusSyncState.waitingToSync);
        expect(updatedSame.activePhone.publicKey, newPub);
        final pendingAfterOld = await repo.loadPendingSync();
        expect(pendingAfterOld, hasLength(1));
        expect(pendingAfterOld.single.kind, PendingSyncKind.publishReplacement);

        // Now reconcile against a third keypair published for the same device ID.
        final thirdKeys = _MemKeys()..value = keys.value;
        final thirdRepo = DesktopAdminRegistryRepository(
          database: thirdDb,
          keyStore: thirdKeys,
        );
        await thirdRepo.initializeIdentity();
        final thirdPub = base64UrlEncode(List.filled(32, 21));
        final thirdSign = base64UrlEncode(List.filled(32, 22));
        await thirdRepo.approveOfflineRegistration(
          registration: sameReg.copyWith(
            activePhone: RegistrationPhoneBinding(
              deviceId: 'phone-same',
              publicKey: thirdPub,
              signingPublicKey: thirdSign,
              keyVersion: 3,
            ),
          ),
          reviewer: reviewer,
          role: RegisteredDeviceRole.civilian,
          reviewedIdentity: sameReg.identity,
          directoryProject: 'dnsc-pilot',
        );
        final thirdBundleJson = await thirdRepo.buildTrustBundleJson(
          await thirdRepo.loadDevices(),
          directoryProject: 'dnsc-pilot',
          minimumPreviousVersion: publishedOld.bundleVersion,
        );
        final publishedThird = TrustBundle.fromJsonString(thirdBundleJson);

        final conflicted = await repo.reconcileWithPublishedRoster(
          publishedThird,
          'dnsc-pilot',
        );
        final conflictedSame = conflicted.firstWhere(
          (r) => r.registrationId == 'reg-same-id-1',
        );
        expect(conflictedSame.status, CampusRegistrationStatus.conflict);
        expect(conflictedSame.syncState, CampusSyncState.conflict);
        final pendingAfterConflict = await repo.loadPendingSync();
        expect(pendingAfterConflict, hasLength(1));
        expect(
          pendingAfterConflict.single.decisionId,
          pendingAfterOld.single.decisionId,
        );
      } finally {
        await db.close();
        await thirdDb.close();
        await dir.delete(recursive: true);
        await thirdDir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'same-ID replacement op drains on sync with 1 publish and empty queue across retries',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final signer = await TestTrustBundleSigner.create();
      final reg = CampusRegistration(
        registrationId: 'reg-same-widget',
        source: CampusRegistrationSource.qr,
        status: CampusRegistrationStatus.approvedLocal,
        syncState: CampusSyncState.waitingToSync,
        accountUid: 'uid-same-widget',
        identity: const CampusIdentityFields(
          affiliation: CampusAffiliation.student,
          displayName: 'Same ID Widget',
          studentNumber: '2026-7003',
          course: 'BSIT',
          yearLevel: '3',
          sectionSet: 'C',
        ),
        role: RegisteredDeviceRole.civilian,
        activePhone: RegistrationPhoneBinding(
          deviceId: 'phone-same',
          publicKey: base64UrlEncode(List.filled(32, 9)),
          signingPublicKey: base64UrlEncode(List.filled(32, 10)),
          keyVersion: 2,
          deviceRegistrationJson: '{"synthetic":"same-widget-qr"}',
        ),
        createdAt: DateTime.utc(2026, 11, 26),
        updatedAt: DateTime.utc(2026, 11, 26),
      );
      final pendingOp = PendingSyncOperation(
        decisionId: 'dec-same-widget',
        registrationId: 'reg-same-widget',
        kind: PendingSyncKind.publishReplacement,
        payloadJson: jsonEncode({
          'old_device_id': 'phone-same',
          'old_public_key': base64UrlEncode(List.filled(32, 1)),
          'old_signing_public_key': base64UrlEncode(List.filled(32, 2)),
          'new_device_id': 'phone-same',
          'expected_bundle_version': 1,
          'account_uid': 'uid-same-widget',
          'new_device_registration': '{"synthetic":"same-widget-qr"}',
          'reason': 'Reinstalled app',
        }),
        createdAt: DateTime.utc(2026, 11, 26),
      );
      final registry = _InMemorySyncRegistry([reg], [pendingOp]);
      final publisher = _CapturingPublisher(
        signer,
        approvedDevices: [
          TrustedDevice(
            deviceId: reg.activePhone.deviceId,
            ownerName: reg.identity.displayName,
            role: reg.role.name,
            status: 'approved',
            publicKey: reg.activePhone.publicKey,
            signingPublicKey: reg.activePhone.signingPublicKey,
            keyVersion: reg.activePhone.keyVersion,
            updatedAt: DateTime.utc(2026, 11, 26, 12),
          ),
        ],
      );

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
      expect(publisher.payloads.single['decisionId'], 'dec-same-widget');
      expect(registry.pendingSync, isEmpty);
      expect(
        registry.registrations.single.status,
        CampusRegistrationStatus.published,
      );
      expect(find.text('Sync 1 pending'), findsNothing);
    },
  );
}
