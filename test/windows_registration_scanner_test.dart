import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shadownetwork/features/admin/data/services/desktop_registration_scan_session.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/security/domain/entities/device_registration_qr.dart';
import 'package:shadownetwork/features/security/domain/entities/user_information.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('accepts a signed registration only from the local session', () async {
    final session = await DesktopRegistrationScanSession.start();
    addTearDown(session.close);
    final client = _LoopbackHttpOverrides().createHttpClient(null);
    addTearDown(() => client.close(force: true));

    Future<int> get(Uri uri) async {
      final response = await (await client.getUrl(uri)).close();
      await response.drain<void>();
      return response.statusCode;
    }

    Future<int> send(String source, String origin) async {
      final request = await client.postUrl(session.uri.resolve('result'));
      final bytes = utf8.encode(source);
      request.headers.set('origin', origin);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    expect(await get(session.uri.resolve('/')), HttpStatus.notFound);
    expect(await get(session.uri), HttpStatus.ok);
    expect(await get(session.uri.resolve('jsqr.js')), HttpStatus.ok);
    expect(await get(session.uri.resolve('scan.js')), HttpStatus.ok);
    final source = await _registration();
    expect(await send(source, 'https://example.test'), HttpStatus.forbidden);
    expect(
      await send('not a registration', session.uri.origin),
      HttpStatus.unprocessableEntity,
    );
    final tampered = source.replaceFirst('Test Resident', 'Other Resident');
    expect(
      await send(tampered, session.uri.origin),
      HttpStatus.unprocessableEntity,
    );
    expect(await send(source, session.uri.origin), HttpStatus.noContent);
    expect(await session.result, source);
    expect(await send(source, session.uri.origin), HttpStatus.gone);
  });

  test('closing the desktop dialog cancels the session', () async {
    final session = await DesktopRegistrationScanSession.start();
    await session.close();
    expect(await session.result, isNull);
  });

  // Run locally with SHADOW_SCAN_TEST_BROWSER set to an Edge/Chrome executable.
  final browser = Platform.environment['SHADOW_SCAN_TEST_BROWSER'];
  test(
    'browser reads a signed QR and closes its scanner tab',
    () async {
      final session = await DesktopRegistrationScanSession.start();
      addTearDown(session.close);
      final source = await _registration();
      final directory = await Directory.systemTemp.createTemp(
        'shadow_qr_test_',
      );
      final fixture = File('${directory.path}/phone.y4m');
      await fixture.writeAsBytes(await _webcamFixture(source));
      final process = await Process.start(browser!, [
        '--headless=new',
        '--disable-background-networking',
        '--no-first-run',
        '--user-data-dir=${directory.path}/profile',
        '--use-fake-ui-for-media-stream',
        '--use-fake-device-for-media-stream',
        '--use-file-for-fake-video-capture=${fixture.path}',
        session.uri.toString(),
      ]);
      unawaitedDrain(process);
      try {
        expect(
          await session.result.timeout(const Duration(seconds: 20)),
          source,
        );
        expect(await process.exitCode.timeout(const Duration(seconds: 8)), 0);
      } finally {
        process.kill();
        await process.exitCode;
        await directory.delete(recursive: true);
      }
    },
    skip: browser == null,
  );
}

Future<String> _registration() async {
  final identity = await DeviceIdentityStore(
    secretStore: InMemorySecretValueStore(),
  ).loadOrCreate();
  final signing = await DeviceSigningIdentityStore(
    secretStore: InMemorySecretValueStore(),
  ).loadOrCreate();
  return (await DeviceRegistrationQr.createSigned(
    deviceId: 'TEST-WEBCAM',
    identity: identity,
    signingIdentity: signing,
    userInformation: const UserInformation(
      fullName: 'Test Resident',
      phoneNumber: '09123456789',
      address: 'Purok 2, Panabo City',
    ),
  )).toJsonString();
}

Future<Uint8List> _webcamFixture(String source) async {
  const width = 640;
  const height = 480;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(Colors.white, BlendMode.src)
    ..translate(140, 60);
  QrPainter(
    data: source,
    version: QrVersions.auto,
    gapless: true,
  ).paint(canvas, const Size.square(360));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final rgba = (await image.toByteData())!;
  image.dispose();
  final frame = Uint8List(width * height * 3 ~/ 2)
    ..fillRange(0, width * height * 3 ~/ 2, 128);
  for (var i = 0; i < width * height; i++) {
    frame[i] = rgba.getUint8(i * 4);
  }
  return (BytesBuilder(copy: false)
        ..add(ascii.encode('YUV4MPEG2 W640 H480 F30:1 Ip A1:1 C420\nFRAME\n'))
        ..add(frame))
      .takeBytes();
}

void unawaitedDrain(Process process) {
  process.stdout.listen((_) {});
  process.stderr.listen((_) {});
}

class _LoopbackHttpOverrides extends HttpOverrides {}
