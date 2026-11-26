import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/data/admin_registry_backup.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/domain/services/canonical_json.dart';
import 'package:shadownetwork/features/trust/domain/services/device_access_resolver.dart';

class _MemKeys implements AdminSigningKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const password = 'strong-backup-v3-password';

  test(
    'encrypted backup v3 preserves verified admin_published_roster and rejects tampered roster',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('backup-v3-');
      final db = await openDesktopAdminRegistryDatabase('${dir.path}/src.sqlite');
      final destDb = await openDesktopAdminRegistryDatabase(
        '${dir.path}/dest.sqlite',
      );
      final badDestDb = await openDesktopAdminRegistryDatabase(
        '${dir.path}/bad_dest.sqlite',
      );
      try {
        final keys = _MemKeys();
        final repo = DesktopAdminRegistryRepository(
          database: db,
          keyStore: keys,
        );
        await repo.initializeIdentity();

        final device = RegisteredDevice(
          deviceId: 'phone-v3-1',
          ownerName: 'Lina Roster',
          role: RegisteredDeviceRole.responder,
          status: RegisteredDeviceStatus.approved,
          registeredAt: DateTime.utc(2026, 11, 26),
          updatedAt: DateTime.utc(2026, 11, 26),
          lastSeenLabel: 'Published',
          publicKey: base64UrlEncode(List.filled(32, 5)),
          signingPublicKey: base64UrlEncode(List.filled(32, 6)),
          keyVersion: 1,
        );
        final rosterJson = await repo.buildTrustBundleJson(
          [device],
          directoryProject: 'dnsc-pilot',
          minimumPreviousVersion: 4,
        );
        final roster = TrustBundle.fromJsonString(rosterJson);
        await repo.saveLastPublishedRoster(roster, rosterJson);

        final encryptedV3 = await repo.createEncryptedBackup(password);
        final decryptedV3 = await AdminRegistryBackup.decrypt(
          encryptedV3,
          password,
        );
        expect(decryptedV3['version'], 3);
        expect(decryptedV3['published_roster'], isA<Map>());

        final destRepo = DesktopAdminRegistryRepository(
          database: destDb,
          keyStore: _MemKeys(),
        );
        await destRepo.restoreEncryptedBackup(encryptedV3, password);
        final restoredRoster = await destRepo.loadLastPublishedRoster();
        expect(restoredRoster, isNotNull);
        expect(restoredRoster!.version, roster.bundleVersion);
        expect(restoredRoster.bundleJson, rosterJson);

        // Tampering with published_roster version must reject restore without DB writes.
        final tamperedPayload = Map<String, Object?>.from(decryptedV3)
          ..['published_roster'] = {
            ...Map<String, Object?>.from(decryptedV3['published_roster']! as Map),
            'version': roster.bundleVersion + 99,
          };
        final tamperedEncrypted = await AdminRegistryBackup.encrypt(
          tamperedPayload,
          password,
        );
        final badDestRepo = DesktopAdminRegistryRepository(
          database: badDestDb,
          keyStore: _MemKeys(),
        );
        await expectLater(
          badDestRepo.restoreEncryptedBackup(tamperedEncrypted, password),
          throwsA(anything),
        );
        expect(await badDestRepo.loadLastPublishedRoster(), isNull);
        expect((await badDestRepo.identityStatus()).hasIdentity, isFalse);

        // Legacy v2 backups without published_roster still restore cleanly.
        final legacyV2Payload = Map<String, Object?>.from(decryptedV3)
          ..['version'] = 2
          ..remove('published_roster');
        final legacyV2Encrypted = await AdminRegistryBackup.encrypt(
          legacyV2Payload,
          password,
        );
        await badDestRepo.restoreEncryptedBackup(legacyV2Encrypted, password);
        expect((await badDestRepo.identityStatus()).hasIdentity, isTrue);
        expect(await badDestRepo.loadLastPublishedRoster(), isNull);
      } finally {
        await db.close();
        await destDb.close();
        await badDestDb.close();
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'R8: encrypted backup v3 with expired publisher delegation restores admin identity and pending sync without activating expired bundle',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('backup-v3-expired-del-');
      final db = await openDesktopAdminRegistryDatabase('${dir.path}/src.sqlite');
      final destDb = await openDesktopAdminRegistryDatabase(
        '${dir.path}/dest.sqlite',
      );
      try {
        final keys = _MemKeys();
        final repo = DesktopAdminRegistryRepository(
          database: db,
          keyStore: keys,
        );
        await repo.initializeIdentity();
        final srcIdentity = await repo.identityStatus();

        // Mint a historical delegation that was valid in Jan 2026 but is expired now.
        final expiredDel = await repo.createPublisherDelegation(
          directoryProject: 'dnsc-pilot',
          issuedAt: DateTime.utc(2026, 1, 1),
          validity: const Duration(days: 30),
        );
        final delSeed = base64Url.decode(expiredDel.publisherPrivateKeySeed);
        final delKeyPair = await Ed25519().newKeyPairFromSeed(delSeed);
        final bundleIssuedAt = DateTime.utc(2026, 1, 15);
        final bundleExpiresAt = DateTime.utc(2026, 1, 31);
        final pub = base64UrlEncode(List.filled(32, 13));
        final sign = base64UrlEncode(List.filled(32, 14));
        final unsignedExpired = TrustBundle(
          schemaVersion: 2,
          bundleVersion: 5,
          generatedAt: bundleIssuedAt,
          issuedAt: bundleIssuedAt,
          expiresAt: bundleExpiresAt,
          directoryProject: 'dnsc-pilot',
          issuer: expiredDel.delegation.publisher,
          publisherDelegation: expiredDel.delegation,
          approvedDevices: [
            TrustedDevice(
              deviceId: 'phone-hist-1',
              ownerName: 'Historical Student',
              role: 'civilian',
              status: 'approved',
              publicKey: pub,
              signingPublicKey: sign,
              keyVersion: 1,
              updatedAt: bundleIssuedAt,
            ),
          ],
          revokedDevices: const [],
        );
        final expiredSig = await Ed25519().sign(
          utf8.encode(canonicalJsonEncode(unsignedExpired.toJson(includeSignature: false))),
          keyPair: delKeyPair,
        );
        final expiredBundleJson = jsonEncode({
          ...unsignedExpired.toJson(includeSignature: false),
          'signature': base64UrlEncode(expiredSig.bytes),
        });
        final expiredBundle = TrustBundle.fromJsonString(expiredBundleJson);
        await repo.saveLastPublishedRoster(expiredBundle, expiredBundleJson);

        final queuedReg = CampusRegistration(
          registrationId: 'reg-r8-queued',
          source: CampusRegistrationSource.qr,
          status: CampusRegistrationStatus.submitted,
          syncState: CampusSyncState.waitingToSync,
          identity: const CampusIdentityFields(
            affiliation: CampusAffiliation.student,
            displayName: 'Queued Student',
            studentNumber: '2026-8801',
            course: 'BSIT',
            yearLevel: '3',
            sectionSet: 'A',
          ),
          role: RegisteredDeviceRole.civilian,
          activePhone: RegistrationPhoneBinding(
            deviceId: 'phone-r8-queued',
            publicKey: base64UrlEncode(List.filled(32, 15)),
            signingPublicKey: base64UrlEncode(List.filled(32, 16)),
            keyVersion: 1,
          ),
          createdAt: DateTime.utc(2026, 11, 26),
          updatedAt: DateTime.utc(2026, 11, 26),
        );
        await repo.approveOfflineRegistration(
          registration: queuedReg,
          reviewer: const ReviewerProfile(
            uid: 'admin-r8',
            email: 'admin-r8@dnsc.edu.ph',
          ),
          role: RegisteredDeviceRole.civilian,
          reviewedIdentity: queuedReg.identity,
          directoryProject: 'dnsc-pilot',
        );

        final encryptedV3 = await repo.createEncryptedBackup(password);

        // Restore onto a fresh repository at current time (> 2026-01-31 delegation expiry).
        final destRepo = DesktopAdminRegistryRepository(
          database: destDb,
          keyStore: _MemKeys(),
        );
        await destRepo.restoreEncryptedBackup(encryptedV3, password);

        final destIdentity = await destRepo.identityStatus();
        expect(destIdentity.hasIdentity, isTrue);
        expect(destIdentity.fingerprint, srcIdentity.fingerprint);
        final restoredRoster = await destRepo.loadLastPublishedRoster();
        expect(restoredRoster, isNotNull);
        expect(restoredRoster!.version, 5);
        final restoredPending = await destRepo.loadPendingSync();
        expect(restoredPending, hasLength(1));
        expect(restoredPending.single.registrationId, 'reg-r8-queued');

        // Expired restored bundle must NOT activate a phone at current time.
        final rootFp = sha256
            .convert(base64Url.decode(expiredDel.delegation.rootIssuer.publicKey))
            .toString();
        final phoneStore = TrustBundleStore();
        await expectLater(
          phoneStore.importBundleJson(
            restoredRoster.bundleJson,
            directoryProject: 'dnsc-pilot',
            issuerFingerprint: rootFp,
          ),
          throwsFormatException,
        );
        expect(await phoneStore.loadBundle(), isNull);
        final accessWithoutBundle = const DeviceAccessResolver().resolve(
          deviceId: 'phone-hist-1',
          publicKey: pub,
          signingPublicKey: sign,
          keyVersion: 1,
          bundle: null,
        );
        expect(accessWithoutBundle.isApproved, isFalse);

        // A renewed delegation & directory at current time allows reconciliation and sync to resume.
        final now = DateTime.now().toUtc();
        final renewedDel = await destRepo.createPublisherDelegation(
          directoryProject: 'dnsc-pilot',
          issuedAt: now.subtract(const Duration(minutes: 5)),
          validity: const Duration(days: 30),
        );
        final renewedSeed = base64Url.decode(renewedDel.publisherPrivateKeySeed);
        final renewedKeyPair = await Ed25519().newKeyPairFromSeed(renewedSeed);
        final unsignedRenewed = TrustBundle(
          schemaVersion: 2,
          bundleVersion: 6,
          generatedAt: now,
          issuedAt: now,
          expiresAt: now.add(const Duration(days: 30)),
          directoryProject: 'dnsc-pilot',
          issuer: renewedDel.delegation.publisher,
          publisherDelegation: renewedDel.delegation,
          approvedDevices: unsignedExpired.approvedDevices,
          revokedDevices: const [],
        );
        final renewedSig = await Ed25519().sign(
          utf8.encode(canonicalJsonEncode(unsignedRenewed.toJson(includeSignature: false))),
          keyPair: renewedKeyPair,
        );
        final renewedJson = jsonEncode({
          ...unsignedRenewed.toJson(includeSignature: false),
          'signature': base64UrlEncode(renewedSig.bytes),
        });
        final renewedBundle = await phoneStore.importBundleJson(
          renewedJson,
          directoryProject: 'dnsc-pilot',
          issuerFingerprint: rootFp,
        );
        expect(renewedBundle.bundleVersion, 6);
        await destRepo.reconcileWithPublishedRoster(renewedBundle, 'dnsc-pilot');
        expect(await destRepo.loadPendingSync(), hasLength(1));
      } finally {
        await db.close();
        await destDb.close();
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
