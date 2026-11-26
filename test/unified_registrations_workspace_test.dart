import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/unified_registrations_workspace.dart';
import 'package:shadownetwork/features/registration/data/registration_review_api.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';
import 'package:shadownetwork/features/security/domain/entities/user_information.dart';
import 'package:shadownetwork/features/trust/domain/entities/approval_receipt.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

import 'support/signed_trust_bundle_fixture.dart';

class _InMemoryWorkspaceRegistry implements DesktopAdminRegistryRepository {
  _InMemoryWorkspaceRegistry({
    List<CampusRegistration>? registrations,
    List<PendingSyncOperation>? pendingSync,
    this.reviewerProfile,
  }) : registrations = [...?registrations],
       pendingSync = [...?pendingSync];

  final List<CampusRegistration> registrations;
  final List<PendingSyncOperation> pendingSync;
  ReviewerProfile? reviewerProfile;
  late TestTrustBundleSigner _signer;

  Future<void> initSigner() async {
    _signer = await TestTrustBundleSigner.create();
  }

  @override
  Future<List<CampusRegistration>> loadRegistrations() async =>
      List.of(registrations);

  @override
  Future<void> saveRegistration(
    CampusRegistration registration, {
    PendingSyncOperation? pendingSync,
    bool removePendingForRegistration = false,
    bool syncDeviceList = true,
  }) async {
    final index = registrations.indexWhere(
      (r) => r.registrationId == registration.registrationId,
    );
    if (index >= 0) {
      registrations[index] = registration;
    } else {
      registrations.add(registration);
    }
    if (removePendingForRegistration) {
      this.pendingSync.removeWhere(
        (op) => op.registrationId == registration.registrationId,
      );
    }
    if (pendingSync != null) {
      this.pendingSync.add(pendingSync);
    }
  }

  @override
  Future<List<PendingSyncOperation>> loadPendingSync() async =>
      List.of(pendingSync);

  @override
  Future<void> removePendingSync(String decisionId) async {
    pendingSync.removeWhere((op) => op.decisionId == decisionId);
  }

  @override
  Future<ReviewerProfile?> loadReviewerProfile() async => reviewerProfile;

  @override
  Future<void> saveReviewerProfile(ReviewerProfile profile) async {
    reviewerProfile = profile;
  }

  @override
  Future<
    ({
      String bundleJson,
      String packageJson,
      SignedApprovalReceipt receipt,
      CampusRegistration registration,
    })
  >
  approveOfflineRegistration({
    required CampusRegistration registration,
    required ReviewerProfile reviewer,
    required RegisteredDeviceRole role,
    required CampusIdentityFields reviewedIdentity,
    String reason = '',
    String? directoryProject,
  }) async {
    final now = DateTime.now().toUtc();
    final decisionId = CampusRegistration.newDecisionId();
    final updated = registration.copyWith(
      identity: reviewedIdentity,
      role: role,
      status: CampusRegistrationStatus.approvedLocal,
      syncState: CampusSyncState.waitingToSync,
      updatedAt: now,
      reviewHistory: [
        ...registration.reviewHistory,
        RegistrationDecisionEntry(
          decisionId: decisionId,
          reviewerUid: reviewer.uid,
          reviewerEmail: reviewer.email,
          status: 'approved_local',
          role: role.name,
          reason: reason,
          revision: registration.revision + 1,
          createdAt: now,
        ),
      ],
    );
    final op = PendingSyncOperation(
      decisionId: decisionId,
      registrationId: updated.registrationId,
      kind: PendingSyncKind.publishManual,
      payloadJson: jsonEncode({'registrationId': updated.registrationId}),
      createdAt: now,
    );
    await saveRegistration(updated, pendingSync: op);
    final devices = await loadDevices();
    final bundleJson = await buildTrustBundleJson(
      devices,
      directoryProject: directoryProject,
    );
    final receipt = await SignedApprovalReceipt.createSigned(
      registrationId: updated.registrationId,
      deviceId: updated.activePhone.deviceId,
      publicKey: updated.activePhone.publicKey ?? '',
      signingPublicKey: updated.activePhone.signingPublicKey ?? '',
      keyVersion: updated.activePhone.keyVersion,
      issuer: TrustBundleIssuer(
        issuerId: _signer.issuerId,
        signingKeyId: 'test-key-1',
        signatureAlgorithm: 'ed25519',
        publicKey: base64UrlEncode(_signer.publicKeyBytes),
      ),
      issuerKeyPair: _signer.keyPair as SimpleKeyPair,
      issuedAt: now,
      expiresAt: now.add(const Duration(days: 30)),
      directoryProject: directoryProject,
    );
    final package = ApprovalQrPackage(
      bundleJson: bundleJson,
      receipt: receipt,
    );
    return (
      bundleJson: bundleJson,
      packageJson: package.toJsonString(),
      receipt: receipt,
      registration: updated,
    );
  }

  @override
  Future<List<RegisteredDevice>> loadDevices() async => [
    for (final reg in registrations) reg.toRegisteredDevice(),
  ];

