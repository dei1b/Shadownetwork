class EncryptedMessageBody {
  const EncryptedMessageBody({
    required this.algorithm,
    required this.protocolVersion,
    required this.recipientKeyId,
    required this.recipientKeyVersion,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.cipherText,
    required this.authenticationTag,
  });

  final String algorithm;
  final int protocolVersion;
  final String recipientKeyId;
  final int recipientKeyVersion;
  final String ephemeralPublicKey;
  final String nonce;
  final String cipherText;
  final String authenticationTag;

  Map<String, Object?> toJson() => {
    'encrypted': true,
    'protocol_version': protocolVersion,
    'algorithm': algorithm,
    'key_id': recipientKeyId,
    'key_version': recipientKeyVersion,
    'ephemeral_public_key': ephemeralPublicKey,
    'nonce': nonce,
    'cipher_text': cipherText,
    'tag': authenticationTag,
  };

  factory EncryptedMessageBody.fromJson(Map<String, Object?> json) {
    if (json['encrypted'] != true) {
      throw const FormatException('Message body is not encrypted.');
    }
    return EncryptedMessageBody(
      algorithm: json['algorithm']! as String,
      protocolVersion: (json['protocol_version']! as num).toInt(),
      recipientKeyId: json['key_id']! as String,
      recipientKeyVersion: (json['key_version']! as num).toInt(),
      ephemeralPublicKey: json['ephemeral_public_key']! as String,
      nonce: json['nonce']! as String,
      cipherText: json['cipher_text']! as String,
      authenticationTag: json['tag']! as String,
    );
  }
}
