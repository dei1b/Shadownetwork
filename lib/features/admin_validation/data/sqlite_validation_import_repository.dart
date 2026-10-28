import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../trust/domain/services/canonical_json.dart';
import '../../validation/domain/services/validation_bundle_codec.dart';
import '../../validation/domain/services/validation_export_service.dart';
import '../domain/validation_import.dart';

class SqliteValidationImportRepository implements ValidationImportRepository {
  SqliteValidationImportRepository({required Database database})
    : _database = database;
  final Database _database;

  @override
  Future<ValidationImportPreview> preview(
    List<ValidationImportFile> files,
  ) async {
    final decoded = await _decode(files);
    return _classify(decoded, await _existingFor(_database, decoded));
  }

  @override
  Future<ValidationImportCommitResult> commit(
    ValidationImportPreview preview,
  ) async {
    // Never trust cached preview classification or caller-created preview entries.
    final decoded = await _decode(preview.entries.map((e) => e.file).toList());
    return _database.transaction((transaction) async {
      final current = _classify(
        decoded,
        await _existingFor(transaction, decoded),
      );
      if (current.hasConflicts) throw const ValidationImportConflict();
      var imported = 0;
      var duplicates = 0;
      var errors = 0;
      for (var i = 0; i < current.entries.length; i++) {
        final entry = current.entries[i];
        switch (entry.status) {
          case ValidationImportStatus.valid:
            final dataset = entry.dataset!;
            await transaction.insert('validation_datasets', {
              'id': dataset.id,
              'canonical_source': decoded[i].canonical,
              'original_source': entry.file.source,
              'filename': entry.file.name,
              'schema_version': dataset.schemaVersion,
              'run_id': dataset.runId,
              'session_id': dataset.sessionId,
              'device_id': dataset.deviceId,
              'role': dataset.role,
              'exported_at': dataset.exportedAt?.toUtc().toIso8601String(),
              'imported_at': DateTime.now().toUtc().toIso8601String(),
              'event_count': dataset.eventCount,
              'receipt_count': dataset.receiptCount,
              'discovery_count': dataset.discoveryCount,
              'battery_count': dataset.batteryCount,
            });
            imported++;
          case ValidationImportStatus.duplicate:
            duplicates++;
          case ValidationImportStatus.error:
            errors++;
          case ValidationImportStatus.conflict:
            throw const ValidationImportConflict();
        }
      }
      return ValidationImportCommitResult(
        importedCount: imported,
        duplicateCount: duplicates,
        errorCount: errors,
      );
    });
  }

  @override
  Future<List<ValidationImportedDataset>> listDatasets() async =>
      (await _database.query(
        'validation_datasets',
        columns: [
          'id',
          'filename',
          'schema_version',
          'run_id',
          'session_id',
          'device_id',
          'role',
          'exported_at',
          'imported_at',
          'event_count',
          'receipt_count',
          'discovery_count',
          'battery_count',
        ],
        orderBy: 'imported_at DESC, id',
      )).map(_fromRow).toList(growable: false);