  @override
  Future<String> buildTrustBundleJson(
    List<RegisteredDevice> devices, {
    String? directoryProject,
    int minimumPreviousVersion = 0,
  }) => _signer.sign(
    bundleVersion: 1,
    issuedAt: DateTime.now().toUtc(),
    directoryProject: directoryProject,
    approvedDevices: [
      for (final d in devices.where(
        (d) =>
            d.status == RegisteredDeviceStatus.approved &&
            (d.publicKey?.isNotEmpty ?? false) &&
            (d.signingPublicKey?.isNotEmpty ?? false),
      ))
        TrustedDevice(
          deviceId: d.deviceId,
          ownerName: d.ownerName,
          role: d.role.name,
          status: 'approved',
          updatedAt: d.updatedAt,
          publicKey: d.publicKey!,
          signingPublicKey: d.signingPublicKey!,
          keyVersion: d.keyVersion,
        ),
    ],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<String> makeSignedPhoneQr({
    required String deviceId,
    required String fullName,
  }) async {
    final secrets = InMemorySecretValueStore();
    final crypto = await DeviceIdentityStore(
      secretStore: secrets,
    ).loadOrCreate();
    final signing = await DeviceSigningIdentityStore(
      secretStore: secrets,
    ).loadOrCreate();
    final qr = await DeviceRegistrationQr.createSigned(
      deviceId: deviceId,
      identity: crypto,
      signingIdentity: signing,
      userInformation: UserInformation(
        fullName: fullName,
        phoneNumber: '09171234567',
        address: 'Panabo City',
      ),
    );
    return jsonEncode(qr.toJson());
  }

  final testReviewApi = RegistrationReviewApi(
    Uri.https(
      'firestore.googleapis.com',
      '/v1/projects/test/databases/(default)/documents/pilotApplications',
    ),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('filters unified registrations by search, role, and sync state', (
    tester,
  ) async {
    final registry = _InMemoryWorkspaceRegistry(
      registrations: [
        CampusRegistration(
          registrationId: 'reg-student-1',
          source: CampusRegistrationSource.qr,
          status: CampusRegistrationStatus.approvedLocal,
          syncState: CampusSyncState.waitingToSync,
          identity: const CampusIdentityFields(
            affiliation: CampusAffiliation.student,
            displayName: 'Ana Reyes',
            studentNumber: '2026-0001',
            course: 'BSIT',
            yearLevel: 'Year 4',
            sectionSet: 'Set H',
          ),
          role: RegisteredDeviceRole.civilian,
          activePhone: const RegistrationPhoneBinding(
            deviceId: 'phone-ana',
            publicKey: 'pk1',
            signingPublicKey: 'sk1',
          ),
          createdAt: DateTime.utc(2026, 11, 20),
          updatedAt: DateTime.utc(2026, 11, 20),
        ),
        CampusRegistration(
          registrationId: 'reg-staff-1',
          source: CampusRegistrationSource.online,
          status: CampusRegistrationStatus.published,
          syncState: CampusSyncState.synced,
          identity: const CampusIdentityFields(
            affiliation: CampusAffiliation.staff,
            displayName: 'Mark Villanueva',
            employeeId: 'EMP-102',
            unit: 'Campus Security',
          ),
          role: RegisteredDeviceRole.responder,
          activePhone: const RegistrationPhoneBinding(
            deviceId: 'phone-mark',
            publicKey: 'pk2',
            signingPublicKey: 'sk2',
          ),
          createdAt: DateTime.utc(2026, 11, 21),
          updatedAt: DateTime.utc(2026, 11, 21),
        ),
      ],
    );
    await registry.initSigner();

    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AdminTheme.light,
        home: Scaffold(
          body: UnifiedRegistrationsWorkspace(
            registry: registry,
            onRegistryChanged: () {},
            reviewApi: testReviewApi,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ana Reyes'), findsOneWidget);
    expect(find.text('Mark Villanueva'), findsOneWidget);
    expect(find.text('Approved on this PC · waiting to sync'), findsWidgets);

    await tester.tap(find.text('Approved · waiting to sync').first);
    await tester.pumpAndSettle();
    expect(find.text('Ana Reyes'), findsOneWidget);
    expect(find.text('Mark Villanueva'), findsNothing);

    await tester.tap(find.text('All').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('unified-registration-search')),
      'Campus Security',
    );
    await tester.pumpAndSettle();
    expect(find.text('Ana Reyes'), findsNothing);
    expect(find.text('Mark Villanueva'), findsOneWidget);
  });

  testWidgets('pasting phone QR lets admin edit staff fields and approve offline with QR dialog', (
    tester,
  ) async {
    final registry = _InMemoryWorkspaceRegistry(
      reviewerProfile: const ReviewerProfile(
        uid: 'admin-1',
        email: 'admin@dnsc.edu.ph',
      ),
    );
    await registry.initSigner();
    final qrJson = await makeSignedPhoneQr(
      deviceId: 'phone-staff-qr',
      fullName: 'Dr. Liza Cruz',
    );

    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AdminTheme.light,
        home: Scaffold(
          body: UnifiedRegistrationsWorkspace(
            registry: registry,
            onRegistryChanged: () {},
            reviewApi: testReviewApi,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('unified-paste-qr-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('desktop-registration-json')),
      qrJson,
    );
    await tester.tap(find.text('Read registration'));
    await tester.pumpAndSettle();

    expect(find.text('Review Dr. Liza Cruz'), findsOneWidget);
    await tester.tap(find.text('Staff').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Employee ID'),
      'EMP-2026-88',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Unit / Office'),
      'DRRMO Office',
    );
    await tester.ensureVisible(find.text('Approve offline & show QR'));
    await tester.tap(find.text('Approve offline & show QR'));
    await tester.pumpAndSettle();

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Copy JSON'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Dr. Liza Cruz'), findsOneWidget);
    expect(find.text('Approved on this PC · waiting to sync'), findsWidgets);
    expect(registry.pendingSync, hasLength(1));
  });
}
