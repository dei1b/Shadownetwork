import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/trust/domain/services/multi_frame_qr.dart';

void main() {
  test('small payloads stay a single QR frame', () {
    const payload = '{"bundle_version":1,"approved_devices":[]}';
    final frames = MultiFrameQrCodec.encode(payload);
    expect(frames, [payload]);
    final collector = MultiFrameQrCollector();
    final progress = collector.accept(frames.single);
    expect(progress.isComplete, isTrue);
    expect(progress.completedPayload, payload);
  });

  test('oversized payloads split and reassemble out of order and ignore duplicates', () {
    final payload = jsonEncode({
      'bundle_type': 'shadow_network_device_trust_bundle',
      'bundle_version': 42,
      'approved_devices': [
        for (var i = 0; i < 40; i++)
          {
            'device_id': 'SN-STUDENT-${i.toString().padLeft(3, '0')}',
            'owner_name': 'Student Number $i',
          },
      ],
    });
    final frames = MultiFrameQrCodec.encode(payload);
    expect(frames.length, greaterThan(1));

    final collector = MultiFrameQrCollector();
    final fedFrames = frames.reversed.skip(1).toList();
    for (final frame in fedFrames) {
      final p = collector.accept(frame);
      expect(p.isComplete, isFalse);
    }
    // Duplicate an already scanned frame before finishing.
    final dup = collector.accept(fedFrames.first);
    expect(dup.isComplete, isFalse);

    final finalProgress = collector.accept(frames.last);
    expect(finalProgress.isComplete, isTrue);
    expect(finalProgress.completedPayload, payload);
  });

  test('tampered digest throws FormatException during reassembly', () {
    final payload = 'x' * 3000;
    final frames = MultiFrameQrCodec.encode(payload);
    final tamperedMap = jsonDecode(frames.first) as Map<String, dynamic>;
    tamperedMap['d'] = base64UrlEncode(utf8.encode('tampered-chunk-data'));
    final framesModified = [jsonEncode(tamperedMap), ...frames.skip(1)];

    final collector = MultiFrameQrCollector();
    for (var i = 0; i < framesModified.length - 1; i++) {
      collector.accept(framesModified[i]);
    }
    expect(
      () => collector.accept(framesModified.last),
      throwsFormatException,
    );
  });
}
