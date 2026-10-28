import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/admin_registry_backup.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';

class MemorySigningKeyStore implements AdminSigningKeyStore {
  String? value;
  bool failWrites = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    if (failWrites) {
      throw StateError('Synthetic protected storage write failure');
    }
    this.value = value;
  }
}

class YieldingSigningKeyStore implements AdminSigningKeyStore {
  YieldingSigningKeyStore(this.delegate);
  final MemorySigningKeyStore delegate;
  int activeReads = 0;
  int maximumReads = 0;
  @override
  Future<String?> read() async {
    activeReads++;
    if (activeReads > maximumReads) maximumReads = activeReads;
    final snapshot = await delegate.read();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    activeReads--;
    return snapshot;
  }

  @override
  Future<void> write(String source) => delegate.write(source);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Database database;
  late MemorySigningKeyStore keys;
  late DesktopAdminRegistryRepository repository;
  const password = 'synthetic-test-password';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('shadow-admin-test-');
    database = await openDesktopAdminRegistryDatabase(
      '${directory.path}/registry.sqlite',
    );
    keys = MemorySigningKeyStore();
    repository = DesktopAdminRegistryRepository(
      database: database,
      keyStore: keys,
    );
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'fresh registry requires explicit identity creation before publishing',
    () async {
      expect((await repository.identityStatus()).hasIdentity, isFalse);
      await expectLater(repository.buildTrustBundleJson([]), throwsStateError);
      expect(keys.value, isNull);
      await repository.initializeIdentity();
      final status = await repository.identityStatus();
      expect(status.hasIdentity, isTrue);
      expect(status.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(status.bundleVersion, 0);
    },
  );

  test(
    'SQLite restart preserves devices, issuer and phone-verifiable versions',
    () async {
      await repository.initializeIdentity();
      await repository.saveDevices([device()]);
      final first = await TrustBundleStore().importBundleJson(
        await repository.buildTrustBundleJson(await repository.loadDevices()),
      );
      await database.close();
      database = await openDesktopAdminRegistryDatabase(
        '${directory.path}/registry.sqlite',
      );
      repository = DesktopAdminRegistryRepository(
        database: database,
        keyStore: keys,
      );
      final loaded = await repository.loadDevices();
      expect(loaded.single.ownerName, 'Synthetic responder');
      final second = await TrustBundleStore().importBundleJson(
        await repository.buildTrustBundleJson(loaded),
      );
      expect(second.isSignatureVerified, isTrue);
      expect(second.issuer!.publicKey, first.issuer!.publicKey);
      expect(second.bundleVersion, 2);
      expect(
        jsonEncode(await database.query('admin_identity')),
        isNot(contains('private_key')),
      );
      expect(
        jsonEncode(await database.query('admin_identity')),
        isNot(contains((jsonDecode(keys.value!) as Map)['private_key'])),
      );
    },
  );

  test('key loss or mismatch cannot silently replace a bound issuer', () async {
    await repository.initializeIdentity();
    final original = keys.value;
    keys.value = null;
    await expectLater(repository.identityStatus(), throwsStateError);
    await expectLater(repository.initializeIdentity(), throwsStateError);
    await expectLater(repository.buildTrustBundleJson([]), throwsStateError);
    expect(keys.value, isNull);
    final otherDb = await openDesktopAdminRegistryDatabase(
      '${directory.path}/other.sqlite',
    );
    try {
      final other = DesktopAdminRegistryRepository(
        database: otherDb,
        keyStore: keys,
      );
      await other.initializeIdentity();
      await expectLater(repository.buildTrustBundleJson([]), throwsStateError);
      await expectLater(repository.initializeIdentity(), throwsStateError);
    } finally {
      await otherDb.close();
    }
    keys.value = original;
    expect((await repository.identityStatus()).hasIdentity, isTrue);
  });

  test(
    'concurrent publishers across repository objects reserve distinct monotonic versions',
    () async {
      await repository.initializeIdentity();
      final second = DesktopAdminRegistryRepository(
        database: database,
        keyStore: keys,
      );
      final results = await Future.wait(
        List.generate(
          8,
          (index) =>
              (index.isEven ? repository : second).buildTrustBundleJson([]),
        ),
      );
      expect(
        results
            .map((source) => (jsonDecode(source) as Map)['bundle_version'])
            .toSet(),
        {1, 2, 3, 4, 5, 6, 7, 8},
      );
      expect((await repository.identityStatus()).bundleVersion, 8);
    },
  );

