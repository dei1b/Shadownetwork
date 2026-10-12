import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../domain/entities/device_crypto_identity.dart';
import '../../domain/entities/encrypted_message_body.dart';
import 'device_identity_store.dart';

class MessageEncryptionException implements Exception {
  const MessageEncryptionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MissingRecipientPublicKeyException extends MessageEncryptionException {
  const MissingRecipientPublicKeyException(String peerId)
    : super('Recipient $peerId has no registered encryption key.');
}

class MessageEncryptionService {
  MessageEncryptionService({X25519? x25519, Cipher? cipher, Hkdf? hkdf})
    : _x25519 = x25519 ?? X25519(),
      _cipher = cipher ?? AesGcm.with256bits(),
      _hkdf = hkdf ?? Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static const algorithm = 'x25519-hkdf-sha256-aes-256-gcm-v1';
  static const protocolVersion = 1;
  static const _hkdfSalt = 'shadow-network-message-encryption-v1';

  final X25519 _x25519;
  final Cipher _cipher;
  final Hkdf _hkdf;

  Future<EncryptedMessageBody> encrypt({
    required String plainText,
    required String recipientPublicKey,
    required int recipientKeyVersion,
    required String authenticatedData,
  }) async {
    final recipientPublicKeyBytes = _decodeKey(
      recipientPublicKey,
      fieldName: 'recipient public key',
    );
    final recipientKeyId = DeviceIdentityStore.keyIdForPublicKey(
      recipientPublicKeyBytes,
    );
    final ephemeralKeyPair = await _x25519.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: SimplePublicKey(
        recipientPublicKeyBytes,
        type: KeyPairType.x25519,
      ),
    );
    final contentKey = await _deriveContentKey(
      sharedSecret,
      authenticatedData: authenticatedData,
    );
    final nonce = _cipher.newNonce();
    final secretBox = await _cipher.encrypt(
      utf8.encode(plainText),
      secretKey: contentKey,
      nonce: nonce,
      aad: utf8.encode(authenticatedData),
    );

    return EncryptedMessageBody(
      algorithm: algorithm,
      protocolVersion: protocolVersion,
      recipientKeyId: recipientKeyId,
      recipientKeyVersion: recipientKeyVersion,
      ephemeralPublicKey: base64UrlEncode(ephemeralPublicKey.bytes),
      nonce: base64UrlEncode(secretBox.nonce),
      cipherText: base64UrlEncode(secretBox.cipherText),
      authenticationTag: base64UrlEncode(secretBox.mac.bytes),
    );
  }

  Future<String> decrypt({
    required EncryptedMessageBody encryptedBody,
    required DeviceCryptoIdentity localIdentity,
    required String authenticatedData,
  }) async {
    if (encryptedBody.algorithm != algorithm ||
        encryptedBody.protocolVersion != protocolVersion) {
      throw const FormatException('Unsupported message encryption protocol.');
    }
    if (encryptedBody.recipientKeyId != localIdentity.keyId ||
        encryptedBody.recipientKeyVersion != localIdentity.keyVersion) {
      throw const FormatException('Encrypted message uses another device key.');
    }

    try {
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: localIdentity.keyPair,
        remotePublicKey: SimplePublicKey(
          _decodeKey(
            encryptedBody.ephemeralPublicKey,
            fieldName: 'ephemeral public key',
          ),
          type: KeyPairType.x25519,
        ),
      );
      final contentKey = await _deriveContentKey(
        sharedSecret,
        authenticatedData: authenticatedData,
      );
      final clearText = await _cipher.decrypt(
        SecretBox(
          base64Url.decode(encryptedBody.cipherText),
          nonce: base64Url.decode(encryptedBody.nonce),
          mac: Mac(base64Url.decode(encryptedBody.authenticationTag)),
        ),
        secretKey: contentKey,
        aad: utf8.encode(authenticatedData),
      );
      return utf8.decode(clearText);
    } on SecretBoxAuthenticationError {
      throw const FormatException('Encrypted message authentication failed.');
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Encrypted message could not be decrypted.');
    }
  }

  Future<SecretKey> _deriveContentKey(
    SecretKey sharedSecret, {
    required String authenticatedData,
  }) {
    return _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: utf8.encode(_hkdfSalt),
      info: utf8.encode(authenticatedData),
    );
  }

  static List<int> _decodeKey(String value, {required String fieldName}) {
    try {
      final bytes = base64Url.decode(value);
      if (bytes.length != 32) {
        throw FormatException('$fieldName must contain 32 bytes.');
      }
      return bytes;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw FormatException('$fieldName is not valid base64url.');
    }
  }
}
