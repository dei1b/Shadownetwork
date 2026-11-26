import crypto from 'node:crypto';

const ED25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

export class PublisherError extends Error {
  constructor(statusCode, message, code = 'publisher_error') {
    super(message);
    this.statusCode = statusCode;
    this.code = code;
  }
}

export function toBase64UrlPadded(bytes) {
  const unpadded = Buffer.from(bytes).toString('base64url');
  return unpadded + '='.repeat((4 - (unpadded.length % 4)) % 4);
}

export function fromBase64Url(value, fieldName = 'base64url field') {
  if (typeof value !== 'string' || !value.trim()) {
    throw new PublisherError(400, `Missing ${fieldName}.`, 'invalid_encoding');
  }
  const normalized = value.trim().replace(/-/g, '+').replace(/_/g, '/');
  const pad = '='.repeat((4 - (normalized.length % 4)) % 4);
  return Buffer.from(normalized + pad, 'base64');
}

export function canonicalJsonEncode(value) {
  if (value === null || typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJsonEncode).join(',')}]`;
  }
  if (typeof value === 'object') {
    const keys = Object.keys(value).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJsonEncode(value[k])}`).join(',')}}`;
  }
  throw new PublisherError(400, `Unsupported canonical JSON value: ${typeof value}`, 'invalid_json');
}

export function ed25519KeyPairFromSeed(seedInput) {
  const seed = Buffer.isBuffer(seedInput) ? seedInput : fromBase64Url(seedInput, 'publisher seed');
  if (seed.length !== 32) {
    throw new PublisherError(500, 'Publisher seed must be 32 bytes.', 'invalid_server_key');
  }
  const privateKey = crypto.createPrivateKey({
    key: Buffer.concat([ED25519_PKCS8_PREFIX, seed]),
    format: 'der',
    type: 'pkcs8',
  });
  const publicKey = crypto.createPublicKey(privateKey);
  const spki = publicKey.export({ format: 'der', type: 'spki' });
  const publicBytes = spki.subarray(ED25519_SPKI_PREFIX.length);
  return {
    privateKey,
    publicKey,
    publicBytes,
    publicKeyBase64Url: toBase64UrlPadded(publicBytes),
    signingKeyId: signingKeyIdForPublicKey(publicBytes),
  };
}

export function signingKeyIdForPublicKey(publicBytes) {
  const digest = crypto.createHash('sha256').update(publicBytes).digest('hex');
  return `ed25519-${digest.slice(0, 16)}`;
}

export function ed25519Verify(message, signatureBase64Url, publicKeyBase64Url, fieldName = 'signature') {
  const pubBytes = fromBase64Url(publicKeyBase64Url, `${fieldName} public key`);
  const sigBytes = fromBase64Url(signatureBase64Url, fieldName);
  if (pubBytes.length !== 32 || sigBytes.length !== 64) {
    return false;
  }
  const publicKey = crypto.createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, pubBytes]),
    format: 'der',
    type: 'spki',
  });
  return crypto.verify(null, Buffer.from(message, 'utf8'), publicKey, sigBytes);
}

export function ed25519Sign(message, privateKey) {
  return toBase64UrlPadded(crypto.sign(null, Buffer.from(message, 'utf8'), privateKey));
}

export function keyIdForX25519PublicKey(publicBytes) {
  const digest = crypto.createHash('sha256').update(publicBytes).digest('hex');
  return `x25519-${digest.slice(0, 16)}`;
}

export function verifyDeviceRegistrationQr(rawJson) {
  let parsed;
  try {
    parsed = typeof rawJson === 'string' ? JSON.parse(rawJson) : rawJson;
  } catch {
    throw new PublisherError(400, 'Device registration JSON is malformed.', 'invalid_qr');
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed) || parsed.registration_type !== 'shadow_network_device_registration') {
    throw new PublisherError(400, 'Unsupported device registration payload.', 'invalid_qr');
  }
  if (Object.hasOwn(parsed, 'private_key') || Object.hasOwn(parsed, 'signing_private_key')) {
    throw new PublisherError(400, 'Registration QR must never contain a private key.', 'invalid_qr');
  }
  const schemaVersion = parsed.schema_version;
  if (schemaVersion !== 2 && schemaVersion !== 3) {
    throw new PublisherError(400, 'Unsupported device registration schema version.', 'invalid_qr');
  }
  const allowedTopKeys = new Set([
    'registration_type',
    'schema_version',
    'device_id',
    'public_key',
    'key_id',
    'key_version',
    'signing_public_key',
    'registration_signature',
    ...(schemaVersion === 3 ? ['user_information'] : []),
  ]);
  for (const key of Object.keys(parsed)) {
    if (!allowedTopKeys.has(key)) {
      throw new PublisherError(400, `Unexpected device registration field: ${key}.`, 'invalid_qr');
    }
  }

  let userInformation = null;
  if (schemaVersion === 3) {
    const info = parsed.user_information;
    if (!info || typeof info !== 'object' || Array.isArray(info)) {
      throw new PublisherError(400, 'Registration is missing user information.', 'invalid_qr');
    }
    if (Object.hasOwn(info, 'private_key') || Object.hasOwn(info, 'signing_private_key')) {
      throw new PublisherError(400, 'Registration QR must never contain a private key.', 'invalid_qr');
    }
    const allowedInfoKeys = new Set(['full_name', 'phone_number', 'address']);
    for (const key of Object.keys(info)) {
      if (!allowedInfoKeys.has(key)) {
        throw new PublisherError(400, `Unexpected user information field: ${key}.`, 'invalid_qr');
      }
    }
    const readInfoField = (key, maxLen) => {
      const value = info[key];
      if (typeof value !== 'string' || !value.trim() || value.length > maxLen) {
        throw new PublisherError(400, 'Registration user information is invalid.', 'invalid_qr');
      }
      return value.trim();
    };
    userInformation = {
      full_name: readInfoField('full_name', 100),
      phone_number: readInfoField('phone_number', 50),
      address: readInfoField('address', 300),
    };
  }

  const deviceId = typeof parsed.device_id === 'string' ? parsed.device_id.trim() : '';
  const publicKey = typeof parsed.public_key === 'string' ? parsed.public_key.trim() : '';
  const signingPublicKey = typeof parsed.signing_public_key === 'string' ? parsed.signing_public_key.trim() : '';
  const keyId = typeof parsed.key_id === 'string' ? parsed.key_id.trim() : '';
  const keyVersion = parsed.key_version;
  const signature = parsed.registration_signature;
  if (!deviceId || !publicKey || !signingPublicKey || !keyId || !Number.isInteger(keyVersion) || keyVersion <= 0 || typeof signature !== 'string' || !signature.trim()) {
    throw new PublisherError(400, 'Signed device registration keys are missing.', 'invalid_qr');
  }
  const pubBytes = fromBase64Url(publicKey, 'registration public key');
  if (pubBytes.length !== 32) {
    throw new PublisherError(400, 'Registration QR public key must contain 32 bytes.', 'invalid_qr');
  }
  if (keyIdForX25519PublicKey(pubBytes) !== keyId) {
    throw new PublisherError(400, 'Registration QR key ID does not match.', 'invalid_qr');
  }

  const canonicalUnsigned = {
    registration_type: 'shadow_network_device_registration',
    schema_version: schemaVersion,
    device_id: deviceId,
    public_key: publicKey,
    key_id: keyId,
    key_version: keyVersion,
    ...(schemaVersion === 3 ? { user_information: userInformation } : {}),
    signing_public_key: signingPublicKey,
  };
  const signingData = `shadow-network-registration-v${schemaVersion}\n${canonicalJsonEncode(canonicalUnsigned)}`;
  if (!ed25519Verify(signingData, signature, signingPublicKey, 'device registration signature')) {
    throw new PublisherError(400, 'Phone registration signature failed verification.', 'invalid_qr_signature');
  }
  return {
    deviceId,
    publicKey,
    signingPublicKey,
    keyId,
    keyVersion,
    schemaVersion,
    ...(userInformation ? { userInformation } : {}),
  };
}

export function verifyAccountLinkProof(proof, { expectedRegistrationId, expectedAccountUid, expectedPhone, expectedProject }) {
  if (!proof || typeof proof !== 'object') {
    throw new PublisherError(400, 'Account link proof is required.', 'invalid_link_proof');
  }
  const strip = (v) => String(v ?? '').trim().replace(/=+$/, '');
  const registrationId = String(proof.registrationId ?? proof.registration_id ?? '').trim();
  const accountUid = String(proof.accountUid ?? proof.account_uid ?? '').trim();
  const nonce = String(proof.nonce ?? '').trim();
  const deviceId = String(proof.deviceId ?? proof.device_id ?? '').trim();
  const publicKey = String(proof.publicKey ?? proof.public_key ?? '').trim();
  const signingPublicKey = String(proof.signingPublicKey ?? proof.signing_public_key ?? '').trim();
  const keyVersion = Number(proof.keyVersion ?? proof.key_version ?? 0);
  const directoryProject = proof.directoryProject ?? proof.directory_project ?? undefined;
  const issuedAt = String(proof.issuedAt ?? proof.issued_at ?? '').trim();
  const signature = String(proof.proofSignature ?? proof.proof_signature ?? '').trim();

  if (
    registrationId !== expectedRegistrationId ||
    accountUid !== expectedAccountUid ||
    !nonce ||
    deviceId.toLowerCase() !== String(expectedPhone.deviceId ?? '').toLowerCase() ||
    strip(publicKey) !== strip(expectedPhone.publicKey) ||
    strip(signingPublicKey) !== strip(expectedPhone.signingPublicKey) ||
    keyVersion !== Number(expectedPhone.keyVersion ?? 1)
  ) {
    throw new PublisherError(400, 'Phone proof does not match the approved device.', 'link_mismatch');
  }
  if (expectedProject && directoryProject && directoryProject !== expectedProject) {
    throw new PublisherError(400, 'Phone proof belongs to another campus project.', 'project_mismatch');
  }
  const canonicalPayload = {
    registration_id: registrationId,
    account_uid: accountUid,
    ...(directoryProject ? { directory_project: directoryProject } : {}),
    nonce,
    device_id: deviceId,
    public_key: publicKey,
    signing_public_key: signingPublicKey,
    key_version: keyVersion,
    issued_at: issuedAt,
  };
  const signingData = `shadow-network-account-link-v1\n${canonicalJsonEncode(canonicalPayload)}`;
  if (!ed25519Verify(signingData, signature, signingPublicKey, 'account link proof')) {
    throw new PublisherError(400, 'Account link proof signature is invalid.', 'invalid_link_signature');
  }
}

export function verifyPublisherDelegation(delegation, { expectedProject, now = new Date() } = {}) {
  if (!delegation || typeof delegation !== 'object' || delegation.delegation_type !== 'shadow_network_publisher_delegation') {
    throw new PublisherError(500, 'Publisher delegation is missing or invalid.', 'invalid_delegation');
  }
  if (delegation.scope !== 'trust_directory_publisher') {
    throw new PublisherError(500, 'Publisher delegation scope is invalid.', 'invalid_delegation');
  }
  const issuedAt = new Date(delegation.issued_at);
  const expiresAt = new Date(delegation.expires_at);
  if (Number.isNaN(issuedAt.getTime()) || Number.isNaN(expiresAt.getTime()) || expiresAt <= now) {
    throw new PublisherError(500, 'Publisher delegation is expired.', 'expired_delegation');
  }
  if (expectedProject && delegation.directory_project && delegation.directory_project !== expectedProject) {
    throw new PublisherError(500, 'Publisher delegation project mismatch.', 'delegation_project_mismatch');
  }
  const { signature, ...unsigned } = delegation;
  const signingData = `shadow-network-publisher-delegation-v1\n${canonicalJsonEncode(unsigned)}`;
  if (!ed25519Verify(signingData, signature, delegation.root_issuer?.public_key, 'publisher delegation')) {
    throw new PublisherError(500, 'Publisher delegation signature is invalid.', 'invalid_delegation_signature');
  }
  return delegation;
}

export function verifyTrustBundle(bundle, { expectedProject, now = new Date() } = {}) {
  if (!bundle || typeof bundle !== 'object' || bundle.bundle_type !== 'shadow_network_device_trust_bundle') {
    throw new PublisherError(409, 'Existing directory bundle is invalid.', 'invalid_directory');
  }
  if (expectedProject && bundle.directory_project && bundle.directory_project !== expectedProject) {
    throw new PublisherError(409, 'Existing directory belongs to another project.', 'project_mismatch');
  }
  if (bundle.publisher_delegation) {
    verifyPublisherDelegation(bundle.publisher_delegation, { expectedProject, now });
    if (bundle.publisher_delegation.publisher?.public_key !== bundle.issuer?.public_key) {
      throw new PublisherError(409, 'Directory issuer does not match delegation.', 'invalid_directory');
    }
  }
  const { signature, ...unsigned } = bundle;
  if (!ed25519Verify(canonicalJsonEncode(unsigned), signature, bundle.issuer?.public_key, 'trust bundle')) {
    throw new PublisherError(409, 'Existing directory signature is invalid.', 'invalid_directory_signature');
  }
  return bundle;
}

export function signTrustBundle({
  version,
  directoryProject,
  publisherKeyPair,
  delegation,
  approvedDevices,
  revokedDevices,
  now = new Date(),
  validityDays = 30,
}) {
  const issuedAt = now.toISOString();
  const expiresAt = new Date(now.getTime() + validityDays * 86400_000).toISOString();
  const unsigned = {
    schema_version: 2,
    bundle_type: 'shadow_network_device_trust_bundle',
    bundle_version: version,
    issued_at: issuedAt,
    expires_at: expiresAt,
    issuer: delegation.publisher,
    publisher_delegation: delegation,
    ...(directoryProject ? { directory_project: directoryProject } : {}),
    approved_devices: approvedDevices,
    revoked_devices: revokedDevices,
  };
  const signature = ed25519Sign(canonicalJsonEncode(unsigned), publisherKeyPair.privateKey);
  return {
    ...unsigned,
    signature,
  };
}

function buildIdentityFieldsPayload(fields = {}) {
  const affiliation = fields.affiliation === 'staff' ? 'staff' : 'student';
  const displayName = String(fields.displayName ?? '').trim();
  if (!displayName) {
    throw new PublisherError(400, 'Full name is required.', 'validation_error');
  }
  if (affiliation === 'staff') {
    const employeeId = String(fields.employeeId ?? '').trim();
    const unit = String(fields.unit ?? '').trim();
    if (!employeeId || !unit) {
      throw new PublisherError(400, 'Employee ID and unit are required.', 'validation_error');
    }
    return {
      affiliation: 'staff',
      displayName,
      employeeId,
      unit,
      studentNumber: String(fields.studentNumber ?? '').trim(),
      course: String(fields.course ?? '').trim(),
      yearLevel: String(fields.yearLevel ?? '').trim(),
      sectionSet: String(fields.sectionSet ?? '').trim(),
      courseYear: String(fields.courseYear ?? '').trim(),
      ...(fields.phone != null ? { phone: String(fields.phone).trim() } : {}),
      ...(fields.address != null ? { address: String(fields.address).trim() } : {}),
    };
  }
  const studentNumber = String(fields.studentNumber ?? '').trim();
  const course = String(fields.course ?? '').trim();
  const yearLevel = String(fields.yearLevel ?? '').trim();
  const sectionSet = String(fields.sectionSet ?? '').trim();
  const courseYear =
    course || yearLevel || sectionSet
      ? [course, yearLevel, sectionSet].filter(Boolean).join(' · ')
      : String(fields.courseYear ?? '').trim();
  if (!studentNumber || !courseYear) {
    throw new PublisherError(400, 'Student number and course details are required.', 'validation_error');
  }
  return {
    affiliation: 'student',
    displayName,
    studentNumber,
    course,
    yearLevel,
    sectionSet,
    courseYear,
    employeeId: '',
    unit: '',
    ...(fields.phone != null ? { phone: String(fields.phone).trim() } : {}),
    ...(fields.address != null ? { address: String(fields.address).trim() } : {}),
  };
}

function normalizeDevicesFromBundle(existingBundle) {
  if (!existingBundle) return { approved: new Map(), revoked: new Map() };
  const approved = new Map();
  const revoked = new Map();
  for (const d of existingBundle.approved_devices ?? []) {
    approved.set(String(d.device_id).toLowerCase(), { ...d });
  }
  for (const d of existingBundle.revoked_devices ?? []) {
    revoked.set(String(d.device_id).toLowerCase(), { ...d });
  }
  return { approved, revoked };
}

function hasDecisionId(doc, decisionId) {
  if (!doc) return false;
  const processed = Array.isArray(doc.processedDecisionIds) ? doc.processedDecisionIds : [];
  if (processed.includes(decisionId)) return true;
  const history = Array.isArray(doc.reviewHistory) ? doc.reviewHistory : [];
  return history.some((entry) => entry && entry.decisionId === decisionId);
}

/**
 * Pure state machine + commit builder shared cleanly by `api/publish-approval.mjs` and unit tests.
 */
export function applyDecisionAndBuildCommit({
  action,
  decisionId,
  reviewerUid,
  directoryProject,
  publisherSeed,
  publisherDelegation,
  existingDirectory = null,
  application = null,
  registration = null,
  linkRequest = null,
  recoveryRequest = null,
  payload = {},
  now = new Date(),
}) {
  if (!reviewerUid) {
    throw new PublisherError(403, 'Reviewer authentication is required.', 'unauthenticated');
  }
  if (!decisionId || typeof decisionId !== 'string') {
    throw new PublisherError(400, 'A unique decisionId is required.', 'missing_decision_id');
  }
  const delegation = verifyPublisherDelegation(
    typeof publisherDelegation === 'string' ? JSON.parse(publisherDelegation) : publisherDelegation,
    { expectedProject: directoryProject, now },
  );
  const publisherKeyPair = ed25519KeyPairFromSeed(publisherSeed);
  if (publisherKeyPair.publicKeyBase64Url !== delegation.publisher.public_key) {
    throw new PublisherError(500, 'Publisher seed does not match delegation public key.', 'server_key_mismatch');
  }

  let parsedBundle = null;
  if (existingDirectory?.bundle) {
    parsedBundle = verifyTrustBundle(JSON.parse(existingDirectory.bundle), {
      expectedProject: directoryProject,
      now,
    });
  }

  // Idempotent retry check for same decisionId.
  if (
    existingDirectory &&
    (existingDirectory.lastDecisionId === decisionId ||
      hasDecisionId(application, decisionId) ||
      hasDecisionId(registration, decisionId))
  ) {
    return {
      status: 'published',
      idempotent: true,
      version: Number(existingDirectory.version ?? parsedBundle?.bundle_version ?? 0),
      bundle: existingDirectory.bundle,
      registrationId: registration?.registrationId ?? application?.registrationId ?? payload.registrationId ?? null,
      decisionId,
      writes: [],
    };
  }

  const targetAccountUid =
    application?.uid ??
    linkRequest?.accountUid ??
    recoveryRequest?.accountUid ??
    registration?.accountUid ??
    payload.accountUid ??
    null;
  if (targetAccountUid && targetAccountUid === reviewerUid) {
    throw new PublisherError(403, 'Another reviewer must approve or update your own registration.', 'self_review_forbidden');
  }

  const role = payload.role === 'responder' ? 'responder' : 'civilian';
  const reason = String(payload.reason ?? '').trim();
  const nextRevision = Number(application?.revision ?? registration?.revision ?? 0) + 1;
  const historyEntry = {
    reviewerUid,
    status: 'published',
    reason,
    revision: nextRevision,
    role,
    decisionId,
    ...(Array.isArray(payload.editedFields) && payload.editedFields.length > 0
      ? { editedFields: payload.editedFields }
      : {}),
  };

  if (action === 'request_changes' || action === 'reject') {
    if (!application) {
      throw new PublisherError(404, 'Online application not found.', 'not_found');
    }
    if (!reason) {
      throw new PublisherError(400, 'Enter a reason for this decision.', 'missing_reason');
    }
    const targetStatus = action === 'request_changes' ? 'changes_requested' : 'rejected';
    const nextFields = {
      ...application,
      status: targetStatus,
      publicationStatus: 'none',
      revision: nextRevision,
      reviewHistory: [...(application.reviewHistory ?? []), { ...historyEntry, status: targetStatus }],
      processedDecisionIds: [...(application.processedDecisionIds ?? []), decisionId],
    };
    return {
      status: targetStatus,
      idempotent: false,
      version: Number(existingDirectory?.version ?? 0),
      bundle: existingDirectory?.bundle ?? null,
      registrationId: nextFields.registrationId ?? null,
      decisionId,
      writes: [{ collection: 'pilotApplications', docId: application.uid, fields: nextFields, updateTime: application.updateTime }],
    };
  }

  const { approved, revoked } = normalizeDevicesFromBundle(parsedBundle);
  const nextVersion = Number(existingDirectory?.version ?? 0) + 1;
  const nowIso = now.toISOString();
  const writes = [];
  let registrationId = payload.registrationId ?? registration?.registrationId ?? application?.registrationId ?? `reg-${crypto.randomUUID()}`;
  let directoryOwnerFields = {};

  if (action === 'approve_online') {
    if (!application) {
      throw new PublisherError(404, 'Application not found.', 'not_found');
    }
    const reviewed = buildIdentityFieldsPayload(payload.reviewedFields ?? application);
    const verifiedPhone = verifyDeviceRegistrationQr(application.deviceRegistration);
    const keyLower = verifiedPhone.deviceId.toLowerCase();
    if (revoked.has(keyLower)) {
      throw new PublisherError(409, 'This phone is revoked in the current published directory.', 'revocation_conflict');
    }
    revoked.delete(keyLower);
    approved.set(keyLower, {
      device_id: verifiedPhone.deviceId,
      owner_name: reviewed.displayName,
      role,
      status: 'approved',
      public_key: verifiedPhone.publicKey,
      signing_public_key: verifiedPhone.signingPublicKey,
      key_version: verifiedPhone.keyVersion,
      updated_at: nowIso,
    });
    directoryOwnerFields = { applicationUid: application.uid, registrationId };
    const nextApp = {
      ...application,
      ...reviewed,
      registrationId,
      status: 'published',
      publicationStatus: 'published',
      revision: nextRevision,
      reviewHistory: [...(application.reviewHistory ?? []), historyEntry],
      processedDecisionIds: [...(application.processedDecisionIds ?? []), decisionId],
    };
    writes.push({ collection: 'pilotApplications', docId: application.uid, fields: nextApp, updateTime: application.updateTime });
    writes.push({
      collection: 'campusRegistrations',
      docId: registrationId,
      fields: {
        registrationId,
        source: 'online',
        status: 'published',
        role,
        accountUid: application.uid,
        ...reviewed,
        deviceRegistration: application.deviceRegistration,
        deviceId: verifiedPhone.deviceId,
        publicKey: verifiedPhone.publicKey,
        signingPublicKey: verifiedPhone.signingPublicKey,
        keyVersion: verifiedPhone.keyVersion,
        processedDecisionIds: [...(registration?.processedDecisionIds ?? []), decisionId],
        updatedAt: nowIso,
      },
      updateTime: registration?.updateTime,
    });
  } else if (action === 'sync_offline_decision') {
    if (!registration) {
      throw new PublisherError(400, 'Registration record is required.', 'missing_registration');
    }
    const reviewed = buildIdentityFieldsPayload(payload.reviewedFields ?? registration);
    const verifiedPhone = verifyDeviceRegistrationQr(
      registration.deviceRegistration ?? payload.deviceRegistration,
    );
    const keyLower = verifiedPhone.deviceId.toLowerCase();
    const targetRevoke = payload.targetStatus === 'revoked' || registration.status === 'revoked';
    if (!targetRevoke && revoked.has(keyLower) && payload.overrideConflict !== true) {
      throw new PublisherError(409, 'A newer revocation exists in the published directory. Review and issue a signed correction.', 'revocation_conflict');
    }
    const existingApproved = approved.get(keyLower);
    if (!targetRevoke && existingApproved && existingApproved.public_key !== verifiedPhone.publicKey) {
      throw new PublisherError(409, 'Published keys for this device differ from the local record.', 'key_conflict');
    }
    const entry = {
      device_id: verifiedPhone.deviceId,
      owner_name: reviewed.displayName,
      role,
      status: targetRevoke ? 'revoked' : 'approved',
      public_key: verifiedPhone.publicKey,
      signing_public_key: verifiedPhone.signingPublicKey,
      key_version: verifiedPhone.keyVersion,
      updated_at: nowIso,
    };
    if (targetRevoke) {
      approved.delete(keyLower);
      revoked.set(keyLower, entry);
    } else {
      revoked.delete(keyLower);
      approved.set(keyLower, entry);
    }
    directoryOwnerFields = {
      ...(targetAccountUid ? { applicationUid: targetAccountUid } : {}),
      registrationId,
    };
    writes.push({
      collection: 'campusRegistrations',
      docId: registrationId,
      fields: {
        ...registration,
        ...reviewed,
        registrationId,
        source: registration.source ?? 'qr',
        status: targetRevoke ? 'revoked' : 'published',
        role,
        ...(targetAccountUid ? { accountUid: targetAccountUid } : {}),
        deviceId: verifiedPhone.deviceId,
        publicKey: verifiedPhone.publicKey,
        signingPublicKey: verifiedPhone.signingPublicKey,
        keyVersion: verifiedPhone.keyVersion,
        reviewHistory: [...(registration.reviewHistory ?? []), historyEntry],
        processedDecisionIds: [...(registration.processedDecisionIds ?? []), decisionId],
        updatedAt: nowIso,
      },
      updateTime: registration.updateTime,
    });
  } else if (action === 'approve_link') {
    if (!linkRequest || !registration) {
      throw new PublisherError(404, 'Link request or registration not found.', 'not_found');
    }
    verifyAccountLinkProof(linkRequest, {
      expectedRegistrationId: registration.registrationId,
      expectedAccountUid: linkRequest.accountUid,
      expectedPhone: {
        deviceId: registration.deviceId,
        publicKey: registration.publicKey,
        signingPublicKey: registration.signingPublicKey,
        keyVersion: registration.keyVersion ?? 1,
      },
      expectedProject: directoryProject,
    });
    const reviewed = buildIdentityFieldsPayload(payload.reviewedFields ?? registration);
    const keyLower = String(registration.deviceId).toLowerCase();
    revoked.delete(keyLower);
    approved.set(keyLower, {
      device_id: registration.deviceId,
      owner_name: reviewed.displayName,
      role,
      status: 'approved',
      public_key: registration.publicKey,
      signing_public_key: registration.signingPublicKey,
      key_version: Number(registration.keyVersion ?? 1),
      updated_at: nowIso,
    });
    directoryOwnerFields = { applicationUid: linkRequest.accountUid, registrationId };
    writes.push({
      collection: 'registrationLinkRequests',
      docId: linkRequest.accountUid,
      fields: { ...linkRequest, status: 'linked', reviewerUid },
      updateTime: linkRequest.updateTime,
    });
    writes.push({
      collection: 'campusRegistrations',
      docId: registrationId,
      fields: {
        ...registration,
        ...reviewed,
        accountUid: linkRequest.accountUid,
        status: 'published',
        processedDecisionIds: [...(registration.processedDecisionIds ?? []), decisionId],
        updatedAt: nowIso,
      },
      updateTime: registration.updateTime,
    });
    writes.push({
      collection: 'pilotApplications',
      docId: linkRequest.accountUid,
      fields: {
        ...reviewed,
        registrationId,
        status: 'published',
        publicationStatus: 'published',
        revision: nextRevision,
        deviceRegistration: registration.deviceRegistration ?? '',
        reviewHistory: [...(application?.reviewHistory ?? []), historyEntry],
        processedDecisionIds: [...(application?.processedDecisionIds ?? []), decisionId],
      },
      updateTime: application?.updateTime,
    });
  } else if (action === 'approve_replacement' || action === 'approve_recovery') {
    const newQrRaw =
      action === 'approve_recovery'
        ? recoveryRequest?.deviceRegistration
        : application?.replacementRequest?.deviceRegistration ?? payload.deviceRegistration;
    if (!newQrRaw) {
      throw new PublisherError(400, 'Signed replacement phone QR is missing.', 'missing_qr');
    }
    const newPhone = verifyDeviceRegistrationQr(newQrRaw);
    const oldPhone = registration ?? (application?.deviceRegistration ? verifyDeviceRegistrationQr(application.deviceRegistration) : null);
    if (!oldPhone) {
      throw new PublisherError(404, 'Existing registration phone record not found.', 'not_found');
    }
    const oldIdLower = String(oldPhone.deviceId).toLowerCase();
    const newIdLower = newPhone.deviceId.toLowerCase();
    const sameId = oldIdLower === newIdLower;
    const nextKeyVersion = sameId
      ? Math.max(Number(oldPhone.keyVersion ?? 1) + 1, newPhone.keyVersion)
      : newPhone.keyVersion;
    if (!sameId && oldPhone.publicKey) {
      approved.delete(oldIdLower);
      revoked.set(oldIdLower, {
        device_id: oldPhone.deviceId,
        owner_name: (registration?.displayName ?? application?.displayName ?? 'Replaced phone'),
        role,
        status: 'revoked',
        public_key: oldPhone.publicKey,
        signing_public_key: oldPhone.signingPublicKey,
        key_version: Number(oldPhone.keyVersion ?? 1),
        updated_at: nowIso,
      });
    }
    const ownerFields = buildIdentityFieldsPayload(payload.reviewedFields ?? registration ?? application ?? {});
    approved.set(newIdLower, {
      device_id: newPhone.deviceId,
      owner_name: ownerFields.displayName,
      role,
      status: 'approved',
      public_key: newPhone.publicKey,
      signing_public_key: newPhone.signingPublicKey,
      key_version: nextKeyVersion,
      updated_at: nowIso,
    });
    directoryOwnerFields = {
      ...(targetAccountUid ? { applicationUid: targetAccountUid } : {}),
      registrationId,
    };
    const retiredRecord = {
      device_id: oldPhone.deviceId,
      public_key_hash: oldPhone.publicKey ? crypto.createHash('sha256').update(oldPhone.publicKey).digest('hex') : null,
      signing_key_hash: oldPhone.signingPublicKey ? crypto.createHash('sha256').update(oldPhone.signingPublicKey).digest('hex') : null,
      key_version: Number(oldPhone.keyVersion ?? 1),
      retired_at: nowIso,
      reason: reason || (action === 'approve_recovery' ? 'Approved lost-phone recovery' : 'Approved phone replacement'),
    };
    writes.push({
      collection: 'campusRegistrations',
      docId: registrationId,
      fields: {
        ...(registration ?? {}),
        ...ownerFields,
        registrationId,
        status: 'published',
        role,
        ...(targetAccountUid ? { accountUid: targetAccountUid } : {}),
        deviceRegistration: newQrRaw,
        deviceId: newPhone.deviceId,
        publicKey: newPhone.publicKey,
        signingPublicKey: newPhone.signingPublicKey,
        keyVersion: nextKeyVersion,
        retiredKeys: [...(registration?.retiredKeys ?? []), retiredRecord],
        processedDecisionIds: [...(registration?.processedDecisionIds ?? []), decisionId],
        updatedAt: nowIso,
      },
      updateTime: registration?.updateTime,
    });
    if (targetAccountUid) {
      writes.push({
        collection: 'pilotApplications',
        docId: targetAccountUid,
        fields: {
          ...(application ?? ownerFields),
          ...ownerFields,
          registrationId,
          status: 'published',
          publicationStatus: 'published',
          revision: nextRevision,
          deviceRegistration: newQrRaw,
          ...(action === 'approve_replacement' && application?.replacementRequest
            ? { replacementRequest: { ...application.replacementRequest, status: 'published', reviewerUid } }
            : {}),
          processedDecisionIds: [...(application?.processedDecisionIds ?? []), decisionId],
        },
        updateTime: application?.updateTime,
      });
    }
    if (action === 'approve_recovery' && recoveryRequest) {
      writes.push({
        collection: 'registrationRecoveryRequests',
        docId: recoveryRequest.accountUid,
        fields: {
          ...recoveryRequest,
          status: 'published',
          reviewerUid,
          ...(payload.verificationMethod ? { verificationMethod: payload.verificationMethod } : {}),
        },
        updateTime: recoveryRequest.updateTime,
      });
    }
  } else {
    throw new PublisherError(400, `Unsupported publisher action: ${action}`, 'unsupported_action');
  }

  const nextBundle = signTrustBundle({
    version: nextVersion,
    directoryProject,
    publisherKeyPair,
    delegation,
    approvedDevices: [...approved.values()],
    revokedDevices: [...revoked.values()],
    now,
  });
  const nextBundleJson = JSON.stringify(nextBundle);

  writes.push({
    collection: 'trustDirectory',
    docId: 'current',
    fields: {
      ...directoryOwnerFields,
      version: nextVersion,
      bundle: nextBundleJson,
      lastDecisionId: decisionId,
      publishedAt: nowIso,
    },
    updateTime: existingDirectory?.updateTime,
  });

  return {
    status: 'published',
    idempotent: false,
    version: nextVersion,
    bundle: nextBundleJson,
    registrationId,
    decisionId,
    writes,
  };
}