  test(
    'protected counter prevents reuse after registry database loss',
    () async {
      await repository.initializeIdentity();
      final fingerprint = (await repository.identityStatus()).fingerprint;
      await repository.buildTrustBundleJson([]);
      await repository.buildTrustBundleJson([]);
      await database.close();
      await File('${directory.path}/registry.sqlite').delete();
      database = await openDesktopAdminRegistryDatabase(
        '${directory.path}/registry.sqlite',
      );
      repository = DesktopAdminRegistryRepository(
        database: database,
        keyStore: keys,
      );
      expect((await repository.identityStatus()).hasIdentity, isFalse);
      await repository.initializeIdentity();
      expect((await repository.identityStatus()).fingerprint, fingerprint);
      expect(
        (jsonDecode(await repository.buildTrustBundleJson([]))
            as Map)['bundle_version'],
        3,
      );
    },
  );

  test(
    'independent SQLite handles serialize protected reservations for one registry',
    () async {
      await repository.initializeIdentity();
      final secondDatabase = await databaseFactoryFfi.openDatabase(
        '${directory.path}/registry.sqlite',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final yieldingKeys = YieldingSigningKeyStore(keys);
      final first = DesktopAdminRegistryRepository(
        database: database,
        keyStore: yieldingKeys,
      );
      final second = DesktopAdminRegistryRepository(
        database: secondDatabase,
        keyStore: yieldingKeys,
      );
      try {
        final results = await Future.wait(
          List.generate(
            4,
            (index) => (index.isEven ? first : second).buildTrustBundleJson([]),
          ),
        );
        expect(
          results
              .map((source) => (jsonDecode(source) as Map)['bundle_version'])
              .toSet(),
          {1, 2, 3, 4},
        );
        expect(yieldingKeys.maximumReads, 1);
        expect((await repository.identityStatus()).bundleVersion, 4);
      } finally {
        await secondDatabase.close();
      }
    },
  );

  test(
    'explicit matching restore repairs malformed protected identity and retains database counter',
    () async {
      await repository.initializeIdentity();
      final originalFingerprint =
          (await repository.identityStatus()).fingerprint;
      final backup = await repository.createEncryptedBackup(password);
      await repository.buildTrustBundleJson([]);
      keys.value = '{broken-protected-identity';
      await expectLater(repository.initializeIdentity(), throwsStateError);
      await repository.restoreEncryptedBackup(backup, password);
      expect(
        (await repository.identityStatus()).fingerprint,
        originalFingerprint,
      );
      expect(
        (jsonDecode(await repository.buildTrustBundleJson([]))
            as Map)['bundle_version'],
        2,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'publisher waits for an existing Windows registry identity lock',
    () async {
      await repository.initializeIdentity();
      final guard = await File(
        '${directory.path}/registry.sqlite.identity.lock',
      ).open(mode: FileMode.append);
      await guard.lock(FileLock.exclusive);
      var finished = false;
      final publication = repository.buildTrustBundleJson([]).then((source) {
        finished = true;
        return source;
      });
      try {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(finished, isFalse);
      } finally {
        await guard.unlock();
        await guard.close();
        await publication;
      }
      expect(finished, isTrue);
    },
    skip: !Platform.isWindows,
  );

  test(
    'malformed protected blob does not permit restoring a different bound administrator',
    () async {
      await repository.initializeIdentity();
      final backup = await repository.createEncryptedBackup(password);
      final destination = await openDesktopAdminRegistryDatabase(
        '${directory.path}/malformed-other.sqlite',
      );
      final destinationKeys = MemorySigningKeyStore();
      final other = DesktopAdminRegistryRepository(
        database: destination,
        keyStore: destinationKeys,
      );
      try {
        await other.initializeIdentity();
        final before = await destination.query('admin_identity');
        destinationKeys.value = '{broken-protected-identity';
        await expectLater(
          other.restoreEncryptedBackup(backup, password),
          throwsStateError,
        );
        expect(destinationKeys.value, '{broken-protected-identity');
        expect(await destination.query('admin_identity'), before);
        expect(await other.loadDevices(), isEmpty);
      } finally {
        await destination.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'failed protected reservation cannot publish and later retry remains monotonic',
    () async {
      await repository.initializeIdentity();
      await repository.buildTrustBundleJson([]);
      keys.failWrites = true;
      await expectLater(repository.buildTrustBundleJson([]), throwsStateError);
      keys.failWrites = false;
      expect(
        (jsonDecode(await repository.buildTrustBundleJson([]))
            as Map)['bundle_version'],
        greaterThan(1),
      );
    },
  );

  test(
    'failed database reservation keeps protected counter for recovery',
    () async {
      await repository.initializeIdentity();
      await database.execute(
        "CREATE TRIGGER synthetic_fail_update BEFORE UPDATE ON admin_identity BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
      await expectLater(
        repository.buildTrustBundleJson([]),
        throwsA(isA<DatabaseException>()),
      );
      await database.execute('DROP TRIGGER synthetic_fail_update');
      expect(
        (jsonDecode(await repository.buildTrustBundleJson([]))
            as Map)['bundle_version'],
        2,
      );
    },
  );

  test(
    'backup restores registry, key and next version without plaintext identity',
    () async {
      await repository.initializeIdentity();
      await repository.saveDevices([device()]);
      await repository.buildTrustBundleJson([device()]);
      final status = await repository.identityStatus();
      final backup = await repository.createEncryptedBackup(password);
      expect(backup, isNot(contains('Synthetic responder')));
      expect(
        backup,
        isNot(contains((jsonDecode(keys.value!) as Map)['private_key'])),
      );
      final destination = await openDesktopAdminRegistryDatabase(
        '${directory.path}/restore.sqlite',
      );
      try {
        final restored = DesktopAdminRegistryRepository(
          database: destination,
          keyStore: MemorySigningKeyStore(),
        );
        await restored.restoreEncryptedBackup(backup, password);
        expect(
          (await restored.identityStatus()).fingerprint,
          status.fingerprint,
        );
        expect(
          (await restored.loadDevices()).single.deviceId,
          'synthetic-phone',
        );
        final verified = await TrustBundleStore().importBundleJson(
          await restored.buildTrustBundleJson(await restored.loadDevices()),
        );
        expect(verified.bundleVersion, 2);
      } finally {
        await destination.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'wrong password and tamper leave empty destination and protected store untouched',
    () async {
      await repository.initializeIdentity();
      final backup = await repository.createEncryptedBackup(password);
      final targetDb = await openDesktopAdminRegistryDatabase(
        '${directory.path}/bad.sqlite',
      );
      final targetKeys = MemorySigningKeyStore();
      final target = DesktopAdminRegistryRepository(
        database: targetDb,
        keyStore: targetKeys,
      );
      try {
        await expectLater(
          target.restoreEncryptedBackup(backup, 'wrong-password-value'),
          throwsFormatException,
        );
        final decoded = jsonDecode(backup) as Map<String, dynamic>;
        final bytes = base64Url.decode(decoded['ciphertext'] as String);
        bytes[0] ^= 1;
        decoded['ciphertext'] = base64UrlEncode(bytes);
        await expectLater(
          target.restoreEncryptedBackup(jsonEncode(decoded), password),
          throwsFormatException,
        );
        expect(targetKeys.value, isNull);
        expect((await target.identityStatus()).hasIdentity, isFalse);
        expect(await target.loadDevices(), isEmpty);
      } finally {
        await targetDb.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'restore refuses populated registry and different protected issuer',
    () async {
      await repository.initializeIdentity();
      final backup = await repository.createEncryptedBackup(password);
      await repository.saveDevices([device()]);
      await expectLater(
        repository.restoreEncryptedBackup(backup, password),
        throwsStateError,
      );
      final destination = await openDesktopAdminRegistryDatabase(
        '${directory.path}/conflict.sqlite',
      );
      try {
        final otherKeys = MemorySigningKeyStore();
        final other = DesktopAdminRegistryRepository(
          database: destination,
          keyStore: otherKeys,
        );
        await other.initializeIdentity();
        final before = otherKeys.value;
        await expectLater(
          other.restoreEncryptedBackup(backup, password),
          throwsStateError,
        );
        expect(otherKeys.value, before);
      } finally {
        await destination.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'restoring an older matching backup retains higher counter',
    () async {
      await repository.initializeIdentity();
      await repository.buildTrustBundleJson([]);
      final backup = await repository.createEncryptedBackup(password);
      await repository.buildTrustBundleJson([]);
      // Simulate an older database surviving beside the newer protected key.
      await database.update('admin_identity', {
        'bundle_version': 0,
      }, where: 'id = 1');
      await repository.restoreEncryptedBackup(backup, password);
      expect(
        (jsonDecode(await repository.buildTrustBundleJson([]))
            as Map)['bundle_version'],
        3,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'authenticated backup rejects mismatched keypair and malformed records before live writes',
    () async {
      await repository.initializeIdentity();
      final identity = jsonDecode(keys.value!) as Map<String, dynamic>;
      final payload = <String, Object?>{
        'version': 1,
        'identity': {
          ...identity,
          'public_key': base64UrlEncode(List.filled(32, 9)),
        },
        'fingerprint': (await repository.identityStatus()).fingerprint,
        'bundle_version': 0,
        'devices': [device().toJson()],
      };
      final destination = await openDesktopAdminRegistryDatabase(
        '${directory.path}/invalid.sqlite',
      );
      final destinationKeys = MemorySigningKeyStore();
      final target = DesktopAdminRegistryRepository(
        database: destination,
        keyStore: destinationKeys,
      );
      try {
        await expectLater(
          target.restoreEncryptedBackup(
            await AdminRegistryBackup.encrypt(payload, password),
            password,
          ),
          throwsFormatException,
        );
        payload['identity'] = identity;
        payload['devices'] = [
          {...device().toJson(), 'role': 'invented-role'},
        ];
        await expectLater(
          target.restoreEncryptedBackup(
            await AdminRegistryBackup.encrypt(payload, password),
            password,
          ),
          throwsFormatException,
        );
        expect(destinationKeys.value, isNull);
        expect(await target.loadDevices(), isEmpty);
        expect((await target.identityStatus()).hasIdentity, isFalse);
      } finally {
        await destination.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'restore transaction failure leaves a matching protected identity and can retry',
    () async {
      await repository.initializeIdentity();
      await repository.saveDevices([device()]);
      await repository.buildTrustBundleJson([device()]);
      final backup = await repository.createEncryptedBackup(password);
      final destination = await openDesktopAdminRegistryDatabase(
        '${directory.path}/retry.sqlite',
      );
      final destinationKeys = MemorySigningKeyStore();
      final target = DesktopAdminRegistryRepository(
        database: destination,
        keyStore: destinationKeys,
      );
      try {
        await destination.execute(
          "CREATE TRIGGER synthetic_fail_insert BEFORE INSERT ON admin_devices BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
        );
        await expectLater(
          target.restoreEncryptedBackup(backup, password),
          throwsA(isA<DatabaseException>()),
        );
        expect(destinationKeys.value, isNotNull);
        expect((await target.identityStatus()).hasIdentity, isFalse);
        expect(await target.loadDevices(), isEmpty);
        await destination.execute('DROP TRIGGER synthetic_fail_insert');
        await target.restoreEncryptedBackup(backup, password);
        expect((await target.loadDevices()).single.deviceId, 'synthetic-phone');
        expect(
          (jsonDecode(
                await target.buildTrustBundleJson(await target.loadDevices()),
              )
              as Map)['bundle_version'],
          2,
        );
      } finally {
        await destination.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'bounds and invalid registry records are rejected before mutations',
    () async {
      await repository.initializeIdentity();
      await expectLater(
        repository.createEncryptedBackup('short'),
        throwsFormatException,
      );
      await expectLater(
        repository.createEncryptedBackup('x' * 1025),
        throwsFormatException,
      );
      await expectLater(
        repository.restoreEncryptedBackup('{"iterations":999999999}', password),
        throwsFormatException,
      );
      await expectLater(
        repository.saveDevices([device(), device()]),
        throwsFormatException,
      );
      await expectLater(
        repository.saveDevices([device().copyWith(publicKey: 'invalid')]),
        throwsFormatException,
      );
      expect(await repository.loadDevices(), isEmpty);
    },
  );
}

RegisteredDevice device() => RegisteredDevice(
  deviceId: 'synthetic-phone',
  ownerName: 'Synthetic responder',
  role: RegisteredDeviceRole.responder,
  status: RegisteredDeviceStatus.approved,
  registeredAt: DateTime.utc(2026, 10, 27),
  updatedAt: DateTime.utc(2026, 10, 27),
  lastSeenLabel: 'Synthetic',
  publicKey: base64UrlEncode(List.filled(32, 1)),
  signingPublicKey: base64UrlEncode(List.filled(32, 2)),
);
