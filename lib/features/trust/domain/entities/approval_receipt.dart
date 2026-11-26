import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import '../../../security/domain/entities/device_crypto_identity.dart';
import '../../../security/domain/entities/device_signing_identity.dart';
import '../services/canonical_json.dart';
import 'trust_bundle.dart';

class SignedApprovalReceipt {
  const SignedApprovalReceipt({
    required this.registrationId,
    required this.deviceId,
    required this.publicKey,
    required this.signingPublicKey,
    required this.keyVersion,
    required this.issuer,
    required this.issuedAt,
    required this.expiresAt,
    this.ownerName,
    this.role,
    this.status,
    this.baseBundleVersion,
    this.directoryProject,
    this.signature,
    this.isSignatureVerified = false,
  });

  static const receiptType = 'shadow_network_approval_receipt';
  static const schemaVersion = 1;

  final String registrationId;
  final String deviceId;
  final String publicKey;
  final String signingPublicKey;
  final int keyVersion;
  final String? ownerName;
  final String? role;
  final String? status;
  final int? baseBundleVersion;
  final String? directoryProject;
  final TrustBundleIssuer issuer;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String? signature;
  final bool isSignatureVerified;

  bool isExpiredAt(DateTime timestamp) =>
      !expiresAt.isAfter(timestamp.toUtc());

  SignedApprovalReceipt withVerifiedImport() => SignedApprovalReceipt(
    registrationId: registrationId,
    deviceId: deviceId,
    publicKey: publicKey,
    signingPublicKey: signingPublicKey,
    keyVersion: keyVersion,
    ownerName: ownerName,
    role: role,
    status: status,
    baseBundleVersion: baseBundleVersion,
    directoryProject: directoryProject,
    issuer: issuer,
    issuedAt: issuedAt,
    expiresAt: expiresAt,
    signature: signature,
    isSignatureVerified: true,
  );

  static Future<SignedApprovalReceipt> createSigned({
    required String registrationId,
    required String deviceId,
    required String publicKey,
    required String signingPublicKey,
    required int keyVersion,
    required TrustBundleIssuer issuer,
    required SimpleKeyPair issuerKeyPair,
    required DateTime issuedAt,
    required DateTime expiresAt,
    String? ownerName,
    String? role,
    String? status,
    int? baseBundleVersion,
    String? directoryProject,
  }) async {
    final trimmedOwner = ownerName?.trim();
    final trimmedRole = role?.trim();
    final trimmedStatus = status?.trim();
    final draft = SignedApprovalReceipt(
      registrationId: registrationId.trim(),
      deviceId: deviceId.trim(),
      publicKey: publicKey.trim(),
      signingPublicKey: signingPublicKey.trim(),
      keyVersion: keyVersion,
      ownerName: trimmedOwner == null || trimmedOwner.isEmpty
          ? null
          : trimmedOwner,
      role: trimmedRole == null || trimmedRole.isEmpty ? null : trimmedRole,
      status: trimmedStatus == null || trimmedStatus.isEmpty
          ? null
          : trimmedStatus,
      baseBundleVersion: baseBundleVersion,
      directoryProject: directoryProject?.trim().isEmpty == true
          ? null
          : directoryProject?.trim(),
      issuer: issuer,
      issuedAt: issuedAt.toUtc(),
      expiresAt: expiresAt.toUtc(),
    );
    final sig = await Ed25519().sign(
      utf8.encode(draft._signingData()),
      keyPair: issuerKeyPair,
    );
    return SignedApprovalReceipt(
      registrationId: draft.registrationId,
      deviceId: draft.deviceId,
      publicKey: draft.publicKey,
      signingPublicKey: draft.signingPublicKey,
      keyVersion: draft.keyVersion,
      ownerName: draft.ownerName,
      role: draft.role,
      status: draft.status,
      baseBundleVersion: draft.baseBundleVersion,
      directoryProject: draft.directoryProject,
      issuer: draft.issuer,
      issuedAt: draft.issuedAt,
      expiresAt: draft.expiresAt,
      signature: base64UrlEncode(sig.bytes),
    );
  }

  String _signingData() =>
      'shadow-network-approval-receipt-v1\n${canonicalJsonEncode(toJson(includeSignature: false))}';

