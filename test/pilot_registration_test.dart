import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
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
