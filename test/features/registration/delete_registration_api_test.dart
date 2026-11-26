import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';

const _prefix = 'projects/test/databases/(default)/documents';
const _time = '2026-11-27T01:00:00Z';

CampusRegistration _registration({String? uid = 'student'}) =>
    CampusRegistration(
      registrationId: 'reg-1',
      source: CampusRegistrationSource.qr,
      status: CampusRegistrationStatus.revoked,
      syncState: CampusSyncState.synced,
      accountUid: uid,
      identity: const CampusIdentityFields(
        displayName: 'Original',
        studentNumber: '123',
      ),
      role: RegisteredDeviceRole.civilian,
      activePhone: const RegistrationPhoneBinding(
        deviceId: 'phone',
        publicKey: 'key',
      ),
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      revision: 4,
    );

ReviewApplication _snapshot(String id, Map<String, dynamic> fields) =>
    ReviewApplication.fromCache(id: id, updateTime: _time, fields: fields);

Map<String, dynamic> _fields(Map write) =>
    ReviewApplication({...write['update'] as Map, 'updateTime': _time}).fields;

void main() {
  late List<http.Request> requests;
  late RegistrationReviewApi api;
  late ReviewApplication app;
  late ReviewApplication remote;
  var responseCode = 200;

  setUp(() {
    requests = [];
    responseCode = 200;
    api = RegistrationReviewApi(
      Uri.https('firestore.googleapis.com', '/v1/$_prefix/pilotApplications'),
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', responseCode);
      }),
    );
    app = _snapshot('student', {
      'registrationId': 'reg-1',
      'status': 'published',
      'revision': 7,
      'displayName': 'Approved identity',
      'deviceRegistration': 'signed-phone',
      'reviewHistory': [
        {'decisionId': 'old'},
      ],
      'decisionOutcomes': {
        'old': {'status': 'published'},
      },
      'profileChange': {
        'status': 'approved_pending_publication',
        'displayName': 'Unapproved',
      },
      'replacementRequest': {
        'status': 'submitted',
        'deviceRegistration': 'new-phone',
      },
    });
    remote = _snapshot('reg-1', {
      'registrationId': 'reg-1',
      'accountUid': 'student',
      'status': 'published',
      'revision': 8,
      'displayName': 'Approved identity',
      'publicKey': 'original-key',
      'retiredKeys': [
        {'device_id': 'retired'},
      ],
      'reviewHistory': [
        {'decisionId': 'old'},
      ],
    });
  });

  Future<void> remove({
    ReviewApplication? application,
    ReviewApplication? registration,
    String? uid = 'student',
  }) => api.deleteRegistration(
    'token',
    reviewerUid: 'reviewer',
    registration: _registration(uid: uid),
    application: application,
    remoteRegistration: registration,
    version: 12,
    bundle: 'signed-revocations',
    directoryUpdateTime: _time,
  );

  test(
    'deletion atomically tombstones both records and directory with every CAS',
    () async {
      await remove(application: app, registration: remote);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/v1/$_prefix:commit');
      expect(requests.single.headers['authorization'], 'Bearer token');
      final writes = (jsonDecode(requests.single.body)['writes'] as List)
          .cast<Map>();
      expect(writes, hasLength(3));
      for (final write in writes) {
        expect(write['currentDocument'], {'updateTime': _time});
        expect(write.containsKey('delete'), isFalse);
      }
      final regFields = _fields(
        writes.firstWhere(
          (w) => w['update']['name'] == '$_prefix/campusRegistrations/reg-1',
        ),
      );
      final appFields = _fields(
        writes.firstWhere(
          (w) => w['update']['name'] == '$_prefix/pilotApplications/student',
        ),
      );
      for (final fields in [regFields, appFields]) {
        expect(fields['status'], 'deleted');
        expect(fields['publicationStatus'], 'deleted');
        expect(fields['revision'], 9);
        expect(fields['deletedBy'], 'reviewer');
        expect(fields['displayName'], 'Approved identity');
        expect(fields['reviewHistory'], [
          {'decisionId': 'old'},
        ]);
      }
      expect(regFields['publicKey'], 'original-key');
      expect(regFields['retiredKeys'], remote.fields['retiredKeys']);
      expect(appFields['decisionOutcomes'], app.fields['decisionOutcomes']);
      expect(appFields['profileChange']['status'], 'rejected');
      expect(appFields['replacementRequest']['status'], 'rejected');
      expect(appFields['deviceRegistration'], 'signed-phone');
      final directory = _fields(writes.last);
      expect(directory['registrationId'], 'reg-1');
      expect(directory['applicationUid'], 'student');
      expect(directory['version'], 12);
      expect(directory['bundle'], 'signed-revocations');
    },
  );

  test(
    'manual registration without account creates only registration and directory',
    () async {
      await remove(uid: null);
      final writes = (jsonDecode(requests.single.body)['writes'] as List)
          .cast<Map>();
      expect(writes, hasLength(2));
      expect(writes.first['currentDocument'], {'exists': false});
      expect(_fields(writes.first)['status'], 'deleted');
      expect(_fields(writes.last).containsKey('applicationUid'), isFalse);
    },
  );

  test(
    'linked missing application gets a create-only tombstone to prevent resubmission',
    () async {
      await remove(registration: remote);
      final writes = (jsonDecode(requests.single.body)['writes'] as List)
          .cast<Map>();
      final write = writes.firstWhere(
        (w) => w['update']['name'] == '$_prefix/pilotApplications/student',
      );
      expect(write['currentDocument'], {'exists': false});
      expect(_fields(write)['status'], 'deleted');
    },
  );

  test('mismatched account or registration snapshots never commit', () async {
    for (final invalid in [
      _snapshot('other', app.fields),
      _snapshot('student', {...app.fields, 'registrationId': 'other'}),
    ]) {
      await expectLater(
        remove(application: invalid, registration: remote),
        throwsStateError,
      );
    }
    await expectLater(
      remove(application: app, registration: _snapshot('other', remote.fields)),
      throwsStateError,
    );
    await expectLater(
      remove(
        application: app,
        registration: _snapshot('reg-1', {
          ...remote.fields,
          'accountUid': 'other',
        }),
      ),
      throwsStateError,
    );
    expect(requests, isEmpty);
  });

  for (final code in [403, 409, 412]) {
    test('Firestore $code propagates without retry or Auth calls', () async {
      responseCode = code;
      await expectLater(
        remove(application: app, registration: remote),
        throwsStateError,
      );
      expect(requests, hasLength(1));
      expect(requests.single.url.host, 'firestore.googleapis.com');
    });
  }

  test(
    'rules explicitly guard tombstones and bind deletion to atomic publication',
    () {
      final rules = File('firestore.rules').readAsStringSync();
      expect(rules, contains('function deleteRegistration('));
      expect(rules, contains('function deleteApplication('));
      expect(rules, contains('function accountNotDeleted('));
      expect(rules, contains('function registrationNotDeleted('));
      expect(rules, contains("resource.data.status != 'deleted'"));
      expect(rules, contains("snapshot.publishedAt == request.time"));
      expect(rules, isNot(contains('allow delete:')));
    },
  );
}
