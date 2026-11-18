import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shadownetwork/features/registration/data/pilot_registration.dart';

class _Auth extends Fake implements FirebaseAuth {}

class _Student extends Fake implements User {
  @override
  String get uid => 'student';

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => 'test-token';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a failed resubmission retains the cached correction', () async {
    final directory = await Directory.systemTemp.createTemp('dnscreview');
    addTearDown(() => directory.delete(recursive: true));
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => directory.path,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
    final registration = PilotRegistration(_Auth(), host: '127.0.0.1');
    final student = _Student();

    await http.runWithClient(
      () async {
        final correction = (await registration.refreshProfile(student))!;
        await expectLater(
          registration.resubmit(student, correction, {
            'displayName': 'Updated',
          }),
          throwsStateError,
        );
        expect(
          (await registration.readCachedProfile(student))?.status,
          'changes_requested',
        );
      },
      () => MockClient((request) async {
        if (request.method == 'POST') return http.Response('', 503);
        return http.Response(
          jsonEncode({
            'name': 'pilotApplications/student',
            'updateTime': 'test-revision',
            'fields': {
              'status': {'stringValue': 'changes_requested'},
            },
          }),
          200,
        );
      }),
    );
  });

  test('retry confirms an existing matching application', () async {
    final details = {'displayName': 'Student', 'status': 'submitted'};
    var writes = 0;
    await http.runWithClient(
      () => PilotRegistration(
        _Auth(),
        host: '127.0.0.1',
      ).submit(_Student(), details),
      () => MockClient((request) async {
        expect(request.url.port, 8080);
        if (request.method == 'POST') {
          writes++;
          return http.Response('', 409);
        }
        return http.Response(
          jsonEncode({
            'fields': details.map(
              (key, value) => MapEntry(key, {'stringValue': value}),
            ),
          }),
          200,
        );
      }),
    );
    expect(writes, 1);
  });
}
