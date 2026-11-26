import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/hosted_publisher_client.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

import '../../support/signed_trust_bundle_fixture.dart';

class _MemKeys implements AdminSigningKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}

class _FakeFallbackReviewApi extends RegistrationReviewApi {
  _FakeFallbackReviewApi({
    required this.initialDirectoryBundle,
    required this.initialDirectoryVersion,
  }) : super(
         Uri.https(
           'firestore.googleapis.com',
           '/v1/projects/test/databases/(default)/documents/pilotApplications',
         ),
       ) {
    _bundle = initialDirectoryBundle;
    _version = initialDirectoryVersion;
  }

  final String initialDirectoryBundle;
  final int initialDirectoryVersion;
  late String _bundle;
  late int _version;
  String _updateTime = '2026-11-26T10:00:00Z';
  String? publishedBundleJson;
  int? publishedVersion;

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
  ) async => (version: _version, bundle: _bundle, updateTime: _updateTime);

  @override
  Future<void> publishCampusRegistration(
    String token, {
    required CampusRegistration registration,
    required int version,
    required String bundle,
    required String? directoryUpdateTime,
    String? remoteRegistrationUpdateTime,
  }) async {
    publishedVersion = version;
    publishedBundleJson = bundle;
    _version = version;
    _bundle = bundle;
    _updateTime = '2026-11-26T10:05:00Z';
  }
}

class _InMemoryMergeRegistry implements DesktopAdminRegistryRepository {
  _InMemoryMergeRegistry({
    required this.signer,
    required this.registrations,
    required this.pendingSync,
  });

  final TestTrustBundleSigner signer;
  final List<CampusRegistration> registrations;
  final List<PendingSyncOperation> pendingSync;
  int mergeCalls = 0;

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
  Future<void> saveReviewerProfile(ReviewerProfile profile) async {}

  @override
  Future<void> saveLastPublishedRoster(
    TrustBundle bundle,
    String rawJson,
  ) async {}