  bool matchesPhone({
    required String deviceId,
    required String publicKey,
    required String signingPublicKey,
    required int keyVersion,
  }) {
    return this.deviceId.toLowerCase() == deviceId.trim().toLowerCase() &&
        _stripPadding(this.publicKey) == _stripPadding(publicKey) &&
        _stripPadding(this.signingPublicKey) ==
            _stripPadding(signingPublicKey) &&
        this.keyVersion == keyVersion;
  }

  Future<void> verify({
    DateTime? now,
    String? expectedProject,
    String? expectedIssuerFingerprint,
    TrustBundleIssuer? pinnedIssuer,
  }) async {
    if (registrationId.isEmpty ||
        deviceId.isEmpty ||
        publicKey.isEmpty ||
        signingPublicKey.isEmpty ||
        keyVersion <= 0) {
      throw const FormatException('Approval receipt is missing required data.');
    }
    final checkTime = (now ?? DateTime.now()).toUtc();
    if (issuedAt.isAfter(checkTime.add(const Duration(minutes: 5)))) {
      throw const FormatException('Approval receipt issue time is invalid.');
    }
    if (!expiresAt.isAfter(checkTime)) {
      throw const FormatException('Approval receipt has expired.');
    }
    if (expectedProject != null &&
        expectedProject.isNotEmpty &&
        directoryProject != expectedProject) {
      throw const FormatException(
        'Approval receipt belongs to another campus project.',
      );
    }
    final List<int> issuerBytes;
    final List<int> sigBytes;
    try {
      issuerBytes = base64Url.decode(issuer.publicKey);
      sigBytes = base64Url.decode(signature ?? '');
    } catch (_) {
      throw const FormatException('Approval receipt encoding is invalid.');
    }
    if (issuerBytes.length != 32 || sigBytes.length != 64) {
      throw const FormatException('Approval receipt signature is invalid.');
    }
    final fingerprint = sha256.convert(issuerBytes).toString();
    final expectedKeyId = 'ed25519-${fingerprint.substring(0, 16)}';
    if (issuer.signingKeyId != expectedKeyId ||
        issuer.signatureAlgorithm != 'ed25519') {
      throw const FormatException('Approval receipt issuer metadata is invalid.');
    }
    if (expectedIssuerFingerprint != null &&
        expectedIssuerFingerprint.isNotEmpty &&
        fingerprint != expectedIssuerFingerprint.toLowerCase()) {
      throw const FormatException(
        'Approval receipt signer does not match the campus key.',
      );
    }
    if (pinnedIssuer != null && pinnedIssuer.publicKey != issuer.publicKey) {
      throw const FormatException(
        'Approval receipt was signed by a different administrator key.',
      );
    }
    final ok = await Ed25519().verify(
      utf8.encode(_signingData()),
      signature: Signature(
        sigBytes,
        publicKey: SimplePublicKey(issuerBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!ok) {
      throw const FormatException('Approval receipt signature is invalid.');
    }
  }

  Map<String, Object?> toJson({bool includeSignature = true}) => {
    'receipt_type': receiptType,
    'schema_version': schemaVersion,
    'registration_id': registrationId,
    'device_id': deviceId,
    'public_key': publicKey,
    'signing_public_key': signingPublicKey,
    'key_version': keyVersion,
    if (ownerName != null) 'owner_name': ownerName,
    if (role != null) 'role': role,
    if (status != null) 'status': status,
    if (baseBundleVersion != null) 'base_bundle_version': baseBundleVersion,
    if (directoryProject != null) 'directory_project': directoryProject,
    'issuer': issuer.toJson(),
    'issued_at': issuedAt.toUtc().toIso8601String(),
    'expires_at': expiresAt.toUtc().toIso8601String(),
    if (includeSignature && signature != null) 'signature': signature,
  };

  String toJsonString() => jsonEncode(toJson());

  factory SignedApprovalReceipt.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Approval receipt must be a JSON object.');
    }
    return SignedApprovalReceipt.fromJson(Map<String, Object?>.from(decoded));
  }

