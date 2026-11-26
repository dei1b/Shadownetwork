import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/admin_web_main.dart';
import 'package:shadownetwork/features/registration/data/hosted_publisher_client.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';

class _NoopReviewApi extends RegistrationReviewApi {
  _NoopReviewApi()
    : super(
        Uri.https(
          'firestore.googleapis.com',
          '/v1/projects/test/databases/(default)/documents/pilotApplications',
        ),
      );
}

class _NoopPublisherClient extends HostedPublisherClient {
  _NoopPublisherClient()
    : super(endpoint: Uri.parse('https://admin.test/api/publish-approval'));
}

void main() {
  test('admin web entry point and workspace do not import desktop scanner', () {
    final webMain = File('lib/admin_web_main.dart').readAsStringSync();
    final workspace = File(
      'lib/features/admin/presentation/widgets/unified_registrations_workspace.dart',
    ).readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(webMain, isNot(contains('windows_registration_scanner')));
    expect(webMain, isNot(contains('desktop_admin_shell')));
    expect(workspace, isNot(contains('windows_registration_scanner')));
    expect(workspace, isNot(contains('desktop_registration_scan_session')));
    expect(pubspec, contains('mobile_scanner: ^7.5.0'));
  });

  testWidgets('ShadowNetworkAdminWebApp renders reviewer workspace cleanly', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ShadowNetworkAdminWebApp(
        reviewApi: _NoopReviewApi(),
        publisherClient: _NoopPublisherClient(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Registrations'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.byKey(const ValueKey('unified-scan-qr-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
