import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';

void main() {
  late List<http.Request> requests;
  late RegistrationReviewApi api;
  late CampusRegistration registration;
  late ReviewApplication remote;
  var responseCode = 200;
  setUp(() {
    requests = [];
    responseCode = 200;
    api = RegistrationReviewApi(
      Uri.parse(
        'https://firestore.googleapis.com/v1/projects/test/databases/(default)/documents/pilotApplications',
      ),
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', responseCode);
      }),
    );
    registration = CampusRegistration(
      registrationId: 'reg-one',
      source: CampusRegistrationSource.online,
      status: CampusRegistrationStatus.published,
      syncState: CampusSyncState.synced,
      accountUid: 'student',
      identity: const CampusIdentityFields(displayName: 'Student'),
      role: RegisteredDeviceRole.civilian,
      activePhone: const RegistrationPhoneBinding(
        deviceId: 'phone',
        publicKey: 'encryption',
        signingPublicKey: 'signing',
      ),
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    remote = ReviewApplication.fromCache(
      id: 'reg-one',
      updateTime: 'reviewed-revocation',
      fields: {
        'status': 'revoked',
        'accountUid': 'student',
        'deviceId': 'phone',
        'publicKey': 'encryption',
        'signingPublicKey': 'signing',
        'keyVersion': 1,
        'revision': 7,
        'reviewHistory': [
          {'decisionId': 'revocation', 'status': 'revoked'},
        ],
        'processedDecisionIds': ['revocation'],
        'decisionOutcomes': {
          'revocation': {'status': 'revoked'},
        },
        'retiredKeys': [
          {'deviceId': 'old-phone'},
        ],
      },
    );
  });

  Future<void> restore({String reviewer = 'reviewer'}) =>
      api.restoreCampusRegistration(
        'token',
        registration: registration,
        reviewedRemote: remote,
        reviewerUid: reviewer,
        decisionId: 'restore-one',
        reason: 'Reviewed again',
        version: 9,
        bundle: 'signed-bundle',
        directoryUpdateTime: 'directory-v8',
      );

  test(
    'fallback restoration atomically restores campus record and directory, preserving audit and account',
    () async {
      await restore();
      expect(requests, hasLength(1));
      final writes =
          (jsonDecode(requests.single.body) as Map)['writes'] as List;
      expect(writes, hasLength(2));
      final regWrite = writes.first as Map;
      expect(regWrite['currentDocument'], {
        'updateTime': 'reviewed-revocation',
      });
      final fields = ReviewApplication({
        ...regWrite['update'] as Map,
        'updateTime': 'after',
      }).fields;
      expect(fields['status'], 'published');
      expect(fields['revision'], 8);
      expect((fields['reviewHistory'] as List).map((h) => h['decisionId']), [
        'revocation',
        'restore-one',
      ]);
      expect(
        (fields['decisionOutcomes'] as Map).keys,
        containsAll(['revocation', 'restore-one']),
      );
      expect(
        (regWrite['updateMask'] as Map)['fieldPaths'],
        isNot(contains('retiredKeys')),
      );
      expect((writes.last as Map)['currentDocument'], {
        'updateTime': 'directory-v8',
      });
      expect(
        writes.any(
          (w) =>
              (w['update']['name'] as String).contains('/pilotApplications/'),
        ),
        false,
      );
    },
  );

  test(
    'stale server precondition fails instead of reporting restored',
    () async {
      responseCode = 412;
      await expectLater(restore(), throwsStateError);
    },
  );
  test(
    'campus-only revocation sync uses registration authorization, not account approval',
    () async {
      await api.publishCampusRegistration(
        'token',
        registration: registration.copyWith(
          status: CampusRegistrationStatus.revoked,
        ),
        version: 9,
        bundle: 'signed-revocation',
        directoryUpdateTime: 'directory-v8',
        remoteRegistrationUpdateTime: 'reviewed-campus',
      );
      final writes =
          (jsonDecode(requests.single.body) as Map)['writes'] as List;
      final directoryFields = ReviewApplication({
        ...writes.last['update'] as Map,
        'updateTime': 'after',
      }).fields;
      expect(directoryFields['registrationId'], 'reg-one');
      expect(directoryFields, isNot(contains('applicationUid')));
      final campusFields = ReviewApplication({
        ...writes.first['update'] as Map,
        'updateTime': 'after',
      }).fields;
      expect(campusFields['status'], 'revoked');
      expect(writes.first['currentDocument'], {
        'updateTime': 'reviewed-campus',
      });
      expect(writes.last['currentDocument'], {'updateTime': 'directory-v8'});
    },
  );
  test(
    'self restoration and changed phone binding never submit writes',
    () async {
      await expectLater(restore(reviewer: 'student'), throwsStateError);
      remote.fields['signingPublicKey'] = 'replacement-key';
      await expectLater(restore(), throwsStateError);
      expect(requests, isEmpty);
    },
  );
  test('deleted registration cannot be restored', () async {
    remote.fields['status'] = 'deleted';
    await expectLater(restore(), throwsStateError);
    expect(requests, isEmpty);
  });
}
