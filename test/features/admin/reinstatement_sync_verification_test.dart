import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/hosted_publisher_client.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/domain/services/device_access_resolver.dart';

import '../../support/signed_trust_bundle_fixture.dart';

class _NoopReviewApi extends RegistrationReviewApi {
  _NoopReviewApi()
    : super(
        Uri.https(
          'firestore.googleapis.com',
          '/v1/projects/test/databases/(default)/documents/pilotApplications',
        ),
      );

  @override
  Future<List<ReviewApplication>> list(String token) async => const [];

  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async => const [];

  @override
  Future<({int version, String bundle, String updateTime})?> readDirectory(
    String token,
  ) async => null;
}

class _ReinstatementPublisher extends HostedPublisherClient {
  _ReinstatementPublisher({
    required this.signer,
    required this.returnRevokedInsteadOfApproved,
    required this.deviceId,
    required this.publicKey,
    required this.signingPublicKey,
    required this.keyVersion,
  }) : super(endpoint: Uri.parse('https://admin.test/api/publish-approval'));

  final TestTrustBundleSigner signer;
  bool returnRevokedInsteadOfApproved;
  final String deviceId;
  final String publicKey;
  final String signingPublicKey;
  final int keyVersion;
  final List<Map<String, Object?>> payloads = [];

  @override
  Future<HostedPublishResult> publishDecision({
    required String token,
    required Map<String, Object?> payload,
  }) async {
    payloads.add(payload);
    final entry = TrustedDevice(
      deviceId: deviceId,
      ownerName: 'Reinstate Student',
      role: 'civilian',
      status: returnRevokedInsteadOfApproved ? 'revoked' : 'approved',
      publicKey: publicKey,
      signingPublicKey: signingPublicKey,
      keyVersion: keyVersion,
      updatedAt: DateTime.utc(2026, 11, 26, 12),
    );
    final bundleJson = await signer.sign(
      bundleVersion: returnRevokedInsteadOfApproved ? 2 : 3,
      issuedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
      directoryProject: 'dnsc-pilot',
      approvedDevices: returnRevokedInsteadOfApproved ? const [] : [entry],
      revokedDevices: returnRevokedInsteadOfApproved ? [entry] : const [],
    );
    return HostedPublishResult(
      status: 'published',
      version: returnRevokedInsteadOfApproved ? 2 : 3,
      bundle: bundleJson,
      registrationId: payload['registrationId'] as String?,
      decisionId: payload['decisionId'] as String,
      idempotent: false,
    );
  }
}

class _InMemorySyncRegistry implements DesktopAdminRegistryRepository {
  _InMemorySyncRegistry(this.registrations, this.pendingSync);

  final List<CampusRegistration> registrations;
  final List<PendingSyncOperation> pendingSync;
  TrustBundle? lastSavedRoster;
  String? lastSavedRawBundle;

  @override
  Future<List<CampusRegistration>> loadRegistrations() async =>
      List.of(registrations);

  @override
  Future<List<PendingSyncOperation>> loadPendingSync() async =>
      List.of(pendingSync);

  @override
  Future<ReviewerProfile?> loadReviewerProfile() async =>
      const ReviewerProfile(uid: 'admin-1', email: 'admin@dnsc.edu.ph');

  @override
  Future<void> saveLastPublishedRoster(
    TrustBundle bundle,
    String rawJson,
  ) async {
    lastSavedRoster = bundle;
    lastSavedRawBundle = rawJson;
  }

  @override
  Future<void> saveRegistration(
    CampusRegistration registration, {
    PendingSyncOperation? pendingSync,
    bool removePendingForRegistration = false,
    bool syncDeviceList = true,
  }) async {
    final idx = registrations.indexWhere(
      (r) => r.registrationId == registration.registrationId,
    );
    if (idx >= 0) registrations[idx] = registration;
    if (removePendingForRegistration) {
      this.pendingSync.removeWhere(
        (op) => op.registrationId == registration.registrationId,
      );
    }
  }

