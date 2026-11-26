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
import 'package:shadownetwork/features/trust/domain/entities/publisher_delegation.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
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
    dir = await Directory.systemTemp.createTemp('delegation-test-');
    db = await openDesktopAdminRegistryDatabase('${dir.path}/admin.sqlite');
    repo = DesktopAdminRegistryRepository(database: db, keyStore: _MemKeys());
    await repo.initializeIdentity();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<String> signWithDelegatedPublisher({
    required TrustBundleIssuer publisherIssuer,
    required SimpleKeyPair publisherKeyPair,
    required PublisherDelegation delegation,
    required int version,
    required List<TrustedDevice> approved,
    List<TrustedDevice> revoked = const [],
    String? project = 'dnsc-pilot',
    DateTime? issuedAt,
  }) async {
    final now = (issuedAt ?? DateTime.now()).toUtc();
    final unsigned = TrustBundle(
      schemaVersion: 2,
      bundleVersion: version,
      generatedAt: now,
      issuedAt: now,
      expiresAt: now.add(const Duration(days: 30)),
      issuer: publisherIssuer,
      publisherDelegation: delegation,
      directoryProject: project,
      approvedDevices: approved,
      revokedDevices: revoked,
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

  test('phone pinned to campus root accepts delegated publisher bundle and repository reconciliation saves roster', () async {
    final secrets = InMemorySecretValueStore();
    final crypto = await DeviceIdentityStore(secretStore: secrets).loadOrCreate();
    final signing = await DeviceSigningIdentityStore(secretStore: secrets).loadOrCreate();

    final delegationResult = await repo.createPublisherDelegation(
      directoryProject: 'dnsc-pilot',
    );
    final delegation = delegationResult.delegation;
    final rootFingerprint = sha256
        .convert(base64Url.decode(delegation.rootIssuer.publicKey))
        .toString();

    final seedBytes = base64Url.decode(delegationResult.publisherPrivateKeySeed);
    final pubKeyPair = await Ed25519().newKeyPairFromSeed(seedBytes);
    final bundleJson = await signWithDelegatedPublisher(
      publisherIssuer: delegation.publisher,
      publisherKeyPair: pubKeyPair,
      delegation: delegation,
      version: 5,
      approved: [
        TrustedDevice(
          deviceId: 'phone-delegated-1',
          ownerName: 'Maria Responder',
          role: 'responder',
          status: 'approved',
          updatedAt: DateTime.now().toUtc(),
          publicKey: crypto.encodedPublicKey,
          signingPublicKey: signing.encodedPublicKey,
        ),
      ],
    );

    final store = TrustBundleStore();
    final imported = await store.importBundleJson(
      bundleJson,
      directoryProject: 'dnsc-pilot',
      issuerFingerprint: rootFingerprint,
    );
    expect(imported.isSignatureVerified, isTrue);
    expect(imported.bundleVersion, 5);
    expect(imported.rootAuthorityIssuer?.publicKey, delegation.rootIssuer.publicKey);

    await repo.saveLastPublishedRoster(imported, bundleJson);
    final cached = await repo.loadLastPublishedRoster();
    expect(cached?.version, 5);

    // Offline desk approval with a cached roster scopes receipt and avoids bumping global version.
    final beforeVersion = (await repo.identityStatus()).bundleVersion;
    final deskResult = await repo.approveOfflineRegistration(
      registration: CampusRegistration(
        registrationId: 'reg-walkin-2',
        source: CampusRegistrationSource.qr,
        status: CampusRegistrationStatus.submitted,
        syncState: CampusSyncState.waitingToSync,
        identity: const CampusIdentityFields(
          affiliation: CampusAffiliation.student,
          displayName: 'Juan Walkin',
          studentNumber: '2026-2222',
          course: 'BSIT',
          yearLevel: 'Year 2',
          sectionSet: 'Set B',
        ),
        role: RegisteredDeviceRole.civilian,
        activePhone: RegistrationPhoneBinding(
          deviceId: 'phone-walkin-2',
          publicKey: base64UrlEncode(List.filled(32, 7)),
          signingPublicKey: base64UrlEncode(List.filled(32, 8)),
        ),
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
      reviewer: const ReviewerProfile(uid: 'admin-1', email: 'admin@dnsc.edu.ph'),
      role: RegisteredDeviceRole.civilian,
      reviewedIdentity: const CampusIdentityFields(
        affiliation: CampusAffiliation.student,
        displayName: 'Juan Walkin',
        studentNumber: '2026-2222',
        course: 'BSIT',
        yearLevel: 'Year 2',
        sectionSet: 'Set B',
      ),
      directoryProject: 'dnsc-pilot',
    );
    expect((await repo.identityStatus()).bundleVersion, beforeVersion);
    expect(deskResult.receipt.baseBundleVersion, 5);
    expect(deskResult.receipt.role, 'civilian');
    expect(deskResult.bundleJson, bundleJson);
  });

  test('phone-scoped offline receipt grants access immediately and revocation overrides it', () async {
    final secrets = InMemorySecretValueStore();
    final crypto = await DeviceIdentityStore(secretStore: secrets).loadOrCreate();
    final signing = await DeviceSigningIdentityStore(secretStore: secrets).loadOrCreate();

    final delegationResult = await repo.createPublisherDelegation(
      directoryProject: 'dnsc-pilot',
    );
    final delegation = delegationResult.delegation;
    final rootFingerprint = sha256
        .convert(base64Url.decode(delegation.rootIssuer.publicKey))
        .toString();
    final seedBytes = base64Url.decode(delegationResult.publisherPrivateKeySeed);
    final pubKeyPair = await Ed25519().newKeyPairFromSeed(seedBytes);

    // Existing v3 roster published online before walk-in student arrived.
    final v3Json = await signWithDelegatedPublisher(
      publisherIssuer: delegation.publisher,
      publisherKeyPair: pubKeyPair,
      delegation: delegation,
      version: 3,
      approved: [
        TrustedDevice(
          deviceId: 'other-phone',
          ownerName: 'Other User',
          role: 'civilian',
          status: 'approved',
          updatedAt: DateTime.now().toUtc(),
          publicKey: base64UrlEncode(List.filled(32, 11)),
          signingPublicKey: base64UrlEncode(List.filled(32, 12)),
        ),
      ],
    );
    final store = TrustBundleStore();
    await repo.saveLastPublishedRoster(
      await store.importBundleJson(
        v3Json,
        directoryProject: 'dnsc-pilot',
        issuerFingerprint: rootFingerprint,
      ),
      v3Json,
    );

    // Simulate a second phone already at v4 importing an offline v3 + receipt package!
    final phoneStore = TrustBundleStore();
    SharedPreferences.setMockInitialValues({});
    final v4Json = await signWithDelegatedPublisher(
      publisherIssuer: delegation.publisher,
      publisherKeyPair: pubKeyPair,
      delegation: delegation,
      version: 4,
      approved: [
        TrustedDevice(
          deviceId: 'other-phone',
          ownerName: 'Other User',
          role: 'civilian',
          status: 'approved',
          updatedAt: DateTime.now().toUtc(),
          publicKey: base64UrlEncode(List.filled(32, 11)),
          signingPublicKey: base64UrlEncode(List.filled(32, 12)),
        ),
      ],
    );
    await phoneStore.importBundleJson(
      v4Json,
      directoryProject: 'dnsc-pilot',
      issuerFingerprint: rootFingerprint,
    );

    final offline = await repo.approveOfflineRegistration(
      registration: CampusRegistration(
        registrationId: 'reg-walkin-3',
        source: CampusRegistrationSource.qr,
        status: CampusRegistrationStatus.submitted,
        syncState: CampusSyncState.waitingToSync,
        identity: const CampusIdentityFields(
          affiliation: CampusAffiliation.staff,
          displayName: 'Liza Responder',
          employeeId: 'EMP-09',
          unit: 'Security',
        ),
        role: RegisteredDeviceRole.responder,
        activePhone: RegistrationPhoneBinding(
          deviceId: 'walkin-phone',
          publicKey: crypto.encodedPublicKey,
          signingPublicKey: signing.encodedPublicKey,
          keyVersion: crypto.keyVersion,
        ),
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
      reviewer: const ReviewerProfile(uid: 'admin-1', email: 'admin@dnsc.edu.ph'),
      role: RegisteredDeviceRole.responder,
      reviewedIdentity: const CampusIdentityFields(
        affiliation: CampusAffiliation.staff,
        displayName: 'Liza Responder',
        employeeId: 'EMP-09',
        unit: 'Security',
      ),
      directoryProject: 'dnsc-pilot',
    );

    final imported = await phoneStore.importApprovalPayload(
      offline.packageJson,
      directoryProject: 'dnsc-pilot',
      issuerFingerprint: rootFingerprint,
      localDeviceId: 'walkin-phone',
      localPublicKey: crypto.encodedPublicKey,
      localSigningPublicKey: signing.encodedPublicKey,
      localKeyVersion: crypto.keyVersion,
    );
    // Kept newer v4 roster AND verified scoped offline receipt!
    expect(imported.bundle?.bundleVersion, 4);
    expect(imported.receipt?.isSignatureVerified, isTrue);

    const resolver = DeviceAccessResolver();
    final activeProfile = resolver.resolve(
      deviceId: 'walkin-phone',
      publicKey: crypto.encodedPublicKey,
      keyVersion: crypto.keyVersion,
      signingPublicKey: signing.encodedPublicKey,
      bundle: await phoneStore.loadBundle(),
      receipt: await phoneStore.loadVerifiedReceipt(expectedProject: 'dnsc-pilot'),
    );
    expect(activeProfile.level, DeviceAccessLevel.responder);
    expect(activeProfile.ownerName, 'Liza Responder');

    // Newer v5 revocation on server must override the cached offline receipt.
    final v5Revoked = await signWithDelegatedPublisher(
      publisherIssuer: delegation.publisher,
      publisherKeyPair: pubKeyPair,
      delegation: delegation,
      version: 5,
      approved: const [],
      revoked: [
        TrustedDevice(
          deviceId: 'walkin-phone',
          ownerName: 'Liza Responder',
          role: 'responder',
          status: 'revoked',
          updatedAt: DateTime.now().toUtc(),
          publicKey: crypto.encodedPublicKey,
          signingPublicKey: signing.encodedPublicKey,
        ),
      ],
    );
    final updatedBundle = await phoneStore.importBundleJson(
      v5Revoked,
      directoryProject: 'dnsc-pilot',
      issuerFingerprint: rootFingerprint,
    );
    final revokedProfile = resolver.resolve(
      deviceId: 'walkin-phone',
      publicKey: crypto.encodedPublicKey,
      keyVersion: crypto.keyVersion,
      signingPublicKey: signing.encodedPublicKey,
      bundle: updatedBundle,
      receipt: await phoneStore.loadVerifiedReceipt(expectedProject: 'dnsc-pilot'),
    );
    expect(revokedProfile.level, DeviceAccessLevel.revoked);
  });
}
