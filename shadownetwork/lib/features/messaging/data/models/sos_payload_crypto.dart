import 'dart:convert';

import 'package:crypto/crypto.dart';

class SosEncryptedPayload {
  const SosEncryptedPayload({
    required this.cipherText,
    required this.nonce,
    required this.tag,
  });

  final String cipherText;
  final String nonce;
  final String tag;
}

class SosPayloadCrypto {
  const SosPayloadCrypto._();

  static const algorithm = 'sn-sha256-stream-v1';
  static const _domain = 'shadow-network-sos-targeted-v1';

  static SosEncryptedPayload encrypt({
    required String plainText,
    required String messageId,
    required String senderPeerId,
    required String recipientPeerId,
    required String createdAt,
  }) {
    final nonceBytes = _nonceBytes(
      messageId: messageId,
      senderPeerId: senderPeerId,
      recipientPeerId: recipientPeerId,
      createdAt: createdAt,
    );
    final key = _key(
      senderPeerId: senderPeerId,
      recipientPeerId: recipientPeerId,
    );
    final plainBytes = utf8.encode(plainText);
    final cipherBytes = _xorWithKeyStream(plainBytes, key, nonceBytes);
    final tagBytes = _tag(
      key: key,
      nonce: nonceBytes,
      cipherBytes: cipherBytes,
    );

    return SosEncryptedPayload(
      cipherText: base64Url.encode(cipherBytes),
      nonce: base64Url.encode(nonceBytes),
      tag: base64Url.encode(tagBytes),
    );
  }

  static String decrypt({
    required String cipherText,
    required String nonce,
    required String tag,
    required String senderPeerId,
    required String recipientPeerId,
  }) {
    final key = _key(
      senderPeerId: senderPeerId,
      recipientPeerId: recipientPeerId,
    );
    final nonceBytes = base64Url.decode(nonce);
    final cipherBytes = base64Url.decode(cipherText);
    final expectedTag = base64Url.encode(
      _tag(key: key, nonce: nonceBytes, cipherBytes: cipherBytes),
    );

    if (expectedTag != tag) {
      throw const FormatException(
        'Encrypted SOS authentication tag is invalid.',
      );
    }

    return utf8.decode(_xorWithKeyStream(cipherBytes, key, nonceBytes));
  }

  static List<int> _key({
    required String senderPeerId,
    required String recipientPeerId,
  }) {
    return sha256
        .convert(utf8.encode('$_domain|$senderPeerId|$recipientPeerId'))
        .bytes;
  }

  static List<int> _nonceBytes({
    required String messageId,
    required String senderPeerId,
    required String recipientPeerId,
    required String createdAt,
  }) {
    return sha256
        .convert(
          utf8.encode('$messageId|$senderPeerId|$recipientPeerId|$createdAt'),
        )
        .bytes
        .take(12)
        .toList(growable: false);
  }

  static List<int> _tag({
    required List<int> key,
    required List<int> nonce,
    required List<int> cipherBytes,
  }) {
    return sha256.convert([...key, ...nonce, ...cipherBytes]).bytes;
  }

  static List<int> _xorWithKeyStream(
    List<int> input,
    List<int> key,
    List<int> nonce,
  ) {
    final output = <int>[];
    var counter = 0;

    while (output.length < input.length) {
      final block = sha256
          .convert(
            utf8.encode(
              '$counter|${base64Url.encode(key)}|${base64Url.encode(nonce)}',
            ),
          )
          .bytes;
      for (final byte in block) {
        if (output.length == input.length) {
          break;
        }
        output.add(input[output.length] ^ byte);
      }
      counter++;
    }

    return output;
  }
}
