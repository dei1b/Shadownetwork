import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';

void main() {
  test('registration QR round trip preserves public device identity', () async {
    final identity = await DeviceIdentityStore(
      secretStore: InMemorySecretValueStore(),
    ).loadOrCreate();
    final registration = DeviceRegistrationQr.fromIdentity(
      deviceId: 'android-peer-123',
      identity: identity,
    );

    final decoded = DeviceRegistrationQr.fromJsonString(
      registration.toJsonString(),
    );

    expect(decoded.deviceId, 'android-peer-123');
    expect(decoded.publicKey, identity.encodedPublicKey);
    expect(decoded.keyId, identity.keyId);
    expect(decoded.keyVersion, identity.keyVersion);
    expect(registration.toJsonString(), isNot(contains('private_key')));
  });

  test('registration QR rejects a mismatched key ID', () async {
    final identity = await DeviceIdentityStore(
      secretStore: InMemorySecretValueStore(),
    ).loadOrCreate();
    final payload = DeviceRegistrationQr.fromIdentity(
      deviceId: 'android-peer-123',
      identity: identity,
    ).toJson();
    payload['key_id'] = 'x25519-invalid';

    expect(
      () => DeviceRegistrationQr.fromJsonString(jsonEncode(payload)),
      throwsFormatException,
    );
  });

  test('registration QR rejects private key material', () async {
    final identity = await DeviceIdentityStore(
      secretStore: InMemorySecretValueStore(),
    ).loadOrCreate();
    final payload = DeviceRegistrationQr.fromIdentity(
      deviceId: 'android-peer-123',
      identity: identity,
    ).toJson();
    payload['private_key'] = 'must-not-be-scanned';

    expect(
      () => DeviceRegistrationQr.fromJsonString(jsonEncode(payload)),
      throwsFormatException,
    );
  });
}
