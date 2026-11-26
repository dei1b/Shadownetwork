import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/hosted_publisher_client.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';

void main() {
  test('RegistrationReviewApi guards missing build-time Firebase defines', () async {
    expect(RegistrationReviewApi.isConfiguredFor(project: '', apiKey: 'abc'), isFalse);
    expect(RegistrationReviewApi.isConfiguredFor(project: 'proj', apiKey: ''), isFalse);
    expect(
      RegistrationReviewApi.isConfiguredFor(project: 'proj', apiKey: 'abc'),
      isTrue,
    );

    await expectLater(
      RegistrationReviewApi.signIn(
        'admin@dnsc.edu.ph',
        'secret',
        project: '',
        apiKey: '',
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('DNSC_FIREBASE_PROJECT'),
        ),
      ),
    );
  });

  testWidgets('UnifiedRegistrationsWorkspace shows clear error when Firebase client config is missing', (
    tester,
  ) async {
    if (RegistrationReviewApi.isConfigured) {
      return;
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: AdminTheme.light,
        home: Scaffold(
          body: UnifiedRegistrationsWorkspace(
            publisherClient: HostedPublisherClient(
              endpoint: Uri.parse('https://admin.test/api/publish-approval'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('DNSC_FIREBASE_PROJECT or DNSC_FIREBASE_API_KEY'),
      findsOneWidget,
    );
  });
}
