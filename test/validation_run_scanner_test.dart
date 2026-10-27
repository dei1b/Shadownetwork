import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shadownetwork/features/validation/presentation/pages/validation_run_scanner_page.dart';
import 'package:shadownetwork/features/validation/presentation/widgets/validation_session_start_dialog.dart';

class _Camera extends MobileScannerController {
  _Camera() : super(autoStart: false);
  final captures = StreamController<BarcodeCapture>.broadcast();
  bool disposed = false;
  @override
  Stream<BarcodeCapture> get barcodes => captures.stream;
  @override
  Future<void> start({
    CameraFacing? cameraDirection,
    CameraLensType? cameraLensType,
  }) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    await captures.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'dev.steenbakker.mobile_scanner/scanner/method',
  );
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null),
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  for (final exit in ['manual', 'appbar', 'system']) {
    testWidgets(
      '$exit cancellation ignores queued scan without popping start dialog',
      (tester) async {
        final camera = _Camera();
        ValidationSessionInput? input;
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      input = await showValidationSessionStartDialog(
                        context,
                        initialRunCode: 'KEEP-RUN',
                        scanRunCode: (dialogContext) =>
                            Navigator.of(dialogContext).push<String>(
                              MaterialPageRoute(
                                builder: (_) => ValidationRunScannerPage(
                                  controller: camera,
                                ),
                              ),
                            ),
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Scan run QR'));
        await tester.pumpAndSettle();
        if (exit == 'manual') {
          await tester.tap(find.text('Enter code manually'));
        } else if (exit == 'appbar') {
          await tester.tap(find.byTooltip('Back'));
        } else {
          tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        }
        camera.captures.add(
          const BarcodeCapture(
            barcodes: [
              Barcode(
                rawValue:
                    '{"schema_version":1,"bundle_type":"shadow_network_validation_run","test_run_id":"LATE-RUN"}',
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Start validation session'), findsOneWidget);
        expect(find.text('KEEP-RUN'), findsOneWidget);
        expect(input, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('wrong QR can retry; valid repeated detections return only once', (
    tester,
  ) async {
    final camera = _Camera();
    String? result;
    var returns = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) =>
                          ValidationRunScannerPage(controller: camera),
                    ),
                  );
                  returns++;
                },
                child: const Text('Scan'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    expect(camera.captures.hasListener, isTrue);
    camera.captures.add(
      const BarcodeCapture(
        barcodes: [Barcode(rawValue: '{"bundle_type":"trust"}')],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('validation run QR'), findsOneWidget);
    const qr =
        '{"schema_version":1,"bundle_type":"shadow_network_validation_run","test_run_id":"RUN-001"}';
    camera.captures.add(
      const BarcodeCapture(
        barcodes: [
          Barcode(rawValue: qr),
          Barcode(rawValue: qr),
        ],
      ),
    );
    camera.captures.add(
      const BarcodeCapture(barcodes: [Barcode(rawValue: qr)]),
    );
    await tester.pumpAndSettle();
    expect(result, 'RUN-001');
    expect(returns, 1);
    expect(camera.disposed, isTrue);
  });
  testWidgets('denied camera leaves manual entry fallback available', (
    tester,
  ) async {
    final camera = _Camera();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: ValidationRunScannerPage(controller: camera)),
      ),
    );
    await tester.pumpAndSettle();
    camera.value = camera.value.copyWith(
      isInitialized: true,
      error: const MobileScannerException(
        errorCode: MobileScannerErrorCode.permissionDenied,
      ),
    );
    await tester.pump();
    expect(find.textContaining('Camera unavailable'), findsOneWidget);
    expect(find.text('Enter code manually'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(camera.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