  factory SignedApprovalReceipt.fromJson(Map<String, Object?> json) {
    if (json['receipt_type'] != receiptType ||
        json['schema_version'] != schemaVersion) {
      throw const FormatException('Unsupported approval receipt format.');
    }
    final issuedAt = DateTime.tryParse(json['issued_at'] as String? ?? '')
        ?.toUtc();
    final expiresAt = DateTime.tryParse(json['expires_at'] as String? ?? '')
        ?.toUtc();
    if (issuedAt == null || expiresAt == null || json['issuer'] is! Map) {
      throw const FormatException('Approval receipt metadata is missing.');
    }
    return SignedApprovalReceipt(
      registrationId: (json['registration_id'] as String? ?? '').trim(),
      deviceId: (json['device_id'] as String? ?? '').trim(),
      publicKey: (json['public_key'] as String? ?? '').trim(),
      signingPublicKey: (json['signing_public_key'] as String? ?? '').trim(),
      keyVersion: (json['key_version'] as num?)?.toInt() ?? 0,
      ownerName: (json['owner_name'] as String?)?.trim(),
      role: (json['role'] as String?)?.trim(),
      status: (json['status'] as String?)?.trim(),
      baseBundleVersion: (json['base_bundle_version'] as num?)?.toInt(),
      directoryProject: (json['directory_project'] as String?)?.trim(),
      issuer: TrustBundleIssuer.fromJson(
        Map<String, Object?>.from(json['issuer']! as Map),
      ),
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      signature: json['signature'] as String?,
    );
  }

  static String _stripPadding(String value) => value.trim().replaceAll('=', '');
}

class ApprovalQrPackage {
  const ApprovalQrPackage({required this.bundleJson, this.receipt});

  static const packageType = 'shadow_network_approval_package';
  static const schemaVersion = 1;

  final String bundleJson;
  final SignedApprovalReceipt? receipt;

  String toJsonString() {
    if (receipt == null) return bundleJson;
    final hasBundle = bundleJson.trim().isNotEmpty;
    return jsonEncode({
      'package_type': packageType,
      'schema_version': schemaVersion,
      if (hasBundle) 'bundle': jsonDecode(bundleJson),
      'receipt': receipt!.toJson(),
    });
  }

  static ApprovalQrPackage parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Approval payload must be a JSON object.');
    }
    if (decoded['package_type'] == packageType) {
      final rawBundle = decoded['bundle'];
      final receiptMap = decoded['receipt'];
      if (decoded['schema_version'] != schemaVersion ||
          (rawBundle != null && rawBundle is! Map) ||
          (rawBundle == null && receiptMap is! Map)) {
        throw const FormatException('Unsupported approval package.');
      }
      return ApprovalQrPackage(
        bundleJson: rawBundle is Map ? jsonEncode(rawBundle) : '',
        receipt: receiptMap is Map
            ? SignedApprovalReceipt.fromJson(
                Map<String, Object?>.from(receiptMap),
              )
            : null,
      );
    }
    if (decoded['receipt_type'] == SignedApprovalReceipt.receiptType) {
      return ApprovalQrPackage(
        bundleJson: '',
        receipt: SignedApprovalReceipt.fromJson(
          Map<String, Object?>.from(decoded),
        ),
      );
    }
    return ApprovalQrPackage(bundleJson: source);
  }
}

class AccountLinkProof {
  const AccountLinkProof({
    required this.registrationId,
    required this.accountUid,
    required this.nonce,
    required this.deviceId,
    required this.publicKey,
    required this.signingPublicKey,
    required this.keyVersion,
    required this.issuedAt,
    this.directoryProject,
    this.signature,
  });

  final String registrationId;
  final String accountUid;
  final String? directoryProject;
  final String nonce;
  final String deviceId;
  final String publicKey;
  final String signingPublicKey;
  final int keyVersion;
  final DateTime issuedAt;
  final String? signature;

  static Future<AccountLinkProof> createSigned({
    required String registrationId,
    required String accountUid,
    required String nonce,
    required String deviceId,
    required DeviceCryptoIdentity identity,
    required DeviceSigningIdentity signingIdentity,
    String? directoryProject,
    DateTime? issuedAt,
  }) async {
    final draft = AccountLinkProof(
      registrationId: registrationId.trim(),
      accountUid: accountUid.trim(),
      directoryProject: directoryProject?.trim().isEmpty == true
          ? null
          : directoryProject?.trim(),
      nonce: nonce.trim(),
      deviceId: deviceId.trim(),
      publicKey: identity.encodedPublicKey,
      signingPublicKey: signingIdentity.encodedPublicKey,
      keyVersion: identity.keyVersion,
      issuedAt: (issuedAt ?? DateTime.now()).toUtc(),
    );
    final sig = await Ed25519().sign(
      utf8.encode(draft._signingData()),
      keyPair: signingIdentity.keyPair,
    );
    return AccountLinkProof(
      registrationId: draft.registrationId,
      accountUid: draft.accountUid,
      directoryProject: draft.directoryProject,
      nonce: draft.nonce,
      deviceId: draft.deviceId,
      publicKey: draft.publicKey,
      signingPublicKey: draft.signingPublicKey,
      keyVersion: draft.keyVersion,
      issuedAt: draft.issuedAt,
      signature: base64UrlEncode(sig.bytes),
    );
  }

