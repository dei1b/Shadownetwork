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

enum SosInboxAccess { allowed, awaitingRenewal, denied }

final sosInboxAccessProvider = Provider<Future<SosInboxAccess> Function()>((
  ref,
) {
  return () async {
    // The background relay can run for hours after the UI resolved its role.
    final bundle = await ref.read(trustBundleStoreProvider).loadBundle();
    final expiresAt = bundle?.expiresAt;
    if (bundle?.isSignatureVerified != true || expiresAt == null) {
      return SosInboxAccess.denied;
    }
    final peer = await ref.read(localPeerProvider.future);
    final identity = await ref.read(deviceCryptoIdentityProvider.future);
    final signingIdentity = await ref.read(
      deviceSigningIdentityProvider.future,
    );
    final now = DateTime.now();
    final expired = bundle!.isExpiredAt(now);
    final profile = ref
        .read(deviceAccessResolverProvider)
        .resolve(
          deviceId: peer.id,
          publicKey: identity.encodedPublicKey,
          keyVersion: identity.keyVersion,
          signingPublicKey: signingIdentity.encodedPublicKey,
          bundle: bundle,
          // Check the prior role and keys to decide whether to retain work.
          now: expired
              ? expiresAt.subtract(const Duration(microseconds: 1))
              : now,
        );
    if (!profile.canAccessResponderInterface) return SosInboxAccess.denied;
    return expired ? SosInboxAccess.awaitingRenewal : SosInboxAccess.allowed;
  };
});

final canReceiveSosProvider = Provider<Future<bool> Function()>((ref) {
  final access = ref.watch(sosInboxAccessProvider);
  return () async => await access() == SosInboxAccess.allowed;
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
