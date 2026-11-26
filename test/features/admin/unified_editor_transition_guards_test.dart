import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/hosted_publisher_client.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';

class _FakeReviewApi extends RegistrationReviewApi {
  _FakeReviewApi(this.apps)
    : super(
        Uri.https(
          'firestore.googleapis.com',
          '/v1/projects/test/databases/(default)/documents/pilotApplications',
        ),
      );

  final List<ReviewApplication> apps;

  @override
  Future<List<ReviewApplication>> list(String token) async => apps;

  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async => const [];
}

class _NoopPublisher extends HostedPublisherClient {
  _NoopPublisher()
    : super(endpoint: Uri.parse('https://admin.test/api/publish-approval'));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'editor hides Request correction and Reject on published and revoked online applications',
    (tester) async {
      final api = _FakeReviewApi([
        ReviewApplication.fromCache(
          id: 'uid-submitted',
          updateTime: '2026-11-26T10:00:00Z',
          fields: {
            'affiliation': 'student',
            'displayName': 'Submitted User',
            'studentNumber': '2026-1001',
            'course': 'BSIT',
            'yearLevel': '4',
            'sectionSet': 'A',
            'status': 'submitted',
            'revision': 0,
            'registrationId': 'reg-sub',
          },
        ),
        ReviewApplication.fromCache(
          id: 'uid-published',
          updateTime: '2026-11-26T10:01:00Z',
          fields: {
            'affiliation': 'student',
            'displayName': 'Published User',
            'studentNumber': '2026-1002',
            'course': 'BSIT',
            'yearLevel': '4',
            'sectionSet': 'B',
            'status': 'published',
            'revision': 2,
            'registrationId': 'reg-pub',
          },
        ),
      ]);

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: Scaffold(
            body: UnifiedRegistrationsWorkspace(
              reviewApi: api,
              publisherClient: _NoopPublisher(),
              initialSessionForTesting: (
                token: 'tok',
                uid: 'admin-uid',
                email: 'admin@dnsc.edu.ph',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Submitted User'));
      await tester.pumpAndSettle();
      expect(find.text('Request correction'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Published User'));
      await tester.pumpAndSettle();
      expect(find.text('Request correction'), findsNothing);
      expect(find.text('Reject'), findsNothing);
      expect(find.text('Revoke'), findsOneWidget);
    },
  );
}