  @override
  Future<String?> readSource(String id) async {
    final rows = await _database.query(
      'validation_datasets',
      columns: ['original_source'],
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : rows.single['original_source']! as String;
  }

  @override
  Future<void> remove(String id) async {
    await _database.delete(
      'validation_datasets',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<_DecodedFile>> _decode(List<ValidationImportFile> files) {
    if (files.length > 50) {
      throw const FormatException('Choose at most 50 files.');
    }
    return compute(
      _decodeFiles,
      List<ValidationImportFile>.unmodifiable(files),
      debugLabel: 'validation import',
    );
  }

  Future<Map<String, String>> _existingFor(
    DatabaseExecutor executor,
    List<_DecodedFile> files,
  ) async {
    final ids = files
        .map((file) => file.dataset?.id)
        .whereType<String>()
        .toSet()
        .toList();
    if (ids.isEmpty) return {};
    final rows = await executor.query(
      'validation_datasets',
      columns: ['id', 'canonical_source'],
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
    return {
      for (final row in rows)
        row['id']! as String: row['canonical_source']! as String,
    };
  }

  ValidationImportPreview _classify(
    List<_DecodedFile> files,
    Map<String, String> existing,
  ) {
    final content = <String, String>{...existing};
    final conflicts = <String>{};
    for (final file in files) {
      final dataset = file.dataset;
      if (dataset == null) continue;
      final previous = content[dataset.id];
      if (previous != null && previous != file.canonical) {
        conflicts.add(dataset.id);
      }
      content[dataset.id] = file.canonical!;
    }
    final seen = existing.keys.toSet();
    return ValidationImportPreview(
      files.map((file) {
        final dataset = file.dataset;
        final ValidationImportStatus status;
        if (dataset == null) {
          status = ValidationImportStatus.error;
        } else if (conflicts.contains(dataset.id)) {
          status = ValidationImportStatus.conflict;
        } else if (!seen.add(dataset.id)) {
          status = ValidationImportStatus.duplicate;
        } else {
          status = ValidationImportStatus.valid;
        }
        return ValidationImportEntry(
          file: file.file,
          status: status,
          dataset: dataset,
          error: file.error,
        );
      }),
    );
  }
}

ValidationImportedDataset _fromRow(Map<String, Object?> row) =>
    ValidationImportedDataset(
      id: row['id']! as String,
      filename: row['filename']! as String,
      schemaVersion: row['schema_version']! as int,
      runId: row['run_id'] as String?,
      sessionId: row['session_id']! as String,
      deviceId: row['device_id']! as String,
      role: row['role']! as String,
      exportedAt: row['exported_at'] == null
          ? null
          : DateTime.parse(row['exported_at']! as String),
      importedAt: DateTime.parse(row['imported_at']! as String),
      eventCount: row['event_count']! as int,
      receiptCount: row['receipt_count']! as int,
      discoveryCount: row['discovery_count']! as int,
      batteryCount: row['battery_count']! as int,
    );

class _DecodedFile {
  const _DecodedFile(this.file, {this.dataset, this.canonical, this.error});
  final ValidationImportFile file;
  final ValidationImportedDataset? dataset;
  final String? canonical;
  final String? error;
}

List<_DecodedFile> _decodeFiles(List<ValidationImportFile> files) =>
    files.map(_decodeFile).toList(growable: false);

_DecodedFile _decodeFile(ValidationImportFile file) {
  if (file.source.length > ValidationBundleCodec.maxSourceBytes ||
      utf8.encode(file.source).length > ValidationBundleCodec.maxSourceBytes) {
    return _DecodedFile(file, error: 'File exceeds 10 MiB UTF-8 limit.');
  }
  try {
    final value = jsonDecode(file.source);
    if (value is! Map<String, dynamic>) throw const FormatException();
    final canonical = canonicalJsonEncode(value);
    if (value['schema_version'] == 2) {
      final json = const ValidationBundleCodec()
          .decodeJson(file.source)
          .toJson();
      final device = json['device']! as Map;
      final session = json['session']! as Map;
      return _DecodedFile(
        file,
        canonical: canonical,
        dataset: ValidationImportedDataset(
          id: json['bundle_id']! as String,
          filename: file.name,
          schemaVersion: 2,
          runId: (json['test_run']! as Map)['id']! as String,
          sessionId: session['id']! as String,
          deviceId: device['peer_id']! as String,
          role: device['role']! as String,
          exportedAt: DateTime.parse(json['generated_at']! as String),
          eventCount: (json['message_events']! as List).length,
          receiptCount: (json['sos_receipts']! as List).length,
          discoveryCount: (json['discovery_attempts']! as List).length,
          batteryCount: (json['battery_samples']! as List).length,
        ),
      );
    }
    if (value['schema_version'] != 1) throw const FormatException();
    // The legacy decoder tolerates missing child arrays; reject malformed array
    // contents rather than silently dropping evidence from an imported file.
    for (final key in [
      'message_events',
      'discovery_attempts',
      'battery_samples',
      'export_records',
    ]) {
      final records = value[key];
      if (records != null &&
          (records is! List || records.any((record) => record is! Map))) {
        throw const FormatException();
      }
    }
    final data = const ValidationExportService().decodeJson(file.source);
    final session = data.session;
    if ([
      ...data.events.map((e) => e.sessionId),
      ...data.discoveryAttempts.map((e) => e.sessionId),
      ...data.batterySamples.map((e) => e.sessionId),
      ...data.exportRecords.map((e) => e.sessionId),
    ].any((owner) => owner != session.id)) {
      throw const FormatException();
    }
    return _DecodedFile(
      file,
      canonical: canonical,
      dataset: ValidationImportedDataset(
        id: 'legacy-${_hash(canonical)}',
        filename: file.name,
        schemaVersion: 1,
        runId: session.testRunId,
        sessionId: 'legacy-session-${_hash(session.id)}',
        deviceId: 'legacy-peer-${_hash(session.deviceId)}',
        role:
            {
              'civilian',
              'responder',
              'relay',
              'admin',
            }.contains(session.deviceRole)
            ? session.deviceRole
            : 'unknown',
        // Schema 1 has no export timestamp; recording end is not an export date.
        exportedAt: null,
        eventCount: data.events.length,
        receiptCount: 0,
        discoveryCount: data.discoveryAttempts.length,
        batteryCount: data.batterySamples.length,
      ),
    );
  } catch (_) {
    // Decoder exceptions may include snippets of source. Never expose them.
    return _DecodedFile(
      file,
      error:
          'Invalid or unsupported validation JSON (check schema, checksum and privacy fields).',
    );
  }
}

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
