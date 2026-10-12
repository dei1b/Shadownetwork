import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class OfflinePanaboTileServer {
  static const _host = '127.0.0.1';
  static const _openFreeMapTileBuild = '20260506_001001_pt';
  static const _minNativeZoom = 10;
  static const _maxNativeZoom = 14;

  HttpServer? _server;
  final HttpClient _client = HttpClient();
  Future<Directory>? _cacheDirectory;

  Uri? get styleUri {
    final port = _server?.port;
    if (port == null) {
      return null;
    }
    return Uri.parse('http://$_host:$port/panabo/style.json');
  }

  Future<Uri> start() async {
    final existingUri = styleUri;
    if (existingUri != null) {
      return existingUri;
    }

    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: true,
    );
    _server = server;
    unawaited(server.listen(_handleRequest).asFuture<void>());
    return styleUri!;
  }

  Future<void> dispose() async {
    _client.close(force: true);
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 2 || segments.first != 'panabo') {
        await _notFound(request);
        return;
      }

      switch (segments[1]) {
        case 'style.json':
          await _serveStyle(request);
          return;
        case 'tiles':
          await _serveTile(request, segments);
          return;
        case 'fonts':
          await _serveFont(request, segments);
          return;
        case 'sprites':
          await _serveSprite(request, segments);
          return;
        default:
          await _notFound(request);
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  Future<void> _serveTile(HttpRequest request, List<String> segments) async {
    if (segments.length != 5 || !segments[4].endsWith('.pbf')) {
      await _notFound(request);
      return;
    }

    final requestedZ = int.tryParse(segments[2]);
    final requestedX = int.tryParse(segments[3]);
    final requestedY = int.tryParse(segments[4].replaceAll('.pbf', ''));
    if (requestedZ == null || requestedX == null || requestedY == null) {
      await _notFound(request);
      return;
    }

    final nativeZ = requestedZ.clamp(_minNativeZoom, _maxNativeZoom).toInt();
    final zoomDelta = requestedZ - nativeZ;
    final nativeX = zoomDelta > 0 ? requestedX >> zoomDelta : requestedX;
    final nativeY = zoomDelta > 0 ? requestedY >> zoomDelta : requestedY;
    final y = '$nativeY.pbf';
    final assetPath = 'assets/map_tiles/panabo_vector/$nativeZ/$nativeX/$y';
    final onlineUrl =
        'https://tiles.openfreemap.org/planet/$_openFreeMapTileBuild/$nativeZ/$nativeX/$y';

    await _serveAsset(
      request,
      assetPath: assetPath,
      contentType: ContentType('application', 'x-protobuf'),
      cachePathSegments: ['tiles', '$nativeZ', '$nativeX', y],
      fallbackUrl: onlineUrl,
    );
  }

  Future<void> _serveStyle(HttpRequest request) async {
    final port = _server?.port;
    if (port == null) {
      await _notFound(request);
      return;
    }

    final baseUrl = 'http://$_host:$port/panabo';
    final style = await rootBundle.loadString(
      'assets/map_styles/panabo_offline.json',
    );
    final resolvedStyle = style
        .replaceAll('tiles/{z}/{x}/{y}.pbf', '$baseUrl/tiles/{z}/{x}/{y}.pbf')
        .replaceAll(
          'fonts/{fontstack}/{range}.pbf',
          '$baseUrl/fonts/{fontstack}/{range}.pbf',
        )
        .replaceAll('sprites/ofm', '$baseUrl/sprites/ofm');

    await _writeBytes(
      request,
      Uint8List.fromList(utf8.encode(resolvedStyle)),
      ContentType.json,
    );
  }

  Future<void> _serveFont(HttpRequest request, List<String> segments) async {
    if (segments.length != 4 || !segments[3].endsWith('.pbf')) {
      await _notFound(request);
      return;
    }

    final fontStack = segments[2];
    final range = segments[3];
    final assetPath = 'assets/map_fonts/$fontStack/$range';
    final onlineFont = Uri.encodeComponent(fontStack);
    final onlineUrl = 'https://tiles.openfreemap.org/fonts/$onlineFont/$range';

    await _serveAsset(
      request,
      assetPath: assetPath,
      contentType: ContentType('application', 'x-protobuf'),
      cachePathSegments: ['fonts', fontStack, range],
      fallbackUrl: onlineUrl,
    );
  }

  Future<void> _serveSprite(HttpRequest request, List<String> segments) async {
    if (segments.length != 3) {
      await _notFound(request);
      return;
    }

    final fileName = segments[2];
    final isJson = fileName.endsWith('.json');
    final isPng = fileName.endsWith('.png');
    if (!isJson && !isPng) {
      await _notFound(request);
      return;
    }

    final assetPath = 'assets/map_sprites/$fileName';
    final onlineUrl =
        'https://tiles.openfreemap.org/sprites/ofm_f384/$fileName';

    await _serveAsset(
      request,
      assetPath: assetPath,
      contentType: isJson ? ContentType.json : ContentType('image', 'png'),
      cachePathSegments: ['sprites', fileName],
      fallbackUrl: onlineUrl,
    );
  }

  Future<void> _serveAsset(
    HttpRequest request, {
    required String assetPath,
    required ContentType contentType,
    List<String>? cachePathSegments,
    String? fallbackUrl,
  }) async {
    try {
      final data = await rootBundle.load(assetPath);
      await _writeBytes(
        request,
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        contentType,
      );
    } catch (_) {
      if (cachePathSegments == null || fallbackUrl == null) {
        await _notFound(request);
        return;
      }
      await _serveCachedOrFetch(
        request,
        cachePathSegments: cachePathSegments,
        fallbackUrl: fallbackUrl,
        fallbackContentType: contentType,
      );
    }
  }

  Future<void> _serveCachedOrFetch(
    HttpRequest request, {
    required List<String> cachePathSegments,
    required String fallbackUrl,
    required ContentType fallbackContentType,
  }) async {
    final cacheFile = await _cacheFile(cachePathSegments);
    if (await cacheFile.exists()) {
      await _writeBytes(
        request,
        await cacheFile.readAsBytes(),
        fallbackContentType,
      );
      return;
    }

    try {
      final upstreamRequest = await _client.getUrl(Uri.parse(fallbackUrl));
      upstreamRequest.headers.set(
        HttpHeaders.userAgentHeader,
        'ShadowNetwork offline map cache',
      );
      final upstreamResponse = await upstreamRequest.close();
      if (upstreamResponse.statusCode != HttpStatus.ok) {
        await _notFound(request);
        return;
      }

      final chunks = <int>[];
      await for (final chunk in upstreamResponse) {
        chunks.addAll(chunk);
      }
      final bytes = Uint8List.fromList(chunks);
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes, flush: false);
      await _writeBytes(
        request,
        bytes,
        upstreamResponse.headers.contentType ?? fallbackContentType,
      );
    } catch (_) {
      await _notFound(request);
    }
  }

  Future<File> _cacheFile(List<String> pathSegments) async {
    final directory = await (_cacheDirectory ??= _createCacheDirectory());
    return File(p.joinAll([directory.path, ...pathSegments]));
  }

  Future<Directory> _createCacheDirectory() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final directory = Directory(
      p.join(supportDirectory.path, 'maplibre_tile_cache'),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _writeBytes(
    HttpRequest request,
    Uint8List bytes,
    ContentType contentType,
  ) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = contentType;
    request.response.headers.set(
      HttpHeaders.cacheControlHeader,
      'public, max-age=31536000',
    );
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _notFound(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}
