import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class DeviceCryptoIdentity {
  const DeviceCryptoIdentity({
    required this.keyId,
    required this.keyVersion,
    required this.privateKeyBytes,
    required this.publicKeyBytes,
  });

  final String keyId;
  final int keyVersion;
  final List<int> privateKeyBytes;
  final List<int> publicKeyBytes;

  String get encodedPublicKey => base64UrlEncode(publicKeyBytes);

  SimplePublicKey get publicKey =>
      SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519);

  SimpleKeyPairData get keyPair => SimpleKeyPairData(
    privateKeyBytes,
    publicKey: publicKey,
    type: KeyPairType.x25519,
  );

  static String keyIdForPublicKey(List<int> publicKeyBytes) {
    final digest = sha256.convert(publicKeyBytes).toString();
    return 'x25519-${digest.substring(0, 16)}';
  }
}
