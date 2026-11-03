import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';
import 'package:shadownetwork/features/security/domain/entities/user_information.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';

void main() {
  test(
    'signed user information survives QR and rejects contact tampering',
    () async {
      final identity = await DeviceIdentityStore(
        secretStore: InMemorySecretValueStore(),
      ).loadOrCreate();
      final signing = await DeviceSigningIdentityStore(
        secretStore: InMemorySecretValueStore(),
      ).loadOrCreate();
      final qr = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone',
        identity: identity,
        signingIdentity: signing,
        userInformation: const UserInformation(
          fullName: 'Maria Santos',
          phoneNumber: '+63 912 345 6789',
          address: 'Purok 2, Panabo City',
        ),
      );
      final decoded = DeviceRegistrationQr.fromJsonString(qr.toJsonString());
      await decoded.verifySignature();
      expect(decoded.toJson()['schema_version'], 3);
      expect(decoded.userInformation!.fullName, 'Maria Santos');
      for (final field in ['full_name', 'phone_number', 'address']) {
        final tampered = qr.toJson();
        tampered['user_information'] = {
          ...decoded.userInformation!.toJson(),
          field: 'Tampered',
        };
        await expectLater(
          DeviceRegistrationQr.fromJson(tampered).verifySignature(),
          throwsFormatException,
        );
      }
      final downgraded = qr.toJson()..['schema_version'] = 2;
      expect(
        () => DeviceRegistrationQr.fromJson(downgraded),
        throwsFormatException,
      );
      final missing = qr.toJson()..remove('user_information');
      expect(
        () => DeviceRegistrationQr.fromJson(missing),
        throwsFormatException,
      );
    },
  );

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
