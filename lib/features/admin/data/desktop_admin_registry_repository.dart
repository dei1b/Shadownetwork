import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';
import '../domain/entities/registered_device.dart';
import '../domain/repositories/admin_registry_repository.dart';
import 'admin_signing_key_store.dart';
import 'admin_registry_backup.dart';
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
    List<RegisteredDevice> devices,
  ) => _serialized(() async {
    final validated = _decodeDevices(
      devices.map((device) => device.toJson()).toList(),
    );
    final identity = await _requireIdentity();
    final metadataBeforeReservation = (await _metadata())!;
    final effectiveCurrent = max(
      metadataBeforeReservation['bundle_version']! as int,
      identity.bundleVersion,
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
  });

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
        return AdminRegistryBackup.encrypt({
          'version': 1,
          'identity': jsonDecode(backupIdentity.source),
          'fingerprint': identity.fingerprint,
          'bundle_version': version,
          'devices': (await _loadDevices())
              .map((device) => device.toJson())
              .toList(),
        }, password);
      });

  Future<void> restoreEncryptedBackup(
    String source,
    String password,
  ) => _serialized(() async {
    final payload = await AdminRegistryBackup.decrypt(source, password);
    if (payload.length != 5 ||
        !payload.keys.every(
          {
            'version',
            'identity',
            'fingerprint',
            'bundle_version',
            'devices',
          }.contains,
        ) ||
        payload['version'] is! int ||
        payload['version'] != 1 ||
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
    // No live writes occur until decryption, keypair and every record validate.
    final current = await _metadata();
    if ((await database.query('admin_devices', limit: 1)).isNotEmpty) {
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
    });
  });

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
    const allowed = {...required, 'public_key', 'signing_public_key', 'notes'};
    for (final value in raw) {
      if (value is! Map ||
          !value.keys.every(allowed.contains) ||
          !required.every(value.containsKey)) {
        throw const FormatException('Invalid device record fields.');
      }
      final map = Map<String, Object?>.from(value);
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
