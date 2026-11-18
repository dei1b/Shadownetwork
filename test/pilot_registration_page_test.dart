import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/registration/data/pilot_registration.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/presentation/pilot_registration_page.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/presentation/providers/device_access_provider.dart';

class _Student extends Fake implements User {
  @override
  String get uid => 'student';
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  final User currentUser = _Student();
}

class _Registration extends PilotRegistration {
  _Registration() : super(_Auth());

  ReviewApplication? cached;
  ReviewApplication? online;
  bool offline = false;
  int refreshes = 0;
  Map<String, dynamic> draft = {'submitted': true};

  @override
  Future<Map<String, dynamic>> loadDraft(String uid) async => draft;

  @override
  Future<void> saveDraft(String uid, Map<String, dynamic> data) async {
    draft = data;
  }

  @override
  Future<ReviewApplication?> readCachedProfile(User user) async => cached;

  @override
  Future<ReviewApplication?> refreshProfile(User user) async {
    refreshes++;
    if (offline) throw StateError('Connection unavailable');
    return cached = online;
  }
}

ReviewApplication _application(
  String status, {
  String binding = 'this-phone',
}) => ReviewApplication.fromCache(
  id: 'student',
  updateTime: 'same-review',
  fields: {
    'status': status,
    'deviceRegistration': binding,
    'displayName': 'Test Student',
  },
);

void main() {
  Future<void> open(WidgetTester tester, _Registration registration) async {
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          registrationMatchesPhoneProvider(
            'this-phone',
          ).overrideWith((ref) async => true),
          registrationMatchesPhoneProvider(
            'other-phone',
          ).overrideWith((ref) async => false),
          deviceAccessProfileProvider.overrideWith(
            (ref) async => const DeviceAccessProfile(
              deviceId: 'this-phone',
              level: DeviceAccessLevel.civilian,
            ),
          ),
        ],
        child: MaterialApp(
          home: PilotRegistrationPage(
            openRegistration: () async => registration,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('automatically restores approval and reopens offline', (
    tester,
  ) async {
    final registration = _Registration()..online = _application('published');
    await open(tester, registration);
    expect(registration.refreshes, 1);
    expect(find.textContaining('Access active on this phone.'), findsOneWidget);
    expect(find.textContaining('Pending review'), findsNothing);

    registration.offline = true;
    await open(tester, registration);
    expect(registration.refreshes, 2);
    expect(find.textContaining('Access active on this phone.'), findsOneWidget);
    expect(find.textContaining('Pending review'), findsNothing);
  });

  testWidgets('an uncached submitted draft has unknown review status offline', (
    tester,
  ) async {
    await open(tester, _Registration()..offline = true);
    expect(find.textContaining('Review status unavailable'), findsOneWidget);
    expect(find.textContaining('Pending review'), findsNothing);
    expect(find.text('Submit for review'), findsNothing);
  });

  testWidgets('a published application for another phone is not active here', (
    tester,
  ) async {
    await open(
      tester,
      _Registration()
        ..online = _application('published', binding: 'other-phone'),
    );
    expect(
      find.textContaining('approved for a different phone'),
      findsOneWidget,
    );
    expect(find.textContaining('Access active on this phone'), findsNothing);
  });

  testWidgets('refreshing the same correction preserves edits', (tester) async {
    final registration = _Registration()
      ..online = _application('changes_requested');
    await open(tester, registration);
    final name = find.widgetWithText(TextField, 'Full name');
    await tester.enterText(name, 'Updated name');
    await tester.tap(find.text('Check review status'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(name).controller!.text, 'Updated name');
  });

  testWidgets('reopening the same correction restores saved edits', (
    tester,
  ) async {
    final registration = _Registration()
      ..online = _application('changes_requested');
    await open(tester, registration);
    final name = find.widgetWithText(TextField, 'Full name');
    await tester.enterText(name, 'Saved correction');
    final save = find.text('Save draft');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    registration.offline = true;
    await open(tester, registration);
    expect(tester.widget<TextField>(name).controller!.text, 'Saved correction');
  });
}
