import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/approval_receipt.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

import 'support/signed_trust_bundle_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SignedApprovalReceipt verifies and ApprovalQrPackage stores receipt for matching phone', () async {
    SharedPreferences.setMockInitialValues({});
    final secrets = InMemorySecretValueStore();
    final crypto = await DeviceIdentityStore(secretStore: secrets).loadOrCreate();
    final signing = await DeviceSigningIdentityStore(secretStore: secrets).loadOrCreate();
    final signer = await TestTrustBundleSigner.create();
    final now = DateTime.now().toUtc();

    final bundleJson = await signer.sign(
      bundleVersion: 3,
      issuedAt: now,
      directoryProject: 'dnsc-pilot',
      approvedDevices: [
        TrustedDevice(
          deviceId: 'phone-1',
          ownerName: 'Juan Dela Cruz',
          role: 'civilian',
          status: 'approved',
          publicKey: crypto.encodedPublicKey,
          signingPublicKey: signing.encodedPublicKey,
          keyVersion: crypto.keyVersion,
          updatedAt: now,
        ),
      ],
    );
    final bundle = TrustBundle.fromJsonString(bundleJson);
    final receipt = await SignedApprovalReceipt.createSigned(
      registrationId: 'reg-001122334455',
      deviceId: 'phone-1',
      publicKey: crypto.encodedPublicKey,
      signingPublicKey: signing.encodedPublicKey,
      keyVersion: crypto.keyVersion,
      issuer: bundle.issuer!,
      issuerKeyPair: signer.keyPair as SimpleKeyPair,
      issuedAt: now,
      expiresAt: now.add(const Duration(days: 30)),
      directoryProject: 'dnsc-pilot',
    );
    final pkg = ApprovalQrPackage(bundleJson: bundleJson, receipt: receipt);

    final store = TrustBundleStore();
    final imported = await store.importApprovalPayload(
      pkg.toJsonString(),
      directoryProject: 'dnsc-pilot',
      issuerFingerprint: sha256.convert(signer.publicKeyBytes).toString(),
      localDeviceId: 'phone-1',
      localPublicKey: crypto.encodedPublicKey,
      localSigningPublicKey: signing.encodedPublicKey,
      localKeyVersion: crypto.keyVersion,
    );
    expect(imported.receipt?.registrationId, 'reg-001122334455');
    expect((await store.loadReceipt())?.registrationId, 'reg-001122334455');

    // Wrong project is rejected.
    await expectLater(
      receipt.verify(expectedProject: 'other-project'),
      throwsFormatException,
    );
  });

  test('AccountLinkProof verifies exact phone keys and rejects tampering or wrong account', () async {
    final secrets = InMemorySecretValueStore();
    final crypto = await DeviceIdentityStore(secretStore: secrets).loadOrCreate();
    final signing = await DeviceSigningIdentityStore(secretStore: secrets).loadOrCreate();
    final proof = await AccountLinkProof.createSigned(
      registrationId: 'reg-abc',
      accountUid: 'uid-alice',
      nonce: 'nonce-123',
      deviceId: 'phone-a',
      identity: crypto,
      signingIdentity: signing,
      directoryProject: 'dnsc-pilot',
    );

    await proof.verify(
      expectedRegistrationId: 'reg-abc',
      expectedAccountUid: 'uid-alice',
      expectedDeviceId: 'phone-a',
      expectedPublicKey: crypto.encodedPublicKey,
      expectedSigningPublicKey: signing.encodedPublicKey,
      expectedKeyVersion: crypto.keyVersion,
      expectedProject: 'dnsc-pilot',
    );

    await expectLater(
      proof.verify(
        expectedRegistrationId: 'reg-abc',
        expectedAccountUid: 'uid-bob',
        expectedDeviceId: 'phone-a',
        expectedPublicKey: crypto.encodedPublicKey,
        expectedSigningPublicKey: signing.encodedPublicKey,
        expectedKeyVersion: crypto.keyVersion,
      ),
      throwsFormatException,
    );
  });
}
