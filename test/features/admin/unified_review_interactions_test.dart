// Regression coverage for registration/profile interactions found in S5–S7.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/hosted_publisher_client.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';

final _collection = Uri.parse(
  'https://firestore.googleapis.com/v1/projects/test/databases/(default)/documents/pilotApplications',
);

const _original = CampusIdentityFields(
  displayName: 'Verified Student',
  studentNumber: '2026-1001',
  course: 'BSIT',
  yearLevel: '3',
  sectionSet: 'A',
  phone: '09170000001',
  address: 'Old address',
);
const _corrected = CampusIdentityFields(
  displayName: 'Corrected Student',
  studentNumber: '2026-1002',
  course: 'BSCS',
  yearLevel: '4',
  sectionSet: 'B',
  phone: '09170000002',
  address: 'Corrected address',
);

class _Api extends RegistrationReviewApi {
  _Api(this.app, this.registration) : super(_collection);
  final ReviewApplication app;
  final ReviewApplication registration;
  @override
  Future<List<ReviewApplication>> list(String token) async => [app];
  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async => name == 'campusRegistrations' ? [registration] : [];
  @override
  Future<({int version, String bundle, String updateTime})?> readDirectory(
    String token,
  ) async => null;
}

class _Publisher extends HostedPublisherClient {
  _Publisher() : super(endpoint: Uri.parse('https://review.test/publish'));
  final payloads = <Map<String, Object?>>[];
  @override
  Future<HostedPublishResult> publishDecision({
    required String token,
    required Map<String, Object?> payload,
  }) async {
    payloads.add(payload);
    return HostedPublishResult(
      status: 'published',
      version: 3,
      decisionId: payload['decisionId'] as String,
      idempotent: false,
    );
  }
}

Future<DeviceRegistrationQr> _qr() async {
  final secrets = InMemorySecretValueStore();
  final identity = await DeviceIdentityStore(
    secretStore: secrets,
  ).loadOrCreate();
  final signing = await DeviceSigningIdentityStore(
    secretStore: secrets,
  ).loadOrCreate();
  return DeviceRegistrationQr.createSigned(
    deviceId: 'phone-reviewed',
    identity: identity,
    signingIdentity: signing,
  );
}

ReviewApplication _app(
  DeviceRegistrationQr qr, {
  int revision = 1,
  String time = '2026-11-26T09:00:00Z',
  Map<String, dynamic> extra = const {},
}) => ReviewApplication.fromCache(
  id: 'uid-applicant',
  updateTime: time,
  fields: {
    ..._original.toFirestoreFields(),
    'status': 'published',
    'registrationId': 'reg-reviewed',
    'revision': revision,
    'deviceRegistration': jsonEncode(qr.toJson()),
    'reviewHistory': [
      {'role': 'civilian', 'status': 'published'},
    ],
    ...extra,
  },
);

ReviewApplication _registration(
  DeviceRegistrationQr qr, {
  int revision = 1,
  String status = 'published',
}) => ReviewApplication.fromCache(
  id: 'reg-reviewed',
  updateTime: '2026-11-26T10:00:00Z',
  fields: {
    ..._original.toFirestoreFields(),
    'registrationId': 'reg-reviewed',
    'accountUid': 'uid-applicant',
    'status': status,
    'revision': revision,
    'source': 'online',
    'role': 'civilian',
    'deviceId': qr.deviceId,
    'publicKey': qr.publicKey,
    'signingPublicKey': qr.signingPublicKey,
    'keyVersion': qr.keyVersion,
    'deviceRegistration': jsonEncode(qr.toJson()),
  },
);

