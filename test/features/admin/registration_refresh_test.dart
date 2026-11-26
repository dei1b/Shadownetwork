import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';

class _Api extends RegistrationReviewApi {
  _Api() : super(Uri.parse('https://test.invalid/pilotApplications'));
  int reads = 0;
  bool failRegistrations = false;
  List<ReviewApplication> applications = [];

  @override
  Future<List<ReviewApplication>> list(String token) async {
    reads++;
    return applications;
  }

  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async {
    if (name == 'campusRegistrations' && failRegistrations) {
      throw StateError('This account cannot perform that action.');
    }
    return [];
  }
}

ReviewApplication _application() => ReviewApplication.fromCache(
  id: 'student-one',
  updateTime: '2026-11-27T00:00:00Z',
  fields: {
    'displayName': 'New Applicant',
    'status': 'submitted',
    'studentNumber': '2026-001',
    'course': 'BSIT',
  },
);

Future<void> _mount(WidgetTester tester, _Api api, {bool active = true}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: AdminTheme.light,
      home: Scaffold(
        body: UnifiedRegistrationsWorkspace(
          reviewApi: api,
          onlineRefreshEnabled: active,
          initialSessionForTesting: (
            token: 'token',
            uid: 'reviewer',
            email: 'reviewer@example.test',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('hidden registration tab pauses reads and checks on return', (
    tester,
  ) async {
    final api = _Api();
    await _mount(tester, api, active: false);
    await tester.pump(const Duration(minutes: 2));
    expect(api.reads, 1);
    api.applications = [_application()];
    await _mount(tester, api);
    expect(api.reads, 2);
    expect(find.text('New Applicant'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('inactive app pauses checks and refreshes when resumed', (
    tester,
  ) async {
    final api = _Api();
    await _mount(tester, api);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(minutes: 1));
    expect(api.reads, 1);
    api.applications = [_application()];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(api.reads, 2);
    expect(find.text('New Applicant'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new registration appears without pressing Refresh', (
    tester,
  ) async {
    final api = _Api();
    await _mount(tester, api);
    expect(find.text('New Applicant'), findsNothing);
    api.applications = [_application()];
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(api.reads, 2);
    expect(find.text('New Applicant'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sign out stops automatic registration reads', (tester) async {
    final api = _Api();
    await _mount(tester, api);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 2));
    expect(api.reads, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'collection permission failure stays visible until successful retry',
    (tester) async {
      final api = _Api()..applications = [_application()];
      await _mount(tester, api);
      api.failRegistrations = true;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('registration-sync-error')), findsOneWidget);
      expect(find.text('New Applicant'), findsOneWidget);
      api.failRegistrations = false;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('registration-sync-error')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('background polling pauses while registration editor is open', (
    tester,
  ) async {
    final api = _Api()..applications = [_application()];
    await _mount(tester, api);
    await tester.tap(find.text('New Applicant'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 1));
    expect(api.reads, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