  @override
  Future<void> removePendingSync(String decisionId) async {
    pendingSync.removeWhere((op) => op.decisionId == decisionId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'sync keeps pending reinstatement until returned bundle confirms approved device',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final signer = await TestTrustBundleSigner.create();
      final pub = base64UrlEncode(List.filled(32, 11));
      final sign = base64UrlEncode(List.filled(32, 12));
      final reg = CampusRegistration(
        registrationId: 'reg-r4-ui',
        source: CampusRegistrationSource.qr,
        status: CampusRegistrationStatus.approvedLocal,
        syncState: CampusSyncState.waitingToSync,
        resolvedConflictVersion: 2,
        accountUid: 'uid-r4-ui',
        identity: const CampusIdentityFields(
          affiliation: CampusAffiliation.student,
          displayName: 'Reinstate Student',
          studentNumber: '2026-4402',
          course: 'BSIT',
          yearLevel: '3',
          sectionSet: 'A',
        ),
        role: RegisteredDeviceRole.civilian,
        activePhone: RegistrationPhoneBinding(
          deviceId: 'phone-r4-ui',
          publicKey: pub,
          signingPublicKey: sign,
          keyVersion: 2,
          deviceRegistrationJson: '{"synthetic":"qr-r4"}',
        ),
        createdAt: DateTime.utc(2026, 11, 26),
        updatedAt: DateTime.utc(2026, 11, 26),
      );
      final op = PendingSyncOperation(
        decisionId: 'dec-r4-ui',
        registrationId: 'reg-r4-ui',
        kind: PendingSyncKind.publishRevocationCorrection,
        payloadJson: jsonEncode({
          'decision_id': 'dec-r4-ui',
          'resolved_conflict_version': 2,
        }),
        createdAt: DateTime.utc(2026, 11, 26),
      );
      final registry = _InMemorySyncRegistry([reg], [op]);
      final publisher = _ReinstatementPublisher(
        signer: signer,
        returnRevokedInsteadOfApproved: true,
        deviceId: 'phone-r4-ui',
        publicKey: pub,
        signingPublicKey: sign,
        keyVersion: 2,
      );

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: Scaffold(
            body: UnifiedRegistrationsWorkspace(
              registry: registry,
              reviewApi: _NoopReviewApi(),
              publisherClient: publisher,
              initialSessionForTesting: (
                token: 'tok',
                uid: 'admin-1',
                email: 'admin@dnsc.edu.ph',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // First attempt returns device in revokedDevices: must fail and retain pending op.
      await tester.tap(find.text('Sync 1 pending'));
      await tester.pumpAndSettle();

      expect(publisher.payloads, hasLength(1));
      expect(publisher.payloads.single['targetStatus'], 'published');
      expect(publisher.payloads.single['overrideConflict'], isTrue);
      expect(publisher.payloads.single['expectedConflictVersion'], 2);
      expect(registry.pendingSync, hasLength(1));
      expect(
        registry.registrations.single.status,
        CampusRegistrationStatus.approvedLocal,
      );
      expect(registry.lastSavedRoster, isNull);
      expect(
        find.textContaining('did not confirm approval of phone-r4-ui'),
        findsOneWidget,
      );

      // Second attempt returns device in approvedDevices: confirms and drains pending op.
      publisher.returnRevokedInsteadOfApproved = false;
      await tester.tap(find.text('Sync 1 pending'));
      await tester.pumpAndSettle();

      expect(publisher.payloads, hasLength(2));
      expect(registry.pendingSync, isEmpty);
      expect(
        registry.registrations.single.status,
        CampusRegistrationStatus.published,
      );
      expect(registry.registrations.single.syncState, CampusSyncState.synced);
      expect(
        registry.lastSavedRoster?.approvedDevices.map((d) => d.deviceId),
        contains('phone-r4-ui'),
      );

      final phoneStore = TrustBundleStore();
      await phoneStore.importBundleJson(
        registry.lastSavedRawBundle!,
        directoryProject: 'dnsc-pilot',
        issuerFingerprint: sha256.convert(signer.publicKeyBytes).toString(),
      );
      final imported = await phoneStore.loadBundle();
      expect(imported, isNotNull);
      final access = const DeviceAccessResolver().resolve(
        deviceId: 'phone-r4-ui',
        publicKey: pub,
        signingPublicKey: sign,
        keyVersion: 2,
        bundle: imported!,
      );
      expect(access.level, DeviceAccessLevel.civilian);
      expect(access.isApproved, isTrue);
    },
  );
}
