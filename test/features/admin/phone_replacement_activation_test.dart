import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
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

  test(
    'same-deviceId cleared-data phone replacement preserves keyVersion 1 and activates in DeviceAccessResolver',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('replace-activate-');
      final db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
      try {
        final repo = DesktopAdminRegistryRepository(
          database: db,
          keyStore: _MemKeys(),
        );
        await repo.initializeIdentity();

        final originalSecrets = InMemorySecretValueStore();
        final oldCrypto = await DeviceIdentityStore(
          secretStore: originalSecrets,
        ).loadOrCreate();
        final oldSigning = await DeviceSigningIdentityStore(
          secretStore: originalSecrets,
        ).loadOrCreate();
        const reviewer = ReviewerProfile(
          uid: 'admin-1',
          email: 'admin@dnsc.edu.ph',
        );

        final approved = await repo.approveOfflineRegistration(
          registration: CampusRegistration(
            registrationId: 'reg-clear-1',
            source: CampusRegistrationSource.qr,
            status: CampusRegistrationStatus.submitted,
            syncState: CampusSyncState.waitingToSync,
            identity: const CampusIdentityFields(
              affiliation: CampusAffiliation.student,
              displayName: 'Cleared Data User',
              studentNumber: '2026-7701',
              course: 'BSIT',
              yearLevel: '4',
              sectionSet: 'H',
            ),
            role: RegisteredDeviceRole.responder,
            activePhone: RegistrationPhoneBinding(
              deviceId: 'phone-cleared-1',
              publicKey: oldCrypto.encodedPublicKey,
              signingPublicKey: oldSigning.encodedPublicKey,
              keyId: oldCrypto.keyId,
              keyVersion: oldCrypto.keyVersion,
            ),
            createdAt: DateTime.utc(2026, 11, 26),
            updatedAt: DateTime.utc(2026, 11, 26),
          ),
          reviewer: reviewer,
          role: RegisteredDeviceRole.responder,
          reviewedIdentity: const CampusIdentityFields(
            affiliation: CampusAffiliation.student,
            displayName: 'Cleared Data User',
            studentNumber: '2026-7701',
            course: 'BSIT',
            yearLevel: '4',
            sectionSet: 'H',
          ),
          directoryProject: 'dnsc-pilot',
        );

        // Fresh install after clearing app data: same deviceId, new keys, keyVersion == 1.
        final clearedSecrets = InMemorySecretValueStore();
        final newCrypto = await DeviceIdentityStore(
          secretStore: clearedSecrets,
        ).loadOrCreate();
        final newSigning = await DeviceSigningIdentityStore(
          secretStore: clearedSecrets,
        ).loadOrCreate();
        expect(newCrypto.keyVersion, 1);
        final replacementQr = await DeviceRegistrationQr.createSigned(
          deviceId: 'phone-cleared-1',
          identity: newCrypto,
          signingIdentity: newSigning,
        );

        final staged = await repo.stagePhoneReplacement(
          registration: approved.registration,
          newPhone: RegistrationPhoneBinding(
            deviceId: replacementQr.deviceId,
            publicKey: replacementQr.publicKey,
            signingPublicKey: replacementQr.signingPublicKey,
            keyId: replacementQr.keyId,
            keyVersion: replacementQr.keyVersion,
            deviceRegistrationJson: jsonEncode(replacementQr.toJson()),
          ),
          reviewer: reviewer,
          directoryProject: 'dnsc-pilot',
          previousVersion: 0,
        );

        expect(staged.registration.activePhone.keyVersion, 1);
        expect(staged.registration.retiredKeys, hasLength(1));

        final store = TrustBundleStore();
        final rootFingerprint = sha256
            .convert(base64Url.decode(approved.receipt.issuer.publicKey))
            .toString();
        final bundle = await store.importBundleJson(
          staged.bundleJson,
          directoryProject: 'dnsc-pilot',
          issuerFingerprint: rootFingerprint,
        );

        const resolver = DeviceAccessResolver();
        final newAccess = resolver.resolve(
          deviceId: 'phone-cleared-1',
          publicKey: newCrypto.encodedPublicKey,
          keyVersion: newCrypto.keyVersion,
          signingPublicKey: newSigning.encodedPublicKey,
          bundle: bundle,
        );
        expect(newAccess.level, DeviceAccessLevel.responder);
        expect(newAccess.ownerName, 'Cleared Data User');

        final oldAccess = resolver.resolve(
          deviceId: 'phone-cleared-1',
          publicKey: oldCrypto.encodedPublicKey,
          keyVersion: oldCrypto.keyVersion,
          signingPublicKey: oldSigning.encodedPublicKey,
          bundle: bundle,
        );
        expect(oldAccess.level, DeviceAccessLevel.keyMismatch);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
