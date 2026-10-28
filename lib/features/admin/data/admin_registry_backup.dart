import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../../trust/domain/services/canonical_json.dart';

/// Versioned administrator-only recovery envelope. All format metadata is AAD.
class AdminRegistryBackup {
  static const maxSourceBytes = 16 * 1024 * 1024;
  static const _format = 'shadow_network_admin_backup';
  static const _iterations = 600000;
  static const _fields = {
    'format',
    'version',
    'kdf',
    'iterations',
    'key_bits',
    'salt',
    'cipher',
    'nonce',
    'ciphertext',
    'mac',
  };

  static void validatePassword(String password) {
    if (password.runes.length < 12 || password.runes.length > 1024) {
      throw const FormatException(
        'Backup password must contain 12 to 1,024 characters.',
      );
    }
  }

  static Future<String> encrypt(
    Map<String, Object?> payload,
    String password,
  ) async {
    validatePassword(password);
    final plaintext = utf8.encode(jsonEncode(payload));
    if (plaintext.length > maxSourceBytes ~/ 2) {
      throw const FormatException('Administrator backup is too large.');
    }
    return Isolate.run(() async {
      final random = Random.secure();
      final salt = List<int>.generate(16, (_) => random.nextInt(256));
      final algorithm = AesGcm.with256bits();
      final nonce = algorithm.newNonce();
      final header = <String, Object?>{
        'format': _format,
        'version': 1,
        'kdf': 'pbkdf2-hmac-sha256',
        'iterations': _iterations,
        'key_bits': 256,
        'salt': base64UrlEncode(salt),
        'cipher': 'aes-256-gcm',
        'nonce': base64UrlEncode(nonce),
      };
      final key = await _derive(password, salt);
      final box = await algorithm.encrypt(
        plaintext,
        secretKey: key,
        nonce: nonce,
        aad: utf8.encode(canonicalJsonEncode(header)),
      );
      return jsonEncode({
        ...header,
        'ciphertext': base64UrlEncode(box.cipherText),
        'mac': base64UrlEncode(box.mac.bytes),
      });
    });
  }

  static Future<Map<String, Object?>> decrypt(
    String source,
    String password,
  ) async {
    validatePassword(password);
    // Bound and validate every attacker-controlled KDF parameter before deriving.
    if (source.length > maxSourceBytes ||
        utf8.encode(source).length > maxSourceBytes) {
      throw const FormatException('Administrator backup is too large.');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded.length != _fields.length ||
        !decoded.keys.every(_fields.contains) ||
        decoded['format'] != _format ||
        decoded['version'] is! int ||
        decoded['version'] != 1 ||
        decoded['kdf'] != 'pbkdf2-hmac-sha256' ||
        decoded['iterations'] is! int ||
        decoded['iterations'] != _iterations ||
        decoded['key_bits'] is! int ||
        decoded['key_bits'] != 256 ||
        decoded['cipher'] != 'aes-256-gcm') {
      throw const FormatException('Unsupported administrator backup format.');
    }
    final salt = _bytes(decoded['salt'], length: 16);
    final nonce = _bytes(decoded['nonce'], length: 12);
    final mac = _bytes(decoded['mac'], length: 16);
    final ciphertext = _bytes(decoded['ciphertext']);
    if (ciphertext.isEmpty || ciphertext.length > maxSourceBytes ~/ 2) {
      throw const FormatException('Invalid administrator backup size.');
    }
    final header = Map<String, Object?>.from(decoded)
      ..remove('ciphertext')
      ..remove('mac');
    return Isolate.run(() async {
      try {
        final plaintext = await AesGcm.with256bits().decrypt(
          SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
          secretKey: await _derive(password, salt),
          aad: utf8.encode(canonicalJsonEncode(header)),
        );
        final payload = jsonDecode(utf8.decode(plaintext));
        if (payload is! Map<String, dynamic>) {
          throw const FormatException();
        }
        return Map<String, Object?>.from(payload);
      } on SecretBoxAuthenticationError {
        throw const FormatException(
          'Backup password is incorrect or the file was changed.',
        );
      } on FormatException {
        // Parser exceptions may contain their source; never surface plaintext.
        throw const FormatException('Invalid administrator backup contents.');
      }
    });
  }

  static Future<SecretKey> _derive(String password, List<int> salt) => Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  ).deriveKeyFromPassword(password: password, nonce: salt);

  static List<int> _bytes(Object? value, {int? length}) {
    if (value is! String) {
      throw const FormatException('Invalid backup encoding.');
    }
    final result = base64Url.decode(value);
    if (length != null && result.length != length) {
      throw const FormatException('Invalid backup field length.');
    }
    return result;
  }
}
