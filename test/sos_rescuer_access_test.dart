import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/category.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_status.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer.dart';
import 'package:shadownetwork/features/messaging/domain/entities/peer_type.dart';
import 'package:shadownetwork/features/messaging/domain/entities/sos_message.dart';
import 'package:shadownetwork/features/messaging/presentation/providers/local_messaging_providers.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/device_signing_identity_store.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/presentation/providers/device_access_provider.dart';

class _BundleStore extends TrustBundleStore {
  TrustBundle? bundle;

  @override
  Future<TrustBundle?> loadBundle() async => bundle;
}

void main() {
  test('SOS access uses the current approval and both local keys', () async {
    const local = Peer(
      id: 'local',
      name: 'Local phone',
      type: PeerType.civilian,
      isConnected: true,
    );
    final identity = await DeviceIdentityStore(
      secretStore: InMemorySecretValueStore(),
    ).loadOrCreate();
    final signingIdentity = await DeviceSigningIdentityStore(
      secretStore: InMemorySecretValueStore(),
    ).loadOrCreate();
    final now = DateTime.now().toUtc();
    final store = _BundleStore();
    final container = ProviderContainer(
      overrides: [
        trustBundleStoreProvider.overrideWithValue(store),
        localPeerProvider.overrideWith((ref) async => local),
        deviceCryptoIdentityProvider.overrideWith((ref) async => identity),
        deviceSigningIdentityProvider.overrideWith(
          (ref) async => signingIdentity,
        ),
      ],
    );
    addTearDown(container.dispose);
    TrustedDevice device(String id, String role, {String? signingKey}) =>
        TrustedDevice(
          deviceId: id,
          ownerName: id,
          role: role,
          status: 'approved',
          updatedAt: now,
          publicKey: identity.encodedPublicKey,
          signingPublicKey: signingKey ?? signingIdentity.encodedPublicKey,
        );
    TrustBundle approval(List<TrustedDevice> devices, {bool expired = false}) =>
        TrustBundle(
          schemaVersion: 2,
          generatedAt: now,
          expiresAt: now.add(Duration(hours: expired ? -1 : 1)),
          isSignatureVerified: true,
          approvedDevices: devices,
          revokedDevices: const [],
        );

    final receiveSos = container.read(canReceiveSosProvider);
    final targets = container.read(approvedSosRescuersProvider);
    expect(await receiveSos(), isFalse);
    store.bundle = approval([
      device(local.id, 'rescuer'),
      device('other-rescuer', 'responder'),
      device('civilian', 'civilian'),
      device('relay', 'relay'),
      device('admin', 'admin'),
    ]);
    expect(await receiveSos(), isTrue);
    expect((await targets(local.id)).map((device) => device.deviceId), [
      'other-rescuer',
    ]);
    final sendSos = container.read(saveSosMessageProvider);
    await expectLater(
      sendSos(
        SosMessage(
          id: 'wrong-target',
          sender: local,
          recipient: local.copyWith(id: 'civilian', type: PeerType.responder),
          body: 'Test SOS',
          category: Category.medical,
          status: MessageStatus.queued,
          createdAt: now,
        ),
      ),
      throwsA(isA<SosRecipientUnavailableException>()),
    );
    store.bundle = approval([
      device(local.id, 'responder', signingKey: 'wrong'),
    ]);
    expect(await receiveSos(), isFalse);
    store.bundle = approval([device(local.id, 'civilian')]);
    expect(await receiveSos(), isFalse);
    store.bundle = approval([device(local.id, 'responder')], expired: true);
    expect(await receiveSos(), isFalse);
    expect(await targets('another-phone'), isEmpty);
  });
}
