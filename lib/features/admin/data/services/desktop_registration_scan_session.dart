import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../../../security/domain/entities/device_registration_qr.dart';

/// A one-use camera handoff between the Windows admin and a local browser tab.
class DesktopRegistrationScanSession {
  DesktopRegistrationScanSession._(this._server, String token, this._assets)
    : uri = Uri.parse('http://127.0.0.1:${_server.port}/$token/');

  static const _maxQrBytes = 4096;
  static const _files = {
    '': ('index.html', 'text/html'),
    'scan.js': ('scan.js', 'text/javascript'),
    'jsqr.js': ('jsQR.js', 'text/javascript'),
  };

  final HttpServer _server;
  final Map<String, String> _assets;
  final _result = Completer<String?>();
  final Uri uri;

  Future<String?> get result => _result.future;

  static Future<DesktopRegistrationScanSession> start() async {
    final assets = <String, String>{
      for (final file in _files.values)
        file.$1: await rootBundle.loadString('assets/admin_scanner/${file.$1}'),
    };
    final random = Random.secure();
    final token = base64UrlEncode(
      List.generate(24, (_) => random.nextInt(256)),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final session = DesktopRegistrationScanSession._(server, token, assets);
    server.listen((request) => unawaited(session._respond(request)));
    return session;
  }

  Future<void> close() async {
    if (!_result.isCompleted) _result.complete(null);
    await _server.close(force: true);
  }

  Future<void> _respond(HttpRequest request) async {
    final response = request.response;
    String? accepted;
    try {
      response.headers
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('Referrer-Policy', 'no-referrer')
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('Permissions-Policy', 'camera=(self), microphone=()')
        ..set(
          'Content-Security-Policy',
          "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; "
              "media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
        );
      if (request.headers.value(HttpHeaders.hostHeader) != uri.authority ||
          !request.uri.path.startsWith(uri.path)) {
        response.statusCode = HttpStatus.notFound;
      } else if (_result.isCompleted) {
        response.statusCode = HttpStatus.gone;
      } else {
        final path = request.uri.path.substring(uri.path.length);
        final file = _files[path];
        if (request.method == 'GET' && file != null) {
          response.headers.contentType = ContentType.parse(
            '${file.$2}; charset=utf-8',
          );
          response.write(_assets[file.$1]);
        } else if (request.method == 'GET' && path == 'status') {
          response.statusCode = HttpStatus.noContent;
        } else if (request.method == 'POST' && path == 'result') {
          accepted = await _accept(request);
        } else {
          response.statusCode = HttpStatus.notFound;
        }
      }
      await response.close();
    } on IOException {
      // The browser may close the tab while a request is in flight.
    } finally {
      if (accepted != null && !_result.isCompleted) _result.complete(accepted);
    }
  }

  Future<String?> _accept(HttpRequest request) async {
    final response = request.response;
    if (request.headers.value('origin') != uri.origin) {
      response.statusCode = HttpStatus.forbidden;
      return null;
    }
    if (request.contentLength <= 0 || request.contentLength > _maxQrBytes) {
      response.statusCode = HttpStatus.requestEntityTooLarge;
      return null;
    }
    try {
      final source = await utf8.decoder.bind(request).join();
      final registration = DeviceRegistrationQr.fromJsonString(source);
      await registration.verifySignature();
      response.statusCode = _result.isCompleted
          ? HttpStatus.gone
          : HttpStatus.noContent;
      return _result.isCompleted ? null : source;
    } on FormatException {
      response.statusCode = HttpStatus.unprocessableEntity;
      return null;
    } on TypeError {
      response.statusCode = HttpStatus.unprocessableEntity;
      return null;
    }
  }
}
