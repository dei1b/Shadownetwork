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
  late _MemKeys keys;
  late DesktopAdminRegistryRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('unified-reg-test-');
    db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
    keys = _MemKeys();
    repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);
    await repo.initializeIdentity();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  CampusRegistration makeQrReg({
    String deviceId = 'phone-qr-1',
    String? accountUid,
  }) => CampusRegistration(
    registrationId: 'reg-test-1',
    source: CampusRegistrationSource.qr,
    status: CampusRegistrationStatus.submitted,
    syncState: CampusSyncState.waitingToSync,
    accountUid: accountUid,
    identity: const CampusIdentityFields(
      affiliation: CampusAffiliation.student,
      displayName: 'Maria Santos',
      studentNumber: '2026-0001',
      course: 'BSIT',
      yearLevel: '4',
      sectionSet: 'H',
    ),
    role: RegisteredDeviceRole.civilian,
    activePhone: RegistrationPhoneBinding(
      deviceId: deviceId,
      publicKey: base64UrlEncode(List.filled(32, 3)),
      signingPublicKey: base64UrlEncode(List.filled(32, 4)),
      keyVersion: 1,
    ),
    createdAt: DateTime.utc(2026, 11, 25),
    updatedAt: DateTime.utc(2026, 11, 25),
  );

  test('offline approval persists across restart and records reviewer edits', () async {
    final reg = makeQrReg();
    const reviewer = ReviewerProfile(
      uid: 'admin-uid',
      email: 'admin@dnsc.edu.ph',
    );
    final res = await repo.approveOfflineRegistration(
      registration: reg,
      reviewer: reviewer,
      role: RegisteredDeviceRole.responder,
      reviewedIdentity: reg.identity.copyWith(sectionSet: 'A'),
      directoryProject: 'dnsc-pilot',
    );
    expect(res.receipt.registrationId, 'reg-test-1');
    expect(res.registration.status, CampusRegistrationStatus.approvedLocal);
    expect(res.registration.syncState, CampusSyncState.waitingToSync);
    expect(res.registration.reviewHistory.single.editedFields, ['courseYear']);

    // Verify TrustBundle never exposes academic details.
    expect(res.bundleJson, isNot(contains('2026-0001')));
    expect(res.bundleJson, isNot(contains('BSIT')));

    await db.close();
    db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
    repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);
    final loadedRegs = await repo.loadRegistrations();
    final pending = await repo.loadPendingSync();
    expect(loadedRegs.single.status, CampusRegistrationStatus.approvedLocal);
    expect(pending.single.registrationId, 'reg-test-1');
  });

  test('blocks self-review for matching accountUid', () async {
    final reg = makeQrReg(accountUid: 'same-uid');
    await expectLater(
      repo.approveOfflineRegistration(
        registration: reg,
        reviewer: const ReviewerProfile(uid: 'same-uid', email: 'a@b.c'),
        role: RegisteredDeviceRole.civilian,
        reviewedIdentity: reg.identity,
      ),
      throwsStateError,
    );
  });

  test('reconciliation pauses local approval when newer online revocation exists and correction supersedes both', () async {
    final reg = makeQrReg();
    const reviewer = ReviewerProfile(uid: 'admin-1', email: 'a@dnsc.edu.ph');
    await repo.approveOfflineRegistration(
      registration: reg,
      reviewer: reviewer,
      role: RegisteredDeviceRole.civilian,
      reviewedIdentity: reg.identity,
      directoryProject: 'dnsc-pilot',
    );

    // Simulate online bundle at version 5 where phone-qr-1 is revoked.
    final revokedBundleJson = await repo.buildTrustBundleJson(
      [
        reg.toRegisteredDevice().copyWith(status: RegisteredDeviceStatus.revoked),
      ],
      directoryProject: 'dnsc-pilot',
      minimumPreviousVersion: 4,
    );
    final published = TrustBundle.fromJsonString(revokedBundleJson);
    final reconciled = await repo.reconcileWithPublishedRoster(
      published,
      'dnsc-pilot',
    );
    expect(reconciled.single.status, CampusRegistrationStatus.conflict);
    expect(await repo.loadPendingSync(), isEmpty);

    final corrected = await repo.issueSignedCorrection(
      registration: reconciled.single,
      reviewer: reviewer,
      targetStatus: RegisteredDeviceStatus.approved,
      role: RegisteredDeviceRole.responder,
      remoteVersion: published.bundleVersion,
      directoryProject: 'dnsc-pilot',
    );
    final correctedBundle = TrustBundle.fromJsonString(corrected.bundleJson);
    expect(correctedBundle.bundleVersion, greaterThan(published.bundleVersion));
  });

  test('phone replacement handles both new deviceId and same deviceId data clear', () async {
    final reg = makeQrReg(deviceId: 'old-device');
    const reviewer = ReviewerProfile(uid: 'admin-1', email: 'a@dnsc.edu.ph');
    final initial = await repo.approveOfflineRegistration(
      registration: reg,
      reviewer: reviewer,
      role: RegisteredDeviceRole.civilian,
      reviewedIdentity: reg.identity,
      directoryProject: 'dnsc-pilot',
    );
    // Replace with different device ID -> old marked revoked, new approved.
    final diffReplace = await repo.stagePhoneReplacement(
      registration: initial.registration,
      newPhone: RegistrationPhoneBinding(
        deviceId: 'new-device',
        publicKey: base64UrlEncode(List.filled(32, 9)),
        signingPublicKey: base64UrlEncode(List.filled(32, 10)),
        keyVersion: 1,
      ),
      reviewer: reviewer,
      directoryProject: 'dnsc-pilot',
      previousVersion: 1,
    );
    final bundle1 = TrustBundle.fromJsonString(diffReplace.bundleJson);
    expect(bundle1.revokedDevices.map((d) => d.deviceId), contains('old-device'));
    expect(bundle1.approvedDevices.map((d) => d.deviceId), contains('new-device'));
    expect(diffReplace.registration.retiredKeys, hasLength(1));

    // Data clear reuses same deviceId -> keyVersion matches new phone keys while revision & retiredKeys track history.
    final sameReplace = await repo.stagePhoneReplacement(
      registration: diffReplace.registration,
      newPhone: RegistrationPhoneBinding(
        deviceId: 'new-device',
        publicKey: base64UrlEncode(List.filled(32, 11)),
        signingPublicKey: base64UrlEncode(List.filled(32, 12)),
        keyVersion: 1,
      ),
      reviewer: reviewer,
      directoryProject: 'dnsc-pilot',
      previousVersion: bundle1.bundleVersion,
    );
    expect(sameReplace.registration.activePhone.keyVersion, 1);
    expect(
      sameReplace.registration.revision,
      greaterThan(diffReplace.registration.revision),
    );
    expect(sameReplace.registration.retiredKeys, hasLength(2));
  });

  test('encrypted backup v2 preserves registrations, pending sync and reviewer profile', () async {
    final reg = makeQrReg();
    const reviewer = ReviewerProfile(uid: 'admin-1', email: 'a@dnsc.edu.ph');
    await repo.saveReviewerProfile(reviewer);
    await repo.approveOfflineRegistration(
      registration: reg,
      reviewer: reviewer,
      role: RegisteredDeviceRole.civilian,
      reviewedIdentity: reg.identity,
      directoryProject: 'dnsc-pilot',
    );
    final backup = await repo.createEncryptedBackup('strong-test-password-1');

    final destDir = await Directory.systemTemp.createTemp('unified-restore-');
    addTearDown(() => destDir.delete(recursive: true));
    final destDb = await openDesktopAdminRegistryDatabase(
      '${destDir.path}/restore.sqlite',
    );
    addTearDown(destDb.close);
    final destRepo = DesktopAdminRegistryRepository(
      database: destDb,
      keyStore: _MemKeys(),
    );
    await destRepo.restoreEncryptedBackup(backup, 'strong-test-password-1');

    expect((await destRepo.loadRegistrations()).single.registrationId, 'reg-test-1');
    expect((await destRepo.loadPendingSync()).single.registrationId, 'reg-test-1');
    expect((await destRepo.loadReviewerProfile())?.email, 'a@dnsc.edu.ph');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
