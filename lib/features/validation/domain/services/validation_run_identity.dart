import 'dart:convert';
import 'dart:math';

/// A grouping label only: possession of a run QR does not grant device trust.
abstract final class ValidationRunIdentity {
  static String normalizeCode(String source) {
    final trimmed = source.trim();
    if (!RegExp(
      r'^[A-Za-z0-9][A-Za-z0-9_-]{1,46}[A-Za-z0-9]$',
    ).hasMatch(trimmed)) {
      throw const FormatException(
        'Use 3–48 letters, numbers, hyphens or underscores; start and end with a letter or number.',
      );
    }
    return trimmed.toUpperCase();
  }

  static String generateCode({DateTime? now}) {
    final date = now ?? DateTime.now();
    final stamp =
        '${date.year.toString().padLeft(4, '0')}'
        '${date.month.toString().padLeft(2, '0')}'
        '${date.day.toString().padLeft(2, '0')}';
    final random = Random.secure();
    final suffix = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join().toUpperCase();
    return 'SN-$stamp-$suffix';
  }

  static String encodeQr(String code) => jsonEncode({
    'schema_version': 1,
    'bundle_type': 'shadow_network_validation_run',
    'test_run_id': normalizeCode(code),
  });

  static String decodeQr(String source) {
    if (source.length > 1024 || utf8.encode(source).length > 1024) {
      throw const FormatException('Run QR is too large (maximum 1 KiB).');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map ||
        decoded['schema_version'] != 1 ||
        decoded['bundle_type'] != 'shadow_network_validation_run' ||
        decoded['test_run_id'] is! String) {
      throw const FormatException(
        'Not a supported Shadow Network validation run QR.',
      );
    }
    return normalizeCode(decoded['test_run_id'] as String);
  }
}
