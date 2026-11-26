import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';

void main() {
  test('S6: profile rules require matching campus identity and revision', () {
    final rules = File('firestore.rules').readAsStringSync();
    expect(rules, contains('profileCampusMatches(uid, before, after)'));
    expect(rules, contains('sameCampusIdentity(after, getAfter(reg).data)'));
    expect(
      rules,
      contains("after.revision == nextProfileRevision(before, reg)"),
    );
    expect(rules, contains("getAfter(reg).data.revision == after.revision"));
  });

  final baseCollection = Uri.https(
    'firestore.googleapis.com',
    '/v1/projects/dnsc-test/databases/(default)/documents/pilotApplications',
  );

  test(
    'R5: RegistrationReviewApi.publish commits Student submitted profile change atomically with reviewerUid and preconditions',
    () async {
      final requests = <http.Request>[];
      final api = RegistrationReviewApi(
        baseCollection,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );

      final app = ReviewApplication.fromCache(
        id: 'uid-stu-1',
        updateTime: '2026-11-26T10:00:00Z',
        fields: {
          'affiliation': 'student',
          'displayName': 'Elena Old',
          'studentNumber': '2026-5000',
          'course': 'BSIT',
          'yearLevel': '2',
          'sectionSet': 'A',
          'status': 'published',
          'revision': 1,
          'profileChange': {
            'status': 'submitted',
            'affiliation': 'student',
            'displayName': 'Elena Student New',
            'studentNumber': '2026-5001',
            'course': 'BSIT',
            'yearLevel': '3',
            'sectionSet': 'B',
          },
        },
      );

      await api.publish(
        'tok-rev-1',
        app,
        4,
        '{"bundle":"signed-student"}',
        directoryUpdateTime: '2026-11-26T09:00:00Z',
        reviewerUid: 'uid-admin-1',
      );

      expect(requests, hasLength(1));
      final req = requests.single;
      expect(req.url.path, endsWith('/documents:commit'));
      expect(req.headers['authorization'], 'Bearer tok-rev-1');

      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final writes = (body['writes'] as List).cast<Map<String, dynamic>>();
      expect(writes, hasLength(2));

      final appWrite = writes[0];
      expect(appWrite['currentDocument'], {
        'updateTime': '2026-11-26T10:00:00Z',
      });
      final appUpdate = appWrite['update'] as Map<String, dynamic>;
      expect(
        appUpdate['name'],
        endsWith('/documents/pilotApplications/uid-stu-1'),
      );
      final decodedApp = ReviewApplication({
        'name': appUpdate['name'],
        'updateTime': '2026-11-26T10:00:00Z',
        'fields': appUpdate['fields'],
      });
      expect(decodedApp.fields['displayName'], 'Elena Student New');
      expect(decodedApp.fields['studentNumber'], '2026-5001');
      expect(decodedApp.fields['yearLevel'], '3');
      expect(decodedApp.fields['sectionSet'], 'B');
      expect(decodedApp.profileChange?['status'], 'published');
      expect(decodedApp.profileChange?['reviewerUid'], 'uid-admin-1');

      final dirWrite = writes[1];
      expect(dirWrite['currentDocument'], {
        'updateTime': '2026-11-26T09:00:00Z',
      });
      final dirUpdate = dirWrite['update'] as Map<String, dynamic>;
      expect(dirUpdate['name'], endsWith('/documents/trustDirectory/current'));
      final dirFields = dirUpdate['fields'] as Map<String, dynamic>;
      expect(dirFields['applicationUid'], {'stringValue': 'uid-stu-1'});
      expect(dirFields['version'], {'integerValue': '4'});
      expect(dirFields['bundle'], {
        'stringValue': '{"bundle":"signed-student"}',
      });
    },
  );

  test(
    'R5: Staff submitted profile change sets reviewerUid while approved_pending_publication preserves prior reviewerUid',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final api = RegistrationReviewApi(
        baseCollection,
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{}', 200);
        }),
      );

      final staffSubmitted = ReviewApplication.fromCache(
        id: 'uid-staff-1',
        updateTime: '2026-11-26T10:05:00Z',
        fields: {
          'affiliation': 'staff',
          'displayName': 'Chief Old',
          'employeeId': 'EMP-100',
          'unit': 'Ops',
          'status': 'published',
          'profileChange': {
            'status': 'submitted',
            'affiliation': 'staff',
            'displayName': 'Chief Staff Updated',
            'employeeId': 'EMP-202',
            'unit': 'DRRM Office',
          },
        },
      );
      await api.publish(
        'tok-rev-1',
        staffSubmitted,
        5,
        '{"bundle":"signed-staff"}',
        directoryUpdateTime: null,
        reviewerUid: 'uid-admin-2',
      );

      final resumed = ReviewApplication.fromCache(
        id: 'uid-staff-2',
        updateTime: '2026-11-26T10:10:00Z',
        fields: {
          'affiliation': 'staff',
          'displayName': 'Nurse Old',
          'employeeId': 'EMP-300',
          'unit': 'Clinic',
          'status': 'published',
          'profileChange': {
            'status': 'approved_pending_publication',
            'reviewerUid': 'uid-first-reviewer',
            'affiliation': 'staff',
            'displayName': 'Nurse Updated',
            'employeeId': 'EMP-301',
            'unit': 'Infirmary',
          },
        },
      );
      await api.publish(
        'tok-rev-2',
        resumed,
        6,
        '{"bundle":"signed-resumed"}',
        directoryUpdateTime: '2026-11-26T10:06:00Z',
        reviewerUid: 'uid-second-reviewer',
      );

      expect(bodies, hasLength(2));
      final staffFields =
          ((bodies[0]['writes'] as List).first as Map)['update']['fields']
              as Map<String, dynamic>;
      final staffDecoded = ReviewApplication({
        'name': 'pilotApplications/uid-staff-1',
        'updateTime': '2026-11-26T10:05:00Z',
        'fields': staffFields,
      });
      expect(staffDecoded.fields['employeeId'], 'EMP-202');
      expect(staffDecoded.fields['unit'], 'DRRM Office');
      expect(staffDecoded.profileChange?['status'], 'published');
      expect(staffDecoded.profileChange?['reviewerUid'], 'uid-admin-2');
      expect((bodies[0]['writes'] as List)[1]['currentDocument'], {
        'exists': false,
      });

      final resumedFields =
          ((bodies[1]['writes'] as List).first as Map)['update']['fields']
              as Map<String, dynamic>;
      final resumedDecoded = ReviewApplication({
        'name': 'pilotApplications/uid-staff-2',
        'updateTime': '2026-11-26T10:10:00Z',
        'fields': resumedFields,
      });
      expect(resumedDecoded.profileChange?['status'], 'published');
      expect(
        resumedDecoded.profileChange?['reviewerUid'],
        'uid-first-reviewer',
      );
    },
  );

  test(
    'R5: publish surfaces Firestore 403 rejections and firestore.rules aligns profileChange and directory guards',
    () async {
      final api = RegistrationReviewApi(
        baseCollection,
        client: MockClient(
          (_) async =>
              http.Response('{"error":{"message":"PERMISSION_DENIED"}}', 403),
        ),
      );
      final selfApp = ReviewApplication.fromCache(
        id: 'uid-self',
        updateTime: '2026-11-26T10:00:00Z',
        fields: {
          'status': 'published',
          'profileChange': {'status': 'submitted', 'displayName': 'Self Edit'},
        },
      );
      await expectLater(
        api.publish(
          'tok-self',
          selfApp,
          2,
          '{}',
          directoryUpdateTime: '2026-11-26T09:00:00Z',
          reviewerUid: 'uid-self',
        ),
        throwsStateError,
      );

      final rules = File('firestore.rules').readAsStringSync();
      expect(
        rules,
        contains(
          "get(application).data.get('profileChange', {}).get('status', '') in ['submitted', 'approved_pending_publication']",
        ),
      );
      expect(
        rules,
        contains(
          "getAfter(application).data.get('profileChange', {}).get('status', '') == 'published'",
        ),
      );
      expect(
        rules,
        contains(
          "after.profileChange.get('reviewerUid', '') == request.auth.uid",
        ),
      );
      expect(rules, contains('reviewer() && request.auth.uid != uid'));
      expect(rules, contains("'phone', 'address'"));
      expect(
        rules,
        contains(
          "after.get('phone', '') == after.profileChange.get('phone', '')",
        ),
      );
      expect(
        rules,
        contains(
          "after.get('address', '') == after.profileChange.get('address', '')",
        ),
      );
    },
  );

  test(
    'R13: RegistrationReviewApi.publish persists phone and address edits via reviewedIdentity onto both top-level and profileChange',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final api = RegistrationReviewApi(
        baseCollection,
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{}', 200);
        }),
      );

      final app = ReviewApplication.fromCache(
        id: 'uid-r13-fb',
        updateTime: '2026-11-26T10:00:00Z',
        fields: {
          'affiliation': 'student',
          'displayName': 'Old Student',
          'studentNumber': '2026-1350',
          'course': 'BSIT',
          'yearLevel': '2',
          'sectionSet': 'A',
          'phone': '09170001111',
          'address': 'Old Address',
          'status': 'published',
          'profileChange': {
            'status': 'submitted',
            'affiliation': 'student',
            'displayName': 'Proposed Student',
            'studentNumber': '2026-1351',
            'course': 'BSIT',
            'yearLevel': '3',
            'sectionSet': 'B',
          },
        },
      );

      await api.publish(
        'tok-rev-13',
        app,
        7,
        '{"bundle":"signed-r13"}',
        directoryUpdateTime: '2026-11-26T09:00:00Z',
        reviewerUid: 'uid-admin-13',
        reviewedIdentity: const CampusIdentityFields(
          affiliation: CampusAffiliation.student,
          displayName: 'Proposed Student',
          studentNumber: '2026-1351',
          course: 'BSIT',
          yearLevel: '3',
          sectionSet: 'B',
          phone: '09175556666',
          address: 'Brgy. Gredu, Panabo City',
        ),
      );

      expect(bodies, hasLength(1));
      final appUpdate =
          ((bodies.single['writes'] as List).first as Map)['update']
              as Map<String, dynamic>;
      final decoded = ReviewApplication({
        'name': appUpdate['name'],
        'updateTime': '2026-11-26T10:00:00Z',
        'fields': appUpdate['fields'],
      });
      expect(decoded.fields['displayName'], 'Proposed Student');
      expect(decoded.fields['phone'], '09175556666');
      expect(decoded.fields['address'], 'Brgy. Gredu, Panabo City');
      expect(decoded.profileChange?['status'], 'published');
      expect(decoded.profileChange?['reviewerUid'], 'uid-admin-13');
      expect(decoded.profileChange?['phone'], '09175556666');
      expect(decoded.profileChange?['address'], 'Brgy. Gredu, Panabo City');
    },
  );
}
