import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

class _MemKeys implements AdminSigningKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Database db;
  late DesktopAdminRegistryRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('signed-correction-reconcile-');
    db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
    repo = DesktopAdminRegistryRepository(database: db, keyStore: _MemKeys());
    await repo.initializeIdentity();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  CampusRegistration makeSubmission() => CampusRegistration(
    registrationId: 'reg-conflict-1',
    source: CampusRegistrationSource.qr,
    status: CampusRegistrationStatus.submitted,
    syncState: CampusSyncState.waitingToSync,
    identity: const CampusIdentityFields(
      affiliation: CampusAffiliation.student,
      displayName: 'Marco Conflict',
      studentNumber: '2026-5001',
      course: 'BSIT',
      yearLevel: '3',
      sectionSet: 'B',
    ),
    role: RegisteredDeviceRole.civilian,
    activePhone: RegistrationPhoneBinding(
      deviceId: 'phone-conflict-1',
      publicKey: base64UrlEncode(List.filled(32, 3)),
      signingPublicKey: base64UrlEncode(List.filled(32, 4)),
      keyVersion: 1,
    ),
    createdAt: DateTime.utc(2026, 11, 26),
    updatedAt: DateTime.utc(2026, 11, 26),
  );

  test(
    'pending signed correction survives pre-sync reconciliation at the examined version and re-flags only on newer versions',
    () async {
      const reviewer = ReviewerProfile(
        uid: 'admin-1',
        email: 'admin@dnsc.edu.ph',
      );
      final approved = await repo.approveOfflineRegistration(
        registration: makeSubmission(),
        reviewer: reviewer,
        role: RegisteredDeviceRole.responder,
        reviewedIdentity: makeSubmission().identity,
        directoryProject: 'dnsc-pilot',
      );

      // Remote directory v2 revoked phone-conflict-1.
      final revokedV2Json = await repo.buildTrustBundleJson(
        [
          approved.registration.toRegisteredDevice().copyWith(
            status: RegisteredDeviceStatus.revoked,
          ),
        ],
        directoryProject: 'dnsc-pilot',
        minimumPreviousVersion: 1,
      );
      final revokedV2 = TrustBundle.fromJsonString(revokedV2Json);
      expect(revokedV2.bundleVersion, 2);

      final firstReconcile = await repo.reconcileWithPublishedRoster(
        revokedV2,
        'dnsc-pilot',
      );
      expect(firstReconcile.single.status, CampusRegistrationStatus.conflict);
      expect(await repo.loadPendingSync(), isEmpty);

      // Admin reviews conflict and issues signed correction targeting remoteVersion 2.
      final corrected = await repo.issueSignedCorrection(
        registration: firstReconcile.single,
        reviewer: reviewer,
        targetStatus: RegisteredDeviceStatus.approved,
        role: RegisteredDeviceRole.responder,
        remoteVersion: revokedV2.bundleVersion,
        directoryProject: 'dnsc-pilot',
        reason: 'Verified physical ID',
      );
      expect(
        corrected.registration.status,
        CampusRegistrationStatus.approvedLocal,
      );
      expect(corrected.registration.resolvedConflictVersion, 2);
      final pendingBeforeSync = await repo.loadPendingSync();
      expect(pendingBeforeSync, hasLength(1));
      expect(
        pendingBeforeSync.single.kind,
        PendingSyncKind.publishRevocationCorrection,
      );

      // Sync starts by calling reconcileWithPublishedRoster(revokedV2) again.
      // The signed correction MUST remain approvedLocal + pending in SQLite!
      final preSyncReconcile = await repo.reconcileWithPublishedRoster(
        revokedV2,
        'dnsc-pilot',
      );
      expect(
        preSyncReconcile.single.status,
        CampusRegistrationStatus.approvedLocal,
      );
      expect(
        preSyncReconcile.single.syncState,
        CampusSyncState.waitingToSync,
      );
      expect(await repo.loadPendingSync(), hasLength(1));

      // An independent newer remote revocation (v4 > resolvedConflictVersion 2)
      // must still flag conflict while retaining review history.
      final newerRevokedJson = await repo.buildTrustBundleJson(
        [
          approved.registration.toRegisteredDevice().copyWith(
            status: RegisteredDeviceStatus.revoked,
          ),
        ],
        directoryProject: 'dnsc-pilot',
        minimumPreviousVersion: 3,
      );
      final newerRevoked = TrustBundle.fromJsonString(newerRevokedJson);
      expect(newerRevoked.bundleVersion, 4);

      final secondConflict = await repo.reconcileWithPublishedRoster(
        newerRevoked,
        'dnsc-pilot',
      );
      expect(secondConflict.single.status, CampusRegistrationStatus.conflict);
      expect(secondConflict.single.reviewHistory.length, greaterThanOrEqualTo(2));
    },
  );
}