  String _signingData() =>
      'shadow-network-account-link-v1\n${canonicalJsonEncode(toJson(includeSignature: false))}';

  Future<void> verify({
    required String expectedRegistrationId,
    required String expectedAccountUid,
    required String expectedDeviceId,
    required String expectedPublicKey,
    required String expectedSigningPublicKey,
    required int expectedKeyVersion,
    String? expectedProject,
  }) async {
    if (registrationId != expectedRegistrationId ||
        accountUid != expectedAccountUid ||
        nonce.isEmpty ||
        deviceId.toLowerCase() != expectedDeviceId.toLowerCase() ||
        _strip(publicKey) != _strip(expectedPublicKey) ||
        _strip(signingPublicKey) != _strip(expectedSigningPublicKey) ||
        keyVersion != expectedKeyVersion) {
      throw const FormatException(
        'Phone proof does not match this account or approved phone.',
      );
    }
    if (expectedProject != null &&
        expectedProject.isNotEmpty &&
        directoryProject != expectedProject) {
      throw const FormatException(
        'Phone proof belongs to another campus project.',
      );
    }
    final List<int> keyBytes;
    final List<int> sigBytes;
    try {
      keyBytes = base64Url.decode(signingPublicKey);
      sigBytes = base64Url.decode(signature ?? '');
    } catch (_) {
      throw const FormatException('Phone link proof encoding is invalid.');
    }
    if (keyBytes.length != 32 || sigBytes.length != 64) {
      throw const FormatException('Phone link proof signature is invalid.');
    }
    final ok = await Ed25519().verify(
      utf8.encode(_signingData()),
      signature: Signature(
        sigBytes,
        publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!ok) {
      throw const FormatException('Phone link proof signature is invalid.');
    }
  }

  Map<String, Object?> toJson({bool includeSignature = true}) => {
    'registration_id': registrationId,
    'account_uid': accountUid,
    if (directoryProject != null) 'directory_project': directoryProject,
    'nonce': nonce,
    'device_id': deviceId,
    'public_key': publicKey,
    'signing_public_key': signingPublicKey,
    'key_version': keyVersion,
    'issued_at': issuedAt.toUtc().toIso8601String(),
    if (includeSignature && signature != null) 'proof_signature': signature,
  };

  factory AccountLinkProof.fromMap(Map<String, dynamic> map) {
    final issued = DateTime.tryParse(map['issuedAt'] as String? ?? '') ??
        DateTime.tryParse(map['issued_at'] as String? ?? '');
    if (issued == null) {
      throw const FormatException('Phone link proof timestamp is missing.');
    }
    return AccountLinkProof(
      registrationId:
          ((map['registrationId'] ?? map['registration_id']) as String? ?? '')
              .trim(),
      accountUid:
          ((map['accountUid'] ?? map['account_uid']) as String? ?? '').trim(),
      directoryProject:
          ((map['directoryProject'] ?? map['directory_project']) as String?)
              ?.trim(),
      nonce: (map['nonce'] as String? ?? '').trim(),
      deviceId:
          ((map['deviceId'] ?? map['device_id']) as String? ?? '').trim(),
      publicKey:
          ((map['publicKey'] ?? map['public_key']) as String? ?? '').trim(),
      signingPublicKey:
          ((map['signingPublicKey'] ?? map['signing_public_key']) as String? ??
                  '')
              .trim(),
      keyVersion: ((map['keyVersion'] ?? map['key_version']) as num?)?.toInt() ??
          0,
      issuedAt: issued.toUtc(),
      signature:
          (map['proofSignature'] ?? map['proof_signature']) as String?,
    );
  }

  static String _strip(String value) => value.trim().replaceAll('=', '');
}
