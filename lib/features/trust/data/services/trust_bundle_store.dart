import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/trust_bundle.dart';
import '../../domain/services/canonical_json.dart';

class TrustBundleStore {
  static const _legacyBundleKey = 'shadow_network_imported_trust_bundle_v1';
  static const _verifiedStateKey = 'shadow_network_verified_trust_state_v2';
  static const _pinnedIssuerKey = 'shadow_network_pinned_trust_issuer_v2';

  static Future<void> _pendingWrite = Future.value();

  Future<T> _serializeWrite<T>(Future<T> Function() action) {
    final write = _pendingWrite.then((_) => action());
    _pendingWrite = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Map<String, dynamic>? _readVerifiedState(SharedPreferences preferences) {
    final source = preferences.getString(_verifiedStateKey);
    if (source == null || source.trim().isEmpty) return null;
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Stored trust state is invalid.');
    }
    return decoded;
  }

  int _storedVersion(Map<String, dynamic> state) {
    final version =
        state['bundle_version'] ?? (state['bundle'] as Map?)?['bundle_version'];
    if (version is! int) {
      throw const FormatException('Stored trust bundle version is invalid.');
    }
    return version;
  }

  Future<TrustBundle?> loadBundle() async {
    final preferences = await SharedPreferences.getInstance();
    final state = _readVerifiedState(preferences);
    if (state != null) {
      if (state['bundle'] == null && state.containsKey('bundle_version')) {
        return null;
      }
      if (state['bundle'] is! Map) {
        throw const FormatException('Stored trust state is invalid.');
      }
      final bundle = TrustBundle.fromJson(
        Map<String, Object?>.from(state['bundle']! as Map),
      );
      return bundle.withVerifiedImport(
        importedAt: _parseRequiredDate(state['imported_at'] as String?),
        bundleHash: state['bundle_hash'] as String? ?? '',
      );
    }

    final legacySource = preferences.getString(_legacyBundleKey);
    if (legacySource == null || legacySource.trim().isEmpty) {
      return null;
    }
    return TrustBundle.fromJsonString(legacySource);
  }

  Future<TrustBundle> importBundleJson(
    String source, {
    bool allowRollbackForTesting = false,
    DateTime? now,
  }) => _serializeWrite(() async {
    final bundle = TrustBundle.fromJsonString(source);
    final preferences = await SharedPreferences.getInstance();
    final importedAt = (now ?? DateTime.now()).toUtc();
    final bundleHash = await _verifyBundle(
      bundle,
      preferences: preferences,
      now: importedAt,
      allowRollbackForTesting: allowRollbackForTesting,
    );
    final verifiedBundle = bundle.withVerifiedImport(
      importedAt: importedAt,
      bundleHash: bundleHash,
    );

    await _savePreference(
      preferences,
      _pinnedIssuerKey,
      jsonEncode(bundle.issuer!.toJson()),
    );
    await _savePreference(
      preferences,
      _verifiedStateKey,
      jsonEncode({
        'bundle': bundle.toJson(),
        'bundle_hash': bundleHash,
        'imported_at': importedAt.toIso8601String(),
      }),
    );
    await preferences.remove(_legacyBundleKey);
    return verifiedBundle;
  });

  Future<void> clearBundle() => _serializeWrite(() async {
    final preferences = await SharedPreferences.getInstance();
    final state = _readVerifiedState(preferences);
    if (state != null) {
      // Keep the rollback floor when the user removes the active approval.
      await _savePreference(
        preferences,
        _verifiedStateKey,
        jsonEncode({
          'bundle_version': _storedVersion(state),
          'bundle_hash': state['bundle_hash'],
        }),
      );
    }
    if (!await preferences.remove(_legacyBundleKey)) {
      throw StateError('Could not remove the legacy approval.');
    }
  });

  Future<void> _savePreference(
    SharedPreferences preferences,
    String key,
    String value,
  ) async {
    if (!await preferences.setString(key, value)) {
      await preferences.reload();
      throw StateError('Could not save approval state.');
    }
  }

  Future<bool> hasPinnedIssuer() async {
    final preferences = await SharedPreferences.getInstance();
    final source = preferences.getString(_pinnedIssuerKey);
    return source != null && source.trim().isNotEmpty;
  }

