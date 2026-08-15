import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/security/data/services/device_identity_store.dart';
import 'package:shadownetwork/features/security/data/services/message_encryption_service.dart';
import 'package:shadownetwork/features/security/domain/entities/device_crypto_identity.dart';
import 'package:shadownetwork/features/security/domain/entities/encrypted_message_body.dart';

void main() {
  test('generates and securely reloads the same X25519 identity', () async {
    final secretStore = InMemorySecretValueStore();
    final firstStore = DeviceIdentityStore(secretStore: secretStore);
    final first = await firstStore.loadOrCreate();
    final second = await DeviceIdentityStore(
      secretStore: secretStore,
    ).loadOrCreate();

    expect(first.privateKeyBytes, hasLength(32));
    expect(first.publicKeyBytes, hasLength(32));
    expect(second.keyId, first.keyId);
    expect(second.privateKeyBytes, first.privateKeyBytes);
    expect(second.publicKeyBytes, first.publicKeyBytes);
  });

  test('encrypts and decrypts using recipient X25519 identity', () async {
    final recipient = await DeviceIdentityStore(
      secretStore: InMemorySecretValueStore(),
    ).loadOrCreate();
    final service = MessageEncryptionService();
    final encrypted = await service.encrypt(
      plainText: 'Need rescue at Purok 3',
      recipientPublicKey: recipient.encodedPublicKey,
      recipientKeyVersion: recipient.keyVersion,
      authenticatedData: 'message-1|sender-a|recipient-b',
    );

    expect(encrypted.cipherText, isNot(contains('Need rescue')));
    expect(encrypted.recipientKeyId, recipient.keyId);
    expect(
      await service.decrypt(
        encryptedBody: encrypted,
        localIdentity: recipient,
        authenticatedData: 'message-1|sender-a|recipient-b',
      ),
      'Need rescue at Purok 3',
    );
  });

  test('rejects a non-recipient identity', () async {
    final recipient = await _newIdentity();
    final otherDevice = await _newIdentity();
    final service = MessageEncryptionService();
    final encrypted = await service.encrypt(
      plainText: 'Private SOS',
      recipientPublicKey: recipient.encodedPublicKey,
      recipientKeyVersion: recipient.keyVersion,
      authenticatedData: 'immutable metadata',
    );

    expect(
      () => service.decrypt(
        encryptedBody: encrypted,
        localIdentity: otherDevice,
        authenticatedData: 'immutable metadata',
      ),
      throwsFormatException,
    );
  });

  test('rejects modified ciphertext and authenticated metadata', () async {
    final recipient = await _newIdentity();
    final service = MessageEncryptionService();
    final encrypted = await service.encrypt(
      plainText: 'Authenticated emergency message',
      recipientPublicKey: recipient.encodedPublicKey,
      recipientKeyVersion: recipient.keyVersion,
      authenticatedData: 'category=rescue|ttl=86400',
    );
    final cipherBytes = base64Url.decode(encrypted.cipherText);
    cipherBytes[0] ^= 1;
    final tampered = EncryptedMessageBody(
      algorithm: encrypted.algorithm,
      protocolVersion: encrypted.protocolVersion,
      recipientKeyId: encrypted.recipientKeyId,
      recipientKeyVersion: encrypted.recipientKeyVersion,
      ephemeralPublicKey: encrypted.ephemeralPublicKey,
      nonce: encrypted.nonce,
      cipherText: base64UrlEncode(cipherBytes),
      authenticationTag: encrypted.authenticationTag,
    );

    expect(
      () => service.decrypt(
        encryptedBody: tampered,
        localIdentity: recipient,
        authenticatedData: 'category=rescue|ttl=86400',
      ),
      throwsFormatException,
    );
    expect(
      () => service.decrypt(
        encryptedBody: encrypted,
        localIdentity: recipient,
        authenticatedData: 'category=other|ttl=86400',
      ),
      throwsFormatException,
    );
  });

  test('rotated device key cannot decrypt an older envelope', () async {
    final secretStore = InMemorySecretValueStore();
    final identityStore = DeviceIdentityStore(secretStore: secretStore);
    final originalIdentity = await identityStore.loadOrCreate();
    final service = MessageEncryptionService();
    final encrypted = await service.encrypt(
      plainText: 'Message for original key',
      recipientPublicKey: originalIdentity.encodedPublicKey,
      recipientKeyVersion: originalIdentity.keyVersion,
      authenticatedData: 'rotation-test',
    );

    await identityStore.clear();
    final rotatedIdentity = await identityStore.loadOrCreate();

    expect(rotatedIdentity.keyId, isNot(originalIdentity.keyId));
    expect(
      () => service.decrypt(
        encryptedBody: encrypted,
        localIdentity: rotatedIdentity,
        authenticatedData: 'rotation-test',
      ),
      throwsFormatException,
    );
  });
}

Future<DeviceCryptoIdentity> _newIdentity() {
  return DeviceIdentityStore(
    secretStore: InMemorySecretValueStore(),
  ).loadOrCreate();
}
