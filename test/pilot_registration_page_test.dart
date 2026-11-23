import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/registration/data/pilot_registration.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/presentation/pilot_registration_page.dart';
import 'package:shadownetwork/features/registration/presentation/profile_section.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/presentation/providers/device_access_provider.dart';

class _Student extends Fake implements User {
  @override
  String get uid => 'student';

  @override
  String get email => 'student@example.test';
}

class _Auth extends Fake implements FirebaseAuth {
  _Auth(this.currentUser);

  final signIn = Completer<UserCredential>();
  String? resetEmail;

  @override
  final User? currentUser;

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) => signIn.future;

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    ActionCodeSettings? actionCodeSettings,
  }) async {
    resetEmail = email;
  }
}

class _Registration extends PilotRegistration {
  _Registration({bool signedIn = true})
    : super(_Auth(signedIn ? _Student() : null));

  ReviewApplication? cached;
  ReviewApplication? online;
  bool offline = false;
  bool failUpdate = false;
  Map<String, dynamic>? savedChanges;
  final submission = Completer<void>();
  final submissionStarted = Completer<void>();
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

  @override
  Future<void> updateProfile(
    User user,
    ReviewApplication application,
    Map<String, dynamic> changes,
  ) async {
    if (failUpdate) throw StateError('Connection unavailable');
    savedChanges = changes;
  }

  @override
  Future<void> submit(User user, Map<String, String> details) {
    submissionStarted.complete();
    return submission.future;
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

  testWidgets('first-run Home stays available during sign-in', (tester) async {
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
    expect(find.text('Continue without an account'), findsNothing);
    await tester.tap(find.text('Continue to Home'));
    expect(continued, isTrue);
    (registration.auth as _Auth).signIn.completeError(
      FirebaseAuthException(code: 'network-request-failed'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Continue without an account'), findsOneWidget);
  });

  testWidgets('password recovery uses the sign-in email without a password', (
    tester,
  ) async {
    final registration = _Registration(signedIn: false);
    await open(tester, registration);
    await tester.enterText(
      find.byType(TextField).first,
      'student@example.test',
    );
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    expect((registration.auth as _Auth).resetEmail, 'student@example.test');
    expect(find.textContaining('password reset link'), findsOneWidget);
    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();
    expect(find.text('Create a DNSC account'), findsOneWidget);
    expect(find.text('Forgot password?'), findsNothing);
  });

  testWidgets('submission can finish after first-run Home opens', (
    tester,
  ) async {
    var firstRunDone = false;
    final registration = _Registration()
      ..draft = {
        'displayName': 'Test Student',
        'studentNumber': '2026-1234',
        'courseYear': 'BSIT 1',
      };
    final secrets = InMemorySecretValueStore();
    final identity = await DeviceIdentityStore(
      secretStore: secrets,
    ).loadOrCreate();
    final signing = await DeviceSigningIdentityStore(
      secretStore: secrets,
    ).loadOrCreate();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localPeerProvider.overrideWith(
            (ref) async => const Peer(
              id: 'this-phone',
              name: 'Test',
              type: PeerType.civilian,
              isConnected: false,
            ),
          ),
          deviceCryptoIdentityProvider.overrideWith((ref) async => identity),
          deviceSigningIdentityProvider.overrideWith((ref) async => signing),
        ],
        child: MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              return firstRunDone
                  ? const Scaffold(body: Text('SOS Home'))
                  : PilotRegistrationPage(
                      openRegistration: () async => registration,
                      onContinue: () => setState(() => firstRunDone = true),
                    );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final submit = find.text('Submit for review');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pump();
    await tester.runAsync(
      () => registration.submissionStarted.future.timeout(
        const Duration(seconds: 5),
      ),
    );
    expect(registration.draft['submitted'], isFalse);
    await tester.tap(find.text('Continue to Home'));
    await tester.pumpAndSettle();
    expect(find.text('SOS Home'), findsOneWidget);
    registration.submission.complete();
    await tester.pump();
    expect(registration.draft['submitted'], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('registration can retry after initialization fails', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: PilotRegistrationPage(
            openRegistration: () async {
              if (++attempts == 1) throw StateError('Unavailable');
              return _Registration(signedIn: false);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to DNSC'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('Profile keeps typed contact details after a failed save', (
    tester,
  ) async {
    final registration = _Registration()
      ..online = _application('published')
      ..failUpdate = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          registrationMatchesPhoneProvider(
            'this-phone',
          ).overrideWith((ref) async => true),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProfileSection(
                active: true,
                access: const DeviceAccessProfile(
                  deviceId: 'this-phone',
                  level: DeviceAccessLevel.civilian,
                ),
                openRegistration: () async => registration,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal details'));
    await tester.pumpAndSettle();
    final edit = find.text('Edit phone and address');
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final address = find.widgetWithText(TextFormField, 'Address');
    await tester.enterText(address, 'Updated address');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not save your changes'), findsOneWidget);
    expect(find.text('Updated address'), findsOneWidget);
    registration.failUpdate = false;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(registration.savedChanges?['address'], 'Updated address');
    expect(find.text('Contact details saved.'), findsOneWidget);
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
    expect(find.textContaining('Last known status'), findsOneWidget);
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
      find.textContaining('this phone needs approval again'),
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
