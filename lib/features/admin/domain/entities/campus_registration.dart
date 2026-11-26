import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../../registration/domain/campus_identity_fields.dart';
import 'registered_device.dart';

enum CampusRegistrationSource {
  online,
  qr;

  String get label => switch (this) {
    CampusRegistrationSource.online => 'Online',
    CampusRegistrationSource.qr => 'Phone QR',
  };

  static CampusRegistrationSource fromCode(String? code) {
    return switch (code) {
      'qr' => CampusRegistrationSource.qr,
      _ => CampusRegistrationSource.online,
    };
  }
}

enum CampusRegistrationStatus {
  submitted,
  approvedLocal,
  approvedPendingPublication,
  published,
  changesRequested,
  rejected,
  revoked,
  conflict;

  String get code => switch (this) {
    CampusRegistrationStatus.submitted => 'submitted',
    CampusRegistrationStatus.approvedLocal => 'approved_local',
    CampusRegistrationStatus.approvedPendingPublication =>
      'approved_pending_publication',
    CampusRegistrationStatus.published => 'published',
    CampusRegistrationStatus.changesRequested => 'changes_requested',
    CampusRegistrationStatus.rejected => 'rejected',
    CampusRegistrationStatus.revoked => 'revoked',
    CampusRegistrationStatus.conflict => 'conflict',
  };

  String get label => switch (this) {
    CampusRegistrationStatus.submitted => 'Needs review',
    CampusRegistrationStatus.approvedLocal => 'Approved on this PC',
    CampusRegistrationStatus.approvedPendingPublication =>
      'Approved · awaiting publication',
    CampusRegistrationStatus.published => 'Published',
    CampusRegistrationStatus.changesRequested => 'Changes requested',
    CampusRegistrationStatus.rejected => 'Rejected',
    CampusRegistrationStatus.revoked => 'Revoked',
    CampusRegistrationStatus.conflict => 'Needs resolution',
  };

  static CampusRegistrationStatus fromCode(String? code) {
    return switch (code) {
      'approved_local' => CampusRegistrationStatus.approvedLocal,
      'approved_pending_publication' =>
        CampusRegistrationStatus.approvedPendingPublication,
      'published' => CampusRegistrationStatus.published,
      'changes_requested' => CampusRegistrationStatus.changesRequested,
      'rejected' => CampusRegistrationStatus.rejected,
      'revoked' => CampusRegistrationStatus.revoked,
      'conflict' => CampusRegistrationStatus.conflict,
      _ => CampusRegistrationStatus.submitted,
    };
  }
}

enum CampusSyncState {
  synced,
  waitingToSync,
  conflict;

  String get code => switch (this) {
    CampusSyncState.synced => 'synced',
    CampusSyncState.waitingToSync => 'waiting_to_sync',
    CampusSyncState.conflict => 'conflict',
  };

  static CampusSyncState fromCode(String? code) {
    return switch (code) {
      'waiting_to_sync' => CampusSyncState.waitingToSync,
      'conflict' => CampusSyncState.conflict,
      _ => CampusSyncState.synced,
    };
  }
}

enum PendingSyncKind {
  publishManual,
  publishOnlineApproval,
  publishProfileChange,
  publishReplacement,
  publishRecovery,
  publishRevocationCorrection,
  linkAccount;

  static PendingSyncKind fromCode(String? code) {
    return PendingSyncKind.values.firstWhere(
      (kind) => kind.name == code,
      orElse: () => PendingSyncKind.publishManual,
    );
  }
}

class RegistrationPhoneBinding {
  const RegistrationPhoneBinding({
    required this.deviceId,
    this.publicKey,
    this.signingPublicKey,
    this.keyId,
    this.keyVersion = 1,
    this.deviceRegistrationJson,
  });

  final String deviceId;
  final String? publicKey;
  final String? signingPublicKey;
  final String? keyId;
  final int keyVersion;
  final String? deviceRegistrationJson;

  bool hasSameKeys(RegistrationPhoneBinding other) =>
      deviceId.toLowerCase() == other.deviceId.toLowerCase() &&
      _strip(publicKey) == _strip(other.publicKey) &&
      _strip(signingPublicKey) == _strip(other.signingPublicKey) &&
      keyVersion == other.keyVersion;

  static String? _strip(String? v) => v?.trim().replaceAll('=', '');

  Map<String, Object?> toJson() => {
    'device_id': deviceId,
    if (publicKey != null) 'public_key': publicKey,
    if (signingPublicKey != null) 'signing_public_key': signingPublicKey,
    if (keyId != null) 'key_id': keyId,
    'key_version': keyVersion,
    if (deviceRegistrationJson != null)
      'device_registration_json': deviceRegistrationJson,
  };

