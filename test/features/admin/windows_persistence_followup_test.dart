// Regression probes from the second unified registration audit at 18a7682d.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin/data/admin_signing_key_store.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_database.dart';
import 'package:shadownetwork/features/admin/data/desktop_admin_registry_repository.dart';
import 'package:shadownetwork/features/admin/domain/entities/campus_registration.dart';
import 'package:shadownetwork/features/admin/domain/entities/registered_device.dart';
import 'package:shadownetwork/features/registration/domain/campus_identity_fields.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';

class _MemoryKeys implements AdminSigningKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}

const _reviewer = ReviewerProfile(
  uid: 'reviewer',
  email: 'reviewer@dnsc.edu.ph',
);
const _project = 'dnsc-pilot';

RegistrationPhoneBinding _phone(String id, int seed) =>
    RegistrationPhoneBinding(
      deviceId: id,
      publicKey: base64UrlEncode(List<int>.filled(32, seed)),
      signingPublicKey: base64UrlEncode(List<int>.filled(32, seed + 1)),
      keyVersion: 1,
    );

CampusRegistration _registration(String id, RegistrationPhoneBinding phone) =>
    CampusRegistration(
      registrationId: id,
      source: CampusRegistrationSource.qr,
      status: CampusRegistrationStatus.published,
      syncState: CampusSyncState.synced,
      accountUid: 'account-$id',
      identity: CampusIdentityFields(
        affiliation: CampusAffiliation.student,
        displayName: 'Student $id',
        studentNumber: 'student-$id',
        course: 'BSIT',
        yearLevel: '3',
        sectionSet: 'A',
      ),
      role: RegisteredDeviceRole.civilian,
      activePhone: phone,
      createdAt: DateTime.utc(2026, 11, 26),
      updatedAt: DateTime.utc(2026, 11, 26),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'R2 follow-up: publishing one replacement must not publish another staged phone',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'windows-queue-isolation-',
      );
      final db = await openDesktopAdminRegistryDatabase(
        '${dir.path}/registry.sqlite',
      );
      final repo = DesktopAdminRegistryRepository(
        database: db,
        keyStore: _MemoryKeys(),
      );
      try {
        await repo.initializeIdentity();
        final first = _registration('first', _phone('first-old', 1));
        final second = _registration('second', _phone('second-old', 3));
        await repo.saveRegistration(first);
        await repo.saveRegistration(second);
        final remote = TrustBundle.fromJsonString(
          await repo.buildTrustBundleJson([
            first.toRegisteredDevice(),
            second.toRegisteredDevice(),
          ], directoryProject: _project),
        );
        final stagedFirst = await repo.stagePhoneReplacement(
          registration: first,
          newPhone: _phone('first-new', 5),
          reviewer: _reviewer,
          directoryProject: _project,
          previousVersion: remote.bundleVersion,
          publishedBundle: remote,
        );
        await repo.stagePhoneReplacement(
          registration: second,
          newPhone: _phone('second-new', 7),
          reviewer: _reviewer,
          directoryProject: _project,
          previousVersion: remote.bundleVersion,
          publishedBundle: remote,
        );
        final operations = await repo.loadPendingSync();
        expect(operations, hasLength(2));
        final firstOperation = operations.firstWhere(
          (op) => op.registrationId == first.registrationId,
        );
        final changes = DesktopAdminRegistryRepository.replacementLocalChanges(
          publishedRegistration: stagedFirst.registration.copyWith(
            status: CampusRegistrationStatus.published,
            syncState: CampusSyncState.synced,
          ),
          opPayload:
              jsonDecode(firstOperation.payloadJson) as Map<String, dynamic>,
          publishedBundle: remote,
        );
        final merged = TrustBundle.fromJsonString(
          await repo.buildMergedTrustBundleJson(
            publishedBundle: remote,
            localChanges: changes,
            directoryProject: _project,
            minimumPreviousVersion: remote.bundleVersion,
          ),
        );
        // This bundle can be committed by the first operation alone. The second
        // operation may fail or never run, so its new phone must remain absent.
        expect(
          merged.approvedDevices.map((d) => d.deviceId).toSet(),
          equals({'first-new', 'second-old'}),
        );
        expect(
          merged.revokedDevices.map((d) => d.deviceId).toSet(),
          equals({'first-old'}),
        );
        await _acknowledge(repo, stagedFirst.registration, merged);
        expect((await repo.loadPendingSync()).single.registrationId, 'second');
        final secondStaged = (await repo.loadRegistrations()).singleWhere(
          (reg) => reg.registrationId == 'second',
        );
        final next = await _publish(repo, secondStaged, merged);
        expect(
          next.approvedDevices.map((d) => d.deviceId).toSet(),
          equals({'first-new', 'second-new'}),
        );
        expect(
          next.revokedDevices.map((d) => d.deviceId).toSet(),
          equals({'first-old', 'second-old'}),
        );
        await _acknowledge(repo, secondStaged, next);
        expect(await repo.loadPendingSync(), isEmpty);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'R3 follow-up: interrupted return to a retired phone survives old roster reconciliation',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'windows-returned-phone-',
      );
      var db = await openDesktopAdminRegistryDatabase(
        '${dir.path}/registry.sqlite',
      );
      final keys = _MemoryKeys();
      var repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);
      try {
        await repo.initializeIdentity();
        final phoneA = _phone('phone-a', 11);
        final phoneB = _phone('phone-b', 13);
        final current = _registration('returning', phoneB);
        await repo.saveRegistration(current);
        final retiredA = _registration(
          'previous',
          phoneA,
        ).toRegisteredDevice().copyWith(status: RegisteredDeviceStatus.revoked);
        await repo.saveDevices([current.toRegisteredDevice(), retiredA]);
        final remote = TrustBundle.fromJsonString(
          await repo.buildTrustBundleJson([
            current.toRegisteredDevice(),
            retiredA,
          ], directoryProject: _project),
        );
        // An administrator has explicitly approved B -> A against this roster.
        // Publication is interrupted before the network commit.
        await repo.stagePhoneReplacement(
          registration: current,
          newPhone: phoneA,
          reviewer: _reviewer,
          directoryProject: _project,
          previousVersion: remote.bundleVersion,
          publishedBundle: remote,
        );
        final decisionId = (await repo.loadPendingSync()).single.decisionId;
        await db.close();
        db = await openDesktopAdminRegistryDatabase(
          '${dir.path}/registry.sqlite',
        );
        repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);
        final records = await repo.reconcileWithPublishedRoster(
          remote,
          _project,
        );
        final restored = records.single;
        expect((await repo.loadPendingSync()).single.decisionId, decisionId);
        // The fallback dispatcher skips conflict records before attempting sync.
        expect(restored.status, CampusRegistrationStatus.approvedLocal);
        expect(restored.syncState, CampusSyncState.waitingToSync);
        final published = await _publish(repo, restored, remote);
        expect(published.approvedDevices.map((d) => d.deviceId), ['phone-a']);
        expect(published.revokedDevices.map((d) => d.deviceId), ['phone-b']);
        await _acknowledge(repo, restored, published);
        expect(await repo.loadPendingSync(), isEmpty);
        expect(
          (await repo.loadRegistrations()).single.status,
          CampusRegistrationStatus.published,
        );
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'S2: first publication excludes all unrelated local pending changes',
    () async {
      final dir = await Directory.systemTemp.createTemp('windows-mixed-queue-');
      final db = await openDesktopAdminRegistryDatabase(
        '${dir.path}/registry.sqlite',
      );
      final repo = DesktopAdminRegistryRepository(
        database: db,
        keyStore: _MemoryKeys(),
      );
      try {
        await repo.initializeIdentity();
        final first = _registration('first', _phone('first-old', 1));
        final revoked = _registration('revocation', _phone('to-revoke', 3));
        final remote = TrustBundle.fromJsonString(
          await repo.buildTrustBundleJson([
            first.toRegisteredDevice(),
            revoked.toRegisteredDevice(),
          ], directoryProject: _project),
        );
        await repo.saveRegistration(first);
        final staged = await repo.stagePhoneReplacement(
          registration: first,
          newPhone: _phone('first-new', 5),
          reviewer: _reviewer,
          directoryProject: _project,
          previousVersion: remote.bundleVersion,
          publishedBundle: remote,
        );
        final approval = _registration('approval', _phone('not-published', 7))
            .copyWith(
              status: CampusRegistrationStatus.approvedLocal,
              syncState: CampusSyncState.waitingToSync,
            );
        final revocation = revoked.copyWith(
          status: CampusRegistrationStatus.revoked,
          syncState: CampusSyncState.waitingToSync,
        );
        for (final reg in [approval, revocation]) {
          await repo.saveRegistration(
            reg,
            pendingSync: PendingSyncOperation(
              decisionId: 'decision-${reg.registrationId}',
              registrationId: reg.registrationId,
              kind: PendingSyncKind.publishManual,
              payloadJson: '{}',
              createdAt: DateTime.utc(2026, 11, 26),
            ),
          );
        }
        final merged = await _publish(repo, staged.registration, remote);
        expect(merged.approvedDevices.map((d) => d.deviceId).toSet(), {
          'first-new',
          'to-revoke',
        });
        expect(merged.revokedDevices.map((d) => d.deviceId), ['first-old']);
        await _acknowledge(repo, staged.registration, merged);
        expect(
          (await repo.loadPendingSync()).map((op) => op.registrationId).toSet(),
          {'approval', 'revocation'},
        );
        // No remote directory yet also means no unrelated local decisions.
        final initial = TrustBundle.fromJsonString(
          await repo.buildMergedTrustBundleJson(
            publishedBundle: null,
            localChanges: [approval.toRegisteredDevice()],
            directoryProject: _project,
          ),
        );
        expect(initial.approvedDevices.map((d) => d.deviceId), [
          'not-published',
        ]);
        expect(initial.revokedDevices, isEmpty);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  for (final kind in [
    PendingSyncKind.publishReplacement,
    PendingSyncKind.publishRecovery,
  ]) {
    test(
      'S3: $kind persists reviewed retirement and request freshness across restart',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'windows-retired-target-',
        );
        var db = await openDesktopAdminRegistryDatabase(
          '${dir.path}/registry.sqlite',
        );
        final keys = _MemoryKeys();
        var repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);
        try {
          await repo.initializeIdentity();
          final original = _registration('returning', _phone('phone-a', 11));
          await repo.saveRegistration(original);
          final initial = TrustBundle.fromJsonString(
            await repo.buildTrustBundleJson([
              original.toRegisteredDevice(),
            ], directoryProject: _project),
          );
          final first = await repo.stagePhoneReplacement(
            registration: original,
            newPhone: _phone('phone-b', 13),
            reviewer: _reviewer,
            directoryProject: _project,
            previousVersion: initial.bundleVersion,
            publishedBundle: initial,
          );
          final retired = await _publish(repo, first.registration, initial);
          final current = await _acknowledge(repo, first.registration, retired);
          final staged = await repo.stagePhoneReplacement(
            registration: current,
            newPhone: original.activePhone,
            reviewer: _reviewer,
            directoryProject: _project,
            previousVersion: retired.bundleVersion,
            publishedBundle: retired,
            syncKind: kind,
            expectedRequestUpdateTime: '2026-11-26T09:00:00.123456Z',
          );
          final decisionId = staged.registration.pendingDecisionId;
          await db.close();
          db = await openDesktopAdminRegistryDatabase(
            '${dir.path}/registry.sqlite',
          );
          repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);
          final queued = (await repo.loadPendingSync()).single;
          expect(queued.decisionId, decisionId);
          final payload =
              jsonDecode(queued.payloadJson) as Map<String, dynamic>;
          expect(
            payload['expected_request_update_time'],
            '2026-11-26T09:00:00.123456Z',
          );
          expect(payload['old_device_id'], 'phone-b');
          expect(payload['old_public_key'], _phone('phone-b', 13).publicKey);
          expect(
            payload['old_signing_public_key'],
            _phone('phone-b', 13).signingPublicKey,
          );
          expect(payload['old_key_version'], 1);
          final restored = (await repo.reconcileWithPublishedRoster(
            retired,
            _project,
          )).single;
          expect(restored.status, CampusRegistrationStatus.approvedLocal);
          // Unrelated publications may advance the directory while retaining the
          // exact retirement that the reviewer examined.
          final later = TrustBundle.fromJsonString(
            await repo.buildTrustBundleJson(
              [
                current.toRegisteredDevice(),
                original.toRegisteredDevice().copyWith(
                  status: RegisteredDeviceStatus.revoked,
                  updatedAt: retired.revokedDevices.single.updatedAt,
                ),
                _registration(
                  'unrelated',
                  _phone('unrelated', 15),
                ).toRegisteredDevice(),
              ],
              directoryProject: _project,
              minimumPreviousVersion: retired.bundleVersion,
            ),
          );
          final reconciled = (await repo.reconcileWithPublishedRoster(
            later,
            _project,
          )).single;
          expect(reconciled.status, CampusRegistrationStatus.approvedLocal);
          final published = await _publish(repo, reconciled, later);
          expect(published.approvedDevices.map((d) => d.deviceId).toSet(), {
            'phone-a',
            'unrelated',
          });
          expect(published.revokedDevices.map((d) => d.deviceId), ['phone-b']);
          await _acknowledge(repo, reconciled, published);
          expect(await repo.loadPendingSync(), isEmpty);
        } finally {
          await db.close();
          await dir.delete(recursive: true);
        }
      },
    );
  }

  for (final change in [
    'revocation time',
    'public key',
    'signing key',
    'key version',
    'unreviewed retirement',
  ]) {
    test(
      'S3: $change blocks the queued replacement and direct merge',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'windows-new-revocation-',
        );
        var db = await openDesktopAdminRegistryDatabase(
          '${dir.path}/registry.sqlite',
        );
        final keys = _MemoryKeys();
        var repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);
        try {
          await repo.initializeIdentity();
          final current = _registration('returning', _phone('phone-b', 13));
          final retired = _registration('previous', _phone('phone-a', 11))
              .toRegisteredDevice()
              .copyWith(status: RegisteredDeviceStatus.revoked);
          await repo.saveRegistration(current);
          final remote = TrustBundle.fromJsonString(
            await repo.buildTrustBundleJson([
              current.toRegisteredDevice(),
              if (change != 'unreviewed retirement') retired,
            ], directoryProject: _project),
          );
          final staged = await repo.stagePhoneReplacement(
            registration: current,
            newPhone: _phone('phone-a', 11),
            reviewer: _reviewer,
            directoryProject: _project,
            previousVersion: remote.bundleVersion,
            publishedBundle: remote,
          );
          final changed = retired.copyWith(
            updatedAt: change == 'revocation time'
                ? retired.updatedAt.add(const Duration(seconds: 1))
                : null,
            publicKey: change == 'public key'
                ? _phone('phone-a', 19).publicKey
                : null,
            signingPublicKey: change == 'signing key'
                ? _phone('phone-a', 19).signingPublicKey
                : null,
            keyVersion: change == 'key version' ? 2 : null,
          );
          final later = TrustBundle.fromJsonString(
            await repo.buildTrustBundleJson(
              [current.toRegisteredDevice(), changed],
              directoryProject: _project,
              minimumPreviousVersion: remote.bundleVersion,
            ),
          );
          await db.close();
          db = await openDesktopAdminRegistryDatabase(
            '${dir.path}/registry.sqlite',
          );
          repo = DesktopAdminRegistryRepository(database: db, keyStore: keys);
          await expectLater(
            _publish(repo, staged.registration, later),
            throwsStateError,
          );
          final restored = (await repo.reconcileWithPublishedRoster(
            later,
            _project,
          )).single;
          expect(restored.status, CampusRegistrationStatus.conflict);
          expect(restored.syncState, CampusSyncState.conflict);
          expect(
            (await repo.loadPendingSync()).single.decisionId,
            staged.registration.pendingDecisionId,
          );
        } finally {
          await db.close();
          await dir.delete(recursive: true);
        }
      },
    );
  }
}

