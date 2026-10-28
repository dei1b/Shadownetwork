import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin_validation/data/desktop_validation_database.dart';
import 'package:shadownetwork/features/admin_validation/data/sqlite_validation_import_repository.dart';
import 'package:shadownetwork/features/admin_validation/domain/validation_import.dart';
import 'package:shadownetwork/features/trust/domain/services/canonical_json.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_bundle_codec.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_export_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/validation_run_fixtures.dart';

ValidationImportFile importFixture({
  String name = 'trial.json',
  String id = 'a',
}) {
  const codec = ValidationBundleCodec();
  return ValidationImportFile(
    name: name,
    source: codec.encodeJson(
      codec.create(
        data: runFixture(id: id),
        messages: [],
        appVersion: 'test',
        generatedAt: DateTime.utc(2026, 10, 27),
      ),
    ),
  );
}

ValidationImportFile changedBundle(ValidationImportFile file) {
  final json = jsonDecode(file.source) as Map<String, dynamic>;
  (json['device'] as Map)['app_version'] = 'changed';
  json.remove('payload_hash');
  json['payload_hash'] = sha256
      .convert(utf8.encode(canonicalJsonEncode(json)))
      .toString();
  return ValidationImportFile(name: 'changed.json', source: jsonEncode(json));
}

void main() {
  late Directory directory;
  late Database db;
  late SqliteValidationImportRepository repository;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('admin-validation-test-');
    db = await openDesktopValidationDatabase(
      '${directory.path}/evidence.sqlite',
    );
    repository = SqliteValidationImportRepository(database: db);
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'multi-file preview classifies without writing and excludes malformed files',
    () async {
      final file = importFixture();
      final preview = await repository.preview([
        file,
        file,
        const ValidationImportFile(
          name: 'broken.json',
          source: '{private-body',
        ),
      ]);
      expect(preview.entries.map((e) => e.status), [
        ValidationImportStatus.valid,
        ValidationImportStatus.duplicate,
        ValidationImportStatus.error,
      ]);
      expect(preview.entries.first.dataset!.recordCount, 3);
      expect(preview.entries.last.error, isNot(contains('private-body')));
      expect(await repository.listDatasets(), isEmpty);
      final result = await repository.commit(preview);
      expect(result.importedCount, 1);
      expect(result.duplicateCount, 1);
      expect(result.errorCount, 1);
      expect(
        await repository.readSource(preview.entries.first.dataset!.id),
        file.source,
      );
    },
  );

  test(
    'persisted imports survive reopen and removal permits reimport',
    () async {
      final file = importFixture();
      await repository.commit(await repository.preview([file]));
      await db.close();
      db = await openDesktopValidationDatabase(
        '${directory.path}/evidence.sqlite',
      );
      repository = SqliteValidationImportRepository(database: db);
      final datasets = await repository.listDatasets();
      expect(datasets, hasLength(1));
      expect(
        (await repository.preview([file])).entries.single.status,
        ValidationImportStatus.duplicate,
      );
      await repository.remove(datasets.single.id);
      expect(await repository.listDatasets(), isEmpty);
      expect(
        (await repository.preview([file])).entries.single.status,
        ValidationImportStatus.valid,
      );
    },
  );

  test(
    'same ID with changed canonical content conflicts across selection and database',
    () async {
      final file = importFixture();
      final changed = changedBundle(file);
      final preview = await repository.preview([
        importFixture(id: 'safe'),
        file,
        changed,
      ]);
      expect(preview.hasConflicts, isTrue);
      expect(
        preview.entries
            .skip(1)
            .every((e) => e.status == ValidationImportStatus.conflict),
        isTrue,
      );
      await expectLater(
        repository.commit(preview),
        throwsA(isA<ValidationImportConflict>()),
      );
      expect(await repository.listDatasets(), isEmpty);
      await repository.commit(await repository.preview([file]));
      expect((await repository.preview([changed])).hasConflicts, isTrue);
    },
  );

  test(
    'commit rechecks database changes and rolls back all selected writes',
    () async {
      final file = importFixture();
      final oldPreview = await repository.preview([
        importFixture(id: 'safe'),
        changedBundle(file),
      ]);
      await repository.commit(await repository.preview([file]));
      await expectLater(
        repository.commit(oldPreview),
        throwsA(isA<ValidationImportConflict>()),
      );
      expect(await repository.listDatasets(), hasLength(1));
      final duplicatePreview = await repository.preview([
        importFixture(id: 'later'),
      ]);
      await repository.commit(duplicatePreview);
      expect((await repository.commit(duplicatePreview)).duplicateCount, 1);
    },
  );

  test(
    'SQLite write failure rolls back prior inserts from the same commit',
    () async {
      final files = [importFixture(id: 'a'), importFixture(id: 'b')];
      final preview = await repository.preview(files);
      await db.execute(
        "CREATE TRIGGER reject_second BEFORE INSERT ON validation_datasets WHEN (SELECT COUNT(*) FROM validation_datasets) = 1 BEGIN SELECT RAISE(ABORT, 'simulated full storage'); END",
      );
      await expectLater(
        repository.commit(preview),
        throwsA(isA<DatabaseException>()),
      );
      expect(await repository.listDatasets(), isEmpty);
    },
  );

  test(
    'checksum and strict privacy validation exclude changed schema2',
    () async {
      final file = importFixture();
      final tampered = jsonDecode(file.source) as Map<String, dynamic>;
      tampered['generated_at'] = '2026-10-28T00:00:00.000Z';
      final privacy = jsonDecode(file.source) as Map<String, dynamic>;
      privacy['payload_text'] = 'PRIVATE-BODY';
      privacy.remove('payload_hash');
      privacy['payload_hash'] = sha256
          .convert(utf8.encode(canonicalJsonEncode(privacy)))
          .toString();
      final preview = await repository.preview([
        ValidationImportFile(
          name: 'tampered.json',
          source: jsonEncode(tampered),
        ),
        ValidationImportFile(name: 'private.json', source: jsonEncode(privacy)),
      ]);
      expect(
        preview.entries.every((e) => e.status == ValidationImportStatus.error),
        isTrue,
      );
      expect((await repository.commit(preview)).importedCount, 0);
    },
  );

  test(
    'legacy identity uses canonical content and never exposes raw device or notes',
    () async {
      final source = const ValidationExportService().encodeJson(
        runFixture(deviceId: 'PRIVATE-DEVICE', runId: null),
      );
      final value = jsonDecode(source) as Map<String, dynamic>;
      (value['session'] as Map)['notes'] = 'PRIVATE-BODY 7.123,125.456';
      final first = ValidationImportFile(
        name: 'legacy.json',
        source: jsonEncode(value),
      );
      final reordered = ValidationImportFile(
        name: 'again.json',
        source: canonicalJsonEncode(value),
      );
      final preview = await repository.preview([first, reordered]);
      expect(preview.entries.last.status, ValidationImportStatus.duplicate);
      final dataset = preview.entries.first.dataset!;
      expect(dataset.isLegacy, isTrue);
      expect(dataset.id, startsWith('legacy-'));
      expect(dataset.deviceId, isNot(contains('PRIVATE-DEVICE')));
      expect(dataset.sessionId, startsWith('legacy-session-'));
      await repository.commit(preview);
      expect(await repository.readSource(dataset.id), first.source);
    },
  );

  test(
    'oversize UTF8 and more than 50 files are rejected before writes',
    () async {
      final oversize = ValidationImportFile(
        name: 'huge.json',
        source: List.filled(6 * 1024 * 1024, 'é').join(),
      );
      expect(
        (await repository.preview([oversize])).entries.single.status,
        ValidationImportStatus.error,
      );
      await expectLater(
        repository.preview(List.filled(51, importFixture())),
        throwsFormatException,
      );
      expect(await repository.listDatasets(), isEmpty);
    },
  );
}
