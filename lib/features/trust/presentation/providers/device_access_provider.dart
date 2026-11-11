import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../../messaging/presentation/providers/peer_location_providers.dart';
import '../../data/services/trust_bundle_store.dart';
import '../../domain/entities/device_access_profile.dart';
import '../../domain/services/device_access_resolver.dart';

final trustBundleStoreProvider = Provider<TrustBundleStore>(
  (ref) => TrustBundleStore(),
);

final deviceAccessResolverProvider = Provider<DeviceAccessResolver>(
  (ref) => const DeviceAccessResolver(),
);

final canReceiveSosProvider = Provider<Future<bool> Function()>((ref) {
  return () async {
    // The background relay can run for hours after the UI resolved its role.
    final bundle = await ref.read(trustBundleStoreProvider).loadBundle();
    if (bundle?.isSignatureVerified != true ||
        bundle!.isExpiredAt(DateTime.now())) {
      return false;
    }
    final peer = await ref.read(localPeerProvider.future);
    final identity = await ref.read(deviceCryptoIdentityProvider.future);
    final signingIdentity = await ref.read(
      deviceSigningIdentityProvider.future,
    );
    return ref
        .read(deviceAccessResolverProvider)
        .resolve(
          deviceId: peer.id,
          publicKey: identity.encodedPublicKey,
          keyVersion: identity.keyVersion,
          signingPublicKey: signingIdentity.encodedPublicKey,
          bundle: bundle,
        )
        .canAccessResponderInterface;
  };
});

final deviceAccessProfileProvider = FutureProvider<DeviceAccessProfile>((
  ref,
) async {
  final localPeer = await ref.watch(localPeerProvider.future);
  final identity = await ref.watch(deviceCryptoIdentityProvider.future);
  final signingIdentity = await ref.watch(deviceSigningIdentityProvider.future);
  final bundle = await ref.watch(trustBundleStoreProvider).loadBundle();
  if (bundle?.isSignatureVerified == true) {
    final repository = await ref.watch(trustRepositoryProvider.future);
    final previous = await repository.getMetadata();
    await repository.replaceFromBundle(bundle!);
    if (previous?.bundleHash != bundle.bundleHash) {
      ref.invalidate(sharedPeerLocationsProvider);
    }
  }

  return ref
      .watch(deviceAccessResolverProvider)
      .resolve(
        deviceId: localPeer.id,
        publicKey: identity.encodedPublicKey,
        keyVersion: identity.keyVersion,
        signingPublicKey: signingIdentity.encodedPublicKey,
        bundle: bundle,
      );
});
