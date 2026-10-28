import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/domain/repositories/sos_message_repository.dart';
import 'package:shadownetwork/features/validation/data/repositories/sqlite_validation_metrics_repository.dart';
import 'package:shadownetwork/features/validation/data/services/android_validation_bundle_file_gateway.dart';
import 'package:shadownetwork/features/validation/domain/repositories/validation_bundle_file_gateway.dart';
import 'package:shadownetwork/features/validation/domain/services/portable_validation_export_service.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_bundle_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/database_migration_test_harness.dart';
import 'support/validation_run_fixtures.dart';

class EmptySosRepository implements SosMessageRepository {
  @override
  Future<List<SosMessage>> getMessages() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FailingFileGateway implements ValidationBundleFileGateway {
  @override
  Future<String> write({
    required String filename,
    required String source,
  }) async => throw const FileSystemException('Disk unavailable');
  @override
  Future<void> openShareSheet(String path) async => fail('No file was created');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  const shareChannel = MethodChannel('shadow_network/validation_exports');
  const codec = ValidationBundleCodec();

  test(
    'writes a real JSON file, records its canonical hash, then opens share',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      final database = await harness.openCurrentDatabase();
      addTearDown(database.close);
      final repo = SqliteValidationMetricsRepository(database: database);
      await repo.importSessionData(runFixture());
      final directory = await Directory.systemTemp.createTemp(
        'validation-exports-',
      );
      addTearDown(() => directory.delete(recursive: true));
      String? sharedPath;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (call) async {
            expect(call.method, 'shareFile');
            sharedPath = (call.arguments as Map)['path'] as String;
            final fileBundle = codec.decodeJson(
              await File(sharedPath!).readAsString(),
            );
            final records = (await repo.getSessionData(
              'session',
            )).exportRecords;
            expect(records.single.id, fileBundle.id);
            expect(records.single.payloadHash, fileBundle.payloadHash);
            expect(records.single.result, 'file_created');
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(shareChannel, null),
      );
      final service = PortableValidationExportService(
        metrics: repo,
        messages: EmptySosRepository(),
        files: AndroidValidationBundleFileGateway(
          supportDirectory: () async => directory,
        ),
      );
      final bundle = await service.exportSession(
        sessionId: 'session',
        localDeviceId: 'local',
        appVersion: '0.1.0+1',
      );
      expect(sharedPath, endsWith(bundle.filename));
      expect(await File(sharedPath!).exists(), isTrue);
      expect(
        codec.decodeJson(await File(sharedPath!).readAsString()).id,
        bundle.id,
      );
      expect(
        await directory
            .list(recursive: true)
            .where((e) => e.path.endsWith('.tmp'))
            .isEmpty,
        isTrue,
      );
    },
  );

  test(
    'write failure records no success; share failure retains created file history',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      final database = await harness.openCurrentDatabase();
      addTearDown(database.close);
      final repo = SqliteValidationMetricsRepository(database: database);
      await repo.importSessionData(runFixture());
      var service = PortableValidationExportService(
        metrics: repo,
        messages: EmptySosRepository(),
        files: FailingFileGateway(),
      );
      await expectLater(
        service.exportSession(
          sessionId: 'session',
          localDeviceId: 'local',
          appVersion: '1',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect((await repo.getSessionData('session')).exportRecords, isEmpty);
      final directory = await Directory.systemTemp.createTemp(
        'validation-failure-',
      );
      addTearDown(() => directory.delete(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            shareChannel,
            (_) async => throw PlatformException(code: 'NO_ACTIVITY'),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(shareChannel, null),
      );
      service = PortableValidationExportService(
        metrics: repo,
        messages: EmptySosRepository(),
        files: AndroidValidationBundleFileGateway(
          supportDirectory: () async => directory,
        ),
      );
      await expectLater(
        service.exportSession(
          sessionId: 'session',
          localDeviceId: 'local',
          appVersion: '1',
        ),
        throwsA(isA<ValidationBundleShareException>()),
      );
      final records = (await repo.getSessionData('session')).exportRecords;
      expect(records.single.result, 'file_created');
      final file =
          (await directory
                      .list(recursive: true)
                      .where((entry) => entry.path.endsWith('.json'))
                      .toList())
                  .single
              as File;
      expect(codec.decodeJson(await file.readAsString()).id, records.single.id);
    },
  );

  test(
    'foreign and legacy evidence cannot be exported as this phone/run',
    () async {
      final harness = await DatabaseMigrationTestHarness.create();
      addTearDown(harness.dispose);
      final database = await harness.openCurrentDatabase();
      addTearDown(database.close);
      final repo = SqliteValidationMetricsRepository(database: database);
      await repo.importSessionData(
        runFixture(id: 'foreign', deviceId: 'other'),
      );
      await repo.importSessionData(runFixture(id: 'legacy', runId: null));
      final service = PortableValidationExportService(
        metrics: repo,
        messages: EmptySosRepository(),
        files: FailingFileGateway(),
      );
      for (final id in ['foreign', 'legacy']) {
        await expectLater(
          service.exportSession(
            sessionId: id,
            localDeviceId: 'local',
            appVersion: '1',
          ),
          throwsStateError,
        );
        expect((await repo.getSessionData(id)).exportRecords, isEmpty);
      }
    },
  );

  test('file gateway rejects a path traversal filename', () async {
    final directory = await Directory.systemTemp.createTemp('validation-path-');
    addTearDown(() => directory.delete(recursive: true));
    final gateway = AndroidValidationBundleFileGateway(
      supportDirectory: () async => directory,
    );
    for (final name in [
      '../private.json',
      r'..\private.json',
      '/private.json',
    ]) {
      await expectLater(
        gateway.write(filename: name, source: '{}'),
        throwsArgumentError,
      );
    }
    expect(await directory.list().isEmpty, isTrue);
  });
}
