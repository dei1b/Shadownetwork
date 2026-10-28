import '../../../messaging/domain/repositories/sos_message_repository.dart';
import '../entities/validation_bundle.dart';
import '../entities/validation_event.dart';
import '../repositories/validation_bundle_file_gateway.dart';
import '../repositories/validation_metrics_repository.dart';
import 'validation_bundle_codec.dart';

class PortableValidationExportService {
  const PortableValidationExportService({
    required this.metrics,
    required this.messages,
    required this.files,
    this.codec = const ValidationBundleCodec(),
  });

  final ValidationMetricsRepository metrics;
  final SosMessageRepository messages;
  final ValidationBundleFileGateway files;
  final ValidationBundleCodec codec;

  Future<ValidationBundle> exportSession({
    required String sessionId,
    required String localDeviceId,
    required String appVersion,
  }) async {
    final data = await metrics.getSessionData(sessionId);
    if (data.session.deviceId != localDeviceId) {
      throw StateError('Only sessions recorded by this phone can be shared.');
    }
    if (data.session.testRunId == null) {
      throw StateError(
        'This legacy session has no run code. Use Copy JSON or Copy CSV.',
      );
    }
    final bundle = codec.create(
      data: data,
      messages: await messages.getMessages(),
      appVersion: appVersion,
    );
    final path = await files.write(
      filename: bundle.filename,
      source: codec.encodeJson(bundle),
    );
    final recorded = await metrics.recordExport(
      ValidationExportRecord(
        id: bundle.id,
        sessionId: sessionId,
        createdAt: DateTime.parse(bundle.toJson()['generated_at']! as String),
        destination: 'portable_json_file',
        result: 'file_created',
        retryCount: 0,
        payloadHash: bundle.payloadHash,
      ),
    );
    if (!recorded) {
      throw StateError(
        'The file was created, but its export history could not be saved. Try again.',
      );
    }
    // A chooser opening is not proof of delivery or an administrator import.
    try {
      await files.openShareSheet(path);
    } catch (_) {
      throw const ValidationBundleShareException();
    }
    return bundle;
  }
}
