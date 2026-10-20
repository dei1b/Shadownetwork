import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../../trust/domain/entities/device_trust_record.dart';
import '../../../trust/domain/entities/device_trust_status.dart';
import '../../../trust/domain/repositories/trust_repository.dart';
import '../../../trust/domain/services/canonical_json.dart';
import '../../domain/entities/device_signing_identity.dart';

class MessageAuthenticationService {
  const MessageAuthenticationService();

  static bool requiresSignature(Map<String, Object?> payload) =>
      (payload['payload_type'] == 'sos_message' &&
          payload['schema_version'] == 5) ||
      (payload['payload_type'] == 'chat_message' &&
          payload['schema_version'] == 3);

  static String signingData(Map<String, Object?> payload) {
    final normalized = Map<String, Object?>.from(payload)
      ..remove('message_hash');
    final routing = Map<String, Object?>.from(payload['routing']! as Map);
    routing['hop_count'] = 0;
    normalized['routing'] = routing;
    final authentication = Map<String, Object?>.from(
      payload['authentication']! as Map,
    )..remove('signature');
    normalized['authentication'] = authentication;
    return 'shadow-network-sender-signature-v1\n${canonicalJsonEncode(normalized)}';
  }

  Future<void> sign(
    Map<String, Object?> payload,
    DeviceSigningIdentity identity,
  ) async {
    payload['authentication'] = {
      'version': 1,
      'algorithm': 'ed25519',
      'key_id': identity.keyId,
      'public_key': identity.encodedPublicKey,
    };
    final signature = await Ed25519().sign(
      utf8.encode(signingData(payload)),
      keyPair: identity.keyPair,
    );
    (payload['authentication']! as Map<String, Object?>)['signature'] =
        base64UrlEncode(signature.bytes);
  }

  /// A self signature proves key possession; admin registration binds the key to a person/device.
  Future<DeviceTrustRecord> authenticate(
    String payloadJson,
    TrustRepository repository,
  ) async {
    final payload = jsonDecode(payloadJson) as Map<String, Object?>;
    final sender = payload['sender'] as Map?;
    final senderId = sender?['peer_id'] as String?;
    if (senderId == null || senderId.trim().isEmpty) {
      throw const FormatException('Message sender is missing.');
    }
    final record = await repository.getDevice(senderId);
    if (!requiresSignature(payload)) {
      // Legacy unsigned messages never inherit a verified label from a claimed ID.
      return record.status == DeviceTrustStatus.revoked
          ? record
          : DeviceTrustRecord.unknown(senderId);
    }
    try {
      final auth = payload['authentication']! as Map;
      if (auth['version'] != 1 || auth['algorithm'] != 'ed25519') {
        throw const FormatException('Unsupported sender signature.');
      }
      final publicBytes = base64Url.decode(auth['public_key']! as String);
      final signatureBytes = base64Url.decode(auth['signature']! as String);
      if (publicBytes.length != 32 ||
          signatureBytes.length != 64 ||
          auth['key_id'] !=
              DeviceSigningIdentity.keyIdForPublicKey(publicBytes)) {
        throw const FormatException('Invalid sender signing key.');
      }
      final registeredKey = record.signingPublicKey;
      if (registeredKey != null &&
          base64UrlEncode(base64Url.decode(registeredKey)) !=
              base64UrlEncode(publicBytes)) {
        throw const FormatException(
          'Sender signing key does not match registration.',
        );
      }
      final valid = await Ed25519().verify(
        utf8.encode(signingData(payload)),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
        ),
      );
      if (!valid) throw const FormatException('Sender signature is invalid.');
      if (record.status == DeviceTrustStatus.revoked) return record;
      return registeredKey != null &&
              record.status == DeviceTrustStatus.approved
          ? record
          : DeviceTrustRecord.unknown(senderId);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Sender signature is missing or malformed.');
    }
  }
}
