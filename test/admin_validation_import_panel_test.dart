import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin_validation/data/desktop_validation_database.dart';
import 'package:shadownetwork/features/admin_validation/data/sqlite_validation_import_repository.dart';
import 'package:shadownetwork/features/admin_validation/domain/validation_import.dart';
import 'package:shadownetwork/features/admin_validation/presentation/desktop_validation_import_panel.dart';
import 'package:shadownetwork/features/admin_validation/presentation/providers/validation_import_provider.dart';
import 'package:shadownetwork/features/validation/domain/services/validation_export_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'admin_validation_import_repository_test.dart'
    show importFixture, changedBundle;
import 'support/validation_run_fixtures.dart';

void main() {
  late Directory directory;
  late Database database;
  late SqliteValidationImportRepository repository;
  late ProviderContainer container;
  late ProviderSubscription<AsyncValue<ValidationImportState>> subscription;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'admin-validation-widget-',
    );
    database = await openDesktopValidationDatabase(
      '${directory.path}/validation.sqlite',
    );
    repository = SqliteValidationImportRepository(database: database);
    container = ProviderContainer(
      overrides: [
        validationImportRepositoryProvider.overrideWithValue(repository),
      ],
    );
    subscription = container.listen(
      validationImportControllerProvider,
      (_, _) {},
    );
    await container.read(validationImportControllerProvider.future);
  });
  tearDown(() async {
    subscription.close();
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester,
    List<ValidationImportFile> files, {
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: DesktopValidationImportPanel(
              onChooseFiles: () async => files,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    // Route completion, FFI timers and isolate responses cross the fake clock.
    // Alternate frames and real I/O time before settling animation frames.
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      if (container
              .read(validationImportControllerProvider)
              .valueOrNull
              ?.busy !=
          true) {
        break;
      }
    }
    expect(
      container.read(validationImportControllerProvider).valueOrNull?.busy,
      isFalse,
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() => tester.tap(finder));
  }

  testWidgets(
    'file preview requires explicit import and removal requires confirmation',
    (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, [
        importFixture(),
        const ValidationImportFile(name: 'bad.json', source: 'PRIVATE-BODY'),
      ]);
      await tap(tester, find.text('Choose JSON files'));
      await finish(tester);
      expect(await tester.runAsync(repository.listDatasets), isEmpty);
      expect(find.text('bad.json'), findsOneWidget);
      expect(find.textContaining('PRIVATE-BODY'), findsNothing);
      await tap(tester, find.text('Import selected'));
      await finish(tester);
      expect(await tester.runAsync(repository.listDatasets), hasLength(1));
      expect(find.textContaining('Imported 1'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Remove imported dataset'));
      await tester.tap(find.byTooltip('Remove imported dataset'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(repository.listDatasets), hasLength(1));
      await tester.tap(find.byTooltip('Remove imported dataset'));
      await tester.pumpAndSettle();
      await tap(tester, find.widgetWithText(FilledButton, 'Remove'));
      await finish(tester);
      expect(await tester.runAsync(repository.listDatasets), isEmpty);
    },
  );

  testWidgets(
    'legacy warnings and metadata fit narrow layouts with scaled text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final file = ValidationImportFile(
        name: 'legacy.json',
        source: const ValidationExportService().encodeJson(
          runFixture(deviceId: 'PRIVATE-DEVICE'),
        ),
      );
      await mount(tester, [file], textScale: 1.5);
      await tap(tester, find.text('Choose JSON files'));
      await finish(tester);
      await tester.scrollUntilVisible(
        find.textContaining('Legacy schema 1'),
        250,
      );
      expect(find.textContaining('Legacy schema 1'), findsWidgets);
      expect(find.textContaining('PRIVATE-DEVICE'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'file picker failure is recoverable and never echoes exception source',
    (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: DesktopValidationImportPanel(
                onChooseFiles: () async => throw Exception('PRIVATE-FILE-PATH'),
              ),
            ),
          ),
        ),
      );
      await finish(tester);
      await tap(tester, find.text('Choose JSON files'));
      await finish(tester);
      expect(find.textContaining('PRIVATE-FILE-PATH'), findsNothing);
      expect(find.textContaining('Unable to open'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Choose JSON files'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('conflicting files block import without writing any dataset', (
    tester,
  ) async {
    final file = importFixture();
    await mount(tester, [file, changedBundle(file)]);
    await tap(tester, find.text('Choose JSON files'));
    await finish(tester);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Import selected'),
          )
          .onPressed,
      isNull,
    );
    await tester.scrollUntilVisible(
      find.textContaining('Conflicting IDs detected.'),
      200,
    );
    expect(find.textContaining('Conflicting IDs detected.'), findsOneWidget);
    expect(await tester.runAsync(repository.listDatasets), isEmpty);
  });
}