Future<TrustBundle> _publish(
  DesktopAdminRegistryRepository repo,
  CampusRegistration registration,
  TrustBundle remote,
) async {
  final op = (await repo.loadPendingSync()).singleWhere(
    (op) => op.registrationId == registration.registrationId,
  );
  final changes = DesktopAdminRegistryRepository.replacementLocalChanges(
    publishedRegistration: registration.copyWith(
      status: CampusRegistrationStatus.published,
      syncState: CampusSyncState.synced,
    ),
    opPayload: jsonDecode(op.payloadJson) as Map<String, dynamic>,
    publishedBundle: remote,
  );
  return TrustBundle.fromJsonString(
    await repo.buildMergedTrustBundleJson(
      publishedBundle: remote,
      localChanges: changes,
      directoryProject: _project,
      minimumPreviousVersion: remote.bundleVersion,
    ),
  );
}

Future<CampusRegistration> _acknowledge(
  DesktopAdminRegistryRepository repo,
  CampusRegistration registration,
  TrustBundle published,
) async {
  await repo.saveLastPublishedRoster(published, jsonEncode(published.toJson()));
  final acknowledged = registration.copyWith(
    status: CampusRegistrationStatus.published,
    syncState: CampusSyncState.synced,
  );
  await repo.saveRegistration(acknowledged, removePendingForRegistration: true);
  return acknowledged;
}
