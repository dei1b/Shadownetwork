import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/registration/data/pilot_registration.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/presentation/pilot_registration_page.dart';
import 'package:shadownetwork/features/registration/presentation/profile_section.dart';
import 'package:shadownetwork/features/trust/data/services/trust_directory_sync_service.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';

class _User extends Fake implements User {
  @override
  String get uid => 'student';
  @override
  String get email => 'student@example.test';
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => _User();
}

class _Registration extends PilotRegistration {
  _Registration() : super(_Auth());
  @override
  Future<Map<String, dynamic>> loadDraft(String uid) async => {};
  @override
  Future<ReviewApplication?> readCachedProfile(User user) async => null;
  @override
  Future<ReviewApplication?> refreshProfile(User user) async =>
      ReviewApplication.fromCache(
        id: 'student',
        updateTime: '1',
        fields: {
          'displayName': 'Student',
          'status': 'published',
          'deviceRegistration': 'phone',
        },
      );
}

class _Sync extends TrustDirectorySyncService {
  _Sync(super.ref);
  @override
  Future<void> refresh() async => throw const FormatException(
    'Trust bundle was signed by a different administrator key.',
  );
}

void main() {
  testWidgets(
    'approval validation failure is not mislabeled as a network failure',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationMatchesPhoneProvider(
              'phone',
            ).overrideWith((ref) async => true),
            trustDirectorySyncProvider.overrideWith(_Sync.new),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProfileSection(
                  active: true,
                  access: const DeviceAccessProfile(
                    deviceId: 'phone',
                    level: DeviceAccessLevel.unregistered,
                  ),
                  openRegistration: () async => _Registration(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Activate this phone'));
      await tester.tap(find.text('Activate this phone'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('signed by a different administrator key'),
        findsOneWidget,
      );
      expect(
        find.text('Could not reach DNSC. Check your connection and try again.'),
        findsNothing,
      );
    },
  );
}
