import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/admin_validation/domain/validation_analysis.dart';
import 'package:shadownetwork/features/admin_validation/domain/validation_import.dart';
import 'package:shadownetwork/features/admin_validation/presentation/providers/validation_analysis_provider.dart';
import 'package:shadownetwork/features/admin_validation/presentation/providers/validation_import_provider.dart';
import 'package:shadownetwork/features/admin_validation/presentation/validation_analysis_dashboard.dart';

class FixtureImports extends ValidationImportController {
  @override
  Future<ValidationImportState> build() async => ValidationImportState(
    datasets: [
      ValidationImportedDataset(
        id: 'fixture',
        filename: 'synthetic.json',
        schemaVersion: 2,
        runId: 'SN-FIXTURE',
        sessionId: 'session',
        deviceId: 'responder-fixture',
        role: 'responder',
        exportedAt: DateTime.utc(2026, 11, 11),
        eventCount: 97,
        receiptCount: 0,
        discoveryCount: 53,
        batteryCount: 11,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = File(r'C:\Windows\Fonts\arial.ttf');
    if (await font.exists()) {
      final loader = FontLoader('Arial')
        ..addFont(font.readAsBytes().then((b) => ByteData.sublistView(b)));
      await loader.load();
    }
  });
  for (final width in [800.0, 1440.0, 360.0]) {
    testWidgets(
      'partial dashboard fits $width and renders honest empty receipt metrics',
      (tester) async {
        tester.view.physicalSize = Size(width, 1700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final key = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              validationImportControllerProvider.overrideWith(
                FixtureImports.new,
              ),
              validationAnalysisProvider.overrideWith(
                (ref) async => [const ValidationAnalysisInput([], [])],
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(fontFamily: 'Arial'),
              home: Scaffold(
                body: RepaintBoundary(
                  key: key,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: const ValidationAnalysisDashboard(),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.textContaining('0 recipient/message pairs'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Expected participants: Unknown'),
          findsOneWidget,
        );
        expect(find.text('Unavailable: no eligible attempts'), findsWidgets);
        if (width == 1440) {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final picture = (await tester.runAsync(() => boundary.toImage()))!;
          final bytes = await tester.runAsync(
            () => picture.toByteData(format: ui.ImageByteFormat.png),
          );
          await tester.runAsync(() async {
            await Directory('output/admin-dashboard').create(recursive: true);
            await File(
              'output/admin-dashboard/partial-fixture.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          });
          picture.dispose();
        }
      },
    );
  }
}
