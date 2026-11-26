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

export function verifyPublisherDelegation(
  delegation,
  { expectedProject, now = new Date(), verifyAt = null } = {},
) {
  if (!delegation || typeof delegation !== 'object' || delegation.delegation_type !== 'shadow_network_publisher_delegation') {
    throw new PublisherError(500, 'Publisher delegation is missing or invalid.', 'invalid_delegation');
  }
  if (delegation.scope !== 'trust_directory_publisher') {
    throw new PublisherError(500, 'Publisher delegation scope is invalid.', 'invalid_delegation');
  }
  const issuedAt = new Date(delegation.issued_at);
  const expiresAt = new Date(delegation.expires_at);
  const checkTime = verifyAt ?? now;
  if (
    Number.isNaN(issuedAt.getTime()) ||
    Number.isNaN(expiresAt.getTime()) ||
    issuedAt.getTime() > checkTime.getTime() + 5 * 60_000
  ) {
    throw new PublisherError(500, 'Publisher delegation timestamps are invalid.', 'invalid_delegation');
  }
  if (expiresAt <= checkTime) {
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

export function verifyTrustBundle(
  bundle,
  { expectedProject, expectedRootPublicKey = null, now = new Date() } = {},
) {
  if (!bundle || typeof bundle !== 'object' || bundle.bundle_type !== 'shadow_network_device_trust_bundle') {
    throw new PublisherError(409, 'Existing directory bundle is invalid.', 'invalid_directory');
  }
  if (expectedProject && bundle.directory_project && bundle.directory_project !== expectedProject) {
    throw new PublisherError(409, 'Existing directory belongs to another project.', 'project_mismatch');
  }
  const bundleIssuedAt = new Date(bundle.issued_at);
  if (Number.isNaN(bundleIssuedAt.getTime())) {
    throw new PublisherError(409, 'Existing directory issue timestamp is invalid.', 'invalid_directory');
  }
  if (bundle.publisher_delegation) {
    verifyPublisherDelegation(bundle.publisher_delegation, {
      expectedProject,
      verifyAt: bundleIssuedAt,
    });
    if (bundle.publisher_delegation.publisher?.public_key !== bundle.issuer?.public_key) {
      throw new PublisherError(409, 'Directory issuer does not match delegation.', 'invalid_directory');
    }
  }
  const bundleRootPublicKey =
    bundle.publisher_delegation?.root_issuer?.public_key ??
    bundle.issuer?.public_key ??
    null;
  if (expectedRootPublicKey && bundleRootPublicKey !== expectedRootPublicKey) {
    throw new PublisherError(
      409,
      'Existing directory was signed by a different campus root authority.',
      'root_authority_mismatch',
    );
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
  const seenApproved = new Set();
  const seenRevoked = new Set();
  for (const device of approvedDevices ?? []) {
    const id = String(device?.device_id ?? '').trim().toLowerCase();
    if (!id || seenApproved.has(id)) {
      throw new PublisherError(
        500,
        'Trust bundle contains a missing or duplicate approved device ID.',
        'duplicate_device_id',
      );
    }
    seenApproved.add(id);
  }
  for (const device of revokedDevices ?? []) {
    const id = String(device?.device_id ?? '').trim().toLowerCase();
    if (!id || seenRevoked.has(id) || seenApproved.has(id)) {
      throw new PublisherError(
        500,
        'Approved and revoked device lists must be disjoint without duplicates.',
        'duplicate_device_id',
      );
    }
    seenRevoked.add(id);
  }
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

function resolveRegistrationPhone(registration) {
  if (!registration) {
    throw new PublisherError(404, 'Registration record not found.', 'not_found');
  }
  let verifiedQr = null;
  if (registration.deviceRegistration) {
    verifiedQr = verifyDeviceRegistrationQr(registration.deviceRegistration);
  }
  const deviceId = String(registration.deviceId ?? verifiedQr?.deviceId ?? '').trim();
  const publicKey = String(registration.publicKey ?? verifiedQr?.publicKey ?? '').trim();
  const signingPublicKey = String(
    registration.signingPublicKey ?? verifiedQr?.signingPublicKey ?? '',
  ).trim();
  const keyVersion = Number(
    registration.keyVersion ?? verifiedQr?.keyVersion ?? 1,
  );
  if (
    !deviceId ||
    !publicKey ||
    !signingPublicKey ||
    !Number.isInteger(keyVersion) ||
    keyVersion <= 0
  ) {
    throw new PublisherError(
      400,
      'Registration phone keys are missing and no valid device registration payload is stored.',
      'missing_phone_keys',
    );
  }
  if (verifiedQr) {
    const strip = (v) => String(v).trim().replace(/=+$/, '');
    if (
      verifiedQr.deviceId.toLowerCase() !== deviceId.toLowerCase() ||
      strip(verifiedQr.publicKey) !== strip(publicKey) ||
      strip(verifiedQr.signingPublicKey) !== strip(signingPublicKey) ||
      verifiedQr.keyVersion !== keyVersion
    ) {
      throw new PublisherError(
        409,
        'Stored registration phone fields do not match its signed device registration.',
        'phone_binding_mismatch',
      );
    }
  }
  return { deviceId, publicKey, signingPublicKey, keyVersion };
}

function hasDecisionId(doc, decisionId) {
  if (!doc) return false;
  const processed = Array.isArray(doc.processedDecisionIds) ? doc.processedDecisionIds : [];
  if (processed.includes(decisionId)) return true;
  const history = Array.isArray(doc.reviewHistory) ? doc.reviewHistory : [];
  return history.some((entry) => entry && entry.decisionId === decisionId);
}

function computeDecisionFingerprint({
  action,
  payload,
  application,
  registration,
  linkRequest,
  recoveryRequest,
}) {
  const accountUid =
    payload.accountUid ??
    payload.applicationUid ??
    (action === 'delete_registration' ? null : (
      linkRequest?.accountUid ?? recoveryRequest?.accountUid ?? application?.uid ?? null
    ));
  const targetRegistrationId = payload.registrationId ?? null;
  const normalizeJsonField = (raw) => {
    if (typeof raw !== 'string') return raw ?? null;
    try {
      return JSON.parse(raw);
    } catch {
      return raw.trim();
    }
  };
  let normalizedEmbeddedReg = payload.registration ?? null;
  if (normalizedEmbeddedReg && typeof normalizedEmbeddedReg === 'object') {
    normalizedEmbeddedReg = {
      registrationId: normalizedEmbeddedReg.registrationId ?? null,
      source: normalizedEmbeddedReg.source ?? null,
      status: normalizedEmbeddedReg.status ?? null,
      accountUid: normalizedEmbeddedReg.accountUid ?? null,
      deviceRegistration: normalizeJsonField(
        normalizedEmbeddedReg.deviceRegistration,
      ),
    };
  }
  const canonical = canonicalJsonEncode({
    action: action ?? null,
    accountUid,
    registrationId: targetRegistrationId,
    role: payload.role ?? null,
    targetStatus: payload.targetStatus ?? null,
    reason: String(payload.reason ?? '').trim(),
    overrideConflict: Boolean(payload.overrideConflict),
    verificationMethod: payload.verificationMethod ?? null,
    deviceRegistration: normalizeJsonField(payload.deviceRegistration),
    reviewedFields: payload.reviewedFields ?? null,
    editedFields: Array.isArray(payload.editedFields)
      ? [...payload.editedFields].map(String).sort()
      : null,
    registration: normalizedEmbeddedReg,
    ...(action === 'approve_online' && payload.restoreRevoked === true ? {
      restoreRevoked: true,
      expectedRegistrationUpdateTime: payload.expectedRegistrationUpdateTime ?? null,
      expectedOldPhone: payload.expectedOldPhone ?? null,
      expectedRevision: payload.expectedRevision ?? null,
    } : {}),
    ...(action === 'delete_registration'
      ? { expectedRevision: payload.expectedRevision ?? null }
      : {}),
    ...((action === 'approve_replacement' || action === 'approve_recovery') &&
      ('expectedRequestUpdateTime' in payload || 'expectedOldPhone' in payload)
      ? {
          expectedRequestUpdateTime: payload.expectedRequestUpdateTime ?? null,
          expectedOldPhone: payload.expectedOldPhone ?? null,
        }
      : {}),
  });
  return crypto.createHash('sha256').update(canonical).digest('hex');
}

function assertMatchingRecordedDecision({
  recordedAction,
  recordedFingerprint,
  recordedStatus,
  recordedExpectedRevision,
  payloadExpectedRevision,
  action,
  requestFingerprint,
}) {
  if (recordedAction && action && recordedAction !== action) {
    throw new PublisherError(
      409,
      'This decisionId was already used for a different decision action.',
      'decision_id_conflict',
    );
  }
  if (
    recordedFingerprint &&
    requestFingerprint &&
    recordedFingerprint !== requestFingerprint
  ) {
    throw new PublisherError(
      409,
      'This decisionId was already used for different decision parameters.',
      'decision_id_conflict',
    );
  }
  if (
    recordedExpectedRevision !== undefined &&
    recordedExpectedRevision !== null &&
    payloadExpectedRevision !== undefined &&
    payloadExpectedRevision !== null &&
    Number(recordedExpectedRevision) !== Number(payloadExpectedRevision)
  ) {
    throw new PublisherError(
      409,
      'This decisionId was already used for a different base revision.',
      'decision_id_conflict',
    );
  }
  if (!recordedAction && recordedStatus && action) {
    const isNegativeOutcome =
      recordedStatus === 'changes_requested' || recordedStatus === 'rejected';
    const isNegativeAction =
      action === 'request_changes' ||
      action === 'reject' ||
      action === 'decline_profile_change';
    if (isNegativeOutcome !== isNegativeAction) {
      throw new PublisherError(
        409,
        'This decisionId was already used for a different decision outcome.',
        'decision_id_conflict',
      );
    }
    if (
      recordedStatus === 'changes_requested' &&
      action !== 'request_changes'
    ) {
      throw new PublisherError(
        409,
        'This decisionId was already used for a different decision action.',
        'decision_id_conflict',
      );
    }
  }
}

function findRecordedDecision(
  decisionId,
  {
    action,
    requestFingerprint,
    existingDirectory,
    application,
    registration,
    parsedBundle,
    payload,
  },
) {
  const appOutcome = application?.decisionOutcomes?.[decisionId];
  const regOutcome = registration?.decisionOutcomes?.[decisionId];
  if (appOutcome && typeof appOutcome === 'object') {
    assertMatchingRecordedDecision({
      recordedAction: appOutcome.action,
      recordedFingerprint: appOutcome.requestFingerprint,
      recordedStatus: appOutcome.status,
      recordedExpectedRevision: appOutcome.expectedRevision,
      payloadExpectedRevision: payload.expectedRevision,
      action,
      requestFingerprint,
    });
  }
  if (regOutcome && typeof regOutcome === 'object') {
    assertMatchingRecordedDecision({
      recordedAction: regOutcome.action,
      recordedFingerprint: regOutcome.requestFingerprint,
      recordedStatus: regOutcome.status,
      recordedExpectedRevision: regOutcome.expectedRevision,
      payloadExpectedRevision: payload.expectedRevision,
      action,
      requestFingerprint,
    });
  }
  const fromOutcome = appOutcome ?? regOutcome;
  if (fromOutcome && typeof fromOutcome === 'object') {
    const status = fromOutcome.status ?? 'published';
    const isPublished = status === 'published';
    return {
      status,
      idempotent: true,
      version: isPublished
        ? Number(existingDirectory?.version ?? parsedBundle?.bundle_version ?? fromOutcome.version ?? 0)
        : Number(existingDirectory?.version ?? fromOutcome.version ?? 0),
      bundle: existingDirectory?.bundle ?? null,
      registrationId: fromOutcome.registrationId ?? registration?.registrationId ?? application?.registrationId ?? payload.registrationId ?? null,
      decisionId,
      writes: [],
    };
  }
  const appHistory = Array.isArray(application?.reviewHistory)
    ? application.reviewHistory.find((entry) => entry && entry.decisionId === decisionId)
    : null;
  const regHistory = Array.isArray(registration?.reviewHistory)
    ? registration.reviewHistory.find((entry) => entry && entry.decisionId === decisionId)
    : null;
  const matchedHistory = appHistory ?? regHistory;
  if (matchedHistory) {
    assertMatchingRecordedDecision({
      recordedAction: matchedHistory.action,
      recordedFingerprint: matchedHistory.requestFingerprint,
      recordedStatus: matchedHistory.status,
      action,
      requestFingerprint,
    });
    return {
      status: matchedHistory.status ?? 'published',
      idempotent: true,
      version: Number(existingDirectory?.version ?? parsedBundle?.bundle_version ?? 0),
      bundle: existingDirectory?.bundle ?? null,
      registrationId: registration?.registrationId ?? application?.registrationId ?? payload.registrationId ?? null,
      decisionId,
      writes: [],
    };
  }
  if (
    existingDirectory &&
    (existingDirectory.lastDecisionId === decisionId ||
      hasDecisionId(application, decisionId) ||
      hasDecisionId(registration, decisionId))
  ) {
    if (existingDirectory.lastDecisionId === decisionId) {
      assertMatchingRecordedDecision({
        recordedAction: existingDirectory.lastDecisionAction,
        recordedFingerprint: existingDirectory.lastDecisionFingerprint,
        action,
        requestFingerprint,
      });
    }
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
  return null;
}

function recordOutcome(doc, decisionId, outcome) {
  return {
    ...(doc?.decisionOutcomes && typeof doc.decisionOutcomes === 'object' ? doc.decisionOutcomes : {}),
    [decisionId]: outcome,
  };
}

function assertExpectedRevision(expectedRevision, currentRevision) {
  if (expectedRevision === undefined || expectedRevision === null) return;
  if (Number(expectedRevision) !== Number(currentRevision ?? 0)) {
    throw new PublisherError(
      409,
      'This registration changed while you were reviewing it. Refresh and try again.',
      'stale_revision',
    );
  }
}

function assertReviewedPhoneRequest(request, updateTime, payload) {
  if (
    !request ||
    !['submitted', 'approved_pending_publication'].includes(request.status) ||
    typeof payload.expectedRequestUpdateTime !== 'string' ||
    !payload.expectedRequestUpdateTime ||
    payload.expectedRequestUpdateTime !== updateTime ||
    !request.deviceRegistration ||
    !payload.deviceRegistration
  ) {
    throw new PublisherError(
      409,
      'This phone request changed or is no longer pending. Refresh and review it again.',
      'stale_request',
    );
  }
  const parseQr = (raw) => typeof raw === 'string' ? JSON.parse(raw) : raw;
  let matchingQr = false;
  try {
    matchingQr = canonicalJsonEncode(parseQr(request.deviceRegistration)) ===
      canonicalJsonEncode(parseQr(payload.deviceRegistration));
  } catch {
    // An unreadable current or reviewed QR cannot identify the reviewed request.
  }
  if (!matchingQr) {
    throw new PublisherError(
      409,
      'The pending phone QR differs from the reviewed QR. Refresh and review it again.',
      'stale_request',
    );
  }
}

function assertReviewedOldPhone(expected, current) {
  const strip = (value) => typeof value === 'string' ? value.trim().replace(/=+$/, '') : '';
  if (
    !expected ||
    typeof expected.deviceId !== 'string' ||
    !expected.deviceId.trim() ||
    expected.deviceId.trim().toLowerCase() !== current.deviceId.toLowerCase() ||
    !strip(expected.publicKey) ||
    strip(expected.publicKey) !== strip(current.publicKey) ||
    !strip(expected.signingPublicKey) ||
    strip(expected.signingPublicKey) !== strip(current.signingPublicKey) ||
    !Number.isInteger(expected.keyVersion) ||
    expected.keyVersion !== current.keyVersion
  ) {
    throw new PublisherError(
      409,
      'The current phone binding differs from the reviewed phone. Refresh and review it again.',
      'stale_phone_binding',
    );
  }
}

function unwrapSnapshot(doc, idFieldName) {
  if (!doc) return { exists: false, updateTime: null, fields: null };
  const isWrapped =
    typeof doc.fields === 'object' &&
    doc.fields !== null &&
    !Array.isArray(doc.fields) &&
    ('updateTime' in doc || 'id' in doc);
  const rawFields = isWrapped ? doc.fields : doc;
  const { updateTime: _legacyUpdateTime, ...clean } = rawFields;
  if (idFieldName && doc.id && !clean[idFieldName]) {
    clean[idFieldName] = doc.id;
  }
  return {
    exists: true,
    updateTime: doc.updateTime ?? null,
    fields: clean,
  };
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
  existingDirectory: existingDirectoryInput = null,
  application: applicationInput = null,
  registration: registrationInput = null,
  linkRequest: linkRequestInput = null,
  recoveryRequest: recoveryRequestInput = null,
  payload = {},
  now = new Date(),
}) {
  if (!reviewerUid) {
    throw new PublisherError(403, 'Reviewer authentication is required.', 'unauthenticated');
  }
  if (!decisionId || typeof decisionId !== 'string') {
    throw new PublisherError(400, 'A unique decisionId is required.', 'missing_decision_id');
  }
  const dirSnap = unwrapSnapshot(existingDirectoryInput);
  const appSnap = unwrapSnapshot(applicationInput, 'uid');
  const regSnap = unwrapSnapshot(registrationInput, 'registrationId');
  const linkSnap = unwrapSnapshot(linkRequestInput, 'accountUid');
  const recSnap = unwrapSnapshot(recoveryRequestInput, 'accountUid');

  const existingDirectory = dirSnap.fields;
  const application = appSnap.fields;
  const registration = regSnap.fields;
  const linkRequest = linkSnap.fields;
  const recoveryRequest = recSnap.fields;

  // A tombstone wins over old queued decisions, including previously completed approvals.
  const isDeleted = registration?.status === 'deleted' || application?.status === 'deleted';
  if (isDeleted && action !== 'delete_registration') {
    throw new PublisherError(409, 'Deleted registrations require explicit re-enrollment.', 'deleted_registration');
  }
  if (action === 'delete_registration') {
    if (typeof payload.registrationId !== 'string' || !payload.registrationId.trim()) {
      throw new PublisherError(400, 'A registrationId is required.', 'missing_registration_id');
    }
    const ids = [registration?.registrationId, application?.registrationId].filter(Boolean);
    const accounts = [payload.accountUid, payload.applicationUid, registration?.accountUid, application?.uid].filter(Boolean);
    if (
      ids.some((id) => id !== payload.registrationId) ||
      accounts.some((uid) => uid !== accounts[0]) ||
      (registration && application && !registration.accountUid && application.registrationId !== payload.registrationId) ||
      (!registration && !application && accounts.length > 0)
    ) {
      throw new PublisherError(409, 'Registration and account bindings do not match.', 'registration_binding_mismatch');
    }
    if (accounts.includes(reviewerUid)) {
      throw new PublisherError(403, 'Another reviewer must delete your registration.', 'self_review_forbidden');
    }
    if (!Number.isInteger(payload.expectedRevision) || payload.expectedRevision < 0) {
      throw new PublisherError(400, 'A reviewed expectedRevision is required.', 'missing_expected_revision');
    }
  }

  const rosterIndependentAction =
    action === 'request_changes' ||
    action === 'reject' ||
    action === 'decline_profile_change';
  const rawDelegation = publisherDelegation
    ? typeof publisherDelegation === 'string'
      ? JSON.parse(publisherDelegation)
      : publisherDelegation
    : null;
  const configuredRootPublicKey =
    rawDelegation?.root_issuer?.public_key ?? null;

  let parsedBundle = null;
  if (existingDirectory?.bundle) {
    parsedBundle = verifyTrustBundle(JSON.parse(existingDirectory.bundle), {
      expectedProject: directoryProject,
      expectedRootPublicKey: configuredRootPublicKey,
      now,
    });
  }

  // Idempotent retry check for same decisionId (before directory existence check).
  const requestFingerprint = computeDecisionFingerprint({
    action,
    payload,
    application,
    registration,
    linkRequest,
    recoveryRequest,
  });
  const recorded = findRecordedDecision(decisionId, {
    action,
    requestFingerprint,
    existingDirectory,
    application,
    registration,
    parsedBundle,
    payload,
  });
  if (recorded) {
    return recorded;
  }
  if (isDeleted) {
    throw new PublisherError(409, 'Registration has already been deleted.', 'deleted_registration');
  }

  let delegation = null;
  let publisherKeyPair = null;
  if (!rosterIndependentAction) {
    delegation = verifyPublisherDelegation(rawDelegation, {
      expectedProject: directoryProject,
      now,
    });
    publisherKeyPair = ed25519KeyPairFromSeed(publisherSeed);
    if (publisherKeyPair.publicKeyBase64Url !== delegation.publisher.public_key) {
      throw new PublisherError(500, 'Publisher seed does not match delegation public key.', 'server_key_mismatch');
    }
  }

  const targetAccountUid = action === 'delete_registration'
    ? (registration?.accountUid ?? application?.uid ?? payload.accountUid ?? payload.applicationUid ?? null)
    : (application?.uid ?? linkRequest?.accountUid ?? recoveryRequest?.accountUid ??
        registration?.accountUid ?? payload.accountUid ?? null);
  if (targetAccountUid && targetAccountUid === reviewerUid) {
    throw new PublisherError(403, 'Another reviewer must approve or update your own registration.', 'self_review_forbidden');
  }

  const role = payload.role === 'responder' ? 'responder' : 'civilian';
  const reason = String(payload.reason ?? '').trim();
  const nextRevision = action === 'delete_registration' || (action === 'approve_online' && payload.restoreRevoked === true)
    ? Math.max(Number(application?.revision ?? 0), Number(registration?.revision ?? 0),
        !application && !registration ? payload.expectedRevision : 0) + 1
    : Number(application?.revision ?? registration?.revision ?? 0) + 1;
  const historyEntry = {
    reviewerUid,
    action,
    requestFingerprint,
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
    if (application.status !== 'submitted') {
      throw new PublisherError(
        409,
        `Cannot ${action === 'reject' ? 'reject' : 'request changes for'} an application in state ${application.status}.`,
        'invalid_transition',
      );
    }
    assertExpectedRevision(payload.expectedRevision, application.revision);
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
      decisionOutcomes: recordOutcome(application, decisionId, {
        action,
        requestFingerprint,
        status: targetStatus,
        version: Number(existingDirectory?.version ?? 0),
        registrationId: application.registrationId ?? null,
        revision: nextRevision,
      }),
    };
    return {
      status: targetStatus,
      idempotent: false,
      version: Number(existingDirectory?.version ?? 0),
      bundle: existingDirectory?.bundle ?? null,
      registrationId: nextFields.registrationId ?? null,
      decisionId,
      writes: [
        {
          collection: 'pilotApplications',
          docId: application.uid,
          fields: nextFields,
          ...(appSnap.updateTime ? { updateTime: appSnap.updateTime } : {}),
        },
      ],
    };
  }

  const existingRegistrationId =
    payload.registrationId ??
    registration?.registrationId ??
    application?.registrationId ??
    null;

  if (action === 'decline_profile_change') {
    if (!application) {
      throw new PublisherError(404, 'Online application not found.', 'not_found');
    }
    if (
      application.status !== 'published' ||
      application.profileChange?.status !== 'submitted'
    ) {
      throw new PublisherError(
        409,
        'No submitted profile change is waiting for review.',
        'invalid_transition',
      );
    }
    assertExpectedRevision(payload.expectedRevision, application.revision);
    if (!reason) {
      throw new PublisherError(400, 'Enter a reason for declining this change.', 'missing_reason');
    }
    const nextFields = {
      ...application,
      profileChange: {
        ...application.profileChange,
        status: 'rejected',
        reviewerUid,
        reason,
      },
      revision: nextRevision,
      reviewHistory: [
        ...(application.reviewHistory ?? []),
        { ...historyEntry, status: 'rejected', action: 'decline_profile_change' },
      ],
      processedDecisionIds: [...(application.processedDecisionIds ?? []), decisionId],
      decisionOutcomes: recordOutcome(application, decisionId, {
        action,
        requestFingerprint,
        status: 'rejected',
        version: Number(existingDirectory?.version ?? 0),
        registrationId: existingRegistrationId,
        revision: nextRevision,
      }),
    };
    return {
      status: 'rejected',
      idempotent: false,
      version: Number(existingDirectory?.version ?? 0),
      bundle: existingDirectory?.bundle ?? null,
      registrationId: existingRegistrationId,
      decisionId,
      writes: [
        {
          collection: 'pilotApplications',
          docId: application.uid,
          fields: nextFields,
          ...(appSnap.updateTime ? { updateTime: appSnap.updateTime } : {}),
        },
      ],
    };
  }

  const { approved, revoked } = normalizeDevicesFromBundle(parsedBundle);
  const nextVersion = Number(existingDirectory?.version ?? 0) + 1;
  const nowIso = now.toISOString();
  const writes = [];
  let registrationId = existingRegistrationId ?? `reg-${crypto.randomUUID()}`;
  let directoryOwnerFields = {};

  if (action === 'delete_registration') {
    if (registration || application) {
      assertExpectedRevision(payload.expectedRevision, registration?.revision ?? application?.revision ?? 0);
    }
    let phone = null;
    if (registration) {
      // Never substitute caller keys or an application proposal for the campus binding.
      if (registration.deviceRegistration ||
          (registration.deviceId && registration.publicKey && registration.signingPublicKey)) {
        phone = resolveRegistrationPhone(registration);
      }
    } else if (application?.deviceRegistration) {
      phone = verifyDeviceRegistrationQr(application.deviceRegistration);
    } else if (!application) {
      if (!payload.deviceRegistration) {
        throw new PublisherError(404, 'Registration record not found.', 'not_found');
      }
      phone = verifyDeviceRegistrationQr(payload.deviceRegistration);
      if (!approved.has(phone.deviceId.toLowerCase())) {
        throw new PublisherError(404, 'Local phone is not in the signed approved directory.', 'not_found');
      }
    }
    if (phone) {
      const keyLower = phone.deviceId.toLowerCase();
      const strip = (value) => String(value ?? '').trim().replace(/=+$/, '');
      const matches = (entry) => !entry || (
        strip(entry.public_key) === strip(phone.publicKey) &&
        strip(entry.signing_public_key) === strip(phone.signingPublicKey) &&
        Number(entry.key_version) === phone.keyVersion
      );
      if (!matches(approved.get(keyLower)) || !matches(revoked.get(keyLower))) {
        throw new PublisherError(409, 'Directory keys do not match the current phone binding.', 'phone_binding_mismatch');
      }
      const oldEntry = approved.get(keyLower) ?? revoked.get(keyLower);
      approved.delete(keyLower);
      // Keep existing revocations (including all retired phones) unchanged.
      if (!revoked.has(keyLower)) {
        revoked.set(keyLower, {
          device_id: phone.deviceId,
          owner_name: registration?.displayName ?? application?.displayName ?? oldEntry?.owner_name ?? 'Deleted registration',
          role: registration?.role ?? oldEntry?.role ?? role,
          status: 'revoked',
          public_key: phone.publicKey,
          signing_public_key: phone.signingPublicKey,
          key_version: phone.keyVersion,
          updated_at: nowIso,
        });
      }
    }
    const outcome = {
      action, status: 'published', targetStatus: 'deleted', version: nextVersion,
      registrationId, revision: nextRevision, expectedRevision: payload.expectedRevision,
    };
    const cancel = (request) => ({ ...request, status: 'deleted', reviewerUid, reason, updatedAt: nowIso });
    const tombstone = (record) => ({
      ...(record ?? {}), registrationId, status: 'deleted', publicationStatus: 'published',
      revision: nextRevision, deletedAt: nowIso, deletedBy: reviewerUid, deletionReason: reason,
      updatedAt: nowIso,
      ...(record?.profileChange ? { profileChange: cancel(record.profileChange) } : {}),
      ...(record?.replacementRequest ? { replacementRequest: cancel(record.replacementRequest) } : {}),
      reviewHistory: [...(record?.reviewHistory ?? []), { ...historyEntry, targetStatus: 'deleted' }],
      processedDecisionIds: [...(record?.processedDecisionIds ?? []), decisionId],
      decisionOutcomes: recordOutcome(record, decisionId, outcome),
    });
    writes.push({
      collection: 'campusRegistrations', docId: registrationId,
      fields: {
        ...tombstone(registration),
        ...(targetAccountUid ? { accountUid: targetAccountUid } : {}),
        ...(!registration && phone ? {
          deviceId: phone.deviceId, publicKey: phone.publicKey, signingPublicKey: phone.signingPublicKey,
          keyVersion: phone.keyVersion, deviceRegistration: application?.deviceRegistration ?? payload.deviceRegistration,
        } : {}),
      },
      ...(regSnap.updateTime ? { updateTime: regSnap.updateTime } : { createOnly: true }),
    });
    if (targetAccountUid) {
      writes.push({
        collection: 'pilotApplications', docId: targetAccountUid,
        fields: { ...tombstone(application), uid: targetAccountUid },
        ...(appSnap.updateTime ? { updateTime: appSnap.updateTime } : { createOnly: true }),
      });
    }
    for (const [collection, snap] of [
      ['registrationLinkRequests', linkSnap], ['registrationRecoveryRequests', recSnap],
    ]) {
      const request = snap.fields;
      if (request?.accountUid && (
        request.registrationId === registrationId ||
        (!request.registrationId && request.accountUid === targetAccountUid)
      )) {
        writes.push({
          collection, docId: request.accountUid, fields: cancel(request),
          ...(snap.updateTime ? { updateTime: snap.updateTime } : { createOnly: true }),
        });
      }
    }
    directoryOwnerFields = { registrationId, ...(targetAccountUid ? { applicationUid: targetAccountUid } : {}) };
  } else if (action === 'approve_online') {
    if (!application) {
      throw new PublisherError(404, 'Application not found.', 'not_found');
    }
    const restoring = payload.restoreRevoked === true;
    if (restoring && (
      application.status !== 'published' || registration?.status !== 'revoked' ||
      registration.registrationId !== registrationId || application.registrationId !== registrationId ||
      registration.accountUid !== application.uid ||
      !Number.isInteger(payload.expectedRevision) || payload.expectedRevision < 0 ||
      !regSnap.updateTime || payload.expectedRegistrationUpdateTime !== regSnap.updateTime
    )) {
      throw new PublisherError(409, 'The revoked registration changed. Refresh and review it again.', 'stale_restoration');
    }
    if (!restoring && (
      application.status !== 'submitted' &&
      application.status !== 'approved_pending_publication'
    )) {
      throw new PublisherError(
        409,
        `Cannot publish online approval from application state ${application.status}.`,
        'invalid_transition',
      );
    }
    assertExpectedRevision(payload.expectedRevision, application.revision);
    const reviewed = buildIdentityFieldsPayload(payload.reviewedFields ?? application);
    const verifiedPhone = verifyDeviceRegistrationQr(application.deviceRegistration);
    const keyLower = verifiedPhone.deviceId.toLowerCase();
    if (restoring) {
      const storedPhone = resolveRegistrationPhone(registration);
      assertReviewedOldPhone(payload.expectedOldPhone, storedPhone);
      assertReviewedOldPhone(verifiedPhone, storedPhone);
      const entry = revoked.get(keyLower);
      if (!entry) {
        throw new PublisherError(409, 'The reviewed phone is no longer revoked. Refresh before restoring access.', 'stale_restoration');
      }
      assertReviewedOldPhone(payload.expectedOldPhone, {
        deviceId: entry.device_id, publicKey: entry.public_key,
        signingPublicKey: entry.signing_public_key, keyVersion: entry.key_version,
      });
    } else if (revoked.has(keyLower)) {
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
    const publishedOutcome = {
      action,
      status: 'published',
      version: nextVersion,
      registrationId,
      revision: nextRevision,
    };
    const nextApp = {
      ...application,
      ...reviewed,
      registrationId,
      status: 'published',
      publicationStatus: 'published',
      revision: nextRevision,
      reviewHistory: [...(application.reviewHistory ?? []), historyEntry],
      processedDecisionIds: [...(application.processedDecisionIds ?? []), decisionId],
      decisionOutcomes: recordOutcome(application, decisionId, publishedOutcome),
    };
    writes.push({
      collection: 'pilotApplications',
      docId: application.uid,
      fields: nextApp,
      ...(appSnap.updateTime ? { updateTime: appSnap.updateTime } : {}),
    });
    writes.push({
      collection: 'campusRegistrations',
      docId: registrationId,
      fields: {
        ...(restoring ? registration : {}),
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
        ...(restoring ? {
          revision: nextRevision,
          reviewHistory: [...(registration.reviewHistory ?? []), historyEntry],
        } : {}),
        processedDecisionIds: [...(registration?.processedDecisionIds ?? []), decisionId],
        decisionOutcomes: recordOutcome(registration, decisionId, publishedOutcome),
        updatedAt: nowIso,
      },
      ...(regSnap.updateTime ? { updateTime: regSnap.updateTime } : { createOnly: true }),
    });
  } else if (action === 'sync_offline_decision') {
    if (!registration) {
      throw new PublisherError(400, 'Registration record is required.', 'missing_registration');
    }
    assertExpectedRevision(payload.expectedRevision, registration.revision);
    const reviewed = buildIdentityFieldsPayload(payload.reviewedFields ?? registration);
    const verifiedPhone = verifyDeviceRegistrationQr(
      registration.deviceRegistration ?? payload.deviceRegistration,
    );
    const keyLower = verifiedPhone.deviceId.toLowerCase();
    let targetRevoke;
    if (payload.targetStatus === 'revoked') {
      targetRevoke = true;
    } else if (
      payload.targetStatus === 'published' ||
      payload.targetStatus === 'approved' ||
      payload.targetStatus === 'approved_local'
    ) {
      targetRevoke = false;
    } else if (
      payload.targetStatus !== undefined &&
      payload.targetStatus !== null &&
      payload.targetStatus !== ''
    ) {
      throw new PublisherError(
        400,
        `Unsupported target status: ${payload.targetStatus}`,
        'invalid_target_status',
      );
    } else {
      targetRevoke = registration.status === 'revoked';
    }
    const currentDirectoryVersion = Number(
      existingDirectory?.version ?? parsedBundle?.bundle_version ?? 0,
    );
    if (
      payload.expectedConflictVersion !== undefined &&
      payload.expectedConflictVersion !== null &&
      Number(payload.expectedConflictVersion) < currentDirectoryVersion
    ) {
      throw new PublisherError(
        409,
        'A newer published directory version exists since this conflict was reviewed.',
        'stale_conflict_resolution',
      );
    }
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
        decisionOutcomes: recordOutcome(registration, decisionId, {
          action,
          status: 'published',
          targetStatus: targetRevoke ? 'revoked' : 'published',
          version: nextVersion,
          registrationId,
          revision: nextRevision,
        }),
        updatedAt: nowIso,
      },
      ...(regSnap.updateTime ? { updateTime: regSnap.updateTime } : { createOnly: true }),
    });
  } else if (action === 'approve_link') {
    if (!linkRequest || !registration) {
      throw new PublisherError(404, 'Link request or registration not found.', 'not_found');
    }
    const phone = resolveRegistrationPhone(registration);
    const keyLower = phone.deviceId.toLowerCase();
    if (registration.status === 'revoked' || revoked.has(keyLower)) {
      throw new PublisherError(
        409,
        'Revoked phones cannot be linked without an explicit re-approval.',
        'revoked_registration',
      );
    }
    if (
      registration.accountUid &&
      registration.accountUid !== linkRequest.accountUid
    ) {
      throw new PublisherError(
        409,
        'This phone registration is already linked to another account.',
        'already_linked',
      );
    }
    verifyAccountLinkProof(linkRequest, {
      expectedRegistrationId: registration.registrationId,
      expectedAccountUid: linkRequest.accountUid,
      expectedPhone: phone,
      expectedProject: directoryProject,
    });
    const reviewed = buildIdentityFieldsPayload(payload.reviewedFields ?? registration);
    revoked.delete(keyLower);
    approved.set(keyLower, {
      device_id: phone.deviceId,
      owner_name: reviewed.displayName,
      role,
      status: 'approved',
      public_key: phone.publicKey,
      signing_public_key: phone.signingPublicKey,
      key_version: phone.keyVersion,
      updated_at: nowIso,
    });
    directoryOwnerFields = { applicationUid: linkRequest.accountUid, registrationId };
    writes.push({
      collection: 'registrationLinkRequests',
      docId: linkRequest.accountUid,
      fields: { ...linkRequest, status: 'linked', reviewerUid },
      ...(linkSnap.updateTime ? { updateTime: linkSnap.updateTime } : {}),
    });
    const linkOutcome = {
      action,
      status: 'published',
      version: nextVersion,
      registrationId,
      revision: nextRevision,
    };
    writes.push({
      collection: 'campusRegistrations',
      docId: registrationId,
      fields: {
        ...registration,
        ...reviewed,
        deviceId: phone.deviceId,
        publicKey: phone.publicKey,
        signingPublicKey: phone.signingPublicKey,
        keyVersion: phone.keyVersion,
        accountUid: linkRequest.accountUid,
        status: 'published',
        processedDecisionIds: [...(registration.processedDecisionIds ?? []), decisionId],
        decisionOutcomes: recordOutcome(registration, decisionId, linkOutcome),
        updatedAt: nowIso,
      },
      ...(regSnap.updateTime ? { updateTime: regSnap.updateTime } : { createOnly: true }),
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
        decisionOutcomes: recordOutcome(application, decisionId, linkOutcome),
      },
      ...(appSnap.updateTime ? { updateTime: appSnap.updateTime } : { createOnly: true }),
    });
  } else if (action === 'approve_replacement' || action === 'approve_recovery') {
    const isRecovery = action === 'approve_recovery';
    assertReviewedPhoneRequest(
      isRecovery ? recoveryRequest : application?.replacementRequest,
      isRecovery ? recSnap.updateTime : appSnap.updateTime,
      payload,
    );
    const newQrRaw = payload.deviceRegistration;
    const newPhone = verifyDeviceRegistrationQr(newQrRaw);
    let oldPhone = null;
    if (registration) {
      const fallbackQr = registration.deviceRegistration ?? application?.deviceRegistration;
      oldPhone = resolveRegistrationPhone(
        fallbackQr && !registration.deviceRegistration
          ? { ...registration, deviceRegistration: fallbackQr }
          : registration,
      );
    } else if (application?.deviceRegistration) {
      oldPhone = verifyDeviceRegistrationQr(application.deviceRegistration);
    }
    if (!oldPhone) {
      throw new PublisherError(404, 'Existing registration phone record not found.', 'not_found');
    }
    assertReviewedOldPhone(payload.expectedOldPhone, oldPhone);
    const oldIdLower = String(oldPhone.deviceId).toLowerCase();
    const newIdLower = newPhone.deviceId.toLowerCase();
    const sameId = oldIdLower === newIdLower;
    const nextKeyVersion = newPhone.keyVersion;
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
    revoked.delete(newIdLower);
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
    const replaceOutcome = {
      action,
      status: 'published',
      version: nextVersion,
      registrationId,
      revision: nextRevision,
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
        revision: nextRevision,
        retiredKeys: [...(registration?.retiredKeys ?? []), retiredRecord],
        processedDecisionIds: [...(registration?.processedDecisionIds ?? []), decisionId],
        decisionOutcomes: recordOutcome(registration, decisionId, replaceOutcome),
        updatedAt: nowIso,
      },
      ...(regSnap.updateTime ? { updateTime: regSnap.updateTime } : { createOnly: true }),
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
          decisionOutcomes: recordOutcome(application, decisionId, replaceOutcome),
        },
        ...(appSnap.updateTime ? { updateTime: appSnap.updateTime } : { createOnly: true }),
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
        ...(recSnap.updateTime ? { updateTime: recSnap.updateTime } : {}),
      });
    }
  } else if (action === 'approve_profile_change') {
    if (!application) {
      throw new PublisherError(404, 'Online application not found.', 'not_found');
    }
    if (application.status !== 'published') {
      throw new PublisherError(
        409,
        'Only published registrations can publish profile changes.',
        'invalid_transition',
      );
    }
    const pendingChange = application.profileChange;
    if (
      !pendingChange ||
      (pendingChange.status !== 'submitted' &&
        pendingChange.status !== 'approved_pending_publication')
    ) {
      throw new PublisherError(
        409,
        'No submitted profile change is waiting for review.',
        'invalid_transition',
      );
    }
    assertExpectedRevision(payload.expectedRevision, application.revision);
    const mergedFields = {
      ...application,
      ...pendingChange,
      ...(payload.reviewedFields ?? {}),
    };
    const reviewed = buildIdentityFieldsPayload(mergedFields);
    const phone = registration
      ? resolveRegistrationPhone(registration)
      : (() => {
          const verifiedQr = verifyDeviceRegistrationQr(application.deviceRegistration);
          return {
            deviceId: verifiedQr.deviceId,
            publicKey: verifiedQr.publicKey,
            signingPublicKey: verifiedQr.signingPublicKey,
            keyVersion: verifiedQr.keyVersion,
          };
        })();
    const keyLower = phone.deviceId.toLowerCase();
    if (registration?.status === 'revoked' || revoked.has(keyLower)) {
      throw new PublisherError(
        409,
        'Revoked phones cannot publish profile changes.',
        'revoked_registration',
      );
    }
    const existingApproved = approved.get(keyLower);
    const effectiveRole =
      payload.role === 'responder'
        ? 'responder'
        : payload.role === 'civilian'
          ? 'civilian'
          : (registration?.role ?? existingApproved?.role ?? 'civilian');
    revoked.delete(keyLower);
    approved.set(keyLower, {
      device_id: phone.deviceId,
      owner_name: reviewed.displayName,
      role: effectiveRole,
      status: 'approved',
      public_key: phone.publicKey,
      signing_public_key: phone.signingPublicKey,
      key_version: phone.keyVersion,
      updated_at: nowIso,
    });
    directoryOwnerFields = {
      applicationUid: application.uid,
      registrationId,
    };
    const changeOutcome = {
      action,
      status: 'published',
      version: nextVersion,
      registrationId,
      revision: nextRevision,
    };
    writes.push({
      collection: 'pilotApplications',
      docId: application.uid,
      fields: {
        ...application,
        ...reviewed,
        registrationId,
        profileChange: {
          ...pendingChange,
          ...reviewed,
          status: 'published',
          reviewerUid,
        },
        revision: nextRevision,
        reviewHistory: [
          ...(application.reviewHistory ?? []),
          { ...historyEntry, role: effectiveRole, action: 'approve_profile_change' },
        ],
        processedDecisionIds: [...(application.processedDecisionIds ?? []), decisionId],
        decisionOutcomes: recordOutcome(application, decisionId, changeOutcome),
      },
      ...(appSnap.updateTime ? { updateTime: appSnap.updateTime } : {}),
    });
    writes.push({
      collection: 'campusRegistrations',
      docId: registrationId,
      fields: {
        ...(registration ?? {}),
        ...reviewed,
        registrationId,
        source: registration?.source ?? 'online',
        status: 'published',
        role: effectiveRole,
        accountUid: application.uid,
        ...(application.deviceRegistration
          ? { deviceRegistration: application.deviceRegistration }
          : {}),
        deviceId: phone.deviceId,
        publicKey: phone.publicKey,
        signingPublicKey: phone.signingPublicKey,
        keyVersion: phone.keyVersion,
        processedDecisionIds: [...(registration?.processedDecisionIds ?? []), decisionId],
        decisionOutcomes: recordOutcome(registration, decisionId, changeOutcome),
        updatedAt: nowIso,
      },
      ...(regSnap.updateTime ? { updateTime: regSnap.updateTime } : { createOnly: true }),
    });
  } else {
    throw new PublisherError(400, `Unsupported publisher action: ${action}`, 'unsupported_action');
  }

  for (const w of writes) {
    const outcomes = w.fields?.decisionOutcomes;
    if (outcomes && typeof outcomes === 'object' && outcomes[decisionId]) {
      outcomes[decisionId] = {
        ...outcomes[decisionId],
        action: outcomes[decisionId].action ?? action,
        requestFingerprint,
      };
    }
    if (Array.isArray(w.fields?.reviewHistory)) {
      w.fields.reviewHistory = w.fields.reviewHistory.map((entry) =>
        entry && entry.decisionId === decisionId
          ? { action, requestFingerprint, ...entry }
          : entry,
      );
    }
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
      lastDecisionAction: action,
      lastDecisionFingerprint: requestFingerprint,
      publishedAt: nowIso,
    },
    ...(dirSnap.updateTime
      ? { updateTime: dirSnap.updateTime }
      : { createOnly: true }),
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
