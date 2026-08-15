import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';

import 'support/signed_trust_bundle_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('imports and persists a valid trust bundle', () async {
    final store = TrustBundleStore();
    final signer = await TestTrustBundleSigner.create();
    final source = await signer.sign(
      bundleVersion: 1,
      issuedAt: DateTime.utc(2026, 8, 15),
      approvedDevices: [testTrustedDevice()],
      revokedDevices: [
        testTrustedDevice(
          deviceId: 'SN-LOST-001',
          ownerName: 'Lost Phone',
          role: 'civilian',
          status: 'revoked',
        ),
      ],
    );

    final imported = await store.importBundleJson(
      source,
      now: DateTime.utc(2026, 8, 15, 1),
    );
    final loaded = await store.loadBundle();

    expect(imported.approvedCount, 1);
    expect(imported.revokedCount, 1);
    expect(imported.isSignatureVerified, isTrue);
    expect(imported.bundleVersion, 1);
    expect(loaded?.approvedDevices.single.deviceId, 'SN-RESPONDER-010');
    expect(loaded?.revokedDevices.single.deviceId, 'SN-LOST-001');
    expect(loaded?.isSignatureVerified, isTrue);
  });

  test('rejects unsupported bundle types', () async {
    final store = TrustBundleStore();

    expect(
      () => store.importBundleJson('{"bundle_type":"wrong"}'),
      throwsFormatException,
    );
  });

  test('clears an imported trust bundle', () async {
    final store = TrustBundleStore();
    final signer = await TestTrustBundleSigner.create();
    final source = await signer.sign(
      bundleVersion: 1,
      issuedAt: DateTime.utc(2026, 8, 15),
    );

    await store.importBundleJson(source, now: DateTime.utc(2026, 8, 15, 1));
    await store.clearBundle();

    expect(await store.loadBundle(), isNull);
    expect(await store.hasPinnedIssuer(), isTrue);
  });

  test('rejects unsigned legacy bundles', () async {
    final store = TrustBundleStore();

    expect(
      () => store.importBundleJson(
        '{"bundle_type":"shadow_network_device_trust_bundle","schema_version":1}',
      ),
      throwsFormatException,
    );
  });

  test('rejects tampering and keeps the last valid bundle', () async {
    final store = TrustBundleStore();
    final signer = await TestTrustBundleSigner.create();
    final source = await signer.sign(
      bundleVersion: 1,
      issuedAt: DateTime.utc(2026, 8, 15),
      approvedDevices: [testTrustedDevice()],
    );
    await store.importBundleJson(source, now: DateTime.utc(2026, 8, 15, 1));

    final tampered = jsonDecode(source) as Map<String, Object?>;
    final approved = (tampered['approved_devices'] as List).single as Map;
    approved['owner_name'] = 'Tampered Owner';

    await expectLater(
      store.importBundleJson(
        jsonEncode(tampered),
        now: DateTime.utc(2026, 8, 15, 2),
      ),
      throwsFormatException,
    );
    final retained = await store.loadBundle();
    expect(retained?.approvedDevices.single.ownerName, 'Responder Phone');
    expect(retained?.bundleVersion, 1);
  });

  test('rejects rollback to an older signed bundle', () async {
    final store = TrustBundleStore();
    final signer = await TestTrustBundleSigner.create();
    final versionTwo = await signer.sign(
      bundleVersion: 2,
      issuedAt: DateTime.utc(2026, 8, 15),
    );
    final versionOne = await signer.sign(
      bundleVersion: 1,
      issuedAt: DateTime.utc(2026, 8, 15),
    );
    await store.importBundleJson(versionTwo, now: DateTime.utc(2026, 8, 15, 1));

    await expectLater(
      store.importBundleJson(versionOne, now: DateTime.utc(2026, 8, 15, 2)),
      throwsFormatException,
    );
    expect((await store.loadBundle())?.bundleVersion, 2);
  });

  test('rejects a different administrator after issuer pinning', () async {
    final store = TrustBundleStore();
    final firstSigner = await TestTrustBundleSigner.create();
    final otherSigner = await TestTrustBundleSigner.create();
    await store.importBundleJson(
      await firstSigner.sign(
        bundleVersion: 1,
        issuedAt: DateTime.utc(2026, 8, 15),
      ),
      now: DateTime.utc(2026, 8, 15, 1),
    );

    await expectLater(
      store.importBundleJson(
        await otherSigner.sign(
          bundleVersion: 2,
          issuedAt: DateTime.utc(2026, 8, 15),
        ),
        now: DateTime.utc(2026, 8, 15, 2),
      ),
      throwsFormatException,
    );
  });
}
