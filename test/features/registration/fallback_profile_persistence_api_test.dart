import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';

final _collection = Uri.parse(
  'https://firestore.googleapis.com/v1/projects/test/databases/(default)/documents/pilotApplications',
);
const _appTime = '2026-11-26T10:00:00Z';
const _campusTime = '2026-11-26T10:01:00Z';
const _dirTime = '2026-11-26T10:02:00Z';
const _corrected = CampusIdentityFields(
  affiliation: CampusAffiliation.student,
  displayName: 'Corrected Student',
  studentNumber: '2026-2000',
  course: 'BSIT',
  yearLevel: '4',
  sectionSet: 'B',
  phone: '09170000002',
  address: 'Corrected address',
);

Map<String, dynamic> _encode(dynamic value) => switch (value) {
  String() => {'stringValue': value},
  int() => {'integerValue': '$value'},
  List() => {
    'arrayValue': {'values': value.map(_encode).toList()},
  },
  Map() => {
    'mapValue': {'fields': value.map((k, v) => MapEntry(k, _encode(v)))},
  },
  _ => throw ArgumentError('Unsupported fixture value'),
};

Map<String, dynamic> _campus() => {
  'registrationId': 'reg-1',
  'accountUid': 'applicant',
  'status': 'published',
  'revision': 2,
  'role': 'civilian',
  'deviceId': 'phone-b',
  'deviceRegistration': 'phone-b-qr',
  'displayName': 'Old Student',
  'processedDecisionIds': ['earlier-decision'],
  'decisionOutcomes': {
    'earlier-decision': {'status': 'published'},
  },
};

ReviewApplication _application({bool replacement = false}) =>
    ReviewApplication.fromCache(
      id: 'applicant',
      updateTime: _appTime,
      fields: {
        'registrationId': 'reg-1',
        'status': 'published',
        'revision': 1,
        'deviceRegistration': replacement ? 'phone-a-qr' : 'phone-b-qr',
        'processedDecisionIds': ['earlier-decision'],
        'decisionOutcomes': {
          'earlier-decision': {'status': 'published'},
        },
        if (replacement)
          'replacementRequest': {
            'status': 'submitted',
            'deviceRegistration': 'phone-b-qr',
          }
        else
          'profileChange': {
            ..._corrected.toFirestoreFields(),
            'status': 'submitted',
          },
      },
    );

ReviewApplication _decodeWrite(Map write) => ReviewApplication({
  ...Map<String, dynamic>.from(write['update'] as Map),
  'updateTime': _campusTime,
});

