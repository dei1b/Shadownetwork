import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/registration/data/pilot_registration.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/registration/presentation/pilot_registration_page.dart';
import 'package:shadownetwork/features/registration/presentation/profile_section.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/approval_receipt.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/presentation/providers/device_access_provider.dart';

import 'support/signed_trust_bundle_fixture.dart';

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
  ReviewApplication? linkRequest;
  AccountLinkProof? submittedLinkProof;
  ReviewApplication? recoveryRequest;
  Map<String, dynamic>? submittedRecovery;
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
  Future<ReviewApplication?> readLinkRequest(User user) async => linkRequest;

  @override
  Future<void> submitLinkRequest(User user, AccountLinkProof proof) async {
    submittedLinkProof = proof;
    linkRequest = ReviewApplication.fromCache(
      id: user.uid,
      updateTime: 'link-1',
      fields: {
        'registrationId': proof.registrationId,
        'accountUid': user.uid,
        'status': 'pending',
      },
    );
  }

  @override
  Future<ReviewApplication?> readRecoveryRequest(User user) async =>
      recoveryRequest;

  @override
  Future<void> submitRecoveryRequest(
    User user, {
    required CampusAffiliation affiliation,
    required String schoolId,
    required String displayName,
    required String deviceRegistrationJson,
  }) async {
    submittedRecovery = {
      'affiliation': affiliation.name,
      'schoolId': schoolId,
      'displayName': displayName,
      'deviceRegistration': deviceRegistrationJson,
    };
    recoveryRequest = ReviewApplication.fromCache(
      id: user.uid,
      updateTime: 'rec-1',
      fields: {
        'schoolId': schoolId,
        'displayName': displayName,
        'status': 'submitted',
      },
    );
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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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
    final submit = find.byKey(const ValueKey('auth-submit-button'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
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
    final submit = find.byKey(const ValueKey('auth-submit-button'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
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
    await tester.tap(find.byKey(const ValueKey('auth-mode-signup')));
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
      final course = find.widgetWithText(TextField, 'Course (required)');
      final year = find.widgetWithText(TextField, 'Year (required)');
      final section = find.widgetWithText(TextField, 'Set (required)');
      await submitDetails();
      expectFocused(name);
      expect(tester.widget<TextField>(name).decoration!.errorText, isNotNull);
      expect(tester.widget<TextField>(number).decoration!.errorText, isNotNull);
      expect(tester.widget<TextField>(course).decoration!.errorText, isNotNull);
      expect(tester.widget<TextField>(year).decoration!.errorText, isNotNull);
      expect(tester.widget<TextField>(section).decoration!.errorText, isNotNull);
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
      await tester.enterText(course, 'BSIT');
      await tester.pumpAndSettle();
      await submitDetails();
      expectFocused(year);
      await tester.enterText(year, 'Year 4');
      await tester.pumpAndSettle();
      await submitDetails();
      expectFocused(section);
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

  testWidgets('Profile renders offline access and account states at 200% text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final registration = _Registration()
      ..cached = _application('changes_requested')
      ..offline = true;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ProfileSection(
                active: true,
                access: const DeviceAccessProfile(
                  deviceId: 'this-phone',
                  level: DeviceAccessLevel.responder,
                  ownerName: 'Test Responder',
                ),
                openRegistration: () async => registration,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This phone’s offline access'), findsOneWidget);
    expect(find.textContaining('DNSC Responder'), findsOneWidget);
    expect(find.textContaining('Last known · Changes requested'), findsOneWidget);
    expect(find.text('Update application'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching to Staff affiliation swaps required fields', (
    tester,
  ) async {
    final registration = _Registration()..draft = {};
    await open(tester, registration);
    expect(find.widgetWithText(TextField, 'Student number (required)'), findsOneWidget);
    await tester.tap(find.text('Staff'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Employee ID (required)'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Unit or office (required)'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Student number (required)'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline receipt enables Link this phone and transitions to waiting for sync', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final registration = _Registration()..draft = {};
    final signer = await TestTrustBundleSigner.create();
    const peer = Peer(
      id: 'this-phone',
      name: 'this-phone',
      type: PeerType.civilian,
      isConnected: false,
    );
    final secrets = InMemorySecretValueStore();
    final crypto = await DeviceIdentityStore(
      secretStore: secrets,
    ).loadOrCreate();
    final signing = await DeviceSigningIdentityStore(
      secretStore: secrets,
    ).loadOrCreate();
    final now = DateTime.now().toUtc();
    final receipt = await SignedApprovalReceipt.createSigned(
      registrationId: 'reg-qr-99',
      deviceId: peer.id,
      publicKey: crypto.encodedPublicKey,
      signingPublicKey: signing.encodedPublicKey,
      keyVersion: crypto.keyVersion,
      issuer: TrustBundleIssuer(
        issuerId: signer.issuerId,
        signingKeyId: 'k1',
        signatureAlgorithm: 'ed25519',
        publicKey: base64UrlEncode(signer.publicKeyBytes),
      ),
      issuerKeyPair: signer.keyPair as SimpleKeyPair,
      issuedAt: now,
      expiresAt: now.add(const Duration(days: 30)),
    );
    final store = TrustBundleStore();
    await store.saveReceipt(receipt);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localPeerProvider.overrideWith((ref) async => peer),
          deviceCryptoIdentityProvider.overrideWith((ref) async => crypto),
          deviceSigningIdentityProvider.overrideWith((ref) async => signing),
          trustBundleStoreProvider.overrideWithValue(store),
          deviceAccessProfileProvider.overrideWith(
            (ref) async => const DeviceAccessProfile(
              deviceId: 'this-phone',
              level: DeviceAccessLevel.civilian,
            ),
          ),
        ],
        child: MaterialApp(
          home: PilotRegistrationPage(openRegistration: () async => registration),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final linkButton = find.widgetWithText(
      FilledButton,
      'Link this phone to my account',
    );
    expect(linkButton, findsOneWidget);
    await tester.ensureVisible(linkButton);
    await tester.tap(linkButton);
    await tester.pumpAndSettle();

    expect(registration.submittedLinkProof, isNotNull);
    expect(registration.submittedLinkProof!.registrationId, 'reg-qr-99');
    expect(find.text('Waiting for campus sync · Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recovery form submits name, school ID, and signed device keys', (
    tester,
  ) async {
    final registration = _Registration()..draft = {};
    const peer = Peer(
      id: 'this-phone',
      name: 'this-phone',
      type: PeerType.civilian,
      isConnected: false,
    );
    final secrets = InMemorySecretValueStore();
    final crypto = await DeviceIdentityStore(
      secretStore: secrets,
    ).loadOrCreate();
    final signing = await DeviceSigningIdentityStore(
      secretStore: secrets,
    ).loadOrCreate();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localPeerProvider.overrideWith((ref) async => peer),
          deviceCryptoIdentityProvider.overrideWith((ref) async => crypto),
          deviceSigningIdentityProvider.overrideWith((ref) async => signing),
          deviceAccessProfileProvider.overrideWith(
            (ref) async => const DeviceAccessProfile(
              deviceId: 'this-phone',
              level: DeviceAccessLevel.civilian,
            ),
          ),
        ],
        child: MaterialApp(
          home: PilotRegistrationPage(openRegistration: () async => registration),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final openRecovery = find.text('Recover registration');
    await tester.ensureVisible(openRecovery);
    await tester.tap(openRecovery);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Full name'),
      'Juan Dela Cruz',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Student number'),
      '2026-4455',
    );
    final submitRecovery = find.text('Submit recovery request');
    await tester.ensureVisible(submitRecovery);
    await tester.tap(submitRecovery);
    await tester.pumpAndSettle();

    expect(registration.submittedRecovery, isNotNull);
    expect(registration.submittedRecovery!['schoolId'], '2026-4455');
    expect(find.textContaining('Recovery request sent'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
