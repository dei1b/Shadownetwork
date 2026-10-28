import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../../trust/domain/services/canonical_json.dart';

class ValidationBundleIdentifiers {
  static String pseudonym(String run, String kind, String value) =>
      '$kind-${sha256.convert(utf8.encode(canonicalJsonEncode(['shadow_network_validation_v2', run, kind, value])))}';

  static String? correlation(String run, String kind, String? value) {
    if (value == null) return null;
    if (isCorrelation(kind, value)) return value;
    return pseudonym(run, 'invalid-$kind', value);
  }

  static bool isCorrelation(String kind, Object? value) {
    if (value is! String) return false;
    final raw = kind == 'message'
        ? RegExp(r'^[a-f0-9]{64}$')
        : RegExp(
            r'^(?:[a-f0-9]{32}|[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})$',
          );
    return raw.hasMatch(value) ||
        RegExp('^invalid-$kind-[a-f0-9]{64}\$').hasMatch(value);
  }
}