Future<void> _mount(WidgetTester tester, _Api api, _Publisher publisher) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: AdminTheme.light,
      home: Scaffold(
        body: UnifiedRegistrationsWorkspace(
          reviewApi: api,
          publisherClient: publisher,
          initialSessionForTesting: (
            token: 'test-token',
            uid: 'reviewer',
            email: 'reviewer@dnsc.edu.ph',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final appRevision in [2, 20]) {
    testWidgets(
      'S5: contact save cannot hide revocation (app revision $appRevision)',
      (tester) async {
        final qr = await _qr();
        await _mount(
          tester,
          _Api(
            _app(
              qr,
              revision: appRevision,
              time: '2026-11-26T11:00:00Z',
              extra: {'phone': '09179999999'},
            ),
            _registration(qr, revision: 2, status: 'revoked'),
          ),
          _Publisher(),
        );
        await tester.tap(find.widgetWithText(FilterChip, 'Revoked'));
        await tester.pumpAndSettle();
        expect(
          find.text('Verified Student'),
          findsOneWidget,
          reason: 'Contact updates do not reinstate campus access.',
        );
      },
    );
  }

  testWidgets(
    'R13: fallback correction survives refresh and next hosted action',
    (tester) async {
      final qr = await _qr();
      // A prior Windows replacement increments campus revision to 2 but leaves
      // the application's revision at 1 (publishPhoneReplacement update mask).
      final before = _app(
        qr,
        extra: {
          'profileChange': {
            ..._corrected.toFirestoreFields(),
            'status': 'submitted',
          },
        },
      );
      var campus = _registration(qr, revision: 2);
      late List<dynamic> writes;
      final api = RegistrationReviewApi(
        _collection,
        client: MockClient((request) async {
          if (request.method == 'GET') {
            Map<String, dynamic> encode(dynamic value) {
              if (value is int) return {'integerValue': '$value'};
              return {'stringValue': value};
            }

            return http.Response(
              jsonEncode({
                'name': 'campusRegistrations/${campus.id}',
                'updateTime': campus.updateTime,
                'fields': campus.fields.map(
                  (key, value) => MapEntry(key, encode(value)),
                ),
              }),
              200,
            );
          }
          writes =
              (jsonDecode(request.body) as Map<String, dynamic>)['writes']
                  as List;
          return http.Response('{}', 200);
        }),
      );
      await api.publish(
        'test-token',
        before,
        3,
        'captured-bundle',
        directoryUpdateTime: '2026-11-26T10:00:00Z',
        reviewerUid: 'reviewer',
        reviewedIdentity: _corrected,
      );
      // Apply the actual API's emitted application patch as Firestore would.
      // This is a contract/UI probe, not a rules or signature verification test.
      final appWrite = writes.cast<Map<String, dynamic>>().singleWhere(
        (write) => ((write['update'] as Map)['name'] as String).contains(
          '/pilotApplications/',
        ),
      );
      final patch = ReviewApplication({
        ...(appWrite['update'] as Map<String, dynamic>),
        'updateTime': '2026-11-26T11:00:00Z',
      });
      final after = ReviewApplication.fromCache(
        id: before.id,
        updateTime: patch.updateTime,
        fields: {...before.fields, ...patch.fields},
      );
      for (final write in writes.cast<Map<String, dynamic>>()) {
        final update = write['update'] as Map<String, dynamic>?;
        if (update == null ||
            !(update['name'] as String).contains('/campusRegistrations/')) {
          continue;
        }
        final campusPatch = ReviewApplication({
          ...update,
          'updateTime': '2026-11-26T11:00:00Z',
        });
        campus = ReviewApplication.fromCache(
          id: campus.id,
          updateTime: campusPatch.updateTime,
          fields: {...campus.fields, ...campusPatch.fields},
        );
      }
      expect(after.fields['displayName'], 'Corrected Student');
      expect(after.fields['phone'], '09170000002');
      expect(writes, hasLength(3));
      expect(after.fields['revision'], 3);
      expect(campus.fields['revision'], 3);
      for (final entry in _corrected.toFirestoreFields().entries) {
        expect(after.fields[entry.key], entry.value);
        expect(campus.fields[entry.key], entry.value);
      }
      final publisher = _Publisher();
      await _mount(tester, _Api(after, campus), publisher);
      // Open the only registration through the rendered queue, regardless of
      // whether it currently displays the old or corrected name.
      await tester.tap(find.textContaining('Phone: phone-reviewed'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Revoke'));
      await tester.tap(find.widgetWithText(TextButton, 'Revoke'));
      await tester.pumpAndSettle();
      expect(publisher.payloads, hasLength(1));
      final reviewed = publisher.payloads.single['reviewedFields'] as Map;
      expect(reviewed['displayName'], 'Corrected Student');
      expect(reviewed['phone'], '09170000002');
      expect(reviewed['address'], 'Corrected address');
      for (final entry in _corrected.toFirestoreFields().entries) {
        expect(reviewed[entry.key], entry.value);
      }
    },
  );

  testWidgets(
    'R13: Revoke must not accept a still-pending profile correction',
    (tester) async {
      final qr = await _qr();
      final publisher = _Publisher();
      await _mount(
        tester,
        _Api(
          _app(
            qr,
            extra: {
              'profileChange': {
                ..._corrected.toFirestoreFields(),
                'status': 'submitted',
              },
            },
          ),
          _registration(qr),
        ),
        publisher,
      );
      await tester.tap(find.text('Verified Student'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Revoke'));
      await tester.tap(find.widgetWithText(TextButton, 'Revoke'));
      await tester.pumpAndSettle();
      expect(publisher.payloads, hasLength(1));
      expect(publisher.payloads.single['targetStatus'], 'revoked');
      final reviewed = publisher.payloads.single['reviewedFields'] as Map;
      expect(
        reviewed['displayName'],
        'Verified Student',
        reason: 'Revocation is not approval of the separate identity request.',
      );
    },
  );

  testWidgets(
    'S5: explicit campus reinstatement overrides stale revoked application',
    (tester) async {
      final qr = await _qr();
      await _mount(
        tester,
        _Api(
          _app(
            qr,
            revision: 30,
            time: '2026-11-26T11:00:00Z',
            extra: {'status': 'revoked'},
          ),
          _registration(qr, revision: 3),
        ),
        _Publisher(),
      );
      await tester.tap(find.widgetWithText(FilterChip, 'Published'));
      await tester.pumpAndSettle();
      expect(find.text('Verified Student'), findsOneWidget);
    },
  );

  testWidgets(
    'S7: replacement approval leaves the profile proposal undecided',
    (tester) async {
      final qr = await _qr();
      final replacement = await _qr();
      final publisher = _Publisher();
      final app = _app(
        qr,
        extra: {
          'profileChange': {
            ..._corrected.toFirestoreFields(),
            'status': 'submitted',
          },
          'replacementRequest': {
            'status': 'submitted',
            'deviceRegistration': jsonEncode(replacement.toJson()),
          },
        },
      );
      await _mount(tester, _Api(app, _registration(qr)), publisher);
      await tester.tap(find.text('Verified Student'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Approve replacement'),
      );
      await tester.tap(
        find.widgetWithText(FilledButton, 'Approve replacement'),
      );
      await tester.pumpAndSettle();
      expect(publisher.payloads, hasLength(1));
      expect(publisher.payloads.single['action'], 'approve_replacement');
      expect(
        (publisher.payloads.single['reviewedFields'] as Map)['displayName'],
        'Verified Student',
      );
      expect(app.profileChange?['status'], 'submitted');
    },
  );
}