  @override
  Future<List<CampusRegistration>> reconcileWithPublishedRoster(
    TrustBundle published,
    String project,
  ) async => List.of(registrations);

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
    if (idx >= 0) {
      registrations[idx] = registration;
    } else {
      registrations.add(registration);
    }
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
  Future<String> buildMergedTrustBundleJson({
    required TrustBundle? publishedBundle,
    required List<RegisteredDevice> localChanges,
    String? directoryProject,
    int minimumPreviousVersion = 0,
  }) async {
    mergeCalls++;
    final approved = <TrustedDevice>[
      ...?publishedBundle?.approvedDevices,
      for (final d in localChanges.where(
        (c) => c.status == RegisteredDeviceStatus.approved,
      ))
        TrustedDevice(
          deviceId: d.deviceId,
          ownerName: d.ownerName,
          role: d.role.name,
          status: 'approved',
          updatedAt: d.updatedAt,
          publicKey: d.publicKey,
          signingPublicKey: d.signingPublicKey,
          keyVersion: d.keyVersion,
        ),
    ];
    final revoked = <TrustedDevice>[
      ...?publishedBundle?.revokedDevices,
      for (final d in localChanges.where(
        (c) => c.status == RegisteredDeviceStatus.revoked,
      ))
        TrustedDevice(
          deviceId: d.deviceId,
          ownerName: d.ownerName,
          role: d.role.name,
          status: 'revoked',
          updatedAt: d.updatedAt,
          publicKey: d.publicKey,
          signingPublicKey: d.signingPublicKey,
          keyVersion: d.keyVersion,
        ),
    ];
    final nextVersion =
        (publishedBundle?.bundleVersion ?? minimumPreviousVersion) + 1;
    return signer.sign(
      bundleVersion: nextVersion,
      issuedAt: DateTime.utc(2026, 11, 26, 10),
      approvedDevices: approved,
      revokedDevices: revoked,
      directoryProject: directoryProject,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RegisteredDevice _makeDevice(
  String id,
  String name,
  RegisteredDeviceStatus status,
) {
  final now = DateTime.utc(2026, 11, 26, 9);
  return RegisteredDevice(
    deviceId: id,
    ownerName: name,
    role: status == RegisteredDeviceStatus.revoked
        ? RegisteredDeviceRole.civilian
        : RegisteredDeviceRole.responder,
    status: status,
    registeredAt: now,
    updatedAt: now,
    lastSeenLabel: 'Test',
    publicKey: base64UrlEncode(List.filled(32, id.hashCode & 0xff)),
    signingPublicKey: base64UrlEncode(
      List.filled(32, (id.hashCode + 7) & 0xff),
    ),
    keyVersion: 1,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SQLite buildMergedTrustBundleJson retains remote-only approved and revoked phones',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('fallback-merge-unit-');
      final db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
      try {
        final repo = DesktopAdminRegistryRepository(
          database: db,
          keyStore: _MemKeys(),
        );
        await repo.initializeIdentity();

        final remoteBundleJson = await repo.buildTrustBundleJson(
          [
            _makeDevice(
              'remote-approved-a',
              'Remote Approved A',
              RegisteredDeviceStatus.approved,
            ),
            _makeDevice(
              'remote-revoked-b',
              'Remote Revoked B',
              RegisteredDeviceStatus.revoked,
            ),
          ],
          directoryProject: reviewProject,
          minimumPreviousVersion: 4,
        );
        final remoteBundle = TrustBundle.fromJsonString(remoteBundleJson);
        final localDevice = _makeDevice(
          'local-phone-c',
          'Local Student C',
          RegisteredDeviceStatus.approved,
        );
        final mergedJson = await repo.buildMergedTrustBundleJson(
          publishedBundle: remoteBundle,
          localChanges: [localDevice],
          directoryProject: reviewProject,
          minimumPreviousVersion: remoteBundle.bundleVersion,
        );
        final merged = TrustBundle.fromJsonString(mergedJson);
        expect(merged.bundleVersion, greaterThan(remoteBundle.bundleVersion));
        expect(
          merged.approvedDevices.map((d) => d.deviceId).toSet(),
          {'remote-approved-a', 'local-phone-c'},
        );
        expect(
          merged.revokedDevices.map((d) => d.deviceId).toSet(),
          {'remote-revoked-b'},
        );
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'Windows fallback sync uses buildMergedTrustBundleJson and retains remote-only devices',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final signer = await TestTrustBundleSigner.create();
      final remoteBundleJson = await signer.sign(
        bundleVersion: 2,
        issuedAt: DateTime.utc(2026, 11, 26, 9),
        approvedDevices: [
          TrustedDevice(
            deviceId: 'remote-approved-a',
            ownerName: 'Remote Approved A',
            role: 'responder',
            status: 'approved',
            updatedAt: DateTime.utc(2026, 11, 26, 9),
            publicKey: base64UrlEncode(List.filled(32, 31)),
            signingPublicKey: base64UrlEncode(List.filled(32, 32)),
            keyVersion: 1,
          ),
        ],
        revokedDevices: [
          TrustedDevice(
            deviceId: 'remote-revoked-b',
            ownerName: 'Remote Revoked B',
            role: 'civilian',
            status: 'revoked',
            updatedAt: DateTime.utc(2026, 11, 26, 9),
            publicKey: base64UrlEncode(List.filled(32, 33)),
            signingPublicKey: base64UrlEncode(List.filled(32, 34)),
            keyVersion: 1,
          ),
        ],
      );
      final localReg = CampusRegistration(
        registrationId: 'reg-local-c',
        source: CampusRegistrationSource.qr,
        status: CampusRegistrationStatus.approvedLocal,
        syncState: CampusSyncState.waitingToSync,
        identity: const CampusIdentityFields(
          affiliation: CampusAffiliation.student,
          displayName: 'Local Student C',
          studentNumber: '2026-3003',
          course: 'BSIT',
          yearLevel: '4',
          sectionSet: 'H',
        ),
        role: RegisteredDeviceRole.civilian,
        activePhone: RegistrationPhoneBinding(
          deviceId: 'local-phone-c',
          publicKey: base64UrlEncode(List.filled(32, 21)),
          signingPublicKey: base64UrlEncode(List.filled(32, 22)),
          keyVersion: 1,
        ),
        createdAt: DateTime.utc(2026, 11, 26),
        updatedAt: DateTime.utc(2026, 11, 26),
      );
      final registry = _InMemoryMergeRegistry(
        signer: signer,
        registrations: [localReg],
        pendingSync: [
          PendingSyncOperation(
            decisionId: 'dec-local-c',
            registrationId: 'reg-local-c',
            kind: PendingSyncKind.publishManual,
            payloadJson: '{}',
            createdAt: DateTime.utc(2026, 11, 26),
          ),
        ],
      );
      final fakeApi = _FakeFallbackReviewApi(
        initialDirectoryBundle: remoteBundleJson,
        initialDirectoryVersion: 2,
      );
      final unconfiguredPublisher = HostedPublisherClient(
        client: MockClient((_) async => http.Response('', 500)),
      );
      expect(unconfiguredPublisher.isConfigured, isFalse);

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: Scaffold(
            body: UnifiedRegistrationsWorkspace(
              registry: registry,
              reviewApi: fakeApi,
              publisherClient: unconfiguredPublisher,
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

      await tester.tap(find.text('Sync 1 pending'));
      await tester.pumpAndSettle();

      expect(registry.mergeCalls, 1);
      expect(fakeApi.publishedVersion, 3);
      final merged = TrustBundle.fromJsonString(fakeApi.publishedBundleJson!);
      expect(
        merged.approvedDevices.map((d) => d.deviceId).toSet(),
        {'remote-approved-a', 'local-phone-c'},
      );
      expect(
        merged.revokedDevices.map((d) => d.deviceId).toSet(),
        {'remote-revoked-b'},
      );
    },
  );
}
