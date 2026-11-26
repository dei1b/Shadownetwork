import 'dart:convert';

import 'package:crypto/crypto.dart';

class MultiFrameQrProgress {
  const MultiFrameQrProgress({
    required this.transferId,
    required this.receivedCount,
    required this.totalFrames,
    this.completedPayload,
  });

  final String transferId;
  final int receivedCount;
  final int totalFrames;
  final String? completedPayload;

  bool get isComplete => completedPayload != null;
}

class MultiFrameQrCodec {
  static const frameType = 'shadow_network_qr_frame';
  // Version 40, byte mode, medium error correction.
  static const int maxSingleQrBytes = 2331;
  static const int maxChunkChars = 1400;

  static List<String> encode(
    String payload, {
    int maxSingleBytes = maxSingleQrBytes,
    int chunkChars = maxChunkChars,
  }) {
    if (payload.isEmpty) {
      throw const FormatException('QR payload cannot be empty.');
    }
    if (chunkChars <= 0) {
      throw ArgumentError.value(chunkChars, 'chunkChars', 'Must be positive.');
    }
    final payloadBytes = utf8.encode(payload);
    if (payloadBytes.length <= maxSingleBytes) {
      return [payload];
    }
    final digest = sha256.convert(payloadBytes).toString();
    final transferId = digest.substring(0, 12);
    final encoded = base64UrlEncode(payloadBytes);
    final chunks = <String>[];
    for (var offset = 0; offset < encoded.length; offset += chunkChars) {
      final end = (offset + chunkChars).clamp(0, encoded.length);
      chunks.add(encoded.substring(offset, end));
    }
    final total = chunks.length;
    return [
      for (var index = 0; index < total; index++)
        jsonEncode({
          'frame_type': frameType,
          'v': 1,
          'id': transferId,
          'i': index + 1,
          'n': total,
          'sha256': digest,
          'd': chunks[index],
        }),
    ];
  }
}

class MultiFrameQrCollector {
  String? _activeId;
  int? _totalFrames;
  String? _expectedDigest;
  final Map<int, String> _frames = {};

  void reset() {
    _activeId = null;
    _totalFrames = null;
    _expectedDigest = null;
    _frames.clear();
  }

  MultiFrameQrProgress accept(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Scanned QR code is empty.');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return MultiFrameQrProgress(
        transferId: 'single',
        receivedCount: 1,
        totalFrames: 1,
        completedPayload: trimmed,
      );
    }
    if (decoded is! Map || decoded['frame_type'] != MultiFrameQrCodec.frameType) {
      return MultiFrameQrProgress(
        transferId: 'single',
        receivedCount: 1,
        totalFrames: 1,
        completedPayload: trimmed,
      );
    }

    final version = decoded['v'];
    final id = decoded['id'];
    final index = decoded['i'];
    final total = decoded['n'];
    final digest = decoded['sha256'];
    final data = decoded['d'];
    if (version != 1 ||
        id is! String ||
        id.isEmpty ||
        index is! int ||
        total is! int ||
        total < 2 ||
        total > 512 ||
        index < 1 ||
        index > total ||
        digest is! String ||
        digest.length != 64 ||
        data is! String ||
        data.isEmpty) {
      throw const FormatException('Invalid approval QR frame.');
    }

    if (_activeId != id || _totalFrames != total || _expectedDigest != digest) {
      _activeId = id;
      _totalFrames = total;
      _expectedDigest = digest;
      _frames.clear();
    }

    _frames[index] = data;
    if (_frames.length < total) {
      return MultiFrameQrProgress(
        transferId: id,
        receivedCount: _frames.length,
        totalFrames: total,
      );
    }

    final combined = StringBuffer();
    for (var i = 1; i <= total; i++) {
      final chunk = _frames[i];
      if (chunk == null) {
        return MultiFrameQrProgress(
          transferId: id,
          receivedCount: _frames.length,
          totalFrames: total,
        );
      }
      combined.write(chunk);
    }

    final List<int> payloadBytes;
    try {
      payloadBytes = base64Url.decode(combined.toString());
    } catch (_) {
      reset();
      throw const FormatException('QR frame encoding is invalid.');
    }
    final actualDigest = sha256.convert(payloadBytes).toString();
    if (actualDigest != digest) {
      reset();
      throw const FormatException(
        'Assembled approval QR failed integrity verification.',
      );
    }
    final payload = utf8.decode(payloadBytes);
    reset();
    return MultiFrameQrProgress(
      transferId: id,
      receivedCount: total,
      totalFrames: total,
      completedPayload: payload,
    );
  }
}
