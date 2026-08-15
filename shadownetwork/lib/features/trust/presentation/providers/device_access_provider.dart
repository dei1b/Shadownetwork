import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../data/services/trust_bundle_store.dart';
import '../../domain/entities/device_access_profile.dart';
import '../../domain/services/device_access_resolver.dart';

final trustBundleStoreProvider = Provider<TrustBundleStore>(
  (ref) => TrustBundleStore(),
);

final deviceAccessResolverProvider = Provider<DeviceAccessResolver>(
  (ref) => const DeviceAccessResolver(),
);

final deviceAccessProfileProvider = FutureProvider<DeviceAccessProfile>((
  ref,
) async {
  final localPeer = await ref.watch(localPeerProvider.future);
  final identity = await ref.watch(deviceCryptoIdentityProvider.future);
  final bundle = await ref.watch(trustBundleStoreProvider).loadBundle();
  if (bundle?.isSignatureVerified == true) {
    final repository = await ref.watch(trustRepositoryProvider.future);
    await repository.replaceFromBundle(bundle!);
  }

  return ref
      .watch(deviceAccessResolverProvider)
      .resolve(
        deviceId: localPeer.id,
        publicKey: identity.encodedPublicKey,
        keyVersion: identity.keyVersion,
        bundle: bundle,
      );
});
