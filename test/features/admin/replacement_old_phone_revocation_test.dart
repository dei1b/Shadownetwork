import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/domain/services/device_access_resolver.dart';

class _MemKeys implements AdminSigningKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}

class _InMemoryR2Registry implements DesktopAdminRegistryRepository {
  _InMemoryR2Registry({
    required this.registrations,
    required this.pendingSync,
  });

  final List<CampusRegistration> registrations;
  final List<PendingSyncOperation> pendingSync;

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
  Future<({String bundleJson, CampusRegistration registration})>
  stagePhoneReplacement({
    required CampusRegistration registration,
    required RegistrationPhoneBinding newPhone,
    required ReviewerProfile reviewer,
    required String directoryProject,
    required int previousVersion,
    TrustBundle? publishedBundle,
    String reason = 'Approved phone replacement',
    PendingSyncKind syncKind = PendingSyncKind.publishReplacement,
    String? verificationMethod,
    String? accountUid,
    String? expectedRequestUpdateTime,
  }) async {
    final updated = registration.copyWith(
      status: CampusRegistrationStatus.approvedLocal,
      syncState: CampusSyncState.waitingToSync,
      activePhone: newPhone,
      updatedAt: DateTime.utc(2026, 11, 26, 12),
    );
    return (bundleJson: '{}', registration: updated);
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
  Future<String> buildMergedTrustBundleJson({
    required TrustBundle? publishedBundle,
    required List<RegisteredDevice> localChanges,
    String? directoryProject,
    int minimumPreviousVersion = 0,
  }) async {
    final byId = <String, TrustedDevice>{
      for (final d in publishedBundle?.approvedDevices ?? const <TrustedDevice>[])
        d.deviceId.toLowerCase(): d,
      for (final d in publishedBundle?.revokedDevices ?? const <TrustedDevice>[])
        d.deviceId.toLowerCase(): d,
    };
    for (final c in localChanges) {
      byId[c.deviceId.toLowerCase()] = TrustedDevice(
        deviceId: c.deviceId,
        ownerName: c.ownerName,
        role: c.role.name,
        status: c.status == RegisteredDeviceStatus.revoked
            ? 'revoked'
            : 'approved',
        updatedAt: c.updatedAt,
        publicKey: c.publicKey,
        signingPublicKey: c.signingPublicKey,
        keyVersion: c.keyVersion,
      );
    }
    final all = byId.values.toList();
    return jsonEncode({
      'schema_version': 2,
      'bundle_type': 'shadow_network_device_trust_bundle',
      'bundle_version':
          (publishedBundle?.bundleVersion ?? minimumPreviousVersion) + 1,
      'issued_at': '2026-11-26T12:00:00Z',
      'expires_at': '2026-12-26T12:00:00Z',
      'directory_project': directoryProject ?? 'dnsc-pilot',
      'issuer': {
        'issuer_id': 'shadow-network-admin',
        'signing_key_id': 'k1',
        'signature_algorithm': 'ed25519',
        'public_key': base64UrlEncode(List.filled(32, 1)),
      },
      'approved_devices': [
        for (final d in all.where((e) => e.status == 'approved')) d.toJson(),
      ],
      'revoked_devices': [
        for (final d in all.where((e) => e.status == 'revoked')) d.toJson(),
      ],
      'signature': base64UrlEncode(List.filled(64, 2)),
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CapturingFallbackApi extends RegistrationReviewApi {
  _CapturingFallbackApi({
    required this.initialBundleJson,
    required this.initialVersion,
    required this.applications,
    this.recoveryRequests = const [],
  }) : super(
         Uri.https(
           'firestore.googleapis.com',
           '/v1/projects/test/databases/(default)/documents/pilotApplications',
         ),
       ) {
    _bundle = initialBundleJson;
    _version = initialVersion;
  }

  final String initialBundleJson;
  final int initialVersion;
  final List<ReviewApplication> applications;
  final List<ReviewApplication> recoveryRequests;
  late String _bundle;
  late int _version;
  String? lastPublishedBundle;

  @override
  Future<List<ReviewApplication>> list(String token) async => applications;

  @override
  Future<List<ReviewApplication>> listCollection(
    String token,
    String name,
  ) async {
    if (name == 'registrationRecoveryRequests') return recoveryRequests;
    return const [];
  }

  @override
  Future<ReviewApplication?> get(String token, String uid) async =>
      applications.where((a) => a.id == uid).firstOrNull;

  @override
  Future<ReviewApplication?> getDocument(
    String token,
    String collectionName,
    String docId,
  ) async => null;

  @override
  Future<({int version, String bundle, String updateTime})?> readDirectory(
    String token,
  ) async => (
    version: _version,
    bundle: _bundle,
    updateTime: '2026-11-26T10:00:00Z',
  );

  @override
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
    lastPublishedBundle = bundle;
    _bundle = bundle;
    _version = version;
  }

  @override
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
    lastPublishedBundle = bundle;
    _bundle = bundle;
    _version = version;
  }

  @override
  Future<void> publishCampusRegistration(
    String token, {
    required CampusRegistration registration,
    required int version,
    required String bundle,
    required String? directoryUpdateTime,
    String? remoteRegistrationUpdateTime,
  }) async {
    lastPublishedBundle = bundle;
    _bundle = bundle;
    _version = version;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'R2: Windows stagePhoneReplacement + replacementLocalChanges retires old device ID after reopen and queued sync while preserving unrelated phones',
    () async {
      final dir = await Directory.systemTemp.createTemp('r2-old-phone-revoke-');
      final keys = _MemKeys();
      var db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
      try {
        var repo = DesktopAdminRegistryRepository(
          database: db,
          keyStore: keys,
        );
        await repo.initializeIdentity();

        final secretsOld = InMemorySecretValueStore();
        final cryptoOld = await DeviceIdentityStore(
          secretStore: secretsOld,
        ).loadOrCreate();
        final signingOld = await DeviceSigningIdentityStore(
          secretStore: secretsOld,
        ).loadOrCreate();
        final qrOld = await DeviceRegistrationQr.createSigned(
          deviceId: 'phone-r2-old',
          identity: cryptoOld,
          signingIdentity: signingOld,
        );

        final secretsNew = InMemorySecretValueStore();
        final cryptoNew = await DeviceIdentityStore(
          secretStore: secretsNew,
        ).loadOrCreate();
        final signingNew = await DeviceSigningIdentityStore(
          secretStore: secretsNew,
        ).loadOrCreate();
        final qrNew = await DeviceRegistrationQr.createSigned(
          deviceId: 'phone-r2-new',
          identity: cryptoNew,
          signingIdentity: signingNew,
        );

        final secretsOther = InMemorySecretValueStore();
        final cryptoOther = await DeviceIdentityStore(
          secretStore: secretsOther,
        ).loadOrCreate();
        final signingOther = await DeviceSigningIdentityStore(
          secretStore: secretsOther,
        ).loadOrCreate();
        final qrOther = await DeviceRegistrationQr.createSigned(
          deviceId: 'phone-r2-unrelated',
          identity: cryptoOther,
          signingIdentity: signingOther,
        );

        final oldReg = CampusRegistration(
          registrationId: 'reg-r2-target',
          source: CampusRegistrationSource.online,
          status: CampusRegistrationStatus.published,
          syncState: CampusSyncState.synced,
          accountUid: 'uid-r2-target',
          identity: const CampusIdentityFields(
            affiliation: CampusAffiliation.student,
            displayName: 'Replacement Student',
            studentNumber: '2026-4100',
            course: 'BSIT',
            yearLevel: '3',
            sectionSet: 'A',
          ),
          role: RegisteredDeviceRole.civilian,
          activePhone: RegistrationPhoneBinding(
            deviceId: 'phone-r2-old',
            publicKey: qrOld.publicKey,
            signingPublicKey: qrOld.signingPublicKey,
            keyVersion: 1,
            deviceRegistrationJson: qrOld.toJsonString(),
          ),
          createdAt: DateTime.utc(2026, 11, 26),
          updatedAt: DateTime.utc(2026, 11, 26),
        );
        final unrelatedDevice = RegisteredDevice(
          deviceId: 'phone-r2-unrelated',
          ownerName: 'Unrelated Approved',
          phoneNumber: '',
          address: '',
          role: RegisteredDeviceRole.responder,
          status: RegisteredDeviceStatus.approved,
          registeredAt: DateTime.utc(2026, 11, 26),
          updatedAt: DateTime.utc(2026, 11, 26),
          lastSeenLabel: 'Published',
          publicKey: qrOther.publicKey,
          signingPublicKey: qrOther.signingPublicKey,
          keyVersion: 1,
        );
        final publishedV1Json = await repo.buildTrustBundleJson([
          oldReg.toRegisteredDevice(),
          unrelatedDevice,
        ], directoryProject: 'dnsc-pilot');
        final publishedV1 = TrustBundle.fromJsonString(publishedV1Json);
        expect(publishedV1.bundleVersion, 1);

        final staged = await repo.stagePhoneReplacement(
          registration: oldReg,
          newPhone: RegistrationPhoneBinding(
            deviceId: qrNew.deviceId,
            publicKey: qrNew.publicKey,
            signingPublicKey: qrNew.signingPublicKey,
            keyId: qrNew.keyId,
            keyVersion: qrNew.keyVersion,
            deviceRegistrationJson: qrNew.toJsonString(),
          ),
          reviewer: const ReviewerProfile(
            uid: 'admin-1',
            email: 'admin@dnsc.edu.ph',
          ),
          directoryProject: 'dnsc-pilot',
          previousVersion: 1,
          publishedBundle: publishedV1,
          reason: 'Lost phone',
          syncKind: PendingSyncKind.publishRecovery,
          verificationMethod: 'desk_id_check',
        );

        final stagedBundle = TrustBundle.fromJsonString(staged.bundleJson);
        expect(
          stagedBundle.approvedDevices.map((d) => d.deviceId),
          contains('phone-r2-new'),
        );
        expect(
          stagedBundle.revokedDevices.map((d) => d.deviceId),
          contains('phone-r2-old'),
        );

        // Close and reopen SQLite to prove restart recovery retains old_device_id metadata.
        await db.close();
        db = await openDesktopAdminRegistryDatabase('${dir.path}/reg.sqlite');
        repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);

        final pending = await repo.loadPendingSync();
        expect(pending, hasLength(1));
        final opPayload =
            jsonDecode(pending.single.payloadJson) as Map<String, dynamic>;
        final mergedChanges =
            DesktopAdminRegistryRepository.replacementLocalChanges(
              publishedRegistration: staged.registration.copyWith(
                status: CampusRegistrationStatus.published,
                syncState: CampusSyncState.synced,
              ),
              opPayload: opPayload,
              publishedBundle: publishedV1,
            );
        final mergedJson = await repo.buildMergedTrustBundleJson(
          publishedBundle: publishedV1,
          localChanges: mergedChanges,
          directoryProject: 'dnsc-pilot',
          minimumPreviousVersion: 1,
        );
        final rootFingerprint = sha256
            .convert(
              base64Url.decode(
                TrustBundle.fromJsonString(mergedJson).rootAuthorityIssuer!.publicKey,
              ),
            )
            .toString();
        final verifiedMerged = await TrustBundleStore().importBundleJson(
          mergedJson,
          directoryProject: 'dnsc-pilot',
          issuerFingerprint: rootFingerprint,
        );
        expect(
          verifiedMerged.approvedDevices.map((d) => d.deviceId).toSet(),
          equals({'phone-r2-new', 'phone-r2-unrelated'}),
        );
        expect(
          verifiedMerged.revokedDevices.map((d) => d.deviceId).toSet(),
          equals({'phone-r2-old'}),
        );

        const resolver = DeviceAccessResolver();
        expect(
          resolver
              .resolve(
                deviceId: 'phone-r2-old',
                publicKey: cryptoOld.encodedPublicKey,
                signingPublicKey: signingOld.encodedPublicKey,
                keyVersion: cryptoOld.keyVersion,
                bundle: verifiedMerged,
              )
              .level,
          DeviceAccessLevel.revoked,
        );
        expect(
          resolver
              .resolve(
                deviceId: 'phone-r2-new',
                publicKey: cryptoNew.encodedPublicKey,
                signingPublicKey: signingNew.encodedPublicKey,
                keyVersion: cryptoNew.keyVersion,
                bundle: verifiedMerged,
              )
              .isApproved,
          isTrue,
        );
        expect(
          resolver
              .resolve(
                deviceId: 'phone-r2-unrelated',
                publicKey: cryptoOther.encodedPublicKey,
                signingPublicKey: signingOther.encodedPublicKey,
                keyVersion: cryptoOther.keyVersion,
                bundle: verifiedMerged,
              )
              .isApproved,
          isTrue,
        );
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'R2: immediate Windows fallback replacement and recovery retire old device ID in published bundle',
    (tester) async {
      final secretsOld = InMemorySecretValueStore();
      final cryptoOld = await DeviceIdentityStore(
        secretStore: secretsOld,
      ).loadOrCreate();
      final signingOld = await DeviceSigningIdentityStore(
        secretStore: secretsOld,
      ).loadOrCreate();
      final qrOld = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-ui-old',
        identity: cryptoOld,
        signingIdentity: signingOld,
      );

      final secretsNew = InMemorySecretValueStore();
      final cryptoNew = await DeviceIdentityStore(
        secretStore: secretsNew,
      ).loadOrCreate();
      final signingNew = await DeviceSigningIdentityStore(
        secretStore: secretsNew,
      ).loadOrCreate();
      final qrNew = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-ui-new',
        identity: cryptoNew,
        signingIdentity: signingNew,
      );

      final secretsRecOld = InMemorySecretValueStore();
      final cryptoRecOld = await DeviceIdentityStore(
        secretStore: secretsRecOld,
      ).loadOrCreate();
      final signingRecOld = await DeviceSigningIdentityStore(
        secretStore: secretsRecOld,
      ).loadOrCreate();
      final qrRecOld = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-ui-rec-old',
        identity: cryptoRecOld,
        signingIdentity: signingRecOld,
      );

      final secretsRecNew = InMemorySecretValueStore();
      final cryptoRecNew = await DeviceIdentityStore(
        secretStore: secretsRecNew,
      ).loadOrCreate();
      final signingRecNew = await DeviceSigningIdentityStore(
        secretStore: secretsRecNew,
      ).loadOrCreate();
      final qrRecNew = await DeviceRegistrationQr.createSigned(
        deviceId: 'phone-ui-rec-new',
        identity: cryptoRecNew,
        signingIdentity: signingRecNew,
      );

      final registry = _InMemoryR2Registry(
        registrations: <CampusRegistration>[],
        pendingSync: <PendingSyncOperation>[],
      );
      final v1Json = await registry.buildMergedTrustBundleJson(
        publishedBundle: null,
        localChanges: [
          RegisteredDevice(
            deviceId: 'phone-ui-old',
            ownerName: 'Fallback UI Student',
            phoneNumber: '',
            address: '',
            role: RegisteredDeviceRole.civilian,
            status: RegisteredDeviceStatus.approved,
            registeredAt: DateTime.utc(2026, 11, 26),
            updatedAt: DateTime.utc(2026, 11, 26),
            lastSeenLabel: 'Published',
            publicKey: qrOld.publicKey,
            signingPublicKey: qrOld.signingPublicKey,
            keyVersion: 1,
          ),
          RegisteredDevice(
            deviceId: 'phone-ui-rec-old',
            ownerName: 'Fallback Recovery Student',
            phoneNumber: '',
            address: '',
            role: RegisteredDeviceRole.civilian,
            status: RegisteredDeviceStatus.approved,
            registeredAt: DateTime.utc(2026, 11, 26),
            updatedAt: DateTime.utc(2026, 11, 26),
            lastSeenLabel: 'Published',
            publicKey: qrRecOld.publicKey,
            signingPublicKey: qrRecOld.signingPublicKey,
            keyVersion: 1,
          ),
          RegisteredDevice(
            deviceId: 'phone-ui-unrelated',
            ownerName: 'Unrelated Responder',
            phoneNumber: '',
            address: '',
            role: RegisteredDeviceRole.responder,
            status: RegisteredDeviceStatus.approved,
            registeredAt: DateTime.utc(2026, 11, 26),
            updatedAt: DateTime.utc(2026, 11, 26),
            lastSeenLabel: 'Published',
            publicKey: base64UrlEncode(List.filled(32, 9)),
            signingPublicKey: base64UrlEncode(List.filled(32, 8)),
            keyVersion: 1,
          ),
        ],
        directoryProject: 'dnsc-pilot',
      );

      final app = ReviewApplication.fromCache(
        id: 'uid-ui-rep',
        updateTime: '2026-11-26T09:00:00Z',
        fields: {
          'affiliation': 'student',
          'displayName': 'Fallback UI Student',
          'studentNumber': '2026-4200',
          'course': 'BSIT',
          'yearLevel': '4',
          'sectionSet': 'A',
          'status': 'published',
          'revision': 1,
          'registrationId': 'reg-ui-rep',
          'deviceRegistration': qrOld.toJsonString(),
          'replacementRequest': {
            'status': 'submitted',
            'reason': 'New handset',
            'deviceRegistration': qrNew.toJsonString(),
          },
        },
      );
      final recApp = ReviewApplication.fromCache(
        id: 'uid-ui-rec',
        updateTime: '2026-11-26T09:00:00Z',
        fields: {
          'affiliation': 'student',
          'displayName': 'Fallback Recovery Student',
          'studentNumber': '2026-4201',
          'course': 'BSIT',
          'yearLevel': '4',
          'sectionSet': 'B',
          'status': 'published',
          'revision': 1,
          'registrationId': 'reg-ui-rec',
          'deviceRegistration': qrRecOld.toJsonString(),
        },
      );
      final recReq = ReviewApplication.fromCache(
        id: 'uid-ui-rec',
        updateTime: '2026-11-26T09:30:00Z',
        fields: {
          'accountUid': 'uid-ui-rec',
          'affiliation': 'student',
          'schoolId': '2026-4201',
          'displayName': 'Fallback Recovery Student',
          'email': 'rec@dnsc.edu.ph',
          'status': 'submitted',
          'deviceRegistration': qrRecNew.toJsonString(),
        },
      );
      final api = _CapturingFallbackApi(
        initialBundleJson: v1Json,
        initialVersion: 1,
        applications: [app, recApp],
        recoveryRequests: [recReq],
      );

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminTheme.light,
          home: Scaffold(
            body: UnifiedRegistrationsWorkspace(
              registry: registry,
              reviewApi: api,
              publisherClient: HostedPublisherClient(),
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

      await tester.tap(find.text('Fallback UI Student'));
      await tester.pumpAndSettle();
      final approveBtn = find.widgetWithText(
        FilledButton,
        'Approve replacement',
      );
      await tester.ensureVisible(approveBtn);
      await tester.tap(approveBtn);
      await tester.pumpAndSettle();

      expect(api.lastPublishedBundle, isNotNull);
      final published = TrustBundle.fromJsonString(api.lastPublishedBundle!);
      expect(
        published.approvedDevices.map((d) => d.deviceId).toSet(),
        equals({'phone-ui-new', 'phone-ui-rec-old', 'phone-ui-unrelated'}),
      );
      expect(
        published.revokedDevices.map((d) => d.deviceId).toSet(),
        equals({'phone-ui-old'}),
      );

      await tester.tap(find.text('Fallback Recovery Student'));
      await tester.pumpAndSettle();
      final approveRecBtn = find.widgetWithText(
        FilledButton,
        'Approve replacement',
      );
      await tester.ensureVisible(approveRecBtn);
      await tester.tap(approveRecBtn);
      await tester.pumpAndSettle();

      final publishedAfterRec = TrustBundle.fromJsonString(
        api.lastPublishedBundle!,
      );
      expect(
        publishedAfterRec.approvedDevices.map((d) => d.deviceId).toSet(),
        equals({'phone-ui-new', 'phone-ui-rec-new', 'phone-ui-unrelated'}),
      );
      expect(
        publishedAfterRec.revokedDevices.map((d) => d.deviceId).toSet(),
        equals({'phone-ui-old', 'phone-ui-rec-old'}),
      );
    },
  );
}
