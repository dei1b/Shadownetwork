import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class DeviceSigningIdentity {
  const DeviceSigningIdentity({
    required this.privateKeyBytes,
    required this.publicKeyBytes,
  });

  final List<int> privateKeyBytes;
  final List<int> publicKeyBytes;

  String get encodedPublicKey => base64UrlEncode(publicKeyBytes);
  String get keyId => keyIdForPublicKey(publicKeyBytes);
  SimpleKeyPairData get keyPair => SimpleKeyPairData(
    privateKeyBytes,
    publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
    type: KeyPairType.ed25519,
  );

  static String keyIdForPublicKey(List<int> bytes) =>
      'ed25519-${sha256.convert(bytes).toString().substring(0, 16)}';
}