  Future<String> _verifyBundle(
    TrustBundle bundle, {
    required SharedPreferences preferences,
    required DateTime now,
    required bool allowRollbackForTesting,
  }) async {
    if (!bundle.isSignedVersion) {
      throw const FormatException(
        'Unsigned legacy bundles are not accepted. Publish a signed Version 2 bundle from the PC admin.',
      );
    }
    _validateDeviceEntries(bundle);
    final issuer = bundle.issuer!;
    if (issuer.issuerId.isEmpty ||
        issuer.signingKeyId.isEmpty ||
        issuer.signatureAlgorithm != 'ed25519' ||
        issuer.publicKey.isEmpty) {
      throw const FormatException('Trust bundle issuer metadata is invalid.');
    }
    if (bundle.issuedAt == null || bundle.expiresAt == null) {
      throw const FormatException('Trust bundle validity dates are missing.');
    }
    if (bundle.issuedAt!.isAfter(now.add(const Duration(minutes: 5)))) {
      throw const FormatException('Trust bundle issue time is in the future.');
    }
    if (!bundle.expiresAt!.isAfter(now)) {
      throw const FormatException('Trust bundle has expired.');
    }

    final publicKeyBytes = _decodeBase64Url(
      issuer.publicKey,
      fieldName: 'issuer public key',
    );
    if (publicKeyBytes.length != 32) {
      throw const FormatException(
        'Issuer Ed25519 public key must be 32 bytes.',
      );
    }
    final expectedKeyId =
        'ed25519-${sha256.convert(publicKeyBytes).toString().substring(0, 16)}';
    if (issuer.signingKeyId != expectedKeyId) {
      throw const FormatException('Issuer signing key ID does not match.');
    }
    _enforcePinnedIssuer(preferences, issuer);

    final signatureBytes = _decodeBase64Url(
      bundle.signature ?? '',
      fieldName: 'bundle signature',
    );
    final publicKey = SimplePublicKey(
      publicKeyBytes,
      type: KeyPairType.ed25519,
    );
    final verified = await Ed25519().verify(
      utf8.encode(canonicalJsonEncode(bundle.toJson(includeSignature: false))),
      signature: Signature(signatureBytes, publicKey: publicKey),
    );
    if (!verified) {
      throw const FormatException('Trust bundle signature is invalid.');
    }

    final bundleHash = sha256
        .convert(utf8.encode(canonicalJsonEncode(bundle.toJson())))
        .toString();
    final current = _readVerifiedState(preferences);
    if (current != null) {
      final currentVersion = _storedVersion(current);
      if (!allowRollbackForTesting && bundle.bundleVersion < currentVersion) {
        throw FormatException(
          'Trust bundle rollback rejected. Current version is $currentVersion.',
        );
      }
      if (bundle.bundleVersion == currentVersion &&
          current['bundle_hash'] != bundleHash) {
        throw const FormatException(
          'A different bundle with the same version was rejected.',
        );
      }
    }
    return bundleHash;
  }

  void _enforcePinnedIssuer(
    SharedPreferences preferences,
    TrustBundleIssuer issuer,
  ) {
    final pinnedSource = preferences.getString(_pinnedIssuerKey);
    if (pinnedSource == null || pinnedSource.trim().isEmpty) {
      return;
    }
    final decoded = jsonDecode(pinnedSource);
    if (decoded is! Map) {
      throw const FormatException('Pinned administrator key is invalid.');
    }
    final pinned = TrustBundleIssuer.fromJson(
      Map<String, Object?>.from(decoded),
    );
    if (pinned.issuerId != issuer.issuerId ||
        pinned.signingKeyId != issuer.signingKeyId ||
        pinned.publicKey != issuer.publicKey) {
      throw const FormatException(
        'Trust bundle was signed by a different administrator key.',
      );
    }
  }

  void _validateDeviceEntries(TrustBundle bundle) {
    final seenIds = <String>{};
    for (final entry in [
      ...bundle.approvedDevices.map((device) => (device, 'approved')),
      ...bundle.revokedDevices.map((device) => (device, 'revoked')),
    ]) {
      final device = entry.$1;
      final expectedStatus = entry.$2;
      final normalizedId = device.deviceId.trim().toLowerCase();
      if (normalizedId.isEmpty || !seenIds.add(normalizedId)) {
        throw const FormatException(
          'Trust bundle contains a missing or duplicate device ID.',
        );
      }
      if (device.status != expectedStatus ||
          device.ownerName.trim().isEmpty ||
          device.role.trim().isEmpty ||
          device.keyVersion <= 0) {
        throw FormatException(
          'Trust record for ${device.deviceId} is invalid.',
        );
      }
      final signingKey = device.signingPublicKey;
      if (signingKey != null &&
          _decodeBase64Url(
                signingKey,
                fieldName: 'signing public key',
              ).length !=
              32) {
        throw const FormatException('Invalid device signing public key.');
      }
      final publicKey = device.publicKey?.trim();
      if (expectedStatus == 'approved' &&
          (publicKey == null ||
              publicKey.isEmpty ||
              _decodeBase64Url(
                    publicKey,
                    fieldName: '${device.deviceId} public key',
                  ).length !=
                  32)) {
        throw FormatException(
          'Approved device ${device.deviceId} has no valid X25519 public key.',
        );
      }
    }
  }

  List<int> _decodeBase64Url(String source, {required String fieldName}) {
    try {
      return base64Url.decode(source);
    } catch (_) {
      throw FormatException('Trust bundle $fieldName is invalid base64url.');
    }
  }

  static DateTime _parseRequiredDate(String? value) {
    final parsed = value == null ? null : DateTime.tryParse(value)?.toUtc();
    if (parsed == null) {
      throw const FormatException('Stored trust import time is invalid.');
    }
    return parsed;
  }
}