  factory RegistrationPhoneBinding.fromJson(Map<String, Object?> json) {
    return RegistrationPhoneBinding(
      deviceId: (json['device_id'] as String? ?? '').trim(),
      publicKey: json['public_key'] as String?,
      signingPublicKey: json['signing_public_key'] as String?,
      keyId: json['key_id'] as String?,
      keyVersion: (json['key_version'] as num?)?.toInt() ?? 1,
      deviceRegistrationJson: json['device_registration_json'] as String?,
    );
  }
}

class RetiredKeyRecord {
  const RetiredKeyRecord({
    required this.deviceId,
    required this.keyVersion,
    required this.retiredAt,
    required this.reason,
    this.publicKeyFingerprint,
    this.signingKeyFingerprint,
    this.reviewerUid,
  });

  final String deviceId;
  final String? publicKeyFingerprint;
  final String? signingKeyFingerprint;
  final int keyVersion;
  final DateTime retiredAt;
  final String reason;
  final String? reviewerUid;

  static String? fingerprintForKey(String? base64Key) {
    if (base64Key == null || base64Key.trim().isEmpty) return null;
    try {
      return sha256.convert(base64Url.decode(base64Key.trim())).toString();
    } catch (_) {
      return sha256.convert(utf8.encode(base64Key.trim())).toString();
    }
  }

  Map<String, Object?> toJson() => {
    'device_id': deviceId,
    if (publicKeyFingerprint != null)
      'public_key_fingerprint': publicKeyFingerprint,
    if (signingKeyFingerprint != null)
      'signing_key_fingerprint': signingKeyFingerprint,
    'key_version': keyVersion,
    'retired_at': retiredAt.toUtc().toIso8601String(),
    'reason': reason,
    if (reviewerUid != null) 'reviewer_uid': reviewerUid,
  };

