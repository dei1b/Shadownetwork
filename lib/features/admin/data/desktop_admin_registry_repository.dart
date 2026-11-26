import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';
import '../domain/entities/campus_registration.dart';
import '../domain/entities/registered_device.dart';
import '../domain/repositories/admin_registry_repository.dart';
import 'admin_signing_key_store.dart';
import 'admin_registry_backup.dart';
import '../../registration/domain/campus_identity_fields.dart';
import '../../trust/domain/entities/approval_receipt.dart';
import '../../trust/domain/entities/publisher_delegation.dart';
import '../../trust/domain/entities/trust_bundle.dart';
import '../../trust/domain/services/canonical_json.dart';

class AdminIdentityStatus {
  const AdminIdentityStatus({
    required this.fingerprint,
    required this.bundleVersion,
    required this.hasIdentity,
  });
  final String? fingerprint;
  final int bundleVersion;
  final bool hasIdentity;
}

class DesktopAdminRegistryRepository implements AdminRegistryRepository {
  DesktopAdminRegistryRepository({
    required this.database,
    required this.keyStore,
  });
  final Database database;
  final AdminSigningKeyStore keyStore;
  // Queue handles for the same canonical file together within this isolate.
  // The OS file lock also protects the SQLite/protected-key pair across Windows
  // sessions and processes; the runner's per-session mutex alone cannot do so.
  static final _memoryQueues = Expando<Future<void>>();
  static final _fileQueues = <String, Future<void>>{};
  late final String? _registryPath = database.path == ':memory:'
      ? null
      : File(database.path).resolveSymbolicLinksSync();
  static const _maxVersion = 9007199254740991;

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final registryPath = _registryPath;
    final queueKey = registryPath == null
        ? null
        : Platform.isWindows
        ? registryPath.toLowerCase()
        : registryPath;
    final previous =
        (queueKey == null ? _memoryQueues[database] : _fileQueues[queueKey]) ??
        Future<void>.value();
    final completed = Completer<void>();
    if (queueKey == null) {
      _memoryQueues[database] = completed.future;
    } else {
      _fileQueues[queueKey] = completed.future;
    }
    return (() async {
      await previous;
      RandomAccessFile? guard;
      var locked = false;
      try {
        if (registryPath != null) {
          // Keep this file rather than unlinking it: removing a lock pathname
          // could let a later process lock a different file while one is held.
          guard = await File(
            '$registryPath.identity.lock',
          ).open(mode: FileMode.append);
          await guard.lock(FileLock.blockingExclusive);
          locked = true;
        }
        return await operation();
      } finally {
        try {
          if (locked) await guard!.unlock();
        } finally {
          try {
            await guard?.close();
          } finally {
            completed.complete();
            if (queueKey != null &&
                identical(_fileQueues[queueKey], completed.future)) {
              _fileQueues.remove(queueKey);
            }
          }
        }
      }
    })();
  }

  Future<Map<String, Object?>?> _metadata([DatabaseExecutor? executor]) async {
    final rows = await (executor ?? database).query(
      'admin_identity',
      where: 'id = 1',
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<_SigningIdentity?> _protectedIdentity({
    bool allowMalformedForRestore = false,
  }) async {
    final source = await keyStore.read();
    if (source == null) return null;
    try {
      return await _SigningIdentity.decode(source);
    } catch (error) {
      // Only an explicit restore with an authenticated, validated backup can
      // repair malformed contents. Storage read/access errors still propagate.
      if (allowMalformedForRestore && error is FormatException) return null;
      throw StateError(
        'Protected administrator identity is invalid. Restore its original backup.',
      );
    }
  }

  Future<_SigningIdentity> _requireIdentity() async {
    final metadata = await _metadata();
    final identity = await _protectedIdentity();
    if (metadata == null ||
        identity == null ||
        metadata['fingerprint'] != identity.fingerprint) {
      throw StateError(
        'Administrator identity is missing or does not match this registry. Restore the original identity backup.',
      );
    }
    return identity;
  }

  Future<void> initializeIdentity() => _serialized(() async {
    final metadata = await _metadata();
    if (metadata != null) {
      await _requireIdentity();
      return;
    }
    var identity = await _protectedIdentity();
    if (identity == null) {
      identity = await _SigningIdentity.create();
      // Key first: a failed database write leaves a recoverable key, never a
      // bound registry with no key. Retrying this explicit action reuses it.
      await keyStore.write(identity.source);
    }
    await database.insert('admin_identity', {
      'id': 1,
      'fingerprint': identity.fingerprint,
      'bundle_version': identity.bundleVersion,
    });
  });

  Future<AdminIdentityStatus> identityStatus() => _serialized(() async {
    final metadata = await _metadata();
    if (metadata == null) {
      final protected = await _protectedIdentity();
      return AdminIdentityStatus(
        fingerprint: protected?.fingerprint,
        bundleVersion: protected?.bundleVersion ?? 0,
        hasIdentity: false,
      );
    }
    final identity = await _requireIdentity();
    return AdminIdentityStatus(
      fingerprint: identity.fingerprint,
      bundleVersion: max(
        metadata['bundle_version']! as int,
        identity.bundleVersion,
      ),
      hasIdentity: true,
    );
  });
  @override
  Future<List<RegisteredDevice>> loadDevices() => _serialized(_loadDevices);

  Future<List<RegisteredDevice>> _loadDevices() async {
    final rows = await database.query('admin_devices', orderBy: 'rowid');
    return _decodeDevices(
      rows.map((row) => jsonDecode(row['record_json']! as String)).toList(),
    );
  }

  @override
  Future<void> saveDevices(List<RegisteredDevice> devices) =>
      _serialized(() async {
        final validated = _decodeDevices(
          devices.map((device) => device.toJson()).toList(),
        );
        await database.transaction(
          (transaction) => _replaceDevices(transaction, validated),
        );
      });

  Future<void> _replaceDevices(
    DatabaseExecutor executor,
    List<RegisteredDevice> devices,
  ) async {
    await executor.delete('admin_devices');
    for (final device in devices) {
      await executor.insert('admin_devices', {
        'device_id': device.deviceId,
        'record_json': jsonEncode(device.toJson()),
      });
    }
  }

  @override
  Future<String> buildTrustBundleJson(
    List<RegisteredDevice> devices, {
    String? directoryProject,
    int minimumPreviousVersion = 0,
  }) => _serialized(
    () => _buildTrustBundleJson(
      devices,
      directoryProject,
      minimumPreviousVersion,
    ),
  );

  /// Merges [localChanges] onto the verified latest remote [publishedBundle]
  /// so fallback desktop publishing preserves remote-only approvals and revocations.
  Future<String> buildMergedTrustBundleJson({
    required TrustBundle? publishedBundle,
    required List<RegisteredDevice> localChanges,
    String? directoryProject,
    int minimumPreviousVersion = 0,
  }) => _serialized(() async {
    final identity = await _requireIdentity();
    final mergedById = <String, RegisteredDevice>{};
    if (publishedBundle != null) {
      await _verifyPublishedBundleForAdmin(
        publishedBundle,
        identity,
        project: directoryProject,
      );
      for (final remote in [
        ...publishedBundle.approvedDevices,
        ...publishedBundle.revokedDevices,
      ]) {
        final keyLower = remote.deviceId.trim().toLowerCase();
        mergedById[keyLower] = RegisteredDevice(
          deviceId: remote.deviceId,
          ownerName: remote.ownerName,
          role: RegisteredDeviceRole.fromCode(remote.role),
          status: remote.status == 'revoked'
              ? RegisteredDeviceStatus.revoked
              : RegisteredDeviceStatus.approved,
          registeredAt: remote.updatedAt,
          updatedAt: remote.updatedAt,
          lastSeenLabel: remote.status == 'revoked'
              ? 'Revoked by admin'
              : 'Published',
          publicKey: remote.publicKey,
          signingPublicKey: remote.signingPublicKey,
          keyVersion: remote.keyVersion,
        );
      }
    }
    // Each publication contains only its explicit decision. Other local rows
    // may be staged approvals, revocations or replacement targets still queued.
    if (publishedBundle != null) {
      final registrations = {
        for (final reg in await _loadRegistrations()) reg.registrationId: reg,
      };
      for (final op in await _loadPendingSync()) {
        if (op.kind != PendingSyncKind.publishReplacement &&
            op.kind != PendingSyncKind.publishRecovery) {
          continue;
        }
        final reg = registrations[op.registrationId];
        if (reg == null) continue;
        final changed = localChanges
            .where(
              (device) =>
                  device.status == RegisteredDeviceStatus.approved &&
                  device.deviceId.trim().toLowerCase() ==
                      reg.activePhone.deviceId.trim().toLowerCase(),
            )
            .firstOrNull;
        if (changed == null) continue;
        final remoteRevoked = publishedBundle.revokedDevices
            .where(
              (device) =>
                  device.deviceId.trim().toLowerCase() ==
                  changed.deviceId.trim().toLowerCase(),
            )
            .firstOrNull;
        if (remoteRevoked == null) continue;
        Map<String, dynamic>? payload;
        try {
          final decoded = jsonDecode(op.payloadJson);
          if (decoded is Map<String, dynamic>) payload = decoded;
        } on FormatException {
          // A missing or unreadable review snapshot cannot override revocation.
        }
        if (changed.publicKey != reg.activePhone.publicKey ||
            changed.signingPublicKey != reg.activePhone.signingPublicKey ||
            changed.keyVersion != reg.activePhone.keyVersion ||
            !_matchesReviewedTargetRevocation(
              pendingOp: payload,
              registration: reg,
              remoteRevoked: remoteRevoked,
              publishedBundleVersion: publishedBundle.bundleVersion,
            )) {
          throw StateError(
            'The replacement target has an unreviewed published revocation. Review it before publishing.',
          );
        }
      }
    }
    for (final changed in localChanges) {
      mergedById[changed.deviceId.trim().toLowerCase()] = changed;
    }
    final merged = mergedById.values
        .where(
          (device) =>
              device.status == RegisteredDeviceStatus.approved ||
              device.status == RegisteredDeviceStatus.revoked,
        )
        .toList();
    return _buildTrustBundleJson(
      merged,
      directoryProject,
      max(minimumPreviousVersion, publishedBundle?.bundleVersion ?? 0),
    );
  });

  Future<void> _verifyPublishedBundleForAdmin(
    TrustBundle published,
    _SigningIdentity identity, {
    String? project,
  }) async {
    final signature = published.signature;
    if (!published.isSignedVersion ||
        (project != null &&
            project.isNotEmpty &&
            published.directoryProject != project) ||
        signature == null) {
      throw StateError('The published campus directory could not be verified.');
    }
    if (published.publisherDelegation != null) {
      try {
        await published.publisherDelegation!.verify(
          expectedProject: project,
          now: published.issuedAt ?? published.generatedAt,
        );
      } on FormatException {
        throw StateError(
          'The published campus directory could not be verified.',
        );
      }
      if (published.publisherDelegation!.publisher.publicKey !=
          published.issuer?.publicKey) {
        throw StateError(
          'The published campus directory could not be verified.',
        );
      }
    }
    final verified = await Ed25519().verify(
      utf8.encode(
        canonicalJsonEncode(published.toJson(includeSignature: false)),
      ),
      signature: Signature(
        base64Url.decode(signature),
        publicKey: SimplePublicKey(
          base64Url.decode(published.issuer!.publicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!verified) {
      throw StateError('The published campus directory could not be verified.');
    }
    if (published.rootAuthorityIssuer?.publicKey != identity.publicKey) {
      throw StateError(
        'Restore the signing identity used for the existing directory.',
      );
    }
  }

  TrustBundleIssuer _issuerFromPublicBytes(
    List<int> publicBytes,
  ) => TrustBundleIssuer(
    issuerId: 'shadow-network-admin',
    signingKeyId:
        'ed25519-${sha256.convert(publicBytes).toString().substring(0, 16)}',
    signatureAlgorithm: 'ed25519',
    publicKey: base64UrlEncode(publicBytes),
  );

  Future<({int version, String bundleJson, String syncedAt})?>
  _loadLastPublishedRoster([DatabaseExecutor? executor]) async {
    final rows = await (executor ?? database).query(
      'admin_published_roster',
      where: 'id = 1',
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return (
      version: row['version']! as int,
      bundleJson: row['bundle_json']! as String,
      syncedAt: row['synced_at']! as String,
    );
  }

  Future<({int version, String bundleJson})?> loadLastPublishedRoster() =>
      _serialized(() async {
        final entry = await _loadLastPublishedRoster();
        if (entry == null) return null;
        return (version: entry.version, bundleJson: entry.bundleJson);
      });

  Future<void> _saveLastPublishedRoster(
    DatabaseExecutor executor,
    TrustBundle bundle,
    String rawJson, {
    String? syncedAtIso,
  }) async {
    await executor.insert('admin_published_roster', {
      'id': 1,
      'version': bundle.bundleVersion,
      'bundle_json': rawJson,
      'synced_at': syncedAtIso ?? DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveLastPublishedRoster(TrustBundle bundle, String rawJson) =>
      _serialized(() async {
        final identity = await _requireIdentity();
        await _verifyPublishedBundleForAdmin(
          bundle,
          identity,
          project: bundle.directoryProject,
        );
        await _saveLastPublishedRoster(database, bundle, rawJson);
      });

  Future<
    ({
      PublisherDelegation delegation,
      String publisherPrivateKeySeed,
      String vercelEnvJson,
    })
  >
  createPublisherDelegation({
    required String directoryProject,
    Duration validity = const Duration(days: 365),
    bool disposable = false,
    DateTime? issuedAt,
  }) => _serialized(() async {
    final TrustBundleIssuer rootIssuer;
    final SimpleKeyPair rootKeyPair;
    if (disposable) {
      rootKeyPair = await Ed25519().newKeyPair();
      final rootPub = (await rootKeyPair.extractPublicKey()).bytes;
      rootIssuer = _issuerFromPublicBytes(rootPub);
    } else {
      final identity = await _requireIdentity();
      rootIssuer = _issuerFromPublicBytes(identity.publicBytes);
      rootKeyPair = identity.keyPair;
    }

    final pubKeyPair = await Ed25519().newKeyPair();
    final pubSeed = await pubKeyPair.extractPrivateKeyBytes();
    final pubBytes = (await pubKeyPair.extractPublicKey()).bytes;
    final publisherIssuer = _issuerFromPublicBytes(pubBytes);
    final now = (issuedAt ?? DateTime.now()).toUtc();
    final delegation = await PublisherDelegation.createSigned(
      rootIssuer: rootIssuer,
      rootKeyPair: rootKeyPair,
      publisher: publisherIssuer,
      issuedAt: now,
      expiresAt: now.add(validity),
      directoryProject: directoryProject,
    );
    final seedEncoded = base64UrlEncode(pubSeed);
    final envJson = const JsonEncoder.withIndent('  ').convert({
      'FIREBASE_PROJECT_ID': directoryProject.trim(),
      'PUBLISHER_PRIVATE_KEY_SEED': seedEncoded,
      'PUBLISHER_DELEGATION_JSON': delegation.toJsonString(),
    });
    return (
      delegation: delegation,
      publisherPrivateKeySeed: seedEncoded,
      vercelEnvJson: envJson,
    );
  });

  Future<String> stageDirectoryApproval(
    RegisteredDevice device,
    String project,
    int previousVersion, {
    TrustBundle? publishedBundle,
    bool assignRole = false,
    bool updateOwnerName = false,
  }) => _serialized(() async {
    final devices = await _loadDevices();
    if (publishedBundle != null) {
      final identity = await _requireIdentity();
      await _verifyPublishedBundleForAdmin(
        publishedBundle,
        identity,
        project: project,
      );
      await _checkPublishedRoster(publishedBundle, project, devices, identity);
    }
    final index = devices.indexWhere(
      (entry) => entry.deviceId.toLowerCase() == device.deviceId.toLowerCase(),
    );
    if (index < 0) {
      if (updateOwnerName) {
        throw StateError(
          'Restore the approved phone in the local registry first.',
        );
      }
      devices.add(device);
    } else {
      final existing = devices[index];
      if (existing.publicKey != device.publicKey ||
          existing.signingPublicKey != device.signingPublicKey ||
          existing.status == RegisteredDeviceStatus.revoked) {
        throw StateError(
          'The device conflicts with the local registry. Resolve it in Devices first.',
        );
      }
      devices[index] = existing.copyWith(
        ownerName: updateOwnerName ? device.ownerName : existing.ownerName,
        status: RegisteredDeviceStatus.approved,
        role: assignRole ? device.role : existing.role,
        updatedAt: device.updatedAt,
      );
    }
    final source = await _buildTrustBundleJson(
      devices,
      project,
      previousVersion,
    );
    await database.transaction(
      (transaction) => _replaceDevices(transaction, devices),
    );
    return source;
  });

  Future<void> _checkPublishedRoster(
    TrustBundle published,
    String project,
    List<RegisteredDevice> devices,
    _SigningIdentity identity,
  ) async {
    await _verifyPublishedBundleForAdmin(published, identity, project: project);

    final local = {
      for (final device in devices)
        device.deviceId.toLowerCase(): _trustDevice(device),
    };
    for (final remote in [
      ...published.approvedDevices,
      ...published.revokedDevices,
    ]) {
      final device = local[remote.deviceId.toLowerCase()];
      if (device == null ||
          device.publicKey != remote.publicKey ||
          device.signingPublicKey != remote.signingPublicKey ||
          device.keyVersion != remote.keyVersion ||
          (remote.status == 'revoked' && device.status != 'revoked') ||
          (device.status != 'approved' && device.status != 'revoked') ||
          ((device.status != remote.status ||
                  device.role != remote.role ||
                  device.ownerName != remote.ownerName) &&
              !device.updatedAt.isAfter(remote.updatedAt))) {
        throw StateError(
          'The local registry is missing or out of date for a published phone. '
          'Restore the latest registry backup before publishing again.',
        );
      }
    }
  }

  Future<String> _buildTrustBundleJson(
    List<RegisteredDevice> devices,
    String? directoryProject,
    int minimumPreviousVersion,
  ) async {
    final validated = _decodeDevices(
      devices.map((device) => device.toJson()).toList(),
    );
    final identity = await _requireIdentity();
    final metadataBeforeReservation = (await _metadata())!;
    final effectiveCurrent = max(
      minimumPreviousVersion,
      max(
        metadataBeforeReservation['bundle_version']! as int,
        identity.bundleVersion,
      ),
    );
    if (effectiveCurrent >= _maxVersion) {
      throw StateError('Trust bundle version limit reached.');
    }
    final reservedVersion = effectiveCurrent + 1;
    // Reserve in protected storage first. A database failure then consumes a
    // version rather than allowing its reuse after repair or database loss.
    await keyStore.write(identity.withBundleVersion(reservedVersion).source);
    final version = await database.transaction((transaction) async {
      final metadata = (await _metadata(transaction))!;
      if (metadata['fingerprint'] != identity.fingerprint) {
        throw StateError('Administrator identity changed.');
      }
      await transaction.update('admin_identity', {
        'bundle_version': reservedVersion,
      }, where: 'id = 1');
      return reservedVersion;
    });
    // Reserve before signing; a failed publication consumes a version safely.
    final now = DateTime.now().toUtc();
    final unsigned = TrustBundle(
      schemaVersion: 2,
      bundleVersion: version,
      generatedAt: now,
      issuedAt: now,
      expiresAt: now.add(const Duration(days: 30)),
      directoryProject: directoryProject,
      issuer: TrustBundleIssuer(
        issuerId: 'shadow-network-admin',
        signingKeyId: 'ed25519-${identity.fingerprint.substring(0, 16)}',
        signatureAlgorithm: 'ed25519',
        publicKey: identity.publicKey,
      ),
      approvedDevices: validated
          .where((device) => device.status == RegisteredDeviceStatus.approved)
          .map(_trustDevice)
          .toList(),
      revokedDevices: validated
          .where((device) => device.status == RegisteredDeviceStatus.revoked)
          .map(_trustDevice)
          .toList(),
    );
    final signature = await Ed25519().sign(
      utf8.encode(
        canonicalJsonEncode(unsigned.toJson(includeSignature: false)),
      ),
      keyPair: identity.keyPair,
    );
    return const JsonEncoder.withIndent('  ').convert({
      ...unsigned.toJson(includeSignature: false),
      'signature': base64UrlEncode(signature.bytes),
    });
  }

  Future<String> createEncryptedBackup(String password) =>
      _serialized(() async {
        AdminRegistryBackup.validatePassword(password);
        final identity = await _requireIdentity();
        final metadata = (await _metadata())!;
        final version = max(
          identity.bundleVersion,
          metadata['bundle_version']! as int,
        );
        final backupIdentity = identity.withBundleVersion(version);
        if (version > identity.bundleVersion) {
          await keyStore.write(backupIdentity.source);
        }
        final registrations = await _loadRegistrations();
        final pendingSync = await _loadPendingSync();
        final reviewerProfile = await _loadReviewerProfile();
        final publishedRoster = await _loadLastPublishedRoster();
        return AdminRegistryBackup.encrypt({
          'version': 3,
          'identity': jsonDecode(backupIdentity.source),
          'fingerprint': identity.fingerprint,
          'bundle_version': version,
          'devices': (await _loadDevices())
              .map((device) => device.toJson())
              .toList(),
          'registrations': registrations.map((r) => r.toJson()).toList(),
          'pending_sync': pendingSync.map((p) => p.toJson()).toList(),
          'reviewer_profile': reviewerProfile?.toJson(),
          'published_roster': publishedRoster == null
              ? null
              : {
                  'version': publishedRoster.version,
                  'bundle_json': publishedRoster.bundleJson,
                  'synced_at': publishedRoster.syncedAt,
                },
        }, password);
      });

  Future<void> restoreEncryptedBackup(
    String source,
    String password,
  ) => _serialized(() async {
    final payload = await AdminRegistryBackup.decrypt(source, password);
    final payloadVersion = payload['version'];
    final isV1 =
        payloadVersion == 1 &&
        payload.length == 5 &&
        payload.keys.every(
          {
            'version',
            'identity',
            'fingerprint',
            'bundle_version',
            'devices',
          }.contains,
        );
    final isV2 =
        payloadVersion == 2 &&
        payload.length == 8 &&
        payload.keys.every(
          {
            'version',
            'identity',
            'fingerprint',
            'bundle_version',
            'devices',
            'registrations',
            'pending_sync',
            'reviewer_profile',
          }.contains,
        );
    final isV3 =
        payloadVersion == 3 &&
        payload.length == 9 &&
        payload.keys.every(
          {
            'version',
            'identity',
            'fingerprint',
            'bundle_version',
            'devices',
            'registrations',
            'pending_sync',
            'reviewer_profile',
            'published_roster',
          }.contains,
        );
    if ((!isV1 && !isV2 && !isV3) ||
        payload['bundle_version'] is! int ||
        (payload['bundle_version']! as int) < 0 ||
        (payload['bundle_version']! as int) > _maxVersion ||
        payload['identity'] is! Map) {
      throw const FormatException('Invalid administrator backup contents.');
    }
    final identity = await _SigningIdentity.decode(
      jsonEncode(payload['identity']),
    );
    if (payload['fingerprint'] != identity.fingerprint ||
        payload['bundle_version'] != identity.bundleVersion) {
      throw const FormatException(
        'Backup issuer fingerprint or counter does not match its protected identity.',
      );
    }
    final devices = _decodeDevices(payload['devices']);
    final List<CampusRegistration> registrations;
    final List<PendingSyncOperation> pendingSync;
    final ReviewerProfile? reviewerProfile;
    ({TrustBundle bundle, String rawJson, String syncedAtIso})? restoredRoster;
    if (isV2 || isV3) {
      registrations = _decodeRegistrations(payload['registrations']);
      pendingSync = _decodePendingSync(payload['pending_sync']);
      final rawReviewer = payload['reviewer_profile'];
      if (rawReviewer == null) {
        reviewerProfile = null;
      } else if (rawReviewer is Map) {
        reviewerProfile = ReviewerProfile.fromJson(
          Map<String, Object?>.from(rawReviewer),
        );
        if (reviewerProfile.uid.isEmpty || reviewerProfile.email.isEmpty) {
          throw const FormatException('Invalid reviewer profile in backup.');
        }
      } else {
        throw const FormatException('Invalid reviewer profile in backup.');
      }
      if (isV3 && payload['published_roster'] != null) {
        final rawRoster = payload['published_roster'];
        if (rawRoster is! Map ||
            rawRoster['version'] is! int ||
            rawRoster['bundle_json'] is! String ||
            rawRoster['synced_at'] is! String) {
          throw const FormatException('Invalid published roster in backup.');
        }
        final rosterVersion = rawRoster['version']! as int;
        final rawJson = rawRoster['bundle_json']! as String;
        final syncedAtIso = rawRoster['synced_at']! as String;
        if (DateTime.tryParse(syncedAtIso) == null) {
          throw const FormatException('Invalid roster timestamp in backup.');
        }
        final parsed = TrustBundle.fromJsonString(rawJson);
        if (parsed.bundleVersion != rosterVersion) {
          throw const FormatException('Published roster version mismatch.');
        }
        await _verifyPublishedBundleForAdmin(
          parsed,
          identity,
          project: parsed.directoryProject,
        );
        restoredRoster = (
          bundle: parsed,
          rawJson: rawJson,
          syncedAtIso: syncedAtIso,
        );
      }
    } else {
      registrations = devices.map(CampusRegistration.fromLegacyDevice).toList();
      pendingSync = const [];
      reviewerProfile = null;
    }
    // No live writes occur until decryption, keypair and every record validate.
    final current = await _metadata();
    if ((await database.query('admin_devices', limit: 1)).isNotEmpty ||
        (await database.query('admin_registrations', limit: 1)).isNotEmpty) {
      throw StateError('Restore requires an empty administrator registry.');
    }
    if (current != null && current['fingerprint'] != identity.fingerprint) {
      throw StateError('Backup belongs to a different administrator identity.');
    }
    final protected = await _protectedIdentity(allowMalformedForRestore: true);
    if (protected != null && protected.fingerprint != identity.fingerprint) {
      throw StateError('Backup belongs to a different administrator identity.');
    }
    final version = max(
      payload['bundle_version']! as int,
      max(
        current?['bundle_version'] as int? ?? 0,
        protected?.bundleVersion ?? 0,
      ),
    );
    // A failure after this write preserves a valid matching key for retry.
    if (protected == null || protected.bundleVersion < version) {
      await keyStore.write(identity.withBundleVersion(version).source);
    }
    await database.transaction((transaction) async {
      await transaction.insert('admin_identity', {
        'id': 1,
        'fingerprint': identity.fingerprint,
        'bundle_version': version,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _replaceDevices(transaction, devices);
      await _replaceRegistrations(transaction, registrations);
      await _replacePendingSync(transaction, pendingSync);
      if (reviewerProfile != null) {
        await transaction.insert('admin_reviewer_profile', {
          'id': 1,
          'reviewer_uid': reviewerProfile.uid,
          'reviewer_email': reviewerProfile.email,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (restoredRoster != null) {
        await _saveLastPublishedRoster(
          transaction,
          restoredRoster.bundle,
          restoredRoster.rawJson,
          syncedAtIso: restoredRoster.syncedAtIso,
        );
      }
    });
  });

  Future<ReviewerProfile?> loadReviewerProfile() =>
      _serialized(_loadReviewerProfile);

  Future<ReviewerProfile?> _loadReviewerProfile() async {
    final rows = await database.query(
      'admin_reviewer_profile',
      where: 'id = 1',
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return ReviewerProfile(
      uid: row['reviewer_uid']! as String,
      email: row['reviewer_email']! as String,
    );
  }

  Future<void> saveReviewerProfile(ReviewerProfile profile) =>
      _serialized(() async {
        await database.insert('admin_reviewer_profile', {
          'id': 1,
          'reviewer_uid': profile.uid.trim(),
          'reviewer_email': profile.email.trim(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  Future<List<CampusRegistration>> loadRegistrations() =>
      _serialized(_loadRegistrations);

  Future<List<CampusRegistration>> _loadRegistrations() async {
    final rows = await database.query('admin_registrations', orderBy: 'rowid');
    if (rows.isEmpty) {
      final devices = await _loadDevices();
      if (devices.isEmpty) return [];
      return devices.map(CampusRegistration.fromLegacyDevice).toList();
    }
    return rows
        .map(
          (row) => CampusRegistration.fromJson(
            Map<String, Object?>.from(
              jsonDecode(row['record_json']! as String) as Map,
            ),
          ),
        )
        .toList();
  }

  Future<List<PendingSyncOperation>> loadPendingSync() =>
      _serialized(_loadPendingSync);

  Future<List<PendingSyncOperation>> _loadPendingSync() async {
    final rows = await database.query('admin_pending_sync', orderBy: 'rowid');
    return rows
        .map(
          (row) => PendingSyncOperation(
            decisionId: row['decision_id']! as String,
            registrationId: row['registration_id']! as String,
            kind: PendingSyncKind.fromCode(row['kind']! as String),
            payloadJson: row['payload_json']! as String,
            createdAt:
                DateTime.tryParse(row['created_at']! as String)?.toUtc() ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          ),
        )
        .toList();
  }

  Future<void> removePendingSync(String decisionId) => _serialized(() async {
    await database.delete(
      'admin_pending_sync',
      where: 'decision_id = ?',
      whereArgs: [decisionId],
    );
  });

  Future<void> saveRegistration(
    CampusRegistration registration, {
    PendingSyncOperation? pendingSync,
    bool removePendingForRegistration = false,
    bool syncDeviceList = true,
  }) => _serialized(() async {
    await database.transaction((transaction) async {
      await transaction.insert('admin_registrations', {
        'registration_id': registration.registrationId,
        'device_id': registration.activePhone.deviceId,
        'account_uid': registration.accountUid,
        'status': registration.status.code,
        'sync_state': registration.syncState.code,
        'record_json': jsonEncode(registration.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (syncDeviceList && registration.activePhone.deviceId.isNotEmpty) {
        final device = registration.toRegisteredDevice();
        await transaction.insert('admin_devices', {
          'device_id': device.deviceId,
          'record_json': jsonEncode(device.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (removePendingForRegistration) {
        await transaction.delete(
          'admin_pending_sync',
          where: 'registration_id = ?',
          whereArgs: [registration.registrationId],
        );
      }
      if (pendingSync != null) {
        await transaction.insert('admin_pending_sync', {
          'decision_id': pendingSync.decisionId,
          'registration_id': pendingSync.registrationId,
          'kind': pendingSync.kind.name,
          'payload_json': pendingSync.payloadJson,
          'created_at': pendingSync.createdAt.toUtc().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  });

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
  }) => _serialized(() async {
    if (registration.accountUid != null &&
        registration.accountUid == reviewer.uid) {
      throw StateError(
        'Another reviewer must approve your own account registration.',
      );
    }
    if (reviewer.uid.trim().isEmpty) {
      throw StateError('An identifiable reviewer session is required.');
    }
    final identity = await _requireIdentity();
    final now = DateTime.now().toUtc();
    final snapshot = registration.submittedSnapshot ?? registration.identity;
    final editedFields = reviewedIdentity.diffKeysFrom(snapshot);
    final decisionId = CampusRegistration.newDecisionId();
    final updatedRegistration = registration.copyWith(
      identity: reviewedIdentity,
      submittedSnapshot: snapshot,
      role: role,
      status: CampusRegistrationStatus.approvedLocal,
      syncState: CampusSyncState.waitingToSync,
      conflictReason: null,
      revision: registration.revision + 1,
      updatedAt: now,
      pendingDecisionId: decisionId,
      reviewHistory: [
        ...registration.reviewHistory,
        RegistrationDecisionEntry(
          decisionId: decisionId,
          reviewerUid: reviewer.uid,
          reviewerEmail: reviewer.email,
          status: CampusRegistrationStatus.approvedLocal.code,
          role: role.name,
          reason: reason.trim(),
          revision: registration.revision + 1,
          editedFields: editedFields,
          createdAt: now,
        ),
      ],
    );

    final devices = await _loadDevices();
    final targetDevice = updatedRegistration.toRegisteredDevice();
    final existingIdx = devices.indexWhere(
      (d) => d.deviceId.toLowerCase() == targetDevice.deviceId.toLowerCase(),
    );
    if (existingIdx < 0) {
      devices.add(targetDevice);
    } else {
      devices[existingIdx] = targetDevice;
    }

    final cachedRoster = await _loadLastPublishedRoster();
    String bundleJson = '';
    int baseVersion = 0;
    if (cachedRoster != null) {
      try {
        final parsedCached = TrustBundle.fromJsonString(
          cachedRoster.bundleJson,
        );
        await _verifyPublishedBundleForAdmin(
          parsedCached,
          identity,
          project: directoryProject,
        );
        if (!parsedCached.isExpiredAt(now)) {
          if (parsedCached.publisherDelegation != null) {
            await parsedCached.publisherDelegation!.verify(
              now: now,
              expectedProject: directoryProject,
            );
          }
          bundleJson = cachedRoster.bundleJson;
          baseVersion = parsedCached.bundleVersion;
        }
      } on FormatException {
        bundleJson = '';
        baseVersion = 0;
      } on StateError {
        bundleJson = '';
        baseVersion = 0;
      }
    }
    final receiptIssuer = _issuerFromPublicBytes(identity.publicBytes);
    final receiptIssuedAt = now;
    final receiptExpiresAt = now.add(const Duration(days: 30));
    final phone = updatedRegistration.activePhone;
    if (phone.publicKey == null || phone.signingPublicKey == null) {
      throw StateError('Phone encryption and signing keys are required.');
    }
    final receipt = await SignedApprovalReceipt.createSigned(
      registrationId: updatedRegistration.registrationId,
      deviceId: phone.deviceId,
      publicKey: phone.publicKey!,
      signingPublicKey: phone.signingPublicKey!,
      keyVersion: phone.keyVersion,
      ownerName: updatedRegistration.identity.displayName,
      role: role.name,
      status: 'approved',
      baseBundleVersion: baseVersion,
      issuer: receiptIssuer,
      issuerKeyPair: identity.keyPair,
      issuedAt: receiptIssuedAt,
      expiresAt: receiptExpiresAt,
      directoryProject: directoryProject,
    );
    final packageJson = ApprovalQrPackage(
      bundleJson: bundleJson,
      receipt: receipt,
    ).toJsonString();
    final syncOp = PendingSyncOperation(
      decisionId: decisionId,
      registrationId: updatedRegistration.registrationId,
      kind: PendingSyncKind.publishManual,
      payloadJson: jsonEncode({'decision_id': decisionId}),
      createdAt: now,
    );

    await database.transaction((transaction) async {
      await _replaceDevices(transaction, devices);
      await transaction.insert('admin_registrations', {
        'registration_id': updatedRegistration.registrationId,
        'device_id': updatedRegistration.activePhone.deviceId,
        'account_uid': updatedRegistration.accountUid,
        'status': updatedRegistration.status.code,
        'sync_state': updatedRegistration.syncState.code,
        'record_json': jsonEncode(updatedRegistration.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await transaction.delete(
        'admin_pending_sync',
        where: 'registration_id = ?',
        whereArgs: [updatedRegistration.registrationId],
      );
      await transaction.insert('admin_pending_sync', {
        'decision_id': syncOp.decisionId,
        'registration_id': syncOp.registrationId,
        'kind': syncOp.kind.name,
        'payload_json': syncOp.payloadJson,
        'created_at': syncOp.createdAt.toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });

    return (
      bundleJson: bundleJson,
      packageJson: packageJson,
      receipt: receipt,
      registration: updatedRegistration,
    );
  });

  Future<List<CampusRegistration>> reconcileWithPublishedRoster(
    TrustBundle published,
    String project,
  ) => _serialized(() async {
    final identity = await _requireIdentity();
    await _verifyPublishedBundleForAdmin(published, identity, project: project);

    final revokedMap = {
      for (final r in published.revokedDevices) r.deviceId.toLowerCase(): r,
    };
    final approvedMap = {
      for (final a in published.approvedDevices) a.deviceId.toLowerCase(): a,
    };
    final pendingOps = await _loadPendingSync();
    final pendingCorrectionRegIds = {
      for (final op in pendingOps)
        if (op.kind == PendingSyncKind.publishRevocationCorrection)
          op.registrationId,
    };
    final pendingReplacementByRegId = <String, Map<String, dynamic>>{};
    for (final op in pendingOps) {
      if (op.kind == PendingSyncKind.publishReplacement ||
          op.kind == PendingSyncKind.publishRecovery) {
        try {
          final decoded = jsonDecode(op.payloadJson);
          if (decoded is Map<String, dynamic>) {
            pendingReplacementByRegId[op.registrationId] = decoded;
          }
        } catch (_) {}
      }
    }
    final registrations = await _loadRegistrations();
    final updated = <CampusRegistration>[];
    final schoolIdOwners = <String, String>{};
    final accountOwners = <String, String>{};

    for (final reg in registrations) {
      if (reg.status == CampusRegistrationStatus.deleted) {
        updated.add(reg);
        continue;
      }
      final sid = reg.identity.schoolId.toLowerCase();
      if (sid.isNotEmpty) {
        final prior = schoolIdOwners[sid];
        if (prior != null && prior != reg.registrationId) {
          final flagged = reg.copyWith(
            status: CampusRegistrationStatus.conflict,
            syncState: CampusSyncState.conflict,
            conflictReason:
                'Conflicting registration shares school ID ${reg.identity.schoolId}.',
          );
          updated.add(flagged);
          continue;
        }
        schoolIdOwners[sid] = reg.registrationId;
      }
      if (reg.accountUid != null && reg.accountUid!.isNotEmpty) {
        final priorAcc = accountOwners[reg.accountUid!];
        if (priorAcc != null && priorAcc != reg.registrationId) {
          updated.add(
            reg.copyWith(
              status: CampusRegistrationStatus.conflict,
              syncState: CampusSyncState.conflict,
              conflictReason:
                  'Conflicting registration shares the same account.',
            ),
          );
          continue;
        }
        accountOwners[reg.accountUid!] = reg.registrationId;
      }

      final devKey = reg.activePhone.deviceId.toLowerCase();
      final remoteRevoked = revokedMap[devKey];
      final remoteApproved = approvedMap[devKey];

      if (remoteRevoked != null &&
          reg.status == CampusRegistrationStatus.approvedLocal) {
        if (_matchesReviewedTargetRevocation(
          pendingOp: pendingReplacementByRegId[reg.registrationId],
          registration: reg,
          remoteRevoked: remoteRevoked,
          publishedBundleVersion: published.bundleVersion,
        )) {
          updated.add(reg);
          continue;
        }
        final examinedVersion = reg.resolvedConflictVersion;
        if (pendingCorrectionRegIds.contains(reg.registrationId) &&
            examinedVersion != null &&
            examinedVersion >= published.bundleVersion) {
          updated.add(reg);
          continue;
        }
        updated.add(
          reg.copyWith(
            status: CampusRegistrationStatus.conflict,
            syncState: CampusSyncState.conflict,
            conflictReason:
                'A newer revocation exists in the published directory. Review and issue a signed correction.',
          ),
        );
        continue;
      }
      if (remoteApproved != null &&
          (remoteApproved.publicKey != reg.activePhone.publicKey ||
              remoteApproved.signingPublicKey !=
                  reg.activePhone.signingPublicKey)) {
        if (_matchesPendingSameIdReplacement(
          pendingOp: pendingReplacementByRegId[reg.registrationId],
          registration: reg,
          remoteApproved: remoteApproved,
          publishedBundleVersion: published.bundleVersion,
        )) {
          updated.add(reg);
          continue;
        }
        updated.add(
          reg.copyWith(
            status: CampusRegistrationStatus.conflict,
            syncState: CampusSyncState.conflict,
            conflictReason:
                'Published keys for ${reg.activePhone.deviceId} differ from the local record.',
          ),
        );
        continue;
      }
      updated.add(reg);
    }

    await database.transaction((transaction) async {
      await _replaceRegistrations(transaction, updated);
      for (final reg in updated) {
        if (reg.status == CampusRegistrationStatus.conflict) {
          await transaction.delete(
            'admin_pending_sync',
            where: 'registration_id = ? AND kind NOT IN (?, ?)',
            whereArgs: [
              reg.registrationId,
              PendingSyncKind.publishReplacement.name,
              PendingSyncKind.publishRecovery.name,
            ],
          );
        }
      }
    });
    return updated;
  });

  static bool _matchesReviewedTargetRevocation({
    required Map<String, dynamic>? pendingOp,
    required CampusRegistration registration,
    required TrustedDevice remoteRevoked,
    required int publishedBundleVersion,
  }) {
    if (pendingOp == null ||
        registration.status != CampusRegistrationStatus.approvedLocal ||
        registration.syncState != CampusSyncState.waitingToSync ||
        registration.pendingDecisionId != pendingOp['decision_id']) {
      return false;
    }
    final reviewedVersion = pendingOp['reviewed_bundle_version'];
    final reviewedTarget = pendingOp['reviewed_target_revocation'];
    final reviewedBinding = pendingOp['new_phone_binding'];
    if (reviewedVersion is! int ||
        reviewedVersion > publishedBundleVersion ||
        reviewedTarget is! Map<String, dynamic> ||
        reviewedBinding is! Map<String, dynamic>) {
      return false;
    }
    final phone = registration.activePhone;
    return reviewedBinding['device_id'] == phone.deviceId &&
        reviewedBinding['public_key'] == phone.publicKey &&
        reviewedBinding['signing_public_key'] == phone.signingPublicKey &&
        reviewedBinding['key_version'] == phone.keyVersion &&
        // Compare the full reviewed record, including its revocation timestamp.
        // An unrelated publication may advance the bundle version; a changed
        // revocation or binding always needs another review.
        canonicalJsonEncode(reviewedTarget) ==
            canonicalJsonEncode(remoteRevoked.toJson());
  }

  static bool _matchesPendingSameIdReplacement({
    required Map<String, dynamic>? pendingOp,
    required CampusRegistration registration,
    required TrustedDevice remoteApproved,
    required int publishedBundleVersion,
  }) {
    if (pendingOp == null ||
        registration.status != CampusRegistrationStatus.approvedLocal ||
        registration.syncState != CampusSyncState.waitingToSync) {
      return false;
    }
    final devKey = remoteApproved.deviceId.trim().toLowerCase();
    final oldDeviceId = (pendingOp['old_device_id'] as String?)
        ?.trim()
        .toLowerCase();
    final newDeviceId = (pendingOp['new_device_id'] as String?)
        ?.trim()
        .toLowerCase();
    if (oldDeviceId == null || oldDeviceId != devKey) {
      return false;
    }
    if (newDeviceId != null &&
        newDeviceId.isNotEmpty &&
        newDeviceId != devKey) {
      return false;
    }
    final oldPublicKey = pendingOp['old_public_key'] as String?;
    final oldSigningKey = pendingOp['old_signing_public_key'] as String?;
    if ((oldPublicKey != null && oldPublicKey.isNotEmpty) ||
        (oldSigningKey != null && oldSigningKey.isNotEmpty)) {
      final pubMatches =
          oldPublicKey == null ||
          oldPublicKey.isEmpty ||
          remoteApproved.publicKey == oldPublicKey;
      final signMatches =
          oldSigningKey == null ||
          oldSigningKey.isEmpty ||
          remoteApproved.signingPublicKey == oldSigningKey;
      return pubMatches && signMatches;
    }
    final expectedVersion = pendingOp['expected_bundle_version'] as int?;
    return expectedVersion != null && expectedVersion >= publishedBundleVersion;
  }

  Future<({String bundleJson, CampusRegistration registration})>
  issueSignedCorrection({
    required CampusRegistration registration,
    required ReviewerProfile reviewer,
    required RegisteredDeviceStatus targetStatus,
    required RegisteredDeviceRole role,
    required int remoteVersion,
    required String directoryProject,
    String reason = '',
  }) => _serialized(() async {
    final now = DateTime.now().toUtc();
    final decisionId = CampusRegistration.newDecisionId();
    final nextStatus = targetStatus == RegisteredDeviceStatus.revoked
        ? CampusRegistrationStatus.revoked
        : CampusRegistrationStatus.approvedLocal;
    final corrected = registration.copyWith(
      role: role,
      status: nextStatus,
      syncState: CampusSyncState.waitingToSync,
      conflictReason: null,
      resolvedConflictVersion: remoteVersion,
      revision: registration.revision + 1,
      updatedAt: now,
      pendingDecisionId: decisionId,
      reviewHistory: [
        ...registration.reviewHistory,
        RegistrationDecisionEntry(
          decisionId: decisionId,
          reviewerUid: reviewer.uid,
          reviewerEmail: reviewer.email,
          status: nextStatus.code,
          role: role.name,
          reason: reason.isEmpty ? 'Signed conflict correction' : reason,
          revision: registration.revision + 1,
          createdAt: now,
        ),
      ],
    );
    final devices = await _loadDevices();
    final deviceRecord = corrected.toRegisteredDevice();
    final idx = devices.indexWhere(
      (d) => d.deviceId.toLowerCase() == deviceRecord.deviceId.toLowerCase(),
    );
    if (idx < 0) {
      devices.add(deviceRecord);
    } else {
      devices[idx] = deviceRecord;
    }
    final bundleJson = await _buildTrustBundleJson(
      devices,
      directoryProject,
      remoteVersion,
    );
    await database.transaction((transaction) async {
      await _replaceDevices(transaction, devices);
      await transaction.insert('admin_registrations', {
        'registration_id': corrected.registrationId,
        'device_id': corrected.activePhone.deviceId,
        'account_uid': corrected.accountUid,
        'status': corrected.status.code,
        'sync_state': corrected.syncState.code,
        'record_json': jsonEncode(corrected.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await transaction.delete(
        'admin_pending_sync',
        where: 'registration_id = ?',
        whereArgs: [corrected.registrationId],
      );
      await transaction.insert('admin_pending_sync', {
        'decision_id': decisionId,
        'registration_id': corrected.registrationId,
        'kind': PendingSyncKind.publishRevocationCorrection.name,
        'payload_json': jsonEncode({
          'decision_id': decisionId,
          'resolved_conflict_version': remoteVersion,
        }),
        'created_at': now.toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return (bundleJson: bundleJson, registration: corrected);
  });

  static List<RegisteredDevice> replacementLocalChanges({
    required CampusRegistration publishedRegistration,
    CampusRegistration? previousRegistration,
    Map<String, dynamic>? opPayload,
    TrustBundle? publishedBundle,
    DateTime? now,
  }) {
    final newDevice = publishedRegistration.toRegisteredDevice();
    final newIdLower = newDevice.deviceId.trim().toLowerCase();
    final ts = (now ?? DateTime.now()).toUtc();
    RegisteredDevice? retiredOld;

    if (previousRegistration != null) {
      final prevId = previousRegistration.activePhone.deviceId.trim();
      if (prevId.isNotEmpty && prevId.toLowerCase() != newIdLower) {
        retiredOld = previousRegistration
            .copyWith(status: CampusRegistrationStatus.revoked, updatedAt: ts)
            .toRegisteredDevice()
            .copyWith(
              status: RegisteredDeviceStatus.revoked,
              updatedAt: ts,
              lastSeenLabel: 'Replaced by ${newDevice.deviceId}',
            );
      }
    } else if (opPayload != null) {
      final oldId = (opPayload['old_device_id'] as String? ?? '').trim();
      if (oldId.isNotEmpty && oldId.toLowerCase() != newIdLower) {
        final fromBundle = publishedBundle?.approvedDevices
            .where((d) => d.deviceId.toLowerCase() == oldId.toLowerCase())
            .firstOrNull;
        final ownerName =
            (opPayload['old_owner_name'] as String?) ??
            fromBundle?.ownerName ??
            (publishedRegistration.identity.displayName.trim().isEmpty
                ? 'Replaced phone'
                : publishedRegistration.identity.displayName.trim());
        retiredOld = RegisteredDevice(
          deviceId: oldId,
          ownerName: ownerName,
          phoneNumber: '',
          address: '',
          role: RegisteredDeviceRole.fromCode(
            (opPayload['old_role'] as String?) ??
                fromBundle?.role ??
                publishedRegistration.role.name,
          ),
          status: RegisteredDeviceStatus.revoked,
          registeredAt: publishedRegistration.createdAt,
          updatedAt: ts,
          lastSeenLabel: 'Replaced by ${newDevice.deviceId}',
          publicKey:
              (opPayload['old_public_key'] as String?) ?? fromBundle?.publicKey,
          signingPublicKey:
              (opPayload['old_signing_public_key'] as String?) ??
              fromBundle?.signingPublicKey,
          keyVersion:
              (opPayload['old_key_version'] as int?) ??
              fromBundle?.keyVersion ??
              1,
        );
      }
    }

    return [
      if (retiredOld != null &&
          retiredOld.deviceId.trim().toLowerCase() != newIdLower)
        retiredOld,
      newDevice,
    ];
  }

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
  }) => _serialized(() async {
    if (registration.accountUid != null &&
        registration.accountUid == reviewer.uid) {
      throw StateError('Another reviewer must approve your phone replacement.');
    }
    final identity = await _requireIdentity();
    if (publishedBundle != null) {
      await _verifyPublishedBundleForAdmin(
        publishedBundle,
        identity,
        project: directoryProject,
      );
    }
    final reviewedTargetRevocation = publishedBundle?.revokedDevices
        .where(
          (device) =>
              device.deviceId.trim().toLowerCase() ==
              newPhone.deviceId.trim().toLowerCase(),
        )
        .firstOrNull;
    final now = DateTime.now().toUtc();
    final oldPhone = registration.activePhone;
    final sameId =
        oldPhone.deviceId.toLowerCase() == newPhone.deviceId.toLowerCase();
    final nextKeyVersion = newPhone.keyVersion;
    final resolvedPhone = RegistrationPhoneBinding(
      deviceId: newPhone.deviceId,
      publicKey: newPhone.publicKey,
      signingPublicKey: newPhone.signingPublicKey,
      keyId: newPhone.keyId,
      keyVersion: nextKeyVersion,
      deviceRegistrationJson: newPhone.deviceRegistrationJson,
    );
    final retiredEntry = RetiredKeyRecord(
      deviceId: oldPhone.deviceId,
      publicKeyFingerprint: RetiredKeyRecord.fingerprintForKey(
        oldPhone.publicKey,
      ),
      signingKeyFingerprint: RetiredKeyRecord.fingerprintForKey(
        oldPhone.signingPublicKey,
      ),
      keyVersion: oldPhone.keyVersion,
      retiredAt: now,
      reason: reason,
      reviewerUid: reviewer.uid,
    );
    final decisionId = CampusRegistration.newDecisionId();
    final updatedRegistration = registration.copyWith(
      status: CampusRegistrationStatus.approvedLocal,
      syncState: CampusSyncState.waitingToSync,
      conflictReason: null,
      activePhone: resolvedPhone,
      retiredKeys: [...registration.retiredKeys, retiredEntry],
      revision: registration.revision + 1,
      updatedAt: now,
      pendingDecisionId: decisionId,
      reviewHistory: [
        ...registration.reviewHistory,
        RegistrationDecisionEntry(
          decisionId: decisionId,
          reviewerUid: reviewer.uid,
          reviewerEmail: reviewer.email,
          status: 'phone_replaced',
          role: registration.role.name,
          reason: reason,
          revision: registration.revision + 1,
          createdAt: now,
        ),
      ],
    );

    final devices = await _loadDevices();
    final nextDevices = <RegisteredDevice>[];
    var addedNew = false;
    var revokedOld = false;
    for (final existing in devices) {
      if (existing.deviceId.toLowerCase() == oldPhone.deviceId.toLowerCase()) {
        if (sameId) {
          nextDevices.add(updatedRegistration.toRegisteredDevice());
          addedNew = true;
        } else {
          nextDevices.add(
            existing.copyWith(
              status: RegisteredDeviceStatus.revoked,
              updatedAt: now,
              lastSeenLabel: 'Replaced by ${resolvedPhone.deviceId}',
            ),
          );
          revokedOld = true;
        }
      } else if (existing.deviceId.toLowerCase() ==
          resolvedPhone.deviceId.toLowerCase()) {
        nextDevices.add(updatedRegistration.toRegisteredDevice());
        addedNew = true;
      } else {
        nextDevices.add(existing);
      }
    }
    if (!sameId && !revokedOld && oldPhone.deviceId.trim().isNotEmpty) {
      nextDevices.add(
        RegisteredDevice(
          deviceId: oldPhone.deviceId,
          ownerName: registration.identity.displayName.trim().isEmpty
              ? 'Replaced phone'
              : registration.identity.displayName.trim(),
          phoneNumber: registration.identity.phone.trim(),
          address: registration.identity.address.trim(),
          role: registration.role,
          status: RegisteredDeviceStatus.revoked,
          registeredAt: registration.createdAt,
          updatedAt: now,
          lastSeenLabel: 'Replaced by ${resolvedPhone.deviceId}',
          publicKey: oldPhone.publicKey,
          signingPublicKey: oldPhone.signingPublicKey,
          keyVersion: oldPhone.keyVersion,
        ),
      );
    }
    if (!addedNew) {
      nextDevices.add(updatedRegistration.toRegisteredDevice());
    }

    final bundleJson = await _buildTrustBundleJson(
      nextDevices,
      directoryProject,
      previousVersion,
    );
    final syncAccountUid = accountUid ?? registration.accountUid;
    final syncOp = PendingSyncOperation(
      decisionId: decisionId,
      registrationId: updatedRegistration.registrationId,
      kind: syncKind,
      payloadJson: jsonEncode({
        'decision_id': decisionId,
        'old_device_id': oldPhone.deviceId,
        if (oldPhone.publicKey != null) 'old_public_key': oldPhone.publicKey,
        if (oldPhone.signingPublicKey != null)
          'old_signing_public_key': oldPhone.signingPublicKey,
        'old_key_version': oldPhone.keyVersion,
        'old_owner_name': registration.identity.displayName.trim().isEmpty
            ? 'Replaced phone'
            : registration.identity.displayName.trim(),
        'old_role': registration.role.name,
        'expected_bundle_version': previousVersion,
        'new_device_id': resolvedPhone.deviceId,
        'new_phone_binding': resolvedPhone.toJson(),
        if (publishedBundle != null)
          'reviewed_bundle_version': publishedBundle.bundleVersion,
        if (reviewedTargetRevocation != null)
          'reviewed_target_revocation': reviewedTargetRevocation.toJson(),
        if (expectedRequestUpdateTime != null)
          'expected_request_update_time': expectedRequestUpdateTime,
        if (resolvedPhone.deviceRegistrationJson != null)
          'new_device_registration': resolvedPhone.deviceRegistrationJson,
        'reason': reason,
        if (verificationMethod != null)
          'verification_method': verificationMethod,
        if (syncAccountUid != null) 'account_uid': syncAccountUid,
        'expected_revision': registration.revision,
      }),
      createdAt: now,
    );
    await database.transaction((transaction) async {
      await _replaceDevices(transaction, nextDevices);
      await transaction.insert('admin_registrations', {
        'registration_id': updatedRegistration.registrationId,
        'device_id': updatedRegistration.activePhone.deviceId,
        'account_uid': updatedRegistration.accountUid,
        'status': updatedRegistration.status.code,
        'sync_state': updatedRegistration.syncState.code,
        'record_json': jsonEncode(updatedRegistration.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await transaction.delete(
        'admin_pending_sync',
        where: 'registration_id = ?',
        whereArgs: [updatedRegistration.registrationId],
      );
      await transaction.insert('admin_pending_sync', {
        'decision_id': syncOp.decisionId,
        'registration_id': syncOp.registrationId,
        'kind': syncOp.kind.name,
        'payload_json': syncOp.payloadJson,
        'created_at': syncOp.createdAt.toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return (bundleJson: bundleJson, registration: updatedRegistration);
  });

  Future<void> _replaceRegistrations(
    DatabaseExecutor executor,
    List<CampusRegistration> registrations,
  ) async {
    await executor.delete('admin_registrations');
    for (final registration in registrations) {
      await executor.insert('admin_registrations', {
        'registration_id': registration.registrationId,
        'device_id': registration.activePhone.deviceId,
        'account_uid': registration.accountUid,
        'status': registration.status.code,
        'sync_state': registration.syncState.code,
        'record_json': jsonEncode(registration.toJson()),
      });
    }
  }

  Future<void> _replacePendingSync(
    DatabaseExecutor executor,
    List<PendingSyncOperation> ops,
  ) async {
    await executor.delete('admin_pending_sync');
    for (final op in ops) {
      await executor.insert('admin_pending_sync', {
        'decision_id': op.decisionId,
        'registration_id': op.registrationId,
        'kind': op.kind.name,
        'payload_json': op.payloadJson,
        'created_at': op.createdAt.toUtc().toIso8601String(),
      });
    }
  }

  static List<CampusRegistration> _decodeRegistrations(Object? raw) {
    if (raw is! List || raw.length > 10000) {
      throw const FormatException('Invalid registrations backup contents.');
    }
    return raw.map((item) {
      if (item is! Map) {
        throw const FormatException('Invalid registration record in backup.');
      }
      final reg = CampusRegistration.fromJson(Map<String, Object?>.from(item));
      if (reg.registrationId.isEmpty || reg.activePhone.deviceId.isEmpty) {
        throw const FormatException('Invalid registration record in backup.');
      }
      return reg;
    }).toList();
  }

  static List<PendingSyncOperation> _decodePendingSync(Object? raw) {
    if (raw is! List || raw.length > 10000) {
      throw const FormatException('Invalid pending sync backup contents.');
    }
    return raw.map((item) {
      if (item is! Map) {
        throw const FormatException('Invalid pending sync entry in backup.');
      }
      final op = PendingSyncOperation.fromJson(Map<String, Object?>.from(item));
      if (op.decisionId.isEmpty || op.registrationId.isEmpty) {
        throw const FormatException('Invalid pending sync entry in backup.');
      }
      return op;
    }).toList();
  }

  TrustedDevice _trustDevice(RegisteredDevice device) =>
      TrustedDevice.fromJson(device.toJson());

  static List<RegisteredDevice> _decodeDevices(Object? raw) {
    if (raw is! List || raw.length > 10000) {
      throw const FormatException('Invalid administrator registry.');
    }
    final ids = <String>{};
    final result = <RegisteredDevice>[];
    const required = {
      'device_id',
      'owner_name',
      'role',
      'status',
      'registered_at',
      'updated_at',
      'last_seen_label',
      'key_version',
    };
    const allowed = {
      ...required,
      'public_key',
      'signing_public_key',
      'notes',
      'phone_number',
      'address',
    };
    for (final value in raw) {
      if (value is! Map ||
          !value.keys.every(allowed.contains) ||
          !required.every(value.containsKey)) {
        throw const FormatException('Invalid device record fields.');
      }
      final map = Map<String, Object?>.from(value);
      for (final field in ['phone_number', 'address']) {
        final contact = map[field];
        if (contact != null && (contact is! String || contact.length > 4096)) {
          throw const FormatException('Invalid user contact field.');
        }
      }
      for (final field in [
        'device_id',
        'owner_name',
        'role',
        'status',
        'registered_at',
        'updated_at',
        'last_seen_label',
      ]) {
        if (map[field] is! String || (map[field]! as String).length > 4096) {
          throw const FormatException('Invalid device text field.');
        }
      }
      final id = (map['device_id']! as String).trim().toLowerCase();
      if (id.isEmpty ||
          !ids.add(id) ||
          (map['owner_name']! as String).trim().isEmpty ||
          !RegisteredDeviceRole.values.any(
            (role) => role.name == map['role'],
          ) ||
          !RegisteredDeviceStatus.values.any(
            (status) => status.name == map['status'],
          ) ||
          map['key_version'] is! int ||
          (map['key_version']! as int) <= 0 ||
          (map['key_version']! as int) > _maxVersion ||
          DateTime.tryParse(map['registered_at']! as String) == null ||
          DateTime.tryParse(map['updated_at']! as String) == null ||
          (map['notes'] != null &&
              (map['notes'] is! String ||
                  (map['notes']! as String).length > 16384))) {
        throw const FormatException('Device record is invalid or duplicated.');
      }
      for (final field in ['public_key', 'signing_public_key']) {
        final key = map[field];
        if (key == null &&
            !(field == 'public_key' && map['status'] == 'approved')) {
          continue;
        }
        if (key is! String ||
            key.length > 128 ||
            base64Url.decode(key).length != 32) {
          throw const FormatException('Device public key is invalid.');
        }
      }
      result.add(RegisteredDevice.fromJson(map));
    }
    return result;
  }
}

class _SigningIdentity {
  _SigningIdentity(
    this.seed,
    this.publicBytes,
    this.keyPair,
    this.bundleVersion,
  );
  final List<int> seed;
  final List<int> publicBytes;
  final SimpleKeyPair keyPair;
  final int bundleVersion;
  _SigningIdentity withBundleVersion(int value) =>
      _SigningIdentity(seed, publicBytes, keyPair, value);
  String get publicKey => base64UrlEncode(publicBytes);
  String get fingerprint => sha256.convert(publicBytes).toString();
  String get source => jsonEncode({
    'private_key': base64UrlEncode(seed),
    'public_key': publicKey,
    'bundle_version': bundleVersion,
  });

  static Future<_SigningIdentity> create() async {
    final pair = await Ed25519().newKeyPair();
    return _SigningIdentity(
      await pair.extractPrivateKeyBytes(),
      (await pair.extractPublicKey()).bytes,
      pair,
      0,
    );
  }

  static Future<_SigningIdentity> decode(String source) async {
    try {
      return await _decode(source);
    } on FormatException {
      // Low-level decoders include source data in their errors. Keep private
      // material out of UI errors and logs even for corrupt backup contents.
      throw const FormatException('Invalid administrator signing identity.');
    }
  }

  static Future<_SigningIdentity> _decode(String source) async {
    if (source.length > 1024) {
      throw const FormatException('Invalid signing identity.');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map ||
        decoded.length != 3 ||
        decoded['private_key'] is! String ||
        decoded['public_key'] is! String ||
        decoded['bundle_version'] is! int ||
        (decoded['bundle_version'] as int) < 0 ||
        (decoded['bundle_version'] as int) >
            DesktopAdminRegistryRepository._maxVersion) {
      throw const FormatException('Invalid signing identity.');
    }
    final seed = base64Url.decode(decoded['private_key'] as String);
    final publicBytes = base64Url.decode(decoded['public_key'] as String);
    if (seed.length != 32 || publicBytes.length != 32) {
      throw const FormatException('Invalid signing key size.');
    }
    final pair = await Ed25519().newKeyPairFromSeed(seed);
    if (base64UrlEncode((await pair.extractPublicKey()).bytes) !=
        base64UrlEncode(publicBytes)) {
      throw const FormatException(
        'Signing private and public keys do not agree.',
      );
    }
    return _SigningIdentity(
      seed,
      publicBytes,
      pair,
      decoded['bundle_version'] as int,
    );
  }
}
