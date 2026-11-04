import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:zxing2/qrcode.dart';

import '../../../../core/widgets/action_feedback.dart';

Future<String> readRegistrationQr(Uint8List encodedImage) async {
  final codec = await ui.instantiateImageCodec(encodedImage);
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final rgba = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final pixels = Int32List(image.width * image.height);
      for (var i = 0; i < pixels.length; i++) {
        final offset = i * 4;
        pixels[i] =
            (rgba.getUint8(offset) << 16) |
            (rgba.getUint8(offset + 1) << 8) |
            rgba.getUint8(offset + 2);
      }
      return QRCodeReader()
          .decode(
            BinaryBitmap(
              HybridBinarizer(
                RGBLuminanceSource(image.width, image.height, pixels),
              ),
            ),
          )
          .text;
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

class WindowsRegistrationScanner extends StatefulWidget {
  const WindowsRegistrationScanner({super.key});

  @override
  State<WindowsRegistrationScanner> createState() =>
      _WindowsRegistrationScannerState();
}

class _WindowsRegistrationScannerState
    extends State<WindowsRegistrationScanner> {
  final _camera = CameraPlatform.instance;
  List<CameraDescription> _cameras = const [];
  int? _cameraId;
  int _selected = 0;
  double _aspectRatio = 4 / 3;
  Future<void>? _operation;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _operation = _open();
  }

  Future<void> _open() async {
    try {
      _cameras = await _camera.availableCameras();
      if (!mounted) return;
      if (_cameras.isEmpty) {
        setState(
          () => _error =
              'No camera found. Connect a webcam or paste registration text.',
        );
        return;
      }
      await _start(_selected);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not find a camera. Check Windows camera permissions.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start(int index) async {
    setState(() {
      _busy = true;
      _selected = index;
      _error = null;
    });
    try {
      await _close();
      if (!mounted) return;
      final id = await _camera.createCamera(
        _cameras[index],
        ResolutionPreset.high,
      );
      _cameraId = id;
      if (!mounted) return;
      final initialized = _camera.onCameraInitialized(id).first;
      await Future.wait([
        _camera.initializeCamera(id),
        initialized,
      ]).timeout(const Duration(seconds: 12));
      final event = await initialized;
      if (event.previewHeight > 0) {
        _aspectRatio = event.previewWidth / event.previewHeight;
      }
    } catch (_) {
      await _close();
      if (mounted) {
        setState(
          () => _error =
              'Could not open the camera. Check permissions or close other camera apps, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    final id = _cameraId;
    _cameraId = null;
    if (id == null) return;
    try {
      await _camera.dispose(id);
    } catch (_) {}
  }

  Future<void> _scan() async {
    final id = _cameraId;
    if (_busy || id == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picture = await _camera.takePicture(id);
      final file = File(picture.path);
      final Uint8List bytes;
      try {
        bytes = await picture.readAsBytes();
      } finally {
        await file.delete();
      }
      final source = await readRegistrationQr(bytes);
      if (mounted && ModalRoute.isCurrentOf(context) == true) {
        Navigator.of(context).pop(source);
      }
    } on ReaderException {
      if (mounted) {
        setState(
          () => _error =
              'No QR code found. Move the phone closer and hold it steady, then scan again.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not read the camera image. Try again or paste registration text.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    unawaited((_operation ?? Future<void>.value()).whenComplete(_close));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Scan phone QR'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_cameras.length > 1)
            DropdownButtonFormField<int>(
              initialValue: _selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Camera'),
              items: [
                for (var i = 0; i < _cameras.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      _cameras[i].name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) _operation = _start(value);
                    },
            ),
          if (_cameraId != null && (!_busy || _error != null))
            AspectRatio(
              aspectRatio: _aspectRatio,
              child: _camera.buildPreview(_cameraId!),
            ),
          if (_busy)
            const LinearProgressIndicator(
              semanticsLabel: 'Preparing camera or reading code',
            ),
          const SizedBox(height: 12),
          const Text(
            'Show the registration code on the phone and hold it in view.',
          ),
          if (_error != null)
            ActionStatus(message: _error!, kind: FeedbackKind.error),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
      if (_cameraId == null && !_busy)
        OutlinedButton(
          onPressed: () {
            setState(() {
              _busy = true;
              _error = null;
            });
            _operation = _open();
          },
          child: const Text('Retry camera'),
        ),
      FilledButton.icon(
        onPressed: _busy || _cameraId == null
            ? null
            : () => _operation = _scan(),
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scan code'),
      ),
    ],
  );
}
