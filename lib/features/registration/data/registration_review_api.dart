import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../admin/domain/entities/campus_registration.dart';

const reviewProject = String.fromEnvironment('DNSC_FIREBASE_PROJECT');
const reviewApiKey = String.fromEnvironment('DNSC_FIREBASE_API_KEY');

class ReviewApplication {
  ReviewApplication(Map<String, dynamic> document)
    : id = (document['name'] as String).split('/').last,
      updateTime = document['updateTime'] as String,
      fields = (document['fields'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, _decode(value as Map)),
      );

  ReviewApplication.fromCache({
    required this.id,
    required this.updateTime,
    required this.fields,
  });

  final String id;
  final String updateTime;
  final Map<String, dynamic> fields;
  String get status => fields['status'] as String;
  int get nextRevision => (fields['revision'] as int? ?? 0) + 1;
  List<dynamic> get history => fields['reviewHistory'] as List? ?? [];
  Map<String, dynamic>? get profileChange {
    final value = fields['profileChange'];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  static dynamic _decode(Map value) {
    if (value.containsKey('stringValue')) return value['stringValue'];
    if (value.containsKey('booleanValue')) return value['booleanValue'];
    if (value.containsKey('timestampValue')) return value['timestampValue'];
    if (value.containsKey('integerValue')) {
      return int.parse(value['integerValue'].toString());
    }
    if (value.containsKey('arrayValue')) {
      final values = value['arrayValue']['values'] as List? ?? [];
      return values.map((item) => _decode(item as Map)).toList();
    }
    if (value.containsKey('mapValue')) {
      final fields = value['mapValue']['fields'] as Map? ?? const {};
      return fields.map(
        (key, item) => MapEntry(key, _decode(item as Map)),
      );
    }
    return null;
  }
}

class RegistrationReviewApi {
  RegistrationReviewApi(this.collection, {http.Client? client})
    : _client = client;
  final Uri collection;
  final http.Client? _client;
  static const timeout = Duration(seconds: 20);

  static bool isConfiguredFor({
    String project = reviewProject,
    String apiKey = reviewApiKey,
  }) => project.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  static bool get isConfigured => isConfiguredFor();

  factory RegistrationReviewApi.live() => RegistrationReviewApi(
    Uri.https(
      'firestore.googleapis.com',
      '/v1/projects/$reviewProject/databases/(default)/documents/pilotApplications',
    ),
  );

