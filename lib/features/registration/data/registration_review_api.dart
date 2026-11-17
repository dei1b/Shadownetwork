import 'dart:convert';

import 'package:http/http.dart' as http;

const reviewProject = String.fromEnvironment('DNSC_FIREBASE_PROJECT');
const reviewApiKey = String.fromEnvironment('DNSC_FIREBASE_API_KEY');

class ReviewApplication {
  ReviewApplication(Map<String, dynamic> document)
    : id = (document['name'] as String).split('/').last,
      updateTime = document['updateTime'] as String,
      fields = (document['fields'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, _decode(value as Map)),
      );

  final String id;
  final String updateTime;
  final Map<String, dynamic> fields;
  String get status => fields['status'] as String;
  int get nextRevision => (fields['revision'] as int? ?? 0) + 1;
  List<dynamic> get history => fields['reviewHistory'] as List? ?? [];

  static dynamic _decode(Map value) {
    if (value.containsKey('stringValue')) return value['stringValue'];
    if (value.containsKey('integerValue')) {
      return int.parse(value['integerValue'].toString());
    }
    if (value.containsKey('arrayValue')) {
      final values = value['arrayValue']['values'] as List? ?? [];
      return values.map((item) => _decode(item as Map)).toList();
    }
    if (value.containsKey('mapValue')) {
      return (value['mapValue']['fields'] as Map).map(
        (key, item) => MapEntry(key, _decode(item as Map)),
      );
    }
    return null;
  }
}

class RegistrationReviewApi {
  RegistrationReviewApi(this.collection);
  final Uri collection;
  static const timeout = Duration(seconds: 20);

  factory RegistrationReviewApi.live() => RegistrationReviewApi(
    Uri.https(
      'firestore.googleapis.com',
      '/v1/projects/$reviewProject/databases/(default)/documents/pilotApplications',
    ),
  );

  static Future<({String token, String uid})> signIn(
    String email,
    String password,
  ) async {
    final response = await http
        .post(
          Uri.https(
            'identitytoolkit.googleapis.com',
            '/v1/accounts:signInWithPassword',
            {'key': reviewApiKey},
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
  }) => update(token, application, {
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
      },
    ],
  });

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

  Future<({int version, String bundle})?> readDirectory(String token) async {
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
    final fields = (jsonDecode(response.body) as Map)['fields'] as Map;
    return (
      version: int.parse(fields['version']['integerValue'].toString()),
      bundle: fields['bundle']['stringValue'] as String,
    );
  }

  Future<void> publish(
    String token,
    ReviewApplication application,
    int version,
    String bundle,
  ) async {
    final path = '$_databasePath/documents';
    final response = await http
        .post(
          collection.replace(path: '/v1/$path:commit'),
          headers: _headers(token),
          body: jsonEncode({
            'writes': [
              {
                'update': {
                  'name': '$path/pilotApplications/${application.id}',
                  'fields': {
                    'status': _encode('published'),
                    'publicationStatus': _encode('published'),
                  },
                },
                'updateMask': {
                  'fieldPaths': ['status', 'publicationStatus'],
                },
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
              },
            ],
          }),
        )
        .timeout(timeout);
    _check(response);
  }

  static Map<String, dynamic> _encode(dynamic value) {
    if (value is String) return {'stringValue': value};
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
