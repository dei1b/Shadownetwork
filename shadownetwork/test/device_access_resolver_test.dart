import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/domain/services/device_access_resolver.dart';

void main() {
  const resolver = DeviceAccessResolver();
  const localDeviceId = 'local-device-001';
  const localPublicKey = 'local-public-key';
  final now = DateTime.utc(2026, 8, 15, 1);

  test('approved responder with matching key receives responder access', () {
    final profile = resolver.resolve(
      deviceId: localDeviceId,
      publicKey: localPublicKey,
      keyVersion: 1,
      bundle: _bundle(approved: [_device(role: 'responder')]),
      now: now,
    );

    expect(profile.level, DeviceAccessLevel.responder);
    expect(profile.canAccessResponderInterface, isTrue);
    expect(profile.ownerName, 'Responder One');
  });

  test(
    'matching device id with a different key is denied responder access',
    () {
      final profile = resolver.resolve(
        deviceId: localDeviceId,
        publicKey: 'replacement-public-key',
        keyVersion: 1,
        bundle: _bundle(approved: [_device(role: 'responder')]),
        now: now,
      );

      expect(profile.level, DeviceAccessLevel.keyMismatch);
      expect(profile.canAccessResponderInterface, isFalse);
    },
  );

  test('matching device id with a different key version is denied', () {
    final profile = resolver.resolve(
      deviceId: localDeviceId,
      publicKey: localPublicKey,
      keyVersion: 2,
      bundle: _bundle(approved: [_device(role: 'responder')]),
      now: now,
    );

    expect(profile.level, DeviceAccessLevel.keyMismatch);
  });

  test('revocation takes priority over an approved responder entry', () {
    final profile = resolver.resolve(
      deviceId: localDeviceId,
      publicKey: localPublicKey,
      keyVersion: 1,
      bundle: _bundle(
        approved: [_device(role: 'responder')],
        revoked: [_device(role: 'responder', status: 'revoked')],
      ),
      now: now,
    );

    expect(profile.level, DeviceAccessLevel.revoked);
    expect(profile.canAccessResponderInterface, isFalse);
  });

  test('approved civilian remains in the civilian interface', () {
    final profile = resolver.resolve(
      deviceId: localDeviceId,
      publicKey: localPublicKey,
      keyVersion: 1,
      bundle: _bundle(approved: [_device(role: 'civilian')]),
      now: now,
    );

    expect(profile.level, DeviceAccessLevel.civilian);
    expect(profile.canAccessResponderInterface, isFalse);
  });

  test('device absent from the bundle is unregistered', () {
    final profile = resolver.resolve(
      deviceId: localDeviceId,
      publicKey: localPublicKey,
      keyVersion: 1,
      bundle: _bundle(approved: const []),
      now: now,
    );

    expect(profile.level, DeviceAccessLevel.unregistered);
    expect(profile.canAccessResponderInterface, isFalse);
  });

  test('expired signed bundle is reported as outdated', () {
    final profile = resolver.resolve(
      deviceId: localDeviceId,
      publicKey: localPublicKey,
      keyVersion: 1,
      bundle: _bundle(approved: [_device(role: 'responder')]),
      now: DateTime.utc(2026, 10, 1),
    );

    expect(profile.level, DeviceAccessLevel.outdatedBundle);
    expect(profile.canAccessResponderInterface, isFalse);
  });
}

TrustBundle _bundle({
  required List<TrustedDevice> approved,
  List<TrustedDevice> revoked = const [],
}) {
  return TrustBundle(
    schemaVersion: 2,
    bundleVersion: 1,
    generatedAt: DateTime.utc(2026, 8, 15),
    issuedAt: DateTime.utc(2026, 8, 15),
    expiresAt: DateTime.utc(2026, 9, 15),
    issuer: const TrustBundleIssuer(
      issuerId: 'test-admin',
      signingKeyId: 'test-key',
      signatureAlgorithm: 'ed25519',
      publicKey: 'test-public-key',
    ),
    approvedDevices: approved,
    revokedDevices: revoked,
    signature: 'test-signature',
    isSignatureVerified: true,
  );
}

TrustedDevice _device({required String role, String status = 'approved'}) {
  return TrustedDevice(
    deviceId: 'local-device-001',
    ownerName: 'Responder One',
    role: role,
    status: status,
    publicKey: 'local-public-key',
    keyVersion: 1,
    updatedAt: DateTime.utc(2026, 8, 15),
  );
}
