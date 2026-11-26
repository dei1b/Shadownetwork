import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/approval_receipt.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/domain/entities/publisher_delegation.dart';
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

  late Directory dir;
  late Database db;
  late DesktopAdminRegistryRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('offline-receipt-scope-');
    db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
    repo = DesktopAdminRegistryRepository(database: db, keyStore: _MemKeys());
    await repo.initializeIdentity();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  CampusRegistration makeSubmission(
    String deviceId,
    String pubKey,
    String sigKey,
  ) => CampusRegistration(
    registrationId: 'reg-$deviceId',
    source: CampusRegistrationSource.qr,
    status: CampusRegistrationStatus.submitted,
    syncState: CampusSyncState.waitingToSync,
    identity: const CampusIdentityFields(
      affiliation: CampusAffiliation.student,
      displayName: 'Walkin Student',
      studentNumber: '2026-4401',
      course: 'BSIT',
      yearLevel: '3',
      sectionSet: 'A',
    ),
    role: RegisteredDeviceRole.civilian,
    activePhone: RegistrationPhoneBinding(
      deviceId: deviceId,
      publicKey: pubKey,
      signingPublicKey: sigKey,
      keyVersion: 1,
    ),
    createdAt: DateTime.utc(2026, 11, 26),
    updatedAt: DateTime.utc(2026, 11, 26),
  );

  Future<String> signBundle({
    required TrustBundleIssuer publisher,
    required SimpleKeyPair publisherKeyPair,
    required PublisherDelegation delegation,
    required int version,
    required DateTime issuedAt,
    required DateTime expiresAt,
  }) async {
    final unsigned = TrustBundle(
      schemaVersion: 2,
      bundleVersion: version,
      generatedAt: issuedAt,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      issuer: publisher,
      publisherDelegation: delegation,
      directoryProject: 'dnsc-pilot',
      approvedDevices: const [],
      revokedDevices: const [],
    );
    final sig = await Ed25519().sign(
      utf8.encode(canonicalJsonEncode(unsigned.toJson(includeSignature: false))),
      keyPair: publisherKeyPair,
    );
    return jsonEncode({
      ...unsigned.toJson(includeSignature: false),
      'signature': base64UrlEncode(sig.bytes),
    });
  }

  test('empty roster cache emits receipt-only package without incrementing global bundle version and activates phone', () async {
    final secrets = InMemorySecretValueStore();
    final crypto = await DeviceIdentityStore(secretStore: secrets).loadOrCreate();
    final signing = await DeviceSigningIdentityStore(secretStore: secrets).loadOrCreate();
    const reviewer = ReviewerProfile(uid: 'admin-1', email: 'admin@dnsc.edu.ph');

    final res = await repo.approveOfflineRegistration(
      registration: makeSubmission(
        'phone-empty-cache',
        crypto.encodedPublicKey,
        signing.encodedPublicKey,
      ),
      reviewer: reviewer,
      role: RegisteredDeviceRole.civilian,
      reviewedIdentity: makeSubmission('x', 'y', 'z').identity,
      directoryProject: 'dnsc-pilot',
    );

    expect(res.bundleJson, isEmpty);
    expect(res.receipt.baseBundleVersion, 0);
    expect((await repo.identityStatus()).bundleVersion, 0);

    final store = TrustBundleStore();
    final rootFingerprint = sha256
        .convert(base64Url.decode(res.receipt.issuer.publicKey))
        .toString();
    final imported = await store.importApprovalPayload(
      res.packageJson,
      directoryProject: 'dnsc-pilot',
      issuerFingerprint: rootFingerprint,
      localDeviceId: 'phone-empty-cache',
      localPublicKey: crypto.encodedPublicKey,
      localSigningPublicKey: signing.encodedPublicKey,
      localKeyVersion: crypto.keyVersion,
    );
    expect(imported.bundle, isNull);
    expect(imported.receipt?.isSignatureVerified, isTrue);

    final access = const DeviceAccessResolver().resolve(
      deviceId: 'phone-empty-cache',
      publicKey: crypto.encodedPublicKey,
      keyVersion: crypto.keyVersion,
      signingPublicKey: signing.encodedPublicKey,
      bundle: await store.loadBundle(),
      receipt: await store.loadVerifiedReceipt(expectedProject: 'dnsc-pilot'),
    );
    expect(access.level, DeviceAccessLevel.civilian);
    expect(access.ownerName, 'Walkin Student');
  });

  test('expired cached roster or expired delegation is omitted in favor of receipt-only QR', () async {
    final delegationResult = await repo.createPublisherDelegation(
      directoryProject: 'dnsc-pilot',
    );
    final delegation = delegationResult.delegation;
    final pubKeyPair = await Ed25519().newKeyPairFromSeed(
      base64Url.decode(delegationResult.publisherPrivateKeySeed),
    );
    final pastIssued = DateTime.now().toUtc().subtract(const Duration(days: 60));
    final pastExpired = DateTime.now().toUtc().subtract(const Duration(days: 1));
    final expiredBundleJson = await signBundle(
      publisher: delegation.publisher,
      publisherKeyPair: pubKeyPair,
      delegation: delegation,
      version: 9,
      issuedAt: pastIssued,
      expiresAt: pastExpired,
    );
    await db.insert('admin_published_roster', {
      'id': 1,
      'version': 9,
      'bundle_json': expiredBundleJson,
      'synced_at': pastIssued.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    final secrets = InMemorySecretValueStore();
    final crypto = await DeviceIdentityStore(secretStore: secrets).loadOrCreate();
    final signing = await DeviceSigningIdentityStore(secretStore: secrets).loadOrCreate();
    const reviewer = ReviewerProfile(uid: 'admin-1', email: 'admin@dnsc.edu.ph');

    final res = await repo.approveOfflineRegistration(
      registration: makeSubmission(
        'phone-expired-cache',
        crypto.encodedPublicKey,
        signing.encodedPublicKey,
      ),
      reviewer: reviewer,
      role: RegisteredDeviceRole.responder,
      reviewedIdentity: makeSubmission('x', 'y', 'z').identity,
      directoryProject: 'dnsc-pilot',
    );
    expect(res.bundleJson, isEmpty);
    expect(res.receipt.baseBundleVersion, 0);

    // Even if an external package combines an expired roster with a valid root-signed receipt,
    // Android keeps only the valid root-signed receipt and rejects alien-root expired bundles.
    final rootFingerprint = sha256
        .convert(base64Url.decode(res.receipt.issuer.publicKey))
        .toString();
    final combinedPkg = ApprovalQrPackage(
      bundleJson: expiredBundleJson,
      receipt: res.receipt,
    ).toJsonString();
    final store = TrustBundleStore();
    final imported = await store.importApprovalPayload(
      combinedPkg,
      directoryProject: 'dnsc-pilot',
      issuerFingerprint: rootFingerprint,
      localDeviceId: 'phone-expired-cache',
      localPublicKey: crypto.encodedPublicKey,
      localSigningPublicKey: signing.encodedPublicKey,
      localKeyVersion: crypto.keyVersion,
    );
    expect(imported.bundle, isNull);
    expect(imported.receipt?.isSignatureVerified, isTrue);

    // Now test expired delegation inside an unexpired bundle.
    final expiredDelegationResult = await repo.createPublisherDelegation(
      directoryProject: 'dnsc-pilot',
      validity: const Duration(milliseconds: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final unexpiredBundleWithExpiredDel = await signBundle(
      publisher: expiredDelegationResult.delegation.publisher,
      publisherKeyPair: await Ed25519().newKeyPairFromSeed(
        base64Url.decode(expiredDelegationResult.publisherPrivateKeySeed),
      ),
      delegation: expiredDelegationResult.delegation,
      version: 10,
      issuedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
    );
    await db.insert('admin_published_roster', {
      'id': 1,
      'version': 10,
      'bundle_json': unexpiredBundleWithExpiredDel,
      'synced_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    final resDel = await repo.approveOfflineRegistration(
      registration: makeSubmission(
        'phone-expired-del',
        crypto.encodedPublicKey,
        signing.encodedPublicKey,
      ),
      reviewer: reviewer,
      role: RegisteredDeviceRole.responder,
      reviewedIdentity: makeSubmission('x', 'y', 'z').identity,
      directoryProject: 'dnsc-pilot',
    );
    expect(resDel.bundleJson, isEmpty);
  });
}