void main() {
  for (final status in [200, 412]) {
    test(
      'S6: all profile records share revision and CAS guards ($status)',
      () async {
        late List<Map<String, dynamic>> writes;
        final api = RegistrationReviewApi(
          _collection,
          client: MockClient((request) async {
            if (request.method == 'GET') {
              expect(request.url.path, endsWith('/campusRegistrations/reg-1'));
              return http.Response(
                jsonEncode({
                  'name': 'campusRegistrations/reg-1',
                  'updateTime': _campusTime,
                  'fields': _campus().map((k, v) => MapEntry(k, _encode(v))),
                }),
                200,
              );
            }
            writes = (jsonDecode(request.body)['writes'] as List)
                .cast<Map<String, dynamic>>();
            return http.Response('{}', status);
          }),
        );
        final publication = api.publish(
          'token',
          _application(),
          4,
          'signed-bundle',
          directoryUpdateTime: _dirTime,
          reviewerUid: 'admin',
          reviewedIdentity: _corrected,
        );
        if (status == 412) {
          await expectLater(publication, throwsStateError);
        } else {
          await publication;
        }
        expect(writes, hasLength(3));
        final app = writes.singleWhere(
          (w) => '${w['update']['name']}'.contains('/pilotApplications/'),
        );
        final campus = writes.singleWhere(
          (w) => '${w['update']['name']}'.contains('/campusRegistrations/'),
        );
        final directory = writes.singleWhere(
          (w) => '${w['update']['name']}'.contains('/trustDirectory/'),
        );
        expect(app['currentDocument'], {'updateTime': _appTime});
        expect(campus['currentDocument'], {'updateTime': _campusTime});
        expect(directory['currentDocument'], {'updateTime': _dirTime});
        for (final write in [app, campus]) {
          final fields = _decodeWrite(write).fields;
          for (final entry in _corrected.toFirestoreFields().entries) {
            expect(fields[entry.key], entry.value, reason: entry.key);
          }
          expect(fields['revision'], 3);
        }
        expect(
          campus['updateMask']['fieldPaths'],
          isNot(contains('deviceRegistration')),
        );
        expect(_decodeWrite(app).profileChange?['status'], 'published');
      },
    );
  }

  test('S6: a legacy application may have no campus record', () async {
    late List<dynamic> writes;
    final api = RegistrationReviewApi(
      _collection,
      client: MockClient((request) async {
        if (request.method == 'GET') return http.Response('{}', 404);
        writes = jsonDecode(request.body)['writes'] as List;
        return http.Response('{}', 200);
      }),
    );
    await api.publish(
      'token',
      _application(),
      4,
      'signed-bundle',
      directoryUpdateTime: _dirTime,
      reviewerUid: 'admin',
      reviewedIdentity: _corrected,
    );
    expect(writes, hasLength(2));
    expect(_decodeWrite(writes.first as Map).fields['revision'], 2);
  });

  for (final recovery in [false, true]) {
    test(
      'S4/S6: ${recovery ? 'recovery' : 'replacement'} aligns revision and preserves durable outcomes',
      () async {
        late List<Map<String, dynamic>> writes;
        final api = RegistrationReviewApi(
          _collection,
          client: MockClient((request) async {
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'name': 'campusRegistrations/reg-1',
                  'updateTime': _campusTime,
                  'fields': _campus().map((k, v) => MapEntry(k, _encode(v))),
                }),
                200,
              );
            }
            writes = (jsonDecode(request.body)['writes'] as List)
                .cast<Map<String, dynamic>>();
            return http.Response('{}', 200);
          }),
        );
        final registration = CampusRegistration(
          registrationId: 'reg-1',
          source: CampusRegistrationSource.online,
          status: CampusRegistrationStatus.published,
          syncState: CampusSyncState.synced,
          accountUid: 'applicant',
          identity: _corrected,
          role: RegisteredDeviceRole.civilian,
          revision: 3,
          pendingDecisionId: 'replacement-decision',
          activePhone: const RegistrationPhoneBinding(
            deviceId: 'phone-b',
            publicKey: 'key-b',
            signingPublicKey: 'sign-b',
            deviceRegistrationJson: 'phone-b-qr',
          ),
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026, 11, 26),
        );
        if (recovery) {
          await api.approveRecoveryAndPublish(
            'token',
            reviewerUid: 'admin',
            verificationMethod: 'desk_id_check',
            registration: registration,
            recoveryRequest: ReviewApplication.fromCache(
              id: 'applicant',
              updateTime: _appTime,
              fields: {
                'status': 'submitted',
                'accountUid': 'applicant',
                'deviceRegistration': 'phone-b-qr',
              },
            ),
            existingApplication: _application(replacement: true),
            newDeviceRegistrationJson: 'phone-b-qr',
            version: 4,
            bundle: 'signed-bundle',
            directoryUpdateTime: _dirTime,
            remoteRegistrationUpdateTime: _campusTime,
          );
        } else {
          await api.publishPhoneReplacement(
            'token',
            application: _application(replacement: true),
            registration: registration,
            newDeviceRegistrationJson: 'phone-b-qr',
            version: 4,
            bundle: 'signed-bundle',
            directoryUpdateTime: _dirTime,
            remoteRegistrationUpdateTime: _campusTime,
          );
        }
        for (final write in writes.where(
          (w) =>
              '${w['update']['name']}'.contains('/pilotApplications/') ||
              '${w['update']['name']}'.contains('/campusRegistrations/'),
        )) {
          final fields = _decodeWrite(write).fields;
          expect(fields['revision'], 3);
          expect(fields['processedDecisionIds'], [
            'earlier-decision',
            'replacement-decision',
          ]);
          expect(
            fields['decisionOutcomes']['earlier-decision']['status'],
            'published',
          );
          expect(
            fields['decisionOutcomes']['replacement-decision'],
            containsPair(
              'action',
              recovery ? 'approve_recovery' : 'approve_replacement',
            ),
          );
          expect(
            fields['decisionOutcomes']['replacement-decision'],
            containsPair('registrationId', 'reg-1'),
          );
          expect(
            fields['decisionOutcomes']['replacement-decision'],
            containsPair('revision', 3),
          );
        }
        expect(writes[0]['currentDocument'], {'updateTime': _appTime});
        expect(writes[1]['currentDocument'], {'updateTime': _campusTime});
        expect(writes.last['currentDocument'], {'updateTime': _dirTime});
        if (recovery) {
          expect(writes, hasLength(4));
          expect(writes[2]['currentDocument'], {'updateTime': _appTime});
          expect(_decodeWrite(writes[0]).fields['status'], 'published');
          expect(
            _decodeWrite(writes[2]).fields['replacementRequest'],
            isA<Map>(),
          );
        }
      },
    );
  }
}
