import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import '../services/canonical_json.dart';
import 'trust_bundle.dart';

class PublisherDelegation {
  const PublisherDelegation({
    required this.rootIssuer,
    required this.publisher,
    required this.issuedAt,
    required this.expiresAt,
    this.scope = defaultScope,
    this.directoryProject,
    this.signature,
  });

  static const delegationType = 'shadow_network_publisher_delegation';
  static const schemaVersion = 1;
  static const defaultScope = 'trust_directory_publisher';

  final TrustBundleIssuer rootIssuer;
  final TrustBundleIssuer publisher;
  final String scope;
  final String? directoryProject;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String? signature;

  bool isExpiredAt(DateTime timestamp) =>
      !expiresAt.isAfter(timestamp.toUtc());

  static Future<PublisherDelegation> createSigned({
    required TrustBundleIssuer rootIssuer,
    required SimpleKeyPair rootKeyPair,
    required TrustBundleIssuer publisher,
    required DateTime issuedAt,
    required DateTime expiresAt,
    String? directoryProject,
  }) async {
    final trimmedProject = directoryProject?.trim();
    final draft = PublisherDelegation(
      rootIssuer: rootIssuer,
      publisher: publisher,
      scope: defaultScope,
      directoryProject:
          trimmedProject == null || trimmedProject.isEmpty ? null : trimmedProject,
      issuedAt: issuedAt.toUtc(),
      expiresAt: expiresAt.toUtc(),
    );
    final sig = await Ed25519().sign(
      utf8.encode(draft._signingData()),
      keyPair: rootKeyPair,
    );
    return PublisherDelegation(
      rootIssuer: draft.rootIssuer,
      publisher: draft.publisher,
      scope: draft.scope,
      directoryProject: draft.directoryProject,
      issuedAt: draft.issuedAt,
      expiresAt: draft.expiresAt,
      signature: base64UrlEncode(sig.bytes),
    );
  }

  String _signingData() =>
      'shadow-network-publisher-delegation-v1\n${canonicalJsonEncode(toJson(includeSignature: false))}';

  Future<void> verify({DateTime? now, String? expectedProject}) async {
    if (scope != defaultScope ||
        rootIssuer.issuerId.isEmpty ||
        publisher.issuerId.isEmpty ||
        rootIssuer.signatureAlgorithm != 'ed25519' ||
        publisher.signatureAlgorithm != 'ed25519') {
      throw const FormatException('Publisher delegation metadata is invalid.');
    }
    final checkTime = (now ?? DateTime.now()).toUtc();
    if (issuedAt.isAfter(checkTime.add(const Duration(minutes: 5)))) {
      throw const FormatException('Publisher delegation issue time is in the future.');
    }
    if (!expiresAt.isAfter(checkTime)) {
      throw const FormatException('Publisher delegation has expired.');
    }
    if (expectedProject != null &&
        expectedProject.isNotEmpty &&
        directoryProject != expectedProject) {
      throw const FormatException(
        'Publisher delegation belongs to another campus project.',
      );
    }

    final rootBytes = _validateKeyAndId(
      rootIssuer,
      label: 'campus root',
    );
    _validateKeyAndId(publisher, label: 'delegated publisher');

    final sigBytes = _decodeBase64Url(
      signature ?? '',
      label: 'delegation signature',
    );
    if (sigBytes.length != 64) {
      throw const FormatException('Publisher delegation signature is invalid.');
    }
    final ok = await Ed25519().verify(
      utf8.encode(_signingData()),
      signature: Signature(
        sigBytes,
        publicKey: SimplePublicKey(rootBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!ok) {
      throw const FormatException('Publisher delegation signature is invalid.');
    }
  }

  static List<int> _validateKeyAndId(
    TrustBundleIssuer issuer, {
    required String label,
  }) {
    final bytes = _decodeBase64Url(issuer.publicKey, label: '$label public key');
    if (bytes.length != 32) {
      throw FormatException('$label Ed25519 public key must be 32 bytes.');
    }
    final expectedId =
        'ed25519-${sha256.convert(bytes).toString().substring(0, 16)}';
    if (issuer.signingKeyId != expectedId) {
      throw FormatException('$label signing key ID does not match.');
    }
    return bytes;
  }

  static List<int> _decodeBase64Url(String source, {required String label}) {
    try {
      return base64Url.decode(source.trim());
    } catch (_) {
      throw FormatException('Publisher delegation $label is invalid base64url.');
    }
  }

  Map<String, Object?> toJson({bool includeSignature = true}) => {
    'delegation_type': delegationType,
    'schema_version': schemaVersion,
    'scope': scope,
    'root_issuer': rootIssuer.toJson(),
    'publisher': publisher.toJson(),
    if (directoryProject != null) 'directory_project': directoryProject,
    'issued_at': issuedAt.toUtc().toIso8601String(),
    'expires_at': expiresAt.toUtc().toIso8601String(),
    if (includeSignature && signature != null) 'signature': signature,
  };

  String toJsonString() => jsonEncode(toJson());

  factory PublisherDelegation.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Publisher delegation must be a JSON object.');
    }
    return PublisherDelegation.fromJson(Map<String, Object?>.from(decoded));
  }

  factory PublisherDelegation.fromJson(Map<String, Object?> json) {
    if (json['delegation_type'] != delegationType ||
        (json['schema_version'] as num?)?.toInt() != schemaVersion) {
      throw const FormatException('Unsupported publisher delegation format.');
    }
    final issuedAt = DateTime.tryParse(
      json['issued_at'] as String? ?? '',
    )?.toUtc();
    final expiresAt = DateTime.tryParse(
      json['expires_at'] as String? ?? '',
    )?.toUtc();
    if (issuedAt == null ||
        expiresAt == null ||
        json['root_issuer'] is! Map ||
        json['publisher'] is! Map) {
      throw const FormatException('Publisher delegation is missing required fields.');
    }
    return PublisherDelegation(
      rootIssuer: TrustBundleIssuer.fromJson(
        Map<String, Object?>.from(json['root_issuer']! as Map),
      ),
      publisher: TrustBundleIssuer.fromJson(
        Map<String, Object?>.from(json['publisher']! as Map),
      ),
      scope: (json['scope'] as String? ?? '').trim(),
      directoryProject: (json['directory_project'] as String?)?.trim(),
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      signature: json['signature'] as String?,
    );
  }
}