  static Future<({String token, String uid})> signIn(
    String email,
    String password, {
    String? project,
    String? apiKey,
  }) async {
    final effectiveProject = project ?? reviewProject;
    final effectiveApiKey = apiKey ?? reviewApiKey;
    if (!isConfiguredFor(project: effectiveProject, apiKey: effectiveApiKey)) {
      throw StateError(
        'Firebase reviewer configuration (DNSC_FIREBASE_PROJECT / DNSC_FIREBASE_API_KEY) is missing from this build.',
      );
    }
    final response = await http
        .post(
          Uri.https(
            'identitytoolkit.googleapis.com',
            '/v1/accounts:signInWithPassword',
            {'key': effectiveApiKey},
          ),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': email,
            'password': password,
            'returnSecureToken': true,
          }),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError('Sign-in failed. Check your email and password.');
    }
    final data = jsonDecode(response.body) as Map;
    return (token: data['idToken'] as String, uid: data['localId'] as String);
  }

  Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  void _check(http.Response response) {
    if (response.statusCode == 200) return;
    if (response.statusCode == 401) {
      throw StateError('Session expired. Sign in again.');
    }
    if (response.statusCode == 403) {
      throw StateError('This account cannot perform that action.');
    }
    if (response.statusCode == 409 || response.statusCode == 412) {
      throw StateError('The application changed. Refresh before trying again.');
    }
    throw StateError(
      'Firebase request failed (${response.statusCode}). Try again.',
    );
  }

  Future<List<ReviewApplication>> list(String token) async {
    final documents = <ReviewApplication>[];
    String? page;
    do {
      final response = await http
          .get(
            collection.replace(
              queryParameters: {'pageSize': '100', 'pageToken': ?page},
            ),
            headers: _headers(token),
          )
          .timeout(timeout);
      _check(response);
      final data = jsonDecode(response.body) as Map;
      documents.addAll(
        (data['documents'] as List? ?? []).map(
          (item) => ReviewApplication(Map<String, dynamic>.from(item as Map)),
        ),
      );
      page = data['nextPageToken'] as String?;
    } while (page != null && page.isNotEmpty);
    return documents;
  }

  Future<ReviewApplication?> get(String token, String uid) async {
    final response = await http
        .get(
          collection.replace(pathSegments: [...collection.pathSegments, uid]),
          headers: _headers(token),
        )
        .timeout(timeout);
    if (response.statusCode == 404) return null;
    _check(response);
    return ReviewApplication(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> decide(
    String token,
    String reviewer,
    ReviewApplication application,
    String status,
    String reason, {
    String? role,
    Map<String, dynamic>? reviewedFields,
    String? registrationId,
    String? decisionId,
    List<String>? editedFields,
  }) => update(token, application, {
    ...?reviewedFields,
    'registrationId': ?registrationId,
    'status': status,
    'revision': application.nextRevision,
    'publicationStatus': status == 'approved_pending_publication'
        ? 'pending'
        : 'none',
    'reviewHistory': [
      ...application.history,
      {
        'reviewerUid': reviewer,
        'status': status,
        'reason': reason,
        'revision': application.nextRevision,
        'role': ?role,
        'decisionId': ?decisionId,
        'editedFields': ?editedFields,
      },
    ],
  });

  Uri _collectionUri(String name) => collection.replace(
    path: '/v1/$_databasePath/documents/$name',
  );

  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async {
    final documents = <ReviewApplication>[];
    String? page;
    final uri = _collectionUri(name);
    do {
      final response = await http
          .get(
            uri.replace(
              queryParameters: {'pageSize': '100', 'pageToken': ?page},
            ),
            headers: _headers(token),
          )
          .timeout(timeout);
      _check(response);
      final data = jsonDecode(response.body) as Map;
      documents.addAll(
        (data['documents'] as List? ?? []).map(
          (item) => ReviewApplication(Map<String, dynamic>.from(item as Map)),
        ),
      );
      page = data['nextPageToken'] as String?;
    } while (page != null && page.isNotEmpty);
    return documents;
  }

  Future<ReviewApplication?> getDocument(
    String token,
    String name,
    String docId,
  ) async {
    final uri = _collectionUri('$name/$docId');
    final response = await http.get(uri, headers: _headers(token)).timeout(
      timeout,
    );
    if (response.statusCode == 404) return null;
    _check(response);
    return ReviewApplication(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> upsertDocument(
    String token,
    String name,
    String docId,
    Map<String, dynamic> fields, {
    String? updateTime,
  }) async {
    final path = '$_databasePath/documents';
    final response = await http
        .post(
          collection.replace(path: '/v1/$path:commit'),
          headers: _headers(token),
          body: jsonEncode({
            'writes': [
              {
                'update': {
                  'name': '$path/$name/$docId',
                  'fields': fields.map(
                    (key, value) => MapEntry(key, _encode(value)),
                  ),
                },
                if (updateTime != null)
                  'currentDocument': {'updateTime': updateTime},
              },
            ],
          }),
        )
        .timeout(timeout);
    _check(response);
  }

  Future<void> commitWrites(
    String token,
    List<Map<String, dynamic>> writes,
  ) async {
    final path = '$_databasePath/documents';
    final response = await http
        .post(
          collection.replace(path: '/v1/$path:commit'),
          headers: _headers(token),
          body: jsonEncode({'writes': writes}),
        )
        .timeout(timeout);
    _check(response);
  }

  String get documentPrefix => '$_databasePath/documents';

  Map<String, dynamic> directoryWrite({
    String? applicationUid,
    String? registrationId,
    required int version,
    required String bundle,
    required String? directoryUpdateTime,
  }) {
    final path = documentPrefix;
    return {
      'update': {
        'name': '$path/trustDirectory/current',
        'fields': {
          if (applicationUid != null && applicationUid.isNotEmpty)
            'applicationUid': _encode(applicationUid),
          if (registrationId != null && registrationId.isNotEmpty)
            'registrationId': _encode(registrationId),
          'version': _encode(version),
          'bundle': _encode(bundle),
        },
      },
      'updateTransforms': [
        {
          'fieldPath': 'publishedAt',
          'setToServerValue': 'REQUEST_TIME',
        },
      ],
      'currentDocument': directoryUpdateTime == null
          ? {'exists': false}
          : {'updateTime': directoryUpdateTime},
    };
  }

  Future<void> publishCampusRegistration(
    String token, {
    required CampusRegistration registration,
    required int version,
    required String bundle,
    required String? directoryUpdateTime,
    String? remoteRegistrationUpdateTime,
  }) async {
    final path = documentPrefix;
    final fields = _campusRegistrationFields(registration);
    await commitWrites(token, [
      {
        'update': {
          'name': '$path/campusRegistrations/${registration.registrationId}',
          'fields': fields.map((key, value) => MapEntry(key, _encode(value))),
        },
        if (remoteRegistrationUpdateTime != null)
          'currentDocument': {'updateTime': remoteRegistrationUpdateTime},
      },
      directoryWrite(
        registrationId: registration.registrationId,
        applicationUid: registration.accountUid,
        version: version,
        bundle: bundle,
        directoryUpdateTime: directoryUpdateTime,
      ),
    ]);
  }

  static Map<String, dynamic> _campusRegistrationFields(
    CampusRegistration reg,
  ) => {
    'registrationId': reg.registrationId,
    'source': reg.source.name,
    'status': reg.status.code,
    'role': reg.role.name,
    'revision': reg.revision,
    if (reg.accountUid != null && reg.accountUid!.isNotEmpty)
      'accountUid': reg.accountUid!,
    if (reg.pendingDecisionId != null) 'decisionId': reg.pendingDecisionId!,
    ...reg.identity.toFirestoreFields(),
    if (reg.activePhone.deviceRegistrationJson != null)
      'deviceRegistration': reg.activePhone.deviceRegistrationJson!,
    'deviceId': reg.activePhone.deviceId,
    if (reg.activePhone.publicKey != null &&
        reg.activePhone.publicKey!.isNotEmpty)
      'publicKey': reg.activePhone.publicKey!,
    if (reg.activePhone.signingPublicKey != null &&
        reg.activePhone.signingPublicKey!.isNotEmpty)
      'signingPublicKey': reg.activePhone.signingPublicKey!,
    'keyVersion': reg.activePhone.keyVersion,
    'reviewHistory': reg.reviewHistory
        .map(
          (entry) => {
            'decisionId': entry.decisionId,
            'reviewerUid': entry.reviewerUid,
            'status': entry.status,
            'reason': entry.reason,
            'revision': entry.revision,
            if (entry.role != null) 'role': entry.role!,
          },
        )
        .toList(),
  };

  Future<void> completeAccountLink(
    String token, {
    required String reviewerUid,
    required CampusRegistration registration,
    required ReviewApplication linkRequest,
    required ReviewApplication? existingApplication,
    required int version,
    required String bundle,
    required String? directoryUpdateTime,
    String? remoteRegistrationUpdateTime,
  }) async {
    final path = documentPrefix;
    final uid = linkRequest.id;
    final deviceRegJson = registration.activePhone.deviceRegistrationJson ?? '';
    final appFields = {
      ...registration.identity.toFirestoreFields(),
      'registrationId': registration.registrationId,
      'deviceRegistration': deviceRegJson,
      'status': 'published',
      'publicationStatus': 'published',
      'revision': registration.revision,
      'reviewHistory': [
        for (final entry in registration.reviewHistory)
          {
            'reviewerUid': entry.reviewerUid,
            'status': 'approved_pending_publication',
            'reason': entry.reason,
            'revision': entry.revision,
            if (entry.role != null) 'role': entry.role!,
          },
      ],
    };
    final regFields = _campusRegistrationFields(registration);
    await commitWrites(token, [
      {
        'update': {
          'name': '$path/registrationLinkRequests/$uid',
          'fields': {
            ...linkRequest.fields,
            'status': 'linked',
            'reviewerUid': reviewerUid,
          }.map((key, value) => MapEntry(key, _encode(value))),
        },
        'currentDocument': {'updateTime': linkRequest.updateTime},
      },
      {
        'update': {
          'name': '$path/campusRegistrations/${registration.registrationId}',
          'fields': regFields.map((key, value) => MapEntry(key, _encode(value))),
        },
        if (remoteRegistrationUpdateTime != null)
          'currentDocument': {'updateTime': remoteRegistrationUpdateTime},
      },
      {
        'update': {
          'name': '$path/pilotApplications/$uid',
          'fields': appFields.map((key, value) => MapEntry(key, _encode(value))),
        },
        'currentDocument': existingApplication == null
            ? {'exists': false}
            : {'updateTime': existingApplication.updateTime},
      },
      directoryWrite(
        applicationUid: uid,
        registrationId: registration.registrationId,
        version: version,
        bundle: bundle,
        directoryUpdateTime: directoryUpdateTime,
      ),
    ]);
  }

  Future<void> approveRecoveryAndPublish(
    String token, {
    required String reviewerUid,
    required String verificationMethod,
    required CampusRegistration registration,
    required ReviewApplication recoveryRequest,
    required ReviewApplication? existingApplication,
    required String newDeviceRegistrationJson,
    required int version,
    required String bundle,
    required String? directoryUpdateTime,
    String? remoteRegistrationUpdateTime,
  }) async {
    final path = documentPrefix;
    final uid = recoveryRequest.id;
    final appFields = {
      ...registration.identity.toFirestoreFields(),
      'registrationId': registration.registrationId,
      'deviceRegistration': newDeviceRegistrationJson,
      'status': 'published',
      'publicationStatus': 'published',
      'revision': registration.revision,
    };
    final regFields = _campusRegistrationFields(registration);
    await commitWrites(token, [
      {
        'update': {
          'name': '$path/registrationRecoveryRequests/$uid',
          'fields': {
            ...recoveryRequest.fields,
            'status': 'published',
            'reviewerUid': reviewerUid,
            'verificationMethod': verificationMethod,
            'registrationId': registration.registrationId,
          }.map((key, value) => MapEntry(key, _encode(value))),
        },
        'currentDocument': {'updateTime': recoveryRequest.updateTime},
      },
      {
        'update': {
          'name': '$path/campusRegistrations/${registration.registrationId}',
          'fields': regFields.map((key, value) => MapEntry(key, _encode(value))),
        },
        if (remoteRegistrationUpdateTime != null)
          'currentDocument': {'updateTime': remoteRegistrationUpdateTime},
      },
      {
        'update': {
          'name': '$path/pilotApplications/$uid',
          'fields': appFields.map((key, value) => MapEntry(key, _encode(value))),
        },
        'currentDocument': existingApplication == null
            ? {'exists': false}
            : {'updateTime': existingApplication.updateTime},
      },
      directoryWrite(
        applicationUid: uid,
        registrationId: registration.registrationId,
        version: version,
        bundle: bundle,
        directoryUpdateTime: directoryUpdateTime,
      ),
    ]);
  }

  Future<void> publishPhoneReplacement(
    String token, {
    required ReviewApplication application,
    required CampusRegistration registration,
    required String newDeviceRegistrationJson,
    required int version,
    required String bundle,
    required String? directoryUpdateTime,
    String? remoteRegistrationUpdateTime,
  }) async {
    final path = documentPrefix;
    final req = application.fields['replacementRequest'] as Map? ?? const {};
    await commitWrites(token, [
      {
        'update': {
          'name': '$path/pilotApplications/${application.id}',
          'fields': {
            'deviceRegistration': newDeviceRegistrationJson,
            'registrationId': registration.registrationId,
            'replacementRequest': {...req, 'status': 'published'},
          }.map((key, value) => MapEntry(key, _encode(value))),
        },
        'updateMask': {
          'fieldPaths': [
            'deviceRegistration',
            'registrationId',
            'replacementRequest',
          ],
        },
        'currentDocument': {'updateTime': application.updateTime},
      },
      {
        'update': {
          'name': '$path/campusRegistrations/${registration.registrationId}',
          'fields': _campusRegistrationFields(
            registration,
          ).map((key, value) => MapEntry(key, _encode(value))),
        },
        if (remoteRegistrationUpdateTime != null)
          'currentDocument': {'updateTime': remoteRegistrationUpdateTime},
      },
      directoryWrite(
        applicationUid: application.id,
        registrationId: registration.registrationId,
        version: version,
        bundle: bundle,
        directoryUpdateTime: directoryUpdateTime,
      ),
    ]);
  }

  Future<void> update(
    String token,
    ReviewApplication application,
    Map<String, dynamic> changes,
  ) async {
    final response = await http
        .post(
          collection.replace(
            pathSegments: [
              ...collection.pathSegments
                  .take(collection.pathSegments.length - 1)
                  .takeWhile((segment) => segment != 'documents'),
              'documents:commit',
            ],
          ),
          headers: _headers(token),
          body: jsonEncode({
            'writes': [
              {
                'update': {
                  'name': [
                    ...collection.pathSegments.skip(1),
                    application.id,
                  ].join('/'),
                  'fields': changes.map(
                    (key, value) => MapEntry(key, _encode(value)),
                  ),
                },
                'updateMask': {'fieldPaths': changes.keys.toList()},
                'currentDocument': {'updateTime': application.updateTime},
              },
            ],
          }),
        )
        .timeout(timeout);
    _check(response);
  }

  String get _databasePath => collection.pathSegments.skip(1).take(4).join('/');

  Future<({int version, String bundle, String updateTime})?> readDirectory(
    String token,
  ) async {
    final response = await http
        .get(
          collection.replace(
            path: '/v1/$_databasePath/documents/trustDirectory/current',
          ),
          headers: _headers(token),
        )
        .timeout(timeout);
    if (response.statusCode == 404) return null;
    _check(response);
    final document = jsonDecode(response.body) as Map;
    final fields = document['fields'] as Map;
    return (
      version: int.parse(fields['version']['integerValue'].toString()),
      bundle: fields['bundle']['stringValue'] as String,
      updateTime: document['updateTime'] as String,
    );
  }

  Future<void> reviewProfileChange(
    String token,
    ReviewApplication application, {
    required String status,
    required String reviewerUid,
    String? reason,
  }) async {
    final change = application.profileChange;
    if (change == null) {
      throw StateError('No pending profile change found.');
    }
    final nextChange = <String, dynamic>{
      ...change,
      'status': status,
      'reviewerUid': reviewerUid,
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    };
    await update(token, application, {'profileChange': nextChange});
  }

  Future<void> publish(
    String token,
    ReviewApplication application,
    int version,
    String bundle, {
    required String? directoryUpdateTime,
    String? reviewerUid,
  }) async {
    final change = application.profileChange;
    const identityKeys = [
      'displayName',
      'affiliation',
      'studentNumber',
      'course',
      'yearLevel',
      'sectionSet',
      'courseYear',
      'employeeId',
      'unit',
    ];
    final existingReviewerUid = change?['reviewerUid'] as String?;
    final effectiveReviewerUid =
        change?['status'] == 'approved_pending_publication' &&
                existingReviewerUid != null &&
                existingReviewerUid.trim().isNotEmpty
            ? existingReviewerUid
            : reviewerUid;
    final changes =
        application.status == 'published' &&
            change != null &&
            (change['status'] == 'submitted' ||
                change['status'] == 'approved_pending_publication')
        ? <String, dynamic>{
            for (final key in identityKeys)
              if (change.containsKey(key) && change[key] != null)
                key: change[key],
            'profileChange': {
              ...change,
              'status': 'published',
              if (effectiveReviewerUid != null &&
                  effectiveReviewerUid.trim().isNotEmpty)
                'reviewerUid': effectiveReviewerUid,
            },
          }
        : <String, dynamic>{
            'status': 'published',
            'publicationStatus': 'published',
          };
    final path = '$_databasePath/documents';
    final uri = collection.replace(path: '/v1/$path:commit');
    final headers = _headers(token);
    final body = jsonEncode({
      'writes': [
        {
          'update': {
            'name': '$path/pilotApplications/${application.id}',
            'fields': changes.map(
              (key, value) => MapEntry(key, _encode(value)),
            ),
          },
          'updateMask': {'fieldPaths': changes.keys.toList()},
          'currentDocument': {'updateTime': application.updateTime},
        },
        {
          'update': {
            'name': '$path/trustDirectory/current',
            'fields': {
              'applicationUid': _encode(application.id),
              'version': _encode(version),
              'bundle': _encode(bundle),
            },
          },
          'updateTransforms': [
            {
              'fieldPath': 'publishedAt',
              'setToServerValue': 'REQUEST_TIME',
            },
          ],
          'currentDocument': directoryUpdateTime == null
              ? {'exists': false}
              : {'updateTime': directoryUpdateTime},
        },
      ],
    });
    final response =
        await (_client != null
                ? _client.post(uri, headers: headers, body: body)
                : http.post(uri, headers: headers, body: body))
            .timeout(timeout);
    _check(response);
  }

  static Map<String, dynamic> _encode(dynamic value) {
    if (value is String) return {'stringValue': value};
    if (value is bool) return {'booleanValue': value};
    if (value is int) return {'integerValue': '$value'};
    if (value is List) {
      return {
        'arrayValue': {'values': value.map(_encode).toList()},
      };
    }
    if (value is Map) {
      return {
        'mapValue': {
          'fields': value.map((key, item) => MapEntry(key, _encode(item))),
        },
      };
    }
    throw ArgumentError('Unsupported registration field.');
  }
}
