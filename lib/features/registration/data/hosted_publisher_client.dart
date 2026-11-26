import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const hostedPublisherUrl = String.fromEnvironment('DNSC_PUBLISHER_URL');

class HostedPublishResult {
  const HostedPublishResult({
    required this.status,
    required this.version,
    required this.decisionId,
    required this.idempotent,
    this.bundle,
    this.registrationId,
  });

  final String status;
  final int version;
  final String? bundle;
  final String? registrationId;
  final String decisionId;
  final bool idempotent;
}

class HostedPublisherClient {
  HostedPublisherClient({
    Uri? endpoint,
    http.Client? client,
  }) : _endpoint = endpoint ?? _resolveDefaultEndpoint(),
       _client = client ?? http.Client();

  factory HostedPublisherClient.live({http.Client? client}) =>
      HostedPublisherClient(client: client);

  static Uri? _resolveDefaultEndpoint() {
    final configured = hostedPublisherUrl.trim();
    if (configured.isNotEmpty) {
      return Uri.tryParse(configured);
    }
    if (kIsWeb) {
      return Uri(path: '/api/publish-approval');
    }
    return null;
  }

  final Uri? _endpoint;
  final http.Client _client;
  static const timeout = Duration(seconds: 25);

  bool get isConfigured => _endpoint != null;

  Future<HostedPublishResult> publishDecision({
    required String token,
    required Map<String, Object?> payload,
  }) async {
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw StateError(
        'Hosted publisher URL is not configured for this build.',
      );
    }
    final response = await _client
        .post(
          endpoint,
          headers: {
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          },
          body: jsonEncode(payload),
        )
        .timeout(timeout);
    Map<String, dynamic> decoded = {};
    try {
      final raw = jsonDecode(response.body);
      if (raw is Map<String, dynamic>) {
        decoded = raw;
      } else if (raw is Map) {
        decoded = Map<String, dynamic>.from(raw);
      }
    } catch (_) {
      decoded = {};
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        decoded['ok'] == false) {
      final message = decoded['error'] as String? ??
          'Could not publish approval (HTTP ${response.statusCode}).';
      throw StateError(message);
    }
    return HostedPublishResult(
      status: decoded['status'] as String? ?? 'published',
      version: (decoded['version'] as num?)?.toInt() ?? 0,
      bundle: decoded['bundle'] as String?,
      registrationId: decoded['registrationId'] as String?,
      decisionId:
          decoded['decisionId'] as String? ??
          (payload['decisionId'] as String? ?? ''),
      idempotent: decoded['idempotent'] == true,
    );
  }
}
