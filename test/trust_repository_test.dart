import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/data/datasources/local_messaging_database.dart';
import 'package:shadownetwork/features/trust/data/repositories/sqlite_trust_repository.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_trust_status.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/signed_trust_bundle_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('persists verified trust records and bundle metadata', () async {
    final database = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(database.close);
    final repository = SqliteTrustRepository(database: database);
    final issuedAt = DateTime.utc(2026, 8, 15);
    final parsed =
        TrustBundle(
          schemaVersion: 2,
          bundleVersion: 7,
          generatedAt: issuedAt,
          issuedAt: issuedAt,
          expiresAt: DateTime.utc(2030, 8, 15),
          issuer: const TrustBundleIssuer(
            issuerId: 'test-admin',
            signingKeyId: 'test-key',
            signatureAlgorithm: 'ed25519',
            publicKey: 'test-public-key',
          ),
          approvedDevices: [testTrustedDevice()],
          revokedDevices: [
            testTrustedDevice(
              deviceId: 'SN-REVOKED-001',
              ownerName: 'Revoked Phone',
              role: 'civilian',
              status: 'revoked',
            ),
          ],
          signature: 'test-signature',
        ).withVerifiedImport(
          importedAt: DateTime.utc(2026, 8, 15, 1),
          bundleHash: 'verified-bundle-hash',
        );

    await repository.replaceFromBundle(parsed);

    final approved = await repository.getDevice('sn-responder-010');
    final revoked = await repository.getDevice('SN-REVOKED-001');
    final unknown = await repository.getDevice('SN-UNKNOWN-001');
    final metadata = await repository.getMetadata();

    expect(approved.status, DeviceTrustStatus.approved);
    expect(approved.ownerName, 'Responder Phone');
    expect(revoked.status, DeviceTrustStatus.revoked);
    expect(unknown.status, DeviceTrustStatus.unknown);
    expect(metadata?.bundleVersion, 7);
    expect(metadata?.bundleHash, 'verified-bundle-hash');
    expect(metadata?.signatureVerified, isTrue);
  });

  test('rejects an unverified trust bundle', () async {
    final database = await LocalMessagingDatabase.open(
      databasePath: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    addTearDown(database.close);
    final repository = SqliteTrustRepository(database: database);
    final issuedAt = DateTime.utc(2026, 8, 15);

    expect(
      () => repository.replaceFromBundle(
        TrustBundle(
          schemaVersion: 2,
          bundleVersion: 1,
          generatedAt: issuedAt,
          issuedAt: issuedAt,
          expiresAt: DateTime.utc(2030, 8, 15),
          issuer: const TrustBundleIssuer(
            issuerId: 'test-admin',
            signingKeyId: 'test-key',
            signatureAlgorithm: 'ed25519',
            publicKey: 'test-public-key',
          ),
          approvedDevices: const [],
          revokedDevices: const [],
        ),
      ),
      throwsFormatException,
    );
  });
}
