import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'registration_review_api.dart';

const pilotRegistrationHost = String.fromEnvironment('DNSC_EMULATOR_HOST');
const liveRegistrationProject = String.fromEnvironment('DNSC_FIREBASE_PROJECT');
bool get pilotRegistrationIsLive =>
    liveRegistrationProject.isNotEmpty && pilotRegistrationHost.isEmpty;
bool get pilotRegistrationEnabled =>
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.android &&
    (pilotRegistrationIsLive ||
        (kDebugMode &&
            const ['10.0.2.2', '127.0.0.1'].contains(pilotRegistrationHost)));

class PilotRegistration {
  PilotRegistration(
    this.auth, {
    String host = pilotRegistrationHost,
    String? liveProject,
  }) : _host = host,
       _liveProject = liveProject;

  static const _project = 'demo-shadownetwork-dnsc';
  final FirebaseAuth auth;
  final String _host;
  final String? _liveProject;
  static Future<PilotRegistration>? _instance;

  static Future<PilotRegistration> open() => _instance ??= _connect();

  static Future<PilotRegistration> _connect() async {
    if (pilotRegistrationIsLive) {
      final options = Firebase.app().options;
      if (options.projectId != liveRegistrationProject) {
        throw StateError('The Firebase project does not match this build.');
      }
      final app = await Firebase.initializeApp(
        name: 'dnsc-live',
        options: options,
      );
      return PilotRegistration(
        FirebaseAuth.instanceFor(app: app),
        liveProject: options.projectId,
      );
    }
    final app = await Firebase.initializeApp(
      name: 'dnsc-pilot',
      options: const FirebaseOptions(
        apiKey: 'demo-key',
        appId: '1:1234567890:android:0123456789abcdef',
        messagingSenderId: '1234567890',
        projectId: _project,
      ),
    );
    final auth = FirebaseAuth.instanceFor(app: app);
    await auth.useAuthEmulator(
      pilotRegistrationHost,
      9099,
      automaticHostMapping: false,
    );
    return PilotRegistration(auth);
  }

  Future<File> _draftFile(String uid, {String kind = 'draft'}) async {
    final directory = await getApplicationSupportDirectory();
    return File(
      '${directory.path}/dnsc-$kind-${_liveProject == null ? '' : '${Uri.encodeComponent(_liveProject)}-'}${Uri.encodeComponent(uid)}.json',
    );
  }

  Future<Map<String, dynamic>> loadDraft(String uid) async {
    final file = await _draftFile(uid);
    if (!await file.exists()) return {};
    return Map<String, dynamic>.from(
      jsonDecode(await file.readAsString()) as Map,
    );
  }

  Future<void> saveDraft(String uid, Map<String, dynamic> draft) async {
    final file = await _draftFile(uid);
    await _writeLocal(file, draft);
  }

  Future<void> _writeLocal(File file, Map<String, dynamic> data) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename(file.path);
  }

  Uri get _collection {
    final firestore = _liveProject == null
        ? 'http://$_host:8080'
        : 'https://firestore.googleapis.com';
    return Uri.parse(
      '$firestore/v1/projects/${_liveProject ?? _project}/databases/(default)/documents/pilotApplications',
    );
  }

  Future<ReviewApplication?> readStatus(User user) async {
    final token = await user.getIdToken();
    if (token == null) throw StateError('Sign in again to check registration.');
    return RegistrationReviewApi(_collection).get(token, user.uid);
  }

  Future<ReviewApplication?> readCachedProfile(User user) async {
    final file = await _draftFile(user.uid, kind: 'profile');
    if (!await file.exists()) return null;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return ReviewApplication.fromCache(
      id: user.uid,
      updateTime: data['updateTime'] as String,
      fields: data['fields'] as Map<String, dynamic>,
    );
  }

  Future<ReviewApplication?> refreshProfile(User user) async {
    final application = await readStatus(user);
    final file = await _draftFile(user.uid, kind: 'profile');
    if (application == null) {
      if (await file.exists()) await file.delete();
    } else {
      await _writeLocal(file, {
        'updateTime': application.updateTime,
        'fields': application.fields,
      });
    }
    return application;
  }

  Future<void> updateProfile(
    User user,
    ReviewApplication application,
    Map<String, dynamic> changes,
  ) async {
    final token = await user.getIdToken();
    if (token == null) throw StateError('Sign in again before saving.');
    await RegistrationReviewApi(
      _collection,
    ).update(token, application, changes);
  }

  Future<void> resubmit(
    User user,
    ReviewApplication application,
    Map<String, String> details,
  ) async {
    final token = await user.getIdToken();
    if (token == null) throw StateError('Sign in again before submitting.');
    await RegistrationReviewApi(_collection).update(token, application, {
      ...details,
      'status': 'submitted',
      'revision': application.nextRevision,
    });
    try {
      final cached = await _draftFile(user.uid, kind: 'profile');
      if (await cached.exists()) await cached.delete();
    } on FileSystemException {
      // The server accepted the correction. A cache error cannot undo it.
    }
  }

  Future<void> submit(User user, Map<String, String> details) async {
    final token = await user.getIdToken();
    if (token == null) throw StateError('Sign in again before submitting.');
    final collection = _collection.toString();
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final response = await http
        .post(
          Uri.parse('$collection?documentId=${Uri.encodeComponent(user.uid)}'),
          headers: headers,
          body: jsonEncode({
            'fields': details.map(
              (key, value) => MapEntry(key, {'stringValue': value}),
            ),
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 200) return;
    if (response.statusCode == 409) {
      final existing = await http
          .get(
            Uri.parse('$collection/${Uri.encodeComponent(user.uid)}'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 20));
      if (existing.statusCode == 200) {
        final fields = (jsonDecode(existing.body) as Map)['fields'] as Map;
        if (details.entries.every(
          (entry) => (fields[entry.key] as Map?)?['stringValue'] == entry.value,
        )) {
          return;
        }
      }
    }
    throw StateError(
      'Submission could not be confirmed. Retry from the saved draft.',
    );
  }
}