  factory RetiredKeyRecord.fromJson(Map<String, Object?> json) {
    return RetiredKeyRecord(
      deviceId: (json['device_id'] as String? ?? '').trim(),
      publicKeyFingerprint: json['public_key_fingerprint'] as String?,
      signingKeyFingerprint: json['signing_key_fingerprint'] as String?,
      keyVersion: (json['key_version'] as num?)?.toInt() ?? 1,
      retiredAt:
          DateTime.tryParse(json['retired_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      reason: json['reason'] as String? ?? '',
      reviewerUid: json['reviewer_uid'] as String?,
    );
  }
}

class RegistrationDecisionEntry {
  const RegistrationDecisionEntry({
    required this.decisionId,
    required this.reviewerUid,
    required this.status,
    required this.revision,
    required this.createdAt,
    this.reviewerEmail,
    this.role,
    this.reason = '',
    this.editedFields = const [],
  });

  final String decisionId;
  final String reviewerUid;
  final String? reviewerEmail;
  final String status;
  final String? role;
  final String reason;
  final int revision;
  final List<String> editedFields;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'decision_id': decisionId,
    'reviewer_uid': reviewerUid,
    if (reviewerEmail != null) 'reviewer_email': reviewerEmail,
    'status': status,
    if (role != null) 'role': role,
    'reason': reason,
    'revision': revision,
    if (editedFields.isNotEmpty) 'edited_fields': editedFields,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  factory RegistrationDecisionEntry.fromJson(Map<String, Object?> json) {
    return RegistrationDecisionEntry(
      decisionId: json['decision_id'] as String? ?? '',
      reviewerUid: json['reviewer_uid'] as String? ?? '',
      reviewerEmail: json['reviewer_email'] as String?,
      status: json['status'] as String? ?? 'submitted',
      role: json['role'] as String?,
      reason: json['reason'] as String? ?? '',
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      editedFields: (json['edited_fields'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

class PendingSyncOperation {
  const PendingSyncOperation({
    required this.decisionId,
    required this.registrationId,
    required this.kind,
    required this.payloadJson,
    required this.createdAt,
  });

  final String decisionId;
  final String registrationId;
  final PendingSyncKind kind;
  final String payloadJson;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'decision_id': decisionId,
    'registration_id': registrationId,
    'kind': kind.name,
    'payload_json': payloadJson,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  factory PendingSyncOperation.fromJson(Map<String, Object?> json) {
    return PendingSyncOperation(
      decisionId: json['decision_id'] as String? ?? '',
      registrationId: json['registration_id'] as String? ?? '',
      kind: PendingSyncKind.fromCode(json['kind'] as String?),
      payloadJson: json['payload_json'] as String? ?? '{}',
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

class ReviewerProfile {
  const ReviewerProfile({required this.uid, required this.email});

  final String uid;
  final String email;

  Map<String, Object?> toJson() => {'uid': uid, 'email': email};

  factory ReviewerProfile.fromJson(Map<String, Object?> json) => ReviewerProfile(
    uid: (json['uid'] as String? ?? '').trim(),
    email: (json['email'] as String? ?? '').trim(),
  );
}

class CampusRegistration {
  const CampusRegistration({
    required this.registrationId,
    required this.source,
    required this.status,
    required this.syncState,
    required this.identity,
    required this.role,
    required this.activePhone,
    required this.createdAt,
    required this.updatedAt,
    this.accountUid,
    this.accountEmail,
    this.submittedSnapshot,
    this.retiredKeys = const [],
    this.reviewHistory = const [],
    this.revision = 0,
    this.conflictReason,
    this.remoteUpdateTime,
    this.pendingDecisionId,
  });

  final String registrationId;
  final CampusRegistrationSource source;
  final CampusRegistrationStatus status;
  final CampusSyncState syncState;
  final String? conflictReason;
  final String? accountUid;
  final String? accountEmail;
  final CampusIdentityFields identity;
  final CampusIdentityFields? submittedSnapshot;
  final RegisteredDeviceRole role;
  final RegistrationPhoneBinding activePhone;
  final List<RetiredKeyRecord> retiredKeys;
  final List<RegistrationDecisionEntry> reviewHistory;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? remoteUpdateTime;
  final String? pendingDecisionId;

  bool get isLinked => accountUid != null && accountUid!.isNotEmpty;

  RegisteredDevice toRegisteredDevice() {
    final mappedStatus = switch (status) {
      CampusRegistrationStatus.approvedLocal ||
      CampusRegistrationStatus.approvedPendingPublication ||
      CampusRegistrationStatus.published => RegisteredDeviceStatus.approved,
      CampusRegistrationStatus.revoked => RegisteredDeviceStatus.revoked,
      _ => RegisteredDeviceStatus.pending,
    };
    final label = switch (status) {
      CampusRegistrationStatus.approvedLocal =>
        syncState == CampusSyncState.waitingToSync
            ? 'Approved on this PC · waiting to sync'
            : 'Approved locally - share updated trust bundle',
      CampusRegistrationStatus.published => 'Published',
      CampusRegistrationStatus.revoked => 'Revoked by admin',
      CampusRegistrationStatus.conflict => conflictReason ?? 'Conflict detected',
      _ => status.label,
    };
    return RegisteredDevice(
      deviceId: activePhone.deviceId,
      ownerName: identity.displayName.trim().isEmpty
          ? 'Unknown owner'
          : identity.displayName.trim(),
      phoneNumber: identity.phone.trim(),
      address: identity.address.trim(),
      role: role,
      status: mappedStatus,
      registeredAt: createdAt,
      updatedAt: updatedAt,
      lastSeenLabel: label,
      publicKey: activePhone.publicKey,
      signingPublicKey: activePhone.signingPublicKey,
      keyVersion: activePhone.keyVersion,
    );
  }

  CampusRegistration copyWith({
    String? registrationId,
    CampusRegistrationSource? source,
    CampusRegistrationStatus? status,
    CampusSyncState? syncState,
    Object? conflictReason = _sentinel,
    Object? accountUid = _sentinel,
    Object? accountEmail = _sentinel,
    CampusIdentityFields? identity,
    Object? submittedSnapshot = _sentinel,
    RegisteredDeviceRole? role,
    RegistrationPhoneBinding? activePhone,
    List<RetiredKeyRecord>? retiredKeys,
    List<RegistrationDecisionEntry>? reviewHistory,
    int? revision,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? remoteUpdateTime = _sentinel,
    Object? pendingDecisionId = _sentinel,
  }) {
    return CampusRegistration(
      registrationId: registrationId ?? this.registrationId,
      source: source ?? this.source,
      status: status ?? this.status,
      syncState: syncState ?? this.syncState,
      conflictReason: identical(conflictReason, _sentinel)
          ? this.conflictReason
          : conflictReason as String?,
      accountUid: identical(accountUid, _sentinel)
          ? this.accountUid
          : accountUid as String?,
      accountEmail: identical(accountEmail, _sentinel)
          ? this.accountEmail
          : accountEmail as String?,
      identity: identity ?? this.identity,
      submittedSnapshot: identical(submittedSnapshot, _sentinel)
          ? this.submittedSnapshot
          : submittedSnapshot as CampusIdentityFields?,
      role: role ?? this.role,
      activePhone: activePhone ?? this.activePhone,
      retiredKeys: retiredKeys ?? this.retiredKeys,
      reviewHistory: reviewHistory ?? this.reviewHistory,
      revision: revision ?? this.revision,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      remoteUpdateTime: identical(remoteUpdateTime, _sentinel)
          ? this.remoteUpdateTime
          : remoteUpdateTime as String?,
      pendingDecisionId: identical(pendingDecisionId, _sentinel)
          ? this.pendingDecisionId
          : pendingDecisionId as String?,
    );
  }

  static String newRegistrationId() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return 'reg-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  static String newDecisionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    return 'dec-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  factory CampusRegistration.fromLegacyDevice(RegisteredDevice device) {
    final digest = sha256
        .convert(utf8.encode(device.deviceId.trim().toLowerCase()))
        .toString()
        .substring(0, 16);
    final status = switch (device.status) {
      RegisteredDeviceStatus.approved => CampusRegistrationStatus.approvedLocal,
      RegisteredDeviceStatus.revoked => CampusRegistrationStatus.revoked,
      RegisteredDeviceStatus.pending => CampusRegistrationStatus.submitted,
    };
    return CampusRegistration(
      registrationId: 'legacy-$digest',
      source: CampusRegistrationSource.qr,
      status: status,
      syncState: CampusSyncState.synced,
      identity: CampusIdentityFields(
        displayName: device.ownerName,
        phone: device.phoneNumber,
        address: device.address,
      ),
      role: device.role,
      activePhone: RegistrationPhoneBinding(
        deviceId: device.deviceId,
        publicKey: device.publicKey,
        signingPublicKey: device.signingPublicKey,
        keyVersion: device.keyVersion,
      ),
      createdAt: device.registeredAt,
      updatedAt: device.updatedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'registration_id': registrationId,
    'source': source.name,
    'status': status.code,
    'sync_state': syncState.code,
    if (conflictReason != null) 'conflict_reason': conflictReason,
    if (accountUid != null) 'account_uid': accountUid,
    if (accountEmail != null) 'account_email': accountEmail,
    'identity': identity.toJson(),
    if (submittedSnapshot != null)
      'submitted_snapshot': submittedSnapshot!.toJson(),
    'role': role.name,
    'active_phone': activePhone.toJson(),
    if (retiredKeys.isNotEmpty)
      'retired_keys': retiredKeys.map((e) => e.toJson()).toList(),
    if (reviewHistory.isNotEmpty)
      'review_history': reviewHistory.map((e) => e.toJson()).toList(),
    'revision': revision,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    if (remoteUpdateTime != null) 'remote_update_time': remoteUpdateTime,
    if (pendingDecisionId != null) 'pending_decision_id': pendingDecisionId,
  };

  factory CampusRegistration.fromJson(Map<String, Object?> json) {
    return CampusRegistration(
      registrationId: (json['registration_id'] as String? ?? '').trim(),
      source: CampusRegistrationSource.fromCode(json['source'] as String?),
      status: CampusRegistrationStatus.fromCode(json['status'] as String?),
      syncState: CampusSyncState.fromCode(json['sync_state'] as String?),
      conflictReason: json['conflict_reason'] as String?,
      accountUid: json['account_uid'] as String?,
      accountEmail: json['account_email'] as String?,
      identity: json['identity'] is Map
          ? CampusIdentityFields.fromJson(
              Map<String, Object?>.from(json['identity']! as Map),
            )
          : const CampusIdentityFields(),
      submittedSnapshot: json['submitted_snapshot'] is Map
          ? CampusIdentityFields.fromJson(
              Map<String, Object?>.from(json['submitted_snapshot']! as Map),
            )
          : null,
      role: RegisteredDeviceRole.fromCode(json['role'] as String?),
      activePhone: json['active_phone'] is Map
          ? RegistrationPhoneBinding.fromJson(
              Map<String, Object?>.from(json['active_phone']! as Map),
            )
          : const RegistrationPhoneBinding(deviceId: ''),
      retiredKeys: (json['retired_keys'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (e) => RetiredKeyRecord.fromJson(Map<String, Object?>.from(e)),
          )
          .toList(),
      reviewHistory: (json['review_history'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (e) => RegistrationDecisionEntry.fromJson(
              Map<String, Object?>.from(e),
            ),
          )
          .toList(),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      remoteUpdateTime: json['remote_update_time'] as String?,
      pendingDecisionId: json['pending_decision_id'] as String?,
    );
  }
}

const _sentinel = Object();
