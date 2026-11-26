import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';

import '../../support/signed_trust_bundle_fixture.dart';

void main() {
  test(
    'publishCampusRegistration writes explicit device publicKey, signingPublicKey, and keyVersion alongside deviceRegistration',
    () async {
      final secrets = InMemorySecretValueStore();
      final crypto = await DeviceIdentityStore(secretStore: secrets).loadOrCreate();
      final signing = await DeviceSigningIdentityStore(secretStore: secrets).loadOrCreate();
      final qr = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-desk-link-1',
        identity: crypto,
        signingIdentity: signing,
      );
      final signer = await TestTrustBundleSigner.create();
      final bundleJson = await signer.sign(
        bundleVersion: 1,
        issuedAt: DateTime.utc(2026, 11, 26),
      );

      Map<String, dynamic>? capturedCommit;
      final api = RegistrationReviewApi(
        Uri.https(
          'firestore.googleapis.com',
          '/v1/projects/dnsc-pilot/databases/(default)/documents/pilotApplications',
        ),
      );
      await http.runWithClient(
        () => api.publishCampusRegistration(
          'tok-admin',
          registration: CampusRegistration(
            registrationId: 'reg-desk-link-1',
            source: CampusRegistrationSource.qr,
            status: CampusRegistrationStatus.published,
            syncState: CampusSyncState.synced,
            identity: const CampusIdentityFields(
              affiliation: CampusAffiliation.student,
              displayName: 'Paula Linked',
              studentNumber: '2026-9001',
              course: 'BSIT',
              yearLevel: '4',
              sectionSet: 'H',
            ),
            role: RegisteredDeviceRole.civilian,
            activePhone: RegistrationPhoneBinding(
              deviceId: qr.deviceId,
              publicKey: qr.publicKey,
              signingPublicKey: qr.signingPublicKey,
              keyId: qr.keyId,
              keyVersion: qr.keyVersion,
              deviceRegistrationJson: jsonEncode(qr.toJson()),
            ),
            createdAt: DateTime.utc(2026, 11, 26),
            updatedAt: DateTime.utc(2026, 11, 26),
          ),
          version: 1,
          bundle: bundleJson,
          directoryUpdateTime: null,
        ),
        () => MockClient((request) async {
          capturedCommit = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('{}', 200);
        }),
      );

      final writes = capturedCommit!['writes'] as List<dynamic>;
      final regFields =
          (writes.first as Map<String, dynamic>)['update']['fields']
              as Map<String, dynamic>;
      expect(regFields['deviceId']!['stringValue'], 'phone-desk-link-1');
      expect(regFields['publicKey']!['stringValue'], qr.publicKey);
      expect(
        regFields['signingPublicKey']!['stringValue'],
        qr.signingPublicKey,
      );
      expect(regFields['keyVersion']!['integerValue'], '1');
    },
  );
}
