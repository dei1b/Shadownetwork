import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/domain/services/canonical_json.dart';

class TestTrustBundleSigner {
  TestTrustBundleSigner._({
    required this.keyPair,
    required this.publicKeyBytes,
    required this.issuerId,
  });

  final KeyPair keyPair;
  final List<int> publicKeyBytes;
  final String issuerId;

  static Future<TestTrustBundleSigner> create({
    String issuerId = 'test-shadow-network-admin',
  }) async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return TestTrustBundleSigner._(
      keyPair: keyPair,
      publicKeyBytes: publicKey.bytes,
      issuerId: issuerId,
    );
  }

  Future<String> sign({
    required int bundleVersion,
    required DateTime issuedAt,
    List<TrustedDevice> approvedDevices = const [],
    List<TrustedDevice> revokedDevices = const [],
    Duration validity = const Duration(days: 30),
  }) async {
    final unsignedBundle = TrustBundle(
      schemaVersion: 2,
      bundleVersion: bundleVersion,
      generatedAt: issuedAt,
      issuedAt: issuedAt,
      expiresAt: issuedAt.add(validity),
      issuer: TrustBundleIssuer(
        issuerId: issuerId,
        signingKeyId:
            'ed25519-${sha256.convert(publicKeyBytes).toString().substring(0, 16)}',
        signatureAlgorithm: 'ed25519',
        publicKey: base64UrlEncode(publicKeyBytes),
      ),
      approvedDevices: approvedDevices,
      revokedDevices: revokedDevices,
    );
    final signature = await Ed25519().sign(
      utf8.encode(
        canonicalJsonEncode(unsignedBundle.toJson(includeSignature: false)),
      ),
      keyPair: keyPair,
    );
    return TrustBundle(
      schemaVersion: unsignedBundle.schemaVersion,
      bundleVersion: unsignedBundle.bundleVersion,
      generatedAt: unsignedBundle.generatedAt,
      issuedAt: unsignedBundle.issuedAt,
      expiresAt: unsignedBundle.expiresAt,
      issuer: unsignedBundle.issuer,
      approvedDevices: unsignedBundle.approvedDevices,
      revokedDevices: unsignedBundle.revokedDevices,
      signature: base64UrlEncode(signature.bytes),
    ).toPrettyJson();
  }
}

TrustedDevice testTrustedDevice({
  String deviceId = 'SN-RESPONDER-010',
  String ownerName = 'Responder Phone',
  String role = 'responder',
  String status = 'approved',
  DateTime? updatedAt,
  String? publicKey,
}) {
  return TrustedDevice(
    deviceId: deviceId,
    ownerName: ownerName,
    role: role,
    status: status,
    publicKey:
        publicKey ?? base64UrlEncode(List<int>.generate(32, (index) => index)),
    keyVersion: 1,
    updatedAt: updatedAt ?? DateTime.utc(2026, 8, 15),
  );
}
