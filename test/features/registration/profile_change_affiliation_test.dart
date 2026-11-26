import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/registration/data/pilot_registration.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/presentation/pilot_registration_page.dart';
import 'package:shadownetwork/features/registration/presentation/profile_section.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';

class _User extends Fake implements User {
  @override
  String get uid => 'user-prof-aff';

  @override
  String get email => 'staff@dnsc.edu.ph';
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => _User();
}

class _AffRegistration extends PilotRegistration {
  _AffRegistration(this.serverApp) : super(_Auth());

  ReviewApplication? serverApp;
  Map<String, dynamic>? savedChanges;

  @override
  Future<Map<String, dynamic>> loadDraft(String uid) async => const {};

  @override
  Future<ReviewApplication?> readCachedProfile(User user) async => null;

  @override
  Future<ReviewApplication?> refreshProfile(User user) async => serverApp;

  @override
  Future<void> updateProfile(
    User user,
    ReviewApplication application,
    Map<String, dynamic> changes,
  ) async {
    savedChanges = changes;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'staff identity edit shows Employee ID and Unit or office and submits canonical staff profileChange',
    (tester) async {
      final staffApp = ReviewApplication.fromCache(
        id: 'user-prof-aff',
        updateTime: 'rev-1',
        fields: {
          'affiliation': 'staff',
          'displayName': 'Staff Officer',
          'employeeId': 'EMP-200',
          'unit': 'DRRMO',
          'status': 'published',
          'deviceRegistration': 'phone-staff-1',
        },
      );
      final reg = _AffRegistration(staffApp);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationMatchesPhoneProvider(
              'phone-staff-1',
            ).overrideWith((ref) async => true),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProfileSection(
                  active: true,
                  access: const DeviceAccessProfile(
                    deviceId: 'phone-staff-1',
                    level: DeviceAccessLevel.responder,
                  ),
                  openRegistration: () async => reg,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Personal details'));
      await tester.pumpAndSettle();
      final editBtn = find.text('Request an identity change');
      await tester.ensureVisible(editBtn);
      await tester.tap(editBtn);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'Employee ID'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Unit or office'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Student number'), findsNothing);
      expect(find.widgetWithText(TextFormField, 'Course'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Unit or office'),
        'Campus Safety Ops',
      );
      await tester.pump();
      await tester.tap(find.text('Send for review'));
      await tester.pumpAndSettle();

      final profileChange = reg.savedChanges?['profileChange'] as Map?;
      expect(profileChange, isNotNull);
      expect(profileChange!['affiliation'], 'staff');
      expect(profileChange['employeeId'], 'EMP-200');
      expect(profileChange['unit'], 'Campus Safety Ops');
      expect(profileChange['status'], 'submitted');
    },
  );

  testWidgets(
    'student identity edit shows Student number, Course, Year, Set and computes courseYear',
    (tester) async {
      final studentApp = ReviewApplication.fromCache(
        id: 'user-prof-aff',
        updateTime: 'rev-1',
        fields: {
          'affiliation': 'student',
          'displayName': 'Student Member',
          'studentNumber': '2026-3001',
          'course': 'BSIT',
          'yearLevel': '3',
          'sectionSet': 'A',
          'status': 'published',
          'deviceRegistration': 'phone-stu-1',
        },
      );
      final reg = _AffRegistration(studentApp);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            registrationMatchesPhoneProvider(
              'phone-stu-1',
            ).overrideWith((ref) async => true),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProfileSection(
                  active: true,
                  access: const DeviceAccessProfile(
                    deviceId: 'phone-stu-1',
                    level: DeviceAccessLevel.civilian,
                  ),
                  openRegistration: () async => reg,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Personal details'));
      await tester.pumpAndSettle();
      final editBtn = find.text('Request an identity change');
      await tester.ensureVisible(editBtn);
      await tester.tap(editBtn);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'Student number'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Course'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Year'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Set'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Employee ID'), findsNothing);

      await tester.enterText(find.widgetWithText(TextFormField, 'Year'), '4');
      await tester.pump();
      await tester.tap(find.text('Send for review'));
      await tester.pumpAndSettle();

      final profileChange = reg.savedChanges?['profileChange'] as Map?;
      expect(profileChange, isNotNull);
      expect(profileChange!['affiliation'], 'student');
      expect(profileChange['yearLevel'], '4');
      expect(profileChange['courseYear'], 'BSIT · Year 4 · Set A');
      expect(profileChange['status'], 'submitted');
    },
  );
}
