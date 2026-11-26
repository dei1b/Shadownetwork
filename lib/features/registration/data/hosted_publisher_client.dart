import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../trust/domain/entities/trust_bundle.dart';

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
    Map<String, dynamic>? decoded;
    try {
      final raw = jsonDecode(response.body);
      if (raw is Map<String, dynamic>) {
        decoded = raw;
      } else if (raw is Map) {
        decoded = Map<String, dynamic>.from(raw);
      }
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        decoded == null ||
        decoded['ok'] != true) {
      final message = decoded?['error'] as String? ??
          'Could not publish approval (HTTP ${response.statusCode}).';
      throw StateError(message);
    }

    final action = (payload['action'] as String? ?? '').trim();
    final sentDecisionId = (payload['decisionId'] as String? ?? '').trim();
    final responseDecisionId = (decoded['decisionId'] as String? ?? '').trim();
    if (responseDecisionId.isEmpty ||
        (sentDecisionId.isNotEmpty && responseDecisionId != sentDecisionId)) {
      throw StateError('Hosted publisher returned a mismatched decisionId.');
    }

    final responseStatus = (decoded['status'] as String? ?? '').trim();
    final expectedStatus = switch (action) {
      'request_changes' => 'changes_requested',
      'reject' || 'decline_profile_change' => 'rejected',
      'approve_online' ||
      'sync_offline_decision' ||
      'approve_link' ||
      'approve_replacement' ||
      'approve_recovery' ||
      'approve_profile_change' =>
        'published',
      _ => null,
    };
    if (responseStatus.isEmpty ||
        (expectedStatus != null && responseStatus != expectedStatus)) {
      throw StateError(
        'Hosted publisher returned an unexpected status ($responseStatus).',
      );
    }

    final version = decoded['version'];
    final bundle = decoded['bundle'] as String?;
    if (responseStatus == 'published') {
      if (version is! int || version <= 0 || bundle == null || bundle.trim().isEmpty) {
        throw StateError(
          'Hosted publisher did not return a published trust directory version and bundle.',
        );
      }
      final TrustBundle parsedBundle;
      try {
        parsedBundle = TrustBundle.fromJsonString(bundle);
      } on FormatException catch (error) {
        throw StateError(
          'Hosted publisher returned an invalid trust bundle: ${error.message}',
        );
      }
      if (!parsedBundle.isSignedVersion || parsedBundle.bundleVersion != version) {
        throw StateError(
          'Hosted publisher returned an unsigned or version-mismatched trust bundle.',
        );
      }
    } else if (version is! int || version < 0) {
      throw StateError('Hosted publisher returned an invalid directory version.');
    }

    return HostedPublishResult(
      status: responseStatus,
      version: version,
      bundle: bundle,
      registrationId: decoded['registrationId'] as String?,
      decisionId: responseDecisionId,
      idempotent: decoded['idempotent'] == true,
    );
  }
}
