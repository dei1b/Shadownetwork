import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/admin/presentation/pages/desktop_admin_shell.dart';
import 'package:shadownetwork/features/admin/presentation/providers/admin_recovery_provider.dart';
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';
import 'package:shadownetwork/features/admin_validation/presentation/providers/validation_import_provider.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/trust/domain/entities/approval_receipt.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

import '../../support/signed_trust_bundle_fixture.dart';

class _EmptyValidationImportController extends ValidationImportController {
  @override
  Future<ValidationImportState> build() async => const ValidationImportState();
}

class _InMemoryShellRegistry implements DesktopAdminRegistryRepository {
  _InMemoryShellRegistry(this.signer, this.registrations);

  final TestTrustBundleSigner signer;
  final List<CampusRegistration> registrations;
  final List<PendingSyncOperation> pendingSync = [];

  @override
  Future<AdminIdentityStatus> identityStatus() async => AdminIdentityStatus(
    fingerprint: '0' * 64,
    bundleVersion: 1,
    hasIdentity: true,
  );

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
    );
    final idx = registrations.indexWhere(
      (r) => r.registrationId == updated.registrationId,
    );
    if (idx >= 0) registrations[idx] = updated;
    pendingSync.add(
      PendingSyncOperation(
        decisionId: decisionId,
        registrationId: updated.registrationId,
        kind: PendingSyncKind.publishManual,
        payloadJson: '{}',
        createdAt: now,
      ),
    );
    final receipt = await SignedApprovalReceipt.createSigned(
      registrationId: updated.registrationId,
      deviceId: updated.activePhone.deviceId,
      publicKey: updated.activePhone.publicKey ?? '',
      signingPublicKey: updated.activePhone.signingPublicKey ?? '',
      keyVersion: updated.activePhone.keyVersion,
      issuer: TrustBundleIssuer(
        issuerId: signer.issuerId,
        signingKeyId: 'test-key-1',
        signatureAlgorithm: 'ed25519',
        publicKey: base64UrlEncode(signer.publicKeyBytes),
      ),
      issuerKeyPair: signer.keyPair as SimpleKeyPair,
      issuedAt: now,
      expiresAt: now.add(const Duration(days: 30)),
      directoryProject: directoryProject,
    );
    return (
      bundleJson: '',
      packageJson: ApprovalQrPackage(bundleJson: '', receipt: receipt)
          .toJsonString(),
      receipt: receipt,
      registration: updated,
    );
  }

  @override
  Future<void> restoreEncryptedBackup(String source, String password) async {
    registrations
      ..clear()
      ..add(
        CampusRegistration(
          registrationId: 'reg-restored-1',
          source: CampusRegistrationSource.qr,
          status: CampusRegistrationStatus.published,
          syncState: CampusSyncState.synced,
          identity: const CampusIdentityFields(
            affiliation: CampusAffiliation.student,
            displayName: 'Restored From Backup',
            studentNumber: '2026-9999',
            course: 'BSIT',
            yearLevel: '4',
            sectionSet: 'A',
          ),
          role: RegisteredDeviceRole.civilian,
          activePhone: RegistrationPhoneBinding(
            deviceId: 'phone-restored-1',
            publicKey: base64UrlEncode(List.filled(32, 8)),
            signingPublicKey: base64UrlEncode(List.filled(32, 9)),
            keyVersion: 1,
          ),
          createdAt: DateTime.utc(2026, 11, 26),
          updatedAt: DateTime.utc(2026, 11, 26),
        ),
      );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'DesktopAdminShell preserves workspace filter state across ordinary edits and resets on backup restore',
    (tester) async {
      final signer = await TestTrustBundleSigner.create();
      final registry = _InMemoryShellRegistry(signer, [
        CampusRegistration(
          registrationId: 'reg-keep-1',
          source: CampusRegistrationSource.qr,
          status: CampusRegistrationStatus.submitted,
          syncState: CampusSyncState.waitingToSync,
          identity: const CampusIdentityFields(
            affiliation: CampusAffiliation.student,
            displayName: 'Student Keep Session',
            studentNumber: '2026-1122',
            course: 'BSIT',
            yearLevel: '3',
            sectionSet: 'A',
          ),
          role: RegisteredDeviceRole.civilian,
          activePhone: RegistrationPhoneBinding(
            deviceId: 'phone-keep-1',
            publicKey: base64UrlEncode(List.filled(32, 3)),
            signingPublicKey: base64UrlEncode(List.filled(32, 4)),
            keyVersion: 1,
          ),
          createdAt: DateTime.utc(2026, 11, 26),
          updatedAt: DateTime.utc(2026, 11, 26),
        ),
      ]);

      final container = ProviderContainer(
        overrides: [
          desktopAdminRegistryProvider.overrideWith((ref) async => registry),
          validationImportControllerProvider.overrideWith(
            _EmptyValidationImportController.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AdminTheme.light,
            home: const DesktopAdminShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Enter search text simulating active reviewer session state.
      final searchField = find.byKey(
        const ValueKey('unified-registration-search'),
      );
      await tester.enterText(searchField, 'Keep Session');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Student Keep Session'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Approve offline & show QR'));
      await tester.tap(find.text('Approve offline & show QR'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // Ordinary edit must NOT reset workspace state or search query.
      expect(
        tester.widget<TextField>(searchField).controller!.text,
        'Keep Session',
      );
      expect(find.text('Approved on this PC · waiting to sync'), findsWidgets);

      // Restoring a backup MUST remount/reload workspace with restored records.
      await container
          .read(adminRecoveryProvider.notifier)
          .restoreBackup('backup', 'pw');
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(searchField).controller!.text,
        isEmpty,
      );
      expect(find.text('Restored From Backup'), findsOneWidget);
    },
  );
}
