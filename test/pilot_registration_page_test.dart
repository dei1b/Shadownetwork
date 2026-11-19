import 'dart:async';

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
  _Auth(this.currentUser);

  final signIn = Completer<UserCredential>();

  @override
  final User? currentUser;

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) => signIn.future;
}

class _Registration extends PilotRegistration {
  _Registration({bool signedIn = true})
    : super(_Auth(signedIn ? _Student() : null));

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
  Future<void> open(
    WidgetTester tester,
    _Registration registration, {
    VoidCallback? onContinue,
    TextScaler? textScaler,
  }) async {
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
          home: PilotRegistrationPage(
            onContinue: onContinue,
            openRegistration: () async => registration,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('first-run registration explains SOS and can be skipped', (
    tester,
  ) async {
    var continued = false;
    await open(
      tester,
      _Registration(signedIn: false),
      onContinue: () => continued = true,
    );
    expect(find.textContaining('send an SOS right away'), findsOneWidget);
    final skip = find.text('Continue without an account');
    expect(skip, findsOneWidget);
    await tester.tap(skip);
    expect(continued, isTrue);
  });

  testWidgets('missing sign-in fields show inline and focus email first', (
    tester,
  ) async {
    await open(tester, _Registration(signedIn: false));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your email.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    final email = find.descendant(
      of: find.widgetWithText(TextField, 'Email (required)'),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(email).focusNode.hasFocus, isTrue);
  });

  testWidgets('first-run guest access waits for an in-flight sign-in', (
    tester,
  ) async {
    final registration = _Registration(signedIn: false);
    var continued = false;
    await open(tester, registration, onContinue: () => continued = true);
    await tester.enterText(
      find.byType(TextField).first,
      'student@example.test',
    );
    await tester.enterText(find.byType(TextField).last, 'test-password');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    final guest = find.widgetWithText(
      OutlinedButton,
      'Continue without an account',
    );
    expect(tester.widget<OutlinedButton>(guest).onPressed, isNull);
    (registration.auth as _Auth).signIn.completeError(
      FirebaseAuthException(code: 'network-request-failed'),
    );
    await tester.pumpAndSettle();
    await tester.tap(guest);
    expect(continued, isTrue);
  });

  for (final size in [const Size(360, 640), const Size(640, 360)]) {
    testWidgets('missing details follow form order at 200% text on $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await open(
        tester,
        _Registration()..draft = {},
        textScaler: const TextScaler.linear(2),
      );

      final submit = find.text('Submit for review');
      Future<void> submitDetails() async {
        await tester.scrollUntilVisible(
          submit,
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(submit);
        await tester.pumpAndSettle();
      }

      void expectFocused(Finder field) {
        final input = find.descendant(
          of: field,
          matching: find.byType(EditableText),
        );
        expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);
        final viewport = find.byType(SingleChildScrollView);
        expect(
          tester.getRect(viewport).contains(tester.getCenter(input)),
          isTrue,
        );
      }

      final name = find.widgetWithText(TextField, 'Full name (required)');
      final number = find.widgetWithText(
        TextField,
        'Student number (required)',
      );
      final course = find.widgetWithText(
        TextField,
        'Course and year (required)',
      );
      await submitDetails();
      expectFocused(name);
      expect(tester.widget<TextField>(name).decoration!.errorText, isNotNull);
      expect(tester.widget<TextField>(number).decoration!.errorText, isNotNull);
      expect(tester.widget<TextField>(course).decoration!.errorText, isNotNull);
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'Phone number (optional)'),
            )
            .decoration!
            .errorText,
        isNull,
      );
      await tester.enterText(name, 'Test Student');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(name).decoration!.errorText, isNull);
      await submitDetails();
      expectFocused(number);
      await tester.enterText(number, '2026-1234');
      await tester.pumpAndSettle();
      await submitDetails();
      expectFocused(course);
      expect(tester.takeException(), isNull);
    });
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
    final name = find.widgetWithText(TextField, 'Full name (required)');
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
    final name = find.widgetWithText(TextField, 'Full name (required)');
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
