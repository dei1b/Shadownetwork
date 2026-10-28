import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../../trust/presentation/providers/device_access_provider.dart';
import '../../data/services/android_validation_bundle_file_gateway.dart';
import '../../domain/entities/validation_bundle.dart';
import '../../domain/repositories/validation_bundle_file_gateway.dart';
import '../../domain/services/portable_validation_export_service.dart';
import 'validation_session_provider.dart';

final validationBundleFileGatewayProvider =
    Provider<ValidationBundleFileGateway>(
      (ref) => AndroidValidationBundleFileGateway(),
    );

final validationAppVersionProvider = FutureProvider<String>((ref) async {
  final package = await PackageInfo.fromPlatform();
  return '${package.version}+${package.buildNumber}';
});

final validationBundleExportProvider =
    AsyncNotifierProvider<ValidationBundleExportController, ValidationBundle?>(
      ValidationBundleExportController.new,
    );

class ValidationBundleExportController
    extends AsyncNotifier<ValidationBundle?> {
  bool _busy = false;
  bool _disposed = false;

  @override
  FutureOr<ValidationBundle?> build() {
    ref.onDispose(() => _disposed = true);
    return null;
  }

  Future<ValidationBundle?> shareSession(String sessionId) async {
    if (_busy) return null;
    _busy = true;
    state = const AsyncLoading();
    try {
      final access = await ref.refresh(deviceAccessProfileProvider.future);
      if (!access.canAccessResponderInterface) {
        throw StateError(
          'An approved responder device is required to share validation files.',
        );
      }
      final local = await ref.read(localPeerProvider.future);
      final metrics = await ref.read(
        validationMetricsRepositoryProvider.future,
      );
      final messages = await ref.read(sosMessageRepositoryProvider.future);
      final version = await ref.read(validationAppVersionProvider.future);
      final currentAccess = await ref.refresh(
        deviceAccessProfileProvider.future,
      );
      if (!currentAccess.canAccessResponderInterface ||
          currentAccess.deviceId != local.id) {
        throw StateError(
          'Responder approval changed. Check this phone registration before exporting.',
        );
      }
      final bundle =
          await PortableValidationExportService(
            metrics: metrics,
            messages: messages,
            files: ref.read(validationBundleFileGatewayProvider),
          ).exportSession(
            sessionId: sessionId,
            localDeviceId: local.id,
            appVersion: version,
          );
      if (!_disposed) {
        // A display refresh failure must not turn a created export into failure.
        await ref
            .read(validationSessionProvider.notifier)
            .refresh()
            .catchError((Object _) {});
        if (!_disposed) state = AsyncData(bundle);
      }
      return bundle;
    } catch (error, stack) {
      if (!_disposed) state = AsyncError(error, stack);
      rethrow;
    } finally {
      _busy = false;
    }
  }
}
