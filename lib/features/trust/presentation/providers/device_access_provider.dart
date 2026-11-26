import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../messaging/presentation/providers/local_messaging_providers.dart';
import '../../../messaging/presentation/providers/peer_location_providers.dart';
import '../../data/services/trust_bundle_store.dart';
import '../../domain/entities/approval_receipt.dart';
import '../../domain/entities/device_access_profile.dart';
import '../../domain/services/device_access_resolver.dart';

Future<SignedApprovalReceipt?> _safeLoadVerifiedReceipt(
  TrustBundleStore store,
) async {
  try {
    return await store.loadVerifiedReceipt();
  } on MissingPluginException {
    return null;
  } on FlutterError {
    return null;
  }
}

final trustBundleStoreProvider = Provider<TrustBundleStore>(
  (ref) => TrustBundleStore(),
);

final deviceAccessResolverProvider = Provider<DeviceAccessResolver>(
  (ref) => const DeviceAccessResolver(),
);

enum SosInboxAccess { allowed, broadcastOnly, awaitingRenewal, denied }

final sosInboxAccessProvider = Provider<Future<SosInboxAccess> Function()>((
  ref,
) {
  return () async {
    // The background relay can run for hours after the UI resolved its role.
    final store = ref.read(trustBundleStoreProvider);
    final bundle = await store.loadBundle();
    final receipt = await _safeLoadVerifiedReceipt(store);
    final expiresAt = bundle?.expiresAt ?? receipt?.expiresAt;
    if ((bundle?.isSignatureVerified != true && receipt == null) ||
        expiresAt == null) {
      return SosInboxAccess.denied;
    }
    final peer = await ref.read(localPeerProvider.future);
    final identity = await ref.read(deviceCryptoIdentityProvider.future);
    final signingIdentity = await ref.read(
      deviceSigningIdentityProvider.future,
    );
    final now = DateTime.now();
    final bundleActive =
        bundle?.isSignatureVerified == true && !bundle!.isExpiredAt(now);
    final receiptActive = receipt != null && !receipt.isExpiredAt(now);
    final expired = !bundleActive && !receiptActive;
    final profile = ref
        .read(deviceAccessResolverProvider)
        .resolve(
          deviceId: peer.id,
          publicKey: identity.encodedPublicKey,
          keyVersion: identity.keyVersion,
          signingPublicKey: signingIdentity.encodedPublicKey,
          bundle: bundle,
          receipt: receipt,
          // Check the prior role and keys to decide whether to retain work.
          now: expired
              ? expiresAt.subtract(const Duration(microseconds: 1))
              : now,
        );
    if (profile.canAccessResponderInterface) {
      return expired ? SosInboxAccess.awaitingRenewal : SosInboxAccess.allowed;
    }
    if (!expired && profile.isApproved) {
      return SosInboxAccess.broadcastOnly;
    }
    return SosInboxAccess.denied;
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
  final store = ref.watch(trustBundleStoreProvider);
  final bundle = await store.loadBundle();
  final receipt = await _safeLoadVerifiedReceipt(store);
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
        receipt: receipt,
      );
});
