import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../domain/services/validation_run_identity.dart';

Future<String?> showValidationRunScanner(BuildContext context) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ValidationRunScannerPage()),
    );

class ValidationRunScannerPage extends ConsumerStatefulWidget {
  const ValidationRunScannerPage({super.key, this.controller});

  /// The page owns and disposes the supplied camera controller.
  final MobileScannerController? controller;
  @override
  ConsumerState<ValidationRunScannerPage> createState() =>
      _ValidationRunScannerPageState();
}

class _ValidationRunScannerPageState
    extends ConsumerState<ValidationRunScannerPage>
    with WidgetsBindingObserver {
  late final _camera =
      widget.controller ??
      MobileScannerController(
        autoStart: false,
        formats: [BarcodeFormat.qrCode],
      );
  bool _handled = false;
  bool _active = true;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  Future<void> _start() async {
    if (_handled ||
        !_active ||
        _starting ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _starting = true;
    try {
      await _camera.start();
      if (!mounted || _handled || !_active) {
        await _camera.stop();
      }
    } catch (_) {
      if (mounted && !_handled) {
        setState(() => _error = 'Camera unavailable. Enter the code manually.');
      }
    } finally {
      _starting = false;
    }
  }

  void _finish() {
    if (_handled) return;
    _handled = true;
    unawaited(_camera.stop().catchError((Object _) {}));
  }

  void _cancel() {
    _finish();
    Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) {
      unawaited(_start());
    } else {
      unawaited(_camera.stop().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    _finish();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_camera.dispose().catchError((Object _) {}));
    super.dispose();
  }

  void _detect(BarcodeCapture capture) {
    if (!mounted ||
        _handled ||
        !_active ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      try {
        final code = ValidationRunIdentity.decodeQr(raw);
        _finish();
        Navigator.of(context).pop(code);
        return;
      } on FormatException {
        setState(
          () => _error =
              'Not a supported validation run QR. Try another QR or enter the code manually.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<String>(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _finish();
    },
    child: Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _cancel),
        title: const Text('Scan run QR'),
      ),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _camera,
              onDetect: _detect,
              errorBuilder: (_, _) => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Camera unavailable. Enter the code manually.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _error ?? 'Scan the run QR displayed by the lead rescuer.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _cancel,
                    child: const Text('Enter code manually'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
