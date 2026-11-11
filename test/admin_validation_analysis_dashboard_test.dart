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
import 'package:shadownetwork/features/admin/presentation/theme/admin_theme.dart';

class FixtureImports extends ValidationImportController {
  FixtureImports(this.includeSender);

  final bool includeSender;

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
      if (includeSender)
        ValidationImportedDataset(
          id: 'sender',
          filename: 'sender.json',
          schemaVersion: 2,
          runId: 'SN-FIXTURE',
          sessionId: 'sender-session',
          deviceId: 'sender-fixture',
          role: 'responder',
          exportedAt: DateTime.utc(2026, 11, 11),
          eventCount: 2,
          receiptCount: 0,
          discoveryCount: 0,
          batteryCount: 0,
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
    testWidgets('dashboard fits $width and leads with SOS field test results', (
      tester,
    ) async {
      final populated = width == 1440;
      tester.view.physicalSize = Size(width, 1700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            validationImportControllerProvider.overrideWith(
              () => FixtureImports(populated),
            ),
            validationAnalysisProvider.overrideWith(
              (ref) async => [
                ValidationAnalysisInput(
                  List.generate(
                    11,
                    (index) => AnalysisRecord(
                      'SN-FIXTURE',
                      'responder-fixture',
                      'responder',
                      'session',
                      'battery_samples',
                      {
                        'id': 'battery-$index',
                        'sampled_at': DateTime.utc(
                          2026,
                          11,
                          11,
                          8,
                          index,
                        ).toIso8601String(),
                        'battery_percent': 80,
                        'is_charging': false,
                      },
                    ),
                  ),
                  [],
                ),
                if (populated) const ValidationAnalysisInput(_sosRecords, []),
              ],
            ),
          ],
          child: MaterialApp(
            theme: AdminTheme.light.copyWith(
              textTheme: AdminTheme.light.textTheme.apply(fontFamily: 'Arial'),
            ),
            home: Scaffold(
              body: RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: AdminTheme.background,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: const ValidationAnalysisDashboard(),
                  ),
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
      expect(find.text('SOS delivery success rate'), findsOneWidget);
      expect(find.text('Typical phone-to-phone wait'), findsOneWidget);
      expect(find.text('SOS alerts received'), findsNothing);
      if (populated) {
        expect(find.text('2 phones imported'), findsOneWidget);
        expect(find.text('50% · 1 of 2'), findsOneWidget);
        expect(find.text('2.00 seconds'), findsOneWidget);
      } else {
        expect(find.text('1 phone imported'), findsOneWidget);
        expect(find.text('Not measured'), findsOneWidget);
      }
      expect(find.text('Filter technical details'), findsOneWidget);
      expect(find.text('Detailed records'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      if (width >= 800) {
        expect(
          tester.getTopLeft(find.text('SOS delivery success rate')).dy,
          tester.getTopLeft(find.text('Typical phone-to-phone wait')).dy,
        );
      }
      await tester.ensureVisible(find.text('How to interpret these results'));
      await tester.tap(find.text('How to interpret these results'));
      await tester.pumpAndSettle();
      expect(find.text('Import every participating phone'), findsOneWidget);
      await tester.tap(find.text('How to interpret these results'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('SOS field test'),
        -500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
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
            'output/admin-dashboard/objective-4-fixture.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
        picture.dispose();
        await tester.ensureVisible(find.text('Timing and battery details'));
        await tester.tap(find.text('Timing and battery details'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Phone 1 · battery level'));
        await tester.pumpAndSettle();
        expect(
          find.text('Battery level over time · orange dots indicate charging.'),
          findsOneWidget,
        );
        final batteryPicture = (await tester.runAsync(
          () => boundary.toImage(),
        ))!;
        final batteryBytes = await tester.runAsync(
          () => batteryPicture.toByteData(format: ui.ImageByteFormat.png),
        );
        await tester.runAsync(
          () => File(
            'output/admin-dashboard/battery-fixture.png',
          ).writeAsBytes(batteryBytes!.buffer.asUint8List()),
        );
        batteryPicture.dispose();
      }
    });
  }
}

const _sosRecords = [
  AnalysisRecord(
    'SN-FIXTURE',
    'sender-fixture',
    'responder',
    'sender-session',
    'message_events',
    {
      'id': 'queued-1',
      'event_type': 'sosQueued',
      'message_hash': 'sos-1',
      'occurred_at': '2026-11-11T08:00:00Z',
    },
  ),
  AnalysisRecord(
    'SN-FIXTURE',
    'sender-fixture',
    'responder',
    'sender-session',
    'message_events',
    {
      'id': 'queued-2',
      'event_type': 'sosQueued',
      'message_hash': 'sos-2',
      'occurred_at': '2026-11-11T08:00:00Z',
    },
  ),
  AnalysisRecord(
    'SN-FIXTURE',
    'sender-fixture',
    'responder',
    'sender-session',
    'message_events',
    {
      'id': 'offer',
      'event_type': 'envelopeOffered',
      'message_hash': 'sos-1',
      'transfer_id': 'transfer-1',
      'peer_id': 'responder-fixture',
      'occurred_at': '2026-11-11T08:00:00Z',
    },
  ),
  AnalysisRecord(
    'SN-FIXTURE',
    'sender-fixture',
    'responder',
    'sender-session',
    'message_events',
    {
      'id': 'ack',
      'event_type': 'envelopeAcknowledged',
      'message_hash': 'sos-1',
      'transfer_id': 'transfer-1',
      'peer_id': 'responder-fixture',
      'occurred_at': '2026-11-11T08:00:02Z',
      'latency_ms': 2000,
    },
  ),
  AnalysisRecord(
    'SN-FIXTURE',
    'responder-fixture',
    'responder',
    'session',
    'sos_receipts',
    {
      'message_hash': 'sos-1',
      'created_at': '2026-11-11T08:00:00Z',
      'received_at': '2026-11-11T08:00:02Z',
      'hop_count': 1,
    },
  ),
];
