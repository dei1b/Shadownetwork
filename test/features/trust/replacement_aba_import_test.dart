import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/domain/services/device_access_resolver.dart';
import 'package:sqflite/sqflite.dart';

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
    dir = await Directory.systemTemp.createTemp('aba-import-test-');
    db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
    repo = DesktopAdminRegistryRepository(database: db, keyStore: _MemKeys());
    await repo.initializeIdentity();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
    'R1: hosted A -> B -> A replacement bundles remain disjoint and import cleanly through TrustBundleStore',
    () async {
      final secretsA = InMemorySecretValueStore();
      final cryptoA = await DeviceIdentityStore(
        secretStore: secretsA,
      ).loadOrCreate();
      final signingA = await DeviceSigningIdentityStore(
        secretStore: secretsA,
      ).loadOrCreate();
      final qrA = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-aba-dart-a',
        identity: cryptoA,
        signingIdentity: signingA,
      );

      final secretsB = InMemorySecretValueStore();
      final cryptoB = await DeviceIdentityStore(
        secretStore: secretsB,
      ).loadOrCreate();
      final signingB = await DeviceSigningIdentityStore(
        secretStore: secretsB,
      ).loadOrCreate();
      final qrB = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-aba-dart-b',
        identity: cryptoB,
        signingIdentity: signingB,
      );

      final secretsOther = InMemorySecretValueStore();
      final cryptoOther = await DeviceIdentityStore(
        secretStore: secretsOther,
      ).loadOrCreate();
      final signingOther = await DeviceSigningIdentityStore(
        secretStore: secretsOther,
      ).loadOrCreate();
      final qrOther = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-aba-unrelated',
        identity: cryptoOther,
        signingIdentity: signingOther,
      );

      final delegationResult = await repo.createPublisherDelegation(
        directoryProject: 'dnsc-pilot',
      );
      final rootFingerprint = sha256
          .convert(base64Url.decode(delegationResult.delegation.rootIssuer.publicKey))
          .toString();

      final script = '''
import { applyDecisionAndBuildCommit } from './api/_lib/publisher_core.mjs';
const input = JSON.parse(process.argv[1]);
const now = new Date();
const v1 = applyDecisionAndBuildCommit({
  action: 'approve_online',
  decisionId: 'd1',
  reviewerUid: 'admin-1',
  directoryProject: 'dnsc-pilot',
  publisherSeed: input.seed,
  publisherDelegation: input.delegation,
  application: {
    uid: 'uid-other',
    affiliation: 'student',
    displayName: 'Unrelated Student',
    studentNumber: '2026-0001',
    course: 'BSIT',
    yearLevel: '1',
    sectionSet: 'A',
    status: 'submitted',
    revision: 0,
    deviceRegistration: input.qrOther,
  },
  payload: { registrationId: 'reg-other', role: 'civilian' },
  now,
});
const v2 = applyDecisionAndBuildCommit({
  action: 'approve_online',
  decisionId: 'd2',
  reviewerUid: 'admin-1',
  directoryProject: 'dnsc-pilot',
  publisherSeed: input.seed,
  publisherDelegation: input.delegation,
  existingDirectory: { version: 1, bundle: v1.bundle },
  application: {
    uid: 'uid-aba',
    affiliation: 'student',
    displayName: 'ABA Student',
    studentNumber: '2026-0002',
    course: 'BSIT',
    yearLevel: '2',
    sectionSet: 'B',
    status: 'submitted',
    revision: 0,
    deviceRegistration: input.qrA,
  },
  payload: { registrationId: 'reg-aba', role: 'civilian' },
  now,
});
const app2 = v2.writes.find((w) => w.collection === 'pilotApplications').fields;
const reg2 = v2.writes.find((w) => w.collection === 'campusRegistrations').fields;
const v3 = applyDecisionAndBuildCommit({
  action: 'approve_replacement',
  decisionId: 'd3',
  reviewerUid: 'admin-2',
  directoryProject: 'dnsc-pilot',
  publisherSeed: input.seed,
  publisherDelegation: input.delegation,
  existingDirectory: { version: 2, bundle: v2.bundle },
  application: { ...app2, replacementRequest: { status: 'submitted', deviceRegistration: input.qrB } },
  registration: reg2,
  payload: { registrationId: 'reg-aba', accountUid: 'uid-aba', role: 'civilian', reason: 'Switch to B' },
  now,
});
const app3 = v3.writes.find((w) => w.collection === 'pilotApplications').fields;
const reg3 = v3.writes.find((w) => w.collection === 'campusRegistrations').fields;
const v4 = applyDecisionAndBuildCommit({
  action: 'approve_replacement',
  decisionId: 'd4',
  reviewerUid: 'admin-1',
  directoryProject: 'dnsc-pilot',
  publisherSeed: input.seed,
  publisherDelegation: input.delegation,
  existingDirectory: { version: 3, bundle: v3.bundle },
  application: { ...app3, replacementRequest: { status: 'submitted', deviceRegistration: input.qrA } },
  registration: reg3,
  payload: { registrationId: 'reg-aba', accountUid: 'uid-aba', role: 'civilian', reason: 'Return to A' },
  now,
});
console.log(JSON.stringify([v1.bundle, v2.bundle, v3.bundle, v4.bundle]));
''';

      final result = await Process.run('node', [
        '--input-type=module',
        '-e',
        script,
        jsonEncode({
          'seed': delegationResult.publisherPrivateKeySeed,
          'delegation': delegationResult.delegation.toJson(),
          'qrOther': qrOther.toJsonString(),
          'qrA': qrA.toJsonString(),
          'qrB': qrB.toJsonString(),
        }),
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final bundles = (jsonDecode(result.stdout as String) as List).cast<String>();
      expect(bundles, hasLength(4));

      final importerA = TrustBundleStore();
      const resolver = DeviceAccessResolver();
      for (final rawBundle in bundles) {
        await importerA.importBundleJson(
          rawBundle,
          directoryProject: 'dnsc-pilot',
          issuerFingerprint: rootFingerprint,
        );
      }

      final latestBundle = await importerA.loadBundle();
      expect(latestBundle, isNotNull);
      expect(latestBundle!.bundleVersion, 4);
      expect(
        latestBundle.approvedDevices.where(
          (d) => d.ownerName == 'ABA Student',
        ),
        hasLength(1),
      );
      expect(
        latestBundle.revokedDevices.map((d) => d.deviceId),
        contains('phone-aba-dart-b'),
      );
      expect(
        latestBundle.revokedDevices.map((d) => d.deviceId),
        isNot(contains('phone-aba-dart-a')),
      );

      final accessA = resolver.resolve(
        deviceId: 'phone-aba-dart-a',
        publicKey: cryptoA.encodedPublicKey,
        signingPublicKey: signingA.encodedPublicKey,
        keyVersion: cryptoA.keyVersion,
        bundle: latestBundle,
      );
      expect(accessA.level, DeviceAccessLevel.civilian);
      expect(accessA.isApproved, isTrue);

      final accessB = resolver.resolve(
        deviceId: 'phone-aba-dart-b',
        publicKey: cryptoB.encodedPublicKey,
        signingPublicKey: signingB.encodedPublicKey,
        keyVersion: cryptoB.keyVersion,
        bundle: latestBundle,
      );
      expect(accessB.level, DeviceAccessLevel.revoked);
      expect(accessB.isApproved, isFalse);

      final accessOther = resolver.resolve(
        deviceId: 'phone-aba-unrelated',
        publicKey: cryptoOther.encodedPublicKey,
        signingPublicKey: signingOther.encodedPublicKey,
        keyVersion: cryptoOther.keyVersion,
        bundle: latestBundle,
      );
      expect(accessOther.isApproved, isTrue);
    },
  );
}
