import 'dart:convert';

String canonicalJsonEncode(Object? value) {
  if (value == null || value is bool || value is num || value is String) {
    return jsonEncode(value);
  }
  if (value is List) {
    return '[${value.map(canonicalJsonEncode).join(',')}]';
  }
  if (value is Map) {
    final entries =
        value.entries
            .map((entry) => MapEntry(entry.key.toString(), entry.value))
            .toList(growable: false)
          ..sort((left, right) => left.key.compareTo(right.key));
    return '{${entries.map((entry) => '${jsonEncode(entry.key)}:${canonicalJsonEncode(entry.value)}').join(',')}}';
  }
  throw FormatException(
    'Unsupported canonical JSON value: ${value.runtimeType}.',
  );
}
