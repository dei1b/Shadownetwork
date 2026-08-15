import 'validation_event.dart';
import 'validation_session.dart';

class ValidationSessionData {
  const ValidationSessionData({
    required this.session,
    required this.events,
    required this.discoveryAttempts,
    required this.batterySamples,
    required this.exportRecords,
  });

  final ValidationSession session;
  final List<ValidationMessageEvent> events;
  final List<ValidationDiscoveryAttempt> discoveryAttempts;
  final List<ValidationBatterySample> batterySamples;
  final List<ValidationExportRecord> exportRecords;

  int get telemetryRecordCount =>
      events.length + discoveryAttempts.length + batterySamples.length;

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'bundle_type': 'shadow_network_validation_session',
    'session': session.toJson(),
    'message_events': events.map((item) => item.toJson()).toList(),
    'discovery_attempts': discoveryAttempts
        .map((item) => item.toJson())
        .toList(),
    'battery_samples': batterySamples.map((item) => item.toJson()).toList(),
    'export_records': exportRecords.map((item) => item.toJson()).toList(),
  };

  factory ValidationSessionData.fromJson(Map<String, Object?> json) {
    if (json['bundle_type'] != 'shadow_network_validation_session' ||
        json['schema_version'] != 1) {
      throw const FormatException('Unsupported validation session export.');
    }
    return ValidationSessionData(
      session: ValidationSession.fromJson(
        Map<String, Object?>.from(json['session']! as Map),
      ),
      events: _maps(
        json['message_events'],
      ).map(ValidationMessageEvent.fromJson).toList(growable: false),
      discoveryAttempts: _maps(
        json['discovery_attempts'],
      ).map(ValidationDiscoveryAttempt.fromJson).toList(growable: false),
      batterySamples: _maps(
        json['battery_samples'],
      ).map(ValidationBatterySample.fromJson).toList(growable: false),
      exportRecords: _maps(
        json['export_records'],
      ).map(ValidationExportRecord.fromJson).toList(growable: false),
    );
  }

  static Iterable<Map<String, Object?>> _maps(Object? source) {
    if (source is! List) {
      return const [];
    }
    return source.whereType<Map>().map(Map<String, Object?>.from);
  }
}
