import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadownetwork/features/admin/presentation/widgets/windows_registration_scanner.dart';

void main() {
  testWidgets(
    'camera decoder reads a dense registration QR with contact fields',
    (tester) async {
      const source =
          '{"device_id":"SN-TEST","full_name":"Maria Santos","phone_number":"+63 912 345 6789","address":"Purok 2, Panabo City","signature":"synthetic-signature-for-decoder-test"}';
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(Colors.white, BlendMode.src);
        canvas.translate(24, 24);
        QrPainter(
          data: source,
          version: QrVersions.auto,
          gapless: true,
        ).paint(canvas, const Size.square(352));
        final picture = recorder.endRecording();
        final image = await picture.toImage(400, 400);
        picture.dispose();
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        image.dispose();
        expect(await readRegistrationQr(png.buffer.asUint8List()), source);
      });
    },
  );
}
