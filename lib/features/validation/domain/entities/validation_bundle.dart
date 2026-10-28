import 'dart:convert';

/// A detached snapshot: callers cannot mutate a checksummed export in place.
class ValidationBundle {
  ValidationBundle(Map<String, Object?> json) : _source = jsonEncode(json);

  final String _source;

  Map<String, Object?> toJson() =>
      Map<String, Object?>.from(jsonDecode(_source) as Map);

  String get id => toJson()['bundle_id']! as String;
  String get payloadHash => toJson()['payload_hash']! as String;

  String get filename {
    final json = toJson();
    final run = (json['test_run']! as Map)['id']! as String;
    final peer = (json['device']! as Map)['peer_id']! as String;
    final date = DateTime.parse(json['generated_at']! as String).toUtc();
    final stamp = date
        .toIso8601String()
        .split('.')
        .first
        .replaceAll('-', '')
        .replaceAll(':', '');
    return 'shadow-network-$run-${peer.substring(0, 21)}-${stamp}Z-${id.substring(7)}.json';
  }
}
