import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../registration/data/pilot_registration.dart';
import '../../../registration/data/registration_review_api.dart';
import '../../domain/entities/trust_bundle.dart';
import '../../presentation/providers/device_access_provider.dart';

const _issuerFingerprint = String.fromEnvironment('DNSC_ISSUER_FINGERPRINT');

final trustDirectorySyncProvider = Provider<TrustDirectorySyncService>(
  TrustDirectorySyncService.new,
);

class TrustDirectorySyncService {
  TrustDirectorySyncService(this.ref);
  final Ref ref;
  Future<void>? _active;

  Future<void> refresh() {
    if (!pilotRegistrationEnabled || !pilotRegistrationIsLive) {
      return Future.value();
    }
    return _active ??= _refresh().whenComplete(() => _active = null);
  }

  Future<void> _refresh() async {
    final registration = await PilotRegistration.open();
    final user = registration.auth.currentUser;
    if (user == null) return;
    final application = await registration.readStatus(user);
    if (application?.status != 'published') return;
    final token = await user.getIdToken();
    if (token == null) return;
    final directory = await RegistrationReviewApi.live().readDirectory(token);
    if (directory == null || registration.auth.currentUser?.uid != user.uid) {
      return;
    }
    final bundle = TrustBundle.fromJsonString(directory.bundle);
    if (bundle.bundleVersion != directory.version) {
      throw const FormatException(
        'The directory version does not match its signed bundle.',
      );
    }
    final store = ref.read(trustBundleStoreProvider);
    final current = await store.loadBundle();
    if (current != null && current.bundleVersion > bundle.bundleVersion) return;
    await store.importBundleJson(
      directory.bundle,
      directoryProject: liveRegistrationProject,
      issuerFingerprint: _issuerFingerprint,
    );
    if (current?.bundleVersion != bundle.bundleVersion) {
      ref.invalidate(deviceAccessProfileProvider);
    }
  }
}
