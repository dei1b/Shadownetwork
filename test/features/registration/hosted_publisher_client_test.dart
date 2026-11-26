import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shadownetwork/features/registration/data/hosted_publisher_client.dart';

import '../../support/signed_trust_bundle_fixture.dart';

void main() {
  test('HostedPublisherClient rejects malformed 2xx payloads and requires signed bundle for published actions', () async {
    final signer = await TestTrustBundleSigner.create();
    final validBundle = await signer.sign(
      bundleVersion: 3,
      issuedAt: DateTime.utc(2026, 11, 26, 12),
      directoryProject: 'dnsc-pilot',
    );

    HostedPublisherClient clientWith(http.Response Function(http.Request) fn) {
      return HostedPublisherClient(
        endpoint: Uri.parse('https://admin.test/api/publish-approval'),
        client: MockClient((request) async => fn(request)),
      );
    }

    // Empty 204
    await expectLater(
      clientWith((_) => http.Response('', 204)).publishDecision(
        token: 'tok',
        payload: {'action': 'approve_online', 'decisionId': 'dec-1'},
      ),
      throwsStateError,
    );

    // 200 HTML page
    await expectLater(
      clientWith((_) => http.Response('<html><body>Error</body></html>', 200))
          .publishDecision(
        token: 'tok',
        payload: {'action': 'approve_online', 'decisionId': 'dec-1'},
      ),
      throwsStateError,
    );

    // 200 missing ok: true
    await expectLater(
      clientWith(
        (_) => http.Response(
          jsonEncode({
            'status': 'published',
            'version': 3,
            'bundle': validBundle,
            'decisionId': 'dec-1',
          }),
          200,
        ),
      ).publishDecision(
        token: 'tok',
        payload: {'action': 'approve_online', 'decisionId': 'dec-1'},
      ),
      throwsStateError,
    );

    // Mismatched decisionId
    await expectLater(
      clientWith(
        (_) => http.Response(
          jsonEncode({
            'ok': true,
            'status': 'published',
            'version': 3,
            'bundle': validBundle,
            'decisionId': 'dec-other',
          }),
          200,
        ),
      ).publishDecision(
        token: 'tok',
        payload: {'action': 'approve_online', 'decisionId': 'dec-1'},
      ),
      throwsStateError,
    );

    // version <= 0 or invalid bundle on published response
    await expectLater(
      clientWith(
        (_) => http.Response(
          jsonEncode({
            'ok': true,
            'status': 'published',
            'version': 0,
            'bundle': '{}',
            'decisionId': 'dec-1',
          }),
          200,
        ),
      ).publishDecision(
        token: 'tok',
        payload: {'action': 'approve_online', 'decisionId': 'dec-1'},
      ),
      throwsStateError,
    );

    // Unsigned legacy bundle rejected
    await expectLater(
      clientWith(
        (_) => http.Response(
          jsonEncode({
            'ok': true,
            'status': 'published',
            'version': 3,
            'bundle': '{"schema_version":1,"bundle_version":3}',
            'decisionId': 'dec-1',
          }),
          200,
        ),
      ).publishDecision(
        token: 'tok',
        payload: {'action': 'approve_online', 'decisionId': 'dec-1'},
      ),
      throwsStateError,
    );

    // Valid non-publishing action (changes_requested) succeeds without bundle
    final reqChangesRes = await clientWith(
      (_) => http.Response(
        jsonEncode({
          'ok': true,
          'status': 'changes_requested',
          'version': 2,
          'bundle': null,
          'decisionId': 'dec-corr-1',
          'idempotent': false,
        }),
        200,
      ),
    ).publishDecision(
      token: 'tok',
      payload: {'action': 'request_changes', 'decisionId': 'dec-corr-1'},
    );
    expect(reqChangesRes.status, 'changes_requested');
    expect(reqChangesRes.version, 2);

    // Valid publishing action with signed v3 TrustBundle succeeds
    final okRes = await clientWith(
      (_) => http.Response(
        jsonEncode({
          'ok': true,
          'status': 'published',
          'version': 3,
          'bundle': validBundle,
          'decisionId': 'dec-1',
          'idempotent': false,
        }),
        200,
      ),
    ).publishDecision(
      token: 'tok',
      payload: {'action': 'approve_online', 'decisionId': 'dec-1'},
    );
    expect(okRes.version, 3);
    expect(okRes.status, 'published');
    expect(okRes.bundle, validBundle);
  });
}
