import 'package:sqflite/sqflite.dart';

import '../../../messaging/data/datasources/local_messaging_database.dart';
import '../../domain/entities/device_trust_record.dart';
import '../../domain/entities/device_trust_status.dart';
import '../../domain/entities/trust_bundle.dart';
import '../../domain/repositories/trust_repository.dart';

class SqliteTrustRepository implements TrustRepository {
  const SqliteTrustRepository({required Database database})
    : _database = database;

  final Database _database;

  @override
  Future<void> replaceFromBundle(TrustBundle bundle) async {
    if (!bundle.isSignatureVerified ||
        bundle.bundleHash == null ||
        bundle.importedAt == null ||
        bundle.issuer == null ||
        bundle.issuedAt == null ||
        bundle.expiresAt == null) {
      throw const FormatException(
        'Only a verified signed trust bundle can replace local trust state.',
      );
    }

    await _database.transaction((transaction) async {
      await transaction.delete(LocalMessagingDatabase.trustedDevicesTable);
      for (final device in bundle.approvedDevices) {
        await _insertDevice(
          transaction,
          device,
          status: DeviceTrustStatus.approved,
          bundle: bundle,
        );
      }
      for (final device in bundle.revokedDevices) {
        await _insertDevice(
          transaction,
          device,
          status: DeviceTrustStatus.revoked,
          bundle: bundle,
        );
      }
      await transaction.insert(
        LocalMessagingDatabase.trustBundleMetadataTable,
        {
          'singleton_id': 1,
          'bundle_version': bundle.bundleVersion,
          'bundle_hash': bundle.bundleHash,
          'issuer_id': bundle.issuer!.issuerId,
          'signing_key_id': bundle.issuer!.signingKeyId,
          'issued_at': bundle.issuedAt!.toIso8601String(),
          'expires_at': bundle.expiresAt!.toIso8601String(),
          'imported_at': bundle.importedAt!.toIso8601String(),
          'signature_verified': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  @override
  Future<DeviceTrustRecord> getDevice(String deviceId) async {
    final rows = await _database.query(
      LocalMessagingDatabase.trustedDevicesTable,
      where: 'LOWER(device_id) = ?',
      whereArgs: [deviceId.trim().toLowerCase()],
      limit: 1,
    );
    if (rows.isEmpty) {
      return DeviceTrustRecord.unknown(deviceId);
    }
    final record = _recordFromMap(rows.single);
    if (record.status != DeviceTrustStatus.approved) {
      return record;
    }
    final metadata = await getMetadata();
    if (metadata == null ||
        !metadata.expiresAt.isAfter(DateTime.now().toUtc())) {
      return DeviceTrustRecord(
        deviceId: record.deviceId,
        ownerName: record.ownerName,
        role: record.role,
        status: DeviceTrustStatus.unknown,
        publicKey: record.publicKey,
        keyVersion: record.keyVersion,
        bundleVersion: record.bundleVersion,
        bundleHash: record.bundleHash,
        adminUpdatedAt: record.adminUpdatedAt,
        importedAt: record.importedAt,
      );
    }
    return record;
  }

  @override
  Future<List<DeviceTrustRecord>> getDevices() async {
    final rows = await _database.query(
      LocalMessagingDatabase.trustedDevicesTable,
      orderBy: 'status ASC, owner_name ASC',
    );
    return rows.map(_recordFromMap).toList(growable: false);
  }

  @override
  Future<TrustBundleMetadata?> getMetadata() async {
    final rows = await _database.query(
      LocalMessagingDatabase.trustBundleMetadataTable,
      where: 'singleton_id = 1',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.single;
    return TrustBundleMetadata(
      bundleVersion: row['bundle_version']! as int,
      bundleHash: row['bundle_hash']! as String,
      issuerId: row['issuer_id']! as String,
      signingKeyId: row['signing_key_id']! as String,
      issuedAt: DateTime.parse(row['issued_at']! as String),
      expiresAt: DateTime.parse(row['expires_at']! as String),
      importedAt: DateTime.parse(row['imported_at']! as String),
      signatureVerified: (row['signature_verified']! as int) == 1,
    );
  }

  @override
  Future<void> clear() async {
    await _database.transaction((transaction) async {
      await transaction.delete(LocalMessagingDatabase.trustedDevicesTable);
      await transaction.delete(LocalMessagingDatabase.trustBundleMetadataTable);
    });
  }

  Future<void> _insertDevice(
    Transaction transaction,
    TrustedDevice device, {
    required DeviceTrustStatus status,
    required TrustBundle bundle,
  }) async {
    await transaction.insert(
      LocalMessagingDatabase.trustedDevicesTable,
      {
        'device_id': device.deviceId,
        'owner_name': device.ownerName,
        'role': device.role,
        'status': status.name,
        'public_key': device.publicKey,
        'key_version': device.keyVersion,
        'bundle_version': bundle.bundleVersion,
        'bundle_hash': bundle.bundleHash,
        'admin_updated_at': device.updatedAt.toIso8601String(),
        'imported_at': bundle.importedAt!.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  DeviceTrustRecord _recordFromMap(Map<String, Object?> row) {
    return DeviceTrustRecord(
      deviceId: row['device_id']! as String,
      ownerName: row['owner_name']! as String,
      role: row['role']! as String,
      status: DeviceTrustStatus.values.byName(row['status']! as String),
      publicKey: row['public_key'] as String?,
      keyVersion: row['key_version']! as int,
      bundleVersion: row['bundle_version']! as int,
      bundleHash: row['bundle_hash']! as String,
      adminUpdatedAt: DateTime.parse(row['admin_updated_at']! as String),
      importedAt: DateTime.parse(row['imported_at']! as String),
    );
  }
}
