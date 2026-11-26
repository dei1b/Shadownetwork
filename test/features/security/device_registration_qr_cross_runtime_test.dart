import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';

void main() {
  test('Dart-generated v2 and v3 registration QR fixtures verify cleanly', () async {
    final v2Source = File(
      'test/vercel/fixtures/dart_registration_qr_v2.json',
    ).readAsStringSync();
    final v3Source = File(
      'test/vercel/fixtures/dart_registration_qr_v3.json',
    ).readAsStringSync();

    final v2 = DeviceRegistrationQr.fromJsonString(v2Source);
    await v2.verifySignature();
    expect(v2.toJson()['schema_version'], 2);
    expect(v2.userInformation, isNull);

    final v3 = DeviceRegistrationQr.fromJsonString(v3Source);
    await v3.verifySignature();
    expect(v3.toJson()['schema_version'], 3);
    expect(v3.userInformation?.fullName, 'Maria Santos');
  });
}
