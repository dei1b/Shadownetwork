import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shadownetwork/features/admin/data/admin_registry_backup.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
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
}
