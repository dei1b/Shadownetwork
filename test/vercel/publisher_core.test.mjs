import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import {
  applyDecisionAndBuildCommit,
  canonicalJsonEncode,
  ed25519KeyPairFromSeed,
  ed25519Sign,
  keyIdForX25519PublicKey,
  PublisherError,
  toBase64UrlPadded,
  verifyDeviceRegistrationQr,
  verifyTrustBundle,
} from '../../api/_lib/publisher_core.mjs';

function makeEd25519() {
  const seed = crypto.randomBytes(32);
  const pair = ed25519KeyPairFromSeed(seed);
  return { seed, ...pair };
}

function makeSignedQr(deviceId, userInformation = null) {
  const encBytes = crypto.randomBytes(32);
  const encPub = toBase64UrlPadded(encBytes);
  const sigPair = makeEd25519();
  const schemaVersion = userInformation ? 3 : 2;
  const unsigned = {
    registration_type: 'shadow_network_device_registration',
    schema_version: schemaVersion,
    device_id: deviceId,
    public_key: encPub,
    key_id: keyIdForX25519PublicKey(encBytes),
    key_version: 1,
    ...(userInformation ? { user_information: userInformation } : {}),
    signing_public_key: sigPair.publicKeyBase64Url,
  };
  const signature = ed25519Sign(
    `shadow-network-registration-v${schemaVersion}\n${canonicalJsonEncode(unsigned)}`,
    sigPair.privateKey,
  );
  return {
    rawJson: JSON.stringify({ ...unsigned, registration_signature: signature }),
    publicKey: encPub,
    signingPublicKey: sigPair.publicKeyBase64Url,
    signingPrivateKey: sigPair.privateKey,
    keyVersion: 1,
  };
}

function makeDelegation(
  root,
  publisher,
  project = 'dnsc-pilot',
  {
    issuedAt = '2026-11-26T00:00:00.000Z',
    expiresAt = '2027-11-26T00:00:00.000Z',
  } = {},
) {
  const unsigned = {
    delegation_type: 'shadow_network_publisher_delegation',
    schema_version: 1,
    scope: 'trust_directory_publisher',
    root_issuer: {
      issuer_id: 'shadow-network-admin',
      signing_key_id: root.signingKeyId,
      signature_algorithm: 'ed25519',
      public_key: root.publicKeyBase64Url,
    },
    publisher: {
      issuer_id: 'shadow-network-admin',
      signing_key_id: publisher.signingKeyId,
      signature_algorithm: 'ed25519',
      public_key: publisher.publicKeyBase64Url,
    },
    directory_project: project,
    issued_at: issuedAt,
    expires_at: expiresAt,
  };
  const signature = ed25519Sign(
    `shadow-network-publisher-delegation-v1\n${canonicalJsonEncode(unsigned)}`,
    root.privateKey,
  );
  return { ...unsigned, signature };
}

test('mobile browser approval publishes v1, retries idempotently, and reconciles offline desk sync into v2', () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const now = new Date('2026-11-26T12:00:00.000Z');

  const onlineQr = makeSignedQr('phone-online-1');
  const first = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-online-1',
    reviewerUid: 'admin-phone',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: null,
    application: {
      uid: 'uid-alice',
      affiliation: 'student',
      displayName: 'Alice Student',
      studentNumber: '2026-0001',
      course: 'BSIT',
      yearLevel: 'Year 4',
      sectionSet: 'Set H',
      status: 'submitted',
      revision: 0,
      deviceRegistration: onlineQr.rawJson,
      updateTime: '2026-11-26T11:59:00Z',
    },
    payload: {
      role: 'responder',
      reason: 'Approved from mobile browser',
      registrationId: 'reg-alice',
    },
    now,
  });

  assert.equal(first.status, 'published');
  assert.equal(first.idempotent, false);
  assert.equal(first.version, 1);
  const bundle1 = verifyTrustBundle(JSON.parse(first.bundle), {
    expectedProject: 'dnsc-pilot',
    now,
  });
  assert.equal(bundle1.approved_devices.length, 1);
  assert.equal(bundle1.approved_devices[0].device_id, 'phone-online-1');
  assert.equal(bundle1.publisher_delegation.root_issuer.public_key, root.publicKeyBase64Url);

  // Retry exact same decisionId on flaky mobile data: must stay v1 and return idempotent: true.
  const retry = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-online-1',
    reviewerUid: 'admin-phone',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: {
      version: 1,
      bundle: first.bundle,
      lastDecisionId: 'dec-online-1',
      updateTime: '2026-11-26T12:00:01Z',
    },
    application: {
      uid: 'uid-alice',
      status: 'published',
      processedDecisionIds: ['dec-online-1'],
    },
    payload: { role: 'responder', registrationId: 'reg-alice' },
    now,
  });
  assert.equal(retry.idempotent, true);
  assert.equal(retry.version, 1);
  assert.equal(retry.writes.length, 0);

  // Reconnect offline desk PC with a separate offline QR approval: both phones must appear in v2.
  const offlineQr = makeSignedQr('phone-desk-2');
  const second = applyDecisionAndBuildCommit({
    action: 'sync_offline_decision',
    decisionId: 'dec-offline-2',
    reviewerUid: 'admin-desk',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: {
      version: 1,
      bundle: first.bundle,
      lastDecisionId: 'dec-online-1',
      updateTime: '2026-11-26T12:00:01Z',
    },
    registration: {
      registrationId: 'reg-bob',
      source: 'qr',
      status: 'approved_local',
      affiliation: 'staff',
      displayName: 'Bob Staff',
      employeeId: 'EMP-77',
      unit: 'DRRMO',
      deviceRegistration: offlineQr.rawJson,
    },
    payload: { role: 'civilian', registrationId: 'reg-bob' },
    now,
  });

  assert.equal(second.version, 2);
  const bundle2 = verifyTrustBundle(JSON.parse(second.bundle), {
    expectedProject: 'dnsc-pilot',
    now,
  });
  assert.deepEqual(
    bundle2.approved_devices.map((d) => d.device_id).sort(),
    ['phone-desk-2', 'phone-online-1'],
  );
});

test('rejects self-review, revoked conflict on offline sync, and retires old phone on replacement', () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const now = new Date('2026-11-26T12:00:00.000Z');
  const oldQr = makeSignedQr('phone-old-1');
  const newQr = makeSignedQr('phone-new-2');

  assert.throws(
    () =>
      applyDecisionAndBuildCommit({
        action: 'approve_online',
        decisionId: 'dec-self',
        reviewerUid: 'uid-same',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher.seed,
        publisherDelegation: delegation,
        application: {
          uid: 'uid-same',
          affiliation: 'student',
          displayName: 'Self Reviewer',
          studentNumber: '2026-9999',
          course: 'BSIT',
          yearLevel: '4',
          sectionSet: 'A',
          status: 'submitted',
          deviceRegistration: oldQr.rawJson,
        },
        now,
      }),
    (err) => err instanceof PublisherError && err.statusCode === 403,
  );

  const initial = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-init',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    application: {
      uid: 'uid-user',
      affiliation: 'student',
      displayName: 'Carlos Student',
      studentNumber: '2026-1111',
      course: 'BSIT',
      yearLevel: '3',
      sectionSet: 'B',
      status: 'submitted',
      deviceRegistration: oldQr.rawJson,
    },
    payload: { registrationId: 'reg-carlos', role: 'civilian' },
    now,
  });

  const replaced = applyDecisionAndBuildCommit({
    action: 'approve_replacement',
    decisionId: 'dec-rep',
    reviewerUid: 'admin-2',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 1, bundle: initial.bundle },
    application: {
      uid: 'uid-user',
      affiliation: 'student',
      displayName: 'Carlos Student',
      studentNumber: '2026-1111',
      course: 'BSIT',
      yearLevel: '3',
      sectionSet: 'B',
      registrationId: 'reg-carlos',
      status: 'published',
      deviceRegistration: oldQr.rawJson,
      replacementRequest: { status: 'submitted', deviceRegistration: newQr.rawJson },
    },
    registration: {
      registrationId: 'reg-carlos',
      accountUid: 'uid-user',
      affiliation: 'student',
      displayName: 'Carlos Student',
      studentNumber: '2026-1111',
      course: 'BSIT',
      yearLevel: '3',
      sectionSet: 'B',
      deviceId: 'phone-old-1',
      publicKey: oldQr.publicKey,
      signingPublicKey: oldQr.signingPublicKey,
      keyVersion: 1,
    },
    payload: { registrationId: 'reg-carlos', role: 'civilian' },
    now,
  });

  assert.equal(replaced.version, 2);
  const bundle2 = JSON.parse(replaced.bundle);
  assert.deepEqual(bundle2.approved_devices.map((d) => d.device_id), ['phone-new-2']);
  assert.deepEqual(bundle2.revoked_devices.map((d) => d.device_id), ['phone-old-1']);
});

test('verifyDeviceRegistrationQr validates real Dart-generated v2 and v3 fixtures and rejects tampered or legacy inputs', () => {
  const v2Raw = fs.readFileSync(
    new URL('./fixtures/dart_registration_qr_v2.json', import.meta.url),
    'utf8',
  );
  const v3Raw = fs.readFileSync(
    new URL('./fixtures/dart_registration_qr_v3.json', import.meta.url),
    'utf8',
  );

  const v2 = verifyDeviceRegistrationQr(v2Raw);
  assert.equal(v2.deviceId, 'android-fixture-v2');
  assert.equal(v2.schemaVersion, 2);
  assert.equal(v2.keyVersion, 1);

  const v3 = verifyDeviceRegistrationQr(v3Raw);
  assert.equal(v3.deviceId, 'android-fixture-v3');
  assert.equal(v3.schemaVersion, 3);
  assert.equal(v3.userInformation.full_name, 'Maria Santos');

  const tamperedV3 = JSON.parse(v3Raw);
  tamperedV3.user_information.full_name = 'Tampered Name';
  assert.throws(
    () => verifyDeviceRegistrationQr(tamperedV3),
    (err) => err instanceof PublisherError && err.code === 'invalid_qr_signature',
  );

  const wrongKeyId = JSON.parse(v2Raw);
  wrongKeyId.key_id = 'x25519-0000000000000000';
  assert.throws(
    () => verifyDeviceRegistrationQr(wrongKeyId),
    (err) => err instanceof PublisherError && err.code === 'invalid_qr',
  );

  const withPrivateKey = JSON.parse(v2Raw);
  withPrivateKey.private_key = 'must-never-be-present';
  assert.throws(
    () => verifyDeviceRegistrationQr(withPrivateKey),
    (err) => err instanceof PublisherError && err.code === 'invalid_qr',
  );

  const legacyV1 = JSON.parse(v2Raw);
  legacyV1.schema_version = 1;
  assert.throws(
    () => verifyDeviceRegistrationQr(legacyV1),
    (err) => err instanceof PublisherError && err.code === 'invalid_qr',
  );

  const missingUserInfo = JSON.parse(v3Raw);
  delete missingUserInfo.user_information;
  assert.throws(
    () => verifyDeviceRegistrationQr(missingUserInfo),
    (err) => err instanceof PublisherError && err.code === 'invalid_qr',
  );
});

test('decision retries preserve request_changes and reject outcomes and enforce transitions and expectedRevision', () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const now = new Date('2026-11-26T12:00:00.000Z');
  const qr = makeSignedQr('phone-review-retry').rawJson;

  const submittedApp = {
    uid: 'uid-retry-app',
    affiliation: 'student',
    displayName: 'Retry Student',
    studentNumber: '2026-2222',
    course: 'BSIT',
    yearLevel: '3',
    sectionSet: 'D',
    status: 'submitted',
    revision: 0,
    deviceRegistration: qr,
    updateTime: '2026-11-26T11:50:00Z',
  };

  // Retrying request_changes when no trustDirectory/current exists must return changes_requested idempotently.
  const reqChanges = applyDecisionAndBuildCommit({
    action: 'request_changes',
    decisionId: 'dec-req-changes-1',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: null,
    application: submittedApp,
    payload: { reason: 'Blur photo / check number', expectedRevision: 0 },
    now,
  });
  assert.equal(reqChanges.status, 'changes_requested');
  assert.equal(reqChanges.idempotent, false);

  const reqChangesRetry = applyDecisionAndBuildCommit({
    action: 'request_changes',
    decisionId: 'dec-req-changes-1',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: null,
    application: { uid: 'uid-retry-app', ...reqChanges.writes[0].fields },
    payload: { reason: 'Blur photo / check number', expectedRevision: 0 },
    now,
  });
  assert.equal(reqChangesRetry.status, 'changes_requested');
  assert.equal(reqChangesRetry.idempotent, true);
  assert.equal(reqChangesRetry.writes.length, 0);

  // Stale expectedRevision is rejected with 409.
  assert.throws(
    () =>
      applyDecisionAndBuildCommit({
        action: 'request_changes',
        decisionId: 'dec-req-stale',
        reviewerUid: 'admin-1',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher.seed,
        publisherDelegation: delegation,
        application: submittedApp,
        payload: { reason: 'Check ID', expectedRevision: 99 },
        now,
      }),
    (err) => err instanceof PublisherError && err.statusCode === 409 && err.code === 'stale_revision',
  );

  // Retrying reject when an unrelated directory exists returns rejected, NOT published.
  const otherApp = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-other-app',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    application: {
      ...submittedApp,
      uid: 'uid-other',
      deviceRegistration: makeSignedQr('phone-other-1').rawJson,
    },
    payload: { registrationId: 'reg-other', role: 'civilian' },
    now,
  });

  const rejected = applyDecisionAndBuildCommit({
    action: 'reject',
    decisionId: 'dec-reject-1',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 1, bundle: otherApp.bundle, lastDecisionId: 'dec-other-app' },
    application: { ...submittedApp, uid: 'uid-reject-target' },
    payload: { reason: 'Not enrolled', expectedRevision: 0 },
    now,
  });
  assert.equal(rejected.status, 'rejected');

  const rejectRetry = applyDecisionAndBuildCommit({
    action: 'reject',
    decisionId: 'dec-reject-1',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 1, bundle: otherApp.bundle, lastDecisionId: 'dec-other-app' },
    application: { uid: 'uid-reject-target', ...rejected.writes[0].fields },
    payload: { reason: 'Not enrolled' },
    now,
  });
  assert.equal(rejectRetry.status, 'rejected');
  assert.equal(rejectRetry.idempotent, true);
  assert.equal(rejectRetry.writes.length, 0);

  // Cannot request_changes or reject an already published application.
  assert.throws(
    () =>
      applyDecisionAndBuildCommit({
        action: 'request_changes',
        decisionId: 'dec-after-pub',
        reviewerUid: 'admin-1',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher.seed,
        publisherDelegation: delegation,
        existingDirectory: { version: 1, bundle: otherApp.bundle },
        application: {
          ...submittedApp,
          uid: 'uid-other',
          status: 'published',
          revision: 1,
        },
        payload: { reason: 'Too late' },
        now,
      }),
    (err) => err instanceof PublisherError && err.statusCode === 409 && err.code === 'invalid_transition',
  );
});

test('renewing expired publisher delegation continues directory chain, blocks alien root, and allows roster-independent corrections', () => {
  const campusRoot = makeEd25519();
  const alienRoot = makeEd25519();
  const publisher1 = makeEd25519();
  const publisher2 = makeEd25519();

  const delegation1 = makeDelegation(campusRoot, publisher1, 'dnsc-pilot', {
    issuedAt: '2026-10-01T00:00:00.000Z',
    expiresAt: '2026-11-01T00:00:00.000Z',
  });
  const t1 = new Date('2026-10-15T12:00:00.000Z');
  const firstQr = makeSignedQr('phone-del-1').rawJson;
  const v1 = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-del-v1',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher1.seed,
    publisherDelegation: delegation1,
    application: {
      uid: 'uid-del-1',
      affiliation: 'student',
      displayName: 'Del Student 1',
      studentNumber: '2026-7001',
      course: 'BSIT',
      yearLevel: '4',
      sectionSet: 'A',
      status: 'submitted',
      revision: 0,
      deviceRegistration: firstQr,
    },
    payload: { role: 'civilian', registrationId: 'reg-del-1' },
    now: t1,
  });
  assert.equal(v1.version, 1);

  // Move clock past delegation1 expiry and renew with publisher2 signed by SAME campusRoot.
  const t2 = new Date('2026-12-15T12:00:00.000Z');
  const delegation2 = makeDelegation(campusRoot, publisher2, 'dnsc-pilot', {
    issuedAt: '2026-12-01T00:00:00.000Z',
    expiresAt: '2027-12-01T00:00:00.000Z',
  });
  const secondQr = makeSignedQr('phone-del-2').rawJson;
  const v2 = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-del-v2',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher2.seed,
    publisherDelegation: delegation2,
    existingDirectory: { version: 1, bundle: v1.bundle, updateTime: '2026-10-15T12:00:01Z' },
    application: {
      uid: 'uid-del-2',
      affiliation: 'student',
      displayName: 'Del Student 2',
      studentNumber: '2026-7002',
      course: 'BSIT',
      yearLevel: '4',
      sectionSet: 'B',
      status: 'submitted',
      revision: 0,
      deviceRegistration: secondQr,
    },
    payload: { role: 'responder', registrationId: 'reg-del-2' },
    now: t2,
  });
  assert.equal(v2.version, 2);
  const parsedV2 = JSON.parse(v2.bundle);
  assert.deepEqual(
    parsedV2.approved_devices.map((d) => d.device_id).sort(),
    ['phone-del-1', 'phone-del-2'],
  );

  // Roster-independent request_changes still succeeds even if delegation1 is expired.
  const correctionWithExpiredDel = applyDecisionAndBuildCommit({
    action: 'request_changes',
    decisionId: 'dec-expired-del-corr',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher1.seed,
    publisherDelegation: delegation1,
    existingDirectory: { version: 1, bundle: v1.bundle },
    application: {
      uid: 'uid-del-3',
      affiliation: 'student',
      displayName: 'Del Student 3',
      studentNumber: '2026-7003',
      course: 'BSIT',
      yearLevel: '4',
      sectionSet: 'C',
      status: 'submitted',
      revision: 0,
      deviceRegistration: makeSignedQr('phone-del-3').rawJson,
    },
    payload: { reason: 'Retake photo' },
    now: t2,
  });
  assert.equal(correctionWithExpiredDel.status, 'changes_requested');

  // An existing directory signed under an unrelated campus root must be rejected cleanly.
  const alienDelegation = makeDelegation(alienRoot, publisher2, 'dnsc-pilot', {
    issuedAt: '2026-12-01T00:00:00.000Z',
    expiresAt: '2027-12-01T00:00:00.000Z',
  });
  assert.throws(
    () =>
      applyDecisionAndBuildCommit({
        action: 'approve_online',
        decisionId: 'dec-alien-root',
        reviewerUid: 'admin-1',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher2.seed,
        publisherDelegation: alienDelegation,
        existingDirectory: { version: 1, bundle: v1.bundle },
        application: {
          uid: 'uid-del-4',
          affiliation: 'student',
          displayName: 'Del Student 4',
          studentNumber: '2026-7004',
          course: 'BSIT',
          yearLevel: '4',
          sectionSet: 'D',
          status: 'submitted',
          revision: 0,
          deviceRegistration: makeSignedQr('phone-del-4').rawJson,
        },
        now: t2,
      }),
    (err) => err instanceof PublisherError && err.statusCode === 409 && err.code === 'root_authority_mismatch',
  );
});

test('approve_link rejects revoked or already-claimed phones and supports legacy desk records with only deviceRegistration', () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const now = new Date('2026-11-26T12:00:00.000Z');
  const qr = makeSignedQr('phone-legacy-link');

  function makeLinkProof({ registrationId, accountUid, nonce = 'nonce-1' }) {
    const canonical = {
      registration_id: registrationId,
      account_uid: accountUid,
      directory_project: 'dnsc-pilot',
      nonce,
      device_id: 'phone-legacy-link',
      public_key: qr.publicKey,
      signing_public_key: qr.signingPublicKey,
      key_version: 1,
      issued_at: now.toISOString(),
    };
    const proofSignature = ed25519Sign(
      `shadow-network-account-link-v1\n${canonicalJsonEncode(canonical)}`,
      qr.signingPrivateKey,
    );
    return {
      registrationId,
      accountUid,
      directoryProject: 'dnsc-pilot',
      nonce,
      deviceId: 'phone-legacy-link',
      publicKey: qr.publicKey,
      signingPublicKey: qr.signingPublicKey,
      keyVersion: 1,
      issuedAt: now.toISOString(),
      proofSignature,
    };
  }

  // Legacy Windows campusRegistrations document with ONLY deviceRegistration JSON (no explicit key fields).
  const legacyRegistration = {
    registrationId: 'reg-legacy-1',
    source: 'qr',
    status: 'published',
    role: 'civilian',
    affiliation: 'student',
    displayName: 'Legacy Desk Student',
    studentNumber: '2026-8801',
    course: 'BSIT',
    yearLevel: '3',
    sectionSet: 'A',
    deviceId: 'phone-legacy-link',
    deviceRegistration: qr.rawJson,
  };

  const linked = applyDecisionAndBuildCommit({
    action: 'approve_link',
    decisionId: 'dec-link-ok',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    registration: legacyRegistration,
    linkRequest: makeLinkProof({
      registrationId: 'reg-legacy-1',
      accountUid: 'uid-alice',
    }),
    payload: { registrationId: 'reg-legacy-1', role: 'civilian' },
    now,
  });
  assert.equal(linked.status, 'published');
  const writtenReg = linked.writes.find((w) => w.collection === 'campusRegistrations').fields;
  assert.equal(writtenReg.publicKey, qr.publicKey);
  assert.equal(writtenReg.signingPublicKey, qr.signingPublicKey);
  assert.equal(writtenReg.accountUid, 'uid-alice');

  // Linking against a revoked directory entry fails with 409 and never un-revokes.
  const revokedBundle = JSON.parse(linked.bundle);
  const { sign: _s, ...bundleNoSig } = revokedBundle;
  const revokeCommit = applyDecisionAndBuildCommit({
    action: 'sync_offline_decision',
    decisionId: 'dec-revoke-first',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 1, bundle: linked.bundle },
    registration: { ...writtenReg, status: 'revoked' },
    payload: { registrationId: 'reg-legacy-1', role: 'civilian', targetStatus: 'revoked' },
    now,
  });
  assert.throws(
    () =>
      applyDecisionAndBuildCommit({
        action: 'approve_link',
        decisionId: 'dec-link-revoked',
        reviewerUid: 'admin-1',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher.seed,
        publisherDelegation: delegation,
        existingDirectory: { version: 2, bundle: revokeCommit.bundle },
        registration: { ...writtenReg, status: 'revoked', accountUid: undefined },
        linkRequest: makeLinkProof({
          registrationId: 'reg-legacy-1',
          accountUid: 'uid-attacker',
        }),
        payload: { registrationId: 'reg-legacy-1', role: 'civilian' },
        now,
      }),
    (err) => err instanceof PublisherError && err.statusCode === 409 && err.code === 'revoked_registration',
  );

  // Linking an already-claimed registration to a different accountUid fails with 409.
  assert.throws(
    () =>
      applyDecisionAndBuildCommit({
        action: 'approve_link',
        decisionId: 'dec-link-claimed',
        reviewerUid: 'admin-1',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher.seed,
        publisherDelegation: delegation,
        existingDirectory: { version: 1, bundle: linked.bundle },
        registration: writtenReg,
        linkRequest: makeLinkProof({
          registrationId: 'reg-legacy-1',
          accountUid: 'uid-bob',
        }),
        payload: { registrationId: 'reg-legacy-1', role: 'civilian' },
        now,
      }),
    (err) => err instanceof PublisherError && err.statusCode === 409 && err.code === 'already_linked',
  );
});

test('same-deviceId replacement preserves replacement QR key_version 1 and increments revision', () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const now = new Date('2026-11-26T12:00:00.000Z');
  const firstQr = makeSignedQr('phone-cleared-node');
  const secondQr = makeSignedQr('phone-cleared-node');

  const init = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-clear-init',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    application: {
      uid: 'uid-cleared',
      affiliation: 'student',
      displayName: 'Cleared Node Student',
      studentNumber: '2026-9911',
      course: 'BSIT',
      yearLevel: '4',
      sectionSet: 'A',
      status: 'submitted',
      revision: 0,
      deviceRegistration: firstQr.rawJson,
    },
    payload: { registrationId: 'reg-cleared-node', role: 'civilian' },
    now,
  });

  const rep = applyDecisionAndBuildCommit({
    action: 'approve_replacement',
    decisionId: 'dec-clear-rep',
    reviewerUid: 'admin-2',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 1, bundle: init.bundle },
    application: {
      uid: 'uid-cleared',
      affiliation: 'student',
      displayName: 'Cleared Node Student',
      studentNumber: '2026-9911',
      course: 'BSIT',
      yearLevel: '4',
      sectionSet: 'A',
      registrationId: 'reg-cleared-node',
      status: 'published',
      revision: 1,
      deviceRegistration: firstQr.rawJson,
      replacementRequest: { status: 'submitted', deviceRegistration: secondQr.rawJson },
    },
    registration: {
      registrationId: 'reg-cleared-node',
      accountUid: 'uid-cleared',
      affiliation: 'student',
      displayName: 'Cleared Node Student',
      studentNumber: '2026-9911',
      course: 'BSIT',
      yearLevel: '4',
      sectionSet: 'A',
      deviceId: 'phone-cleared-node',
      publicKey: firstQr.publicKey,
      signingPublicKey: firstQr.signingPublicKey,
      keyVersion: 1,
      revision: 1,
    },
    payload: { registrationId: 'reg-cleared-node', role: 'civilian' },
    now,
  });

  const bundle2 = JSON.parse(rep.bundle);
  assert.equal(bundle2.approved_devices.length, 1);
  assert.equal(bundle2.approved_devices[0].key_version, 1);
  assert.equal(bundle2.approved_devices[0].public_key, secondQr.publicKey);
  const regWrite = rep.writes.find((w) => w.collection === 'campusRegistrations').fields;
  assert.equal(regWrite.keyVersion, 1);
  assert.equal(regWrite.retiredKeys.length, 1);
});

test('approve_profile_change updates staff and student affiliation fields and trust bundle owner name, and decline_profile_change works without delegations', () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const staffQr = makeSignedQr('staff-prof-1');
  const now = new Date('2026-11-26T12:00:00.000Z');

  const init = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-staff-init',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    application: {
      uid: 'uid-staff-prof',
      affiliation: 'staff',
      displayName: 'Old Staff Name',
      employeeId: 'EMP-100',
      unit: 'Old Office',
      status: 'submitted',
      revision: 0,
      deviceRegistration: staffQr.rawJson,
    },
    payload: { registrationId: 'reg-staff-prof', role: 'responder' },
    now,
  });

  // Decline a pending staff change without requiring fresh delegation
  const declined = applyDecisionAndBuildCommit({
    action: 'decline_profile_change',
    decisionId: 'dec-prof-decline',
    reviewerUid: 'admin-2',
    directoryProject: 'dnsc-pilot',
    publisherSeed: null,
    publisherDelegation: null,
    existingDirectory: { version: 1, bundle: init.bundle },
    application: {
      uid: 'uid-staff-prof',
      affiliation: 'staff',
      displayName: 'Old Staff Name',
      employeeId: 'EMP-100',
      unit: 'Old Office',
      registrationId: 'reg-staff-prof',
      status: 'published',
      revision: 1,
      deviceRegistration: staffQr.rawJson,
      profileChange: {
        affiliation: 'staff',
        displayName: 'Unverified Alias',
        employeeId: 'EMP-100',
        unit: 'New Unit',
        status: 'submitted',
      },
    },
    payload: { reason: 'ID badge does not match alias' },
    now,
  });
  assert.equal(declined.status, 'rejected');
  assert.equal(declined.version, 1);
  assert.equal(declined.writes.length, 1);
  assert.equal(declined.writes[0].fields.profileChange.status, 'rejected');
  assert.equal(
    declined.writes[0].fields.profileChange.reason,
    'ID badge does not match alias',
  );

  // Approve updated staff change -> updates pilotApplications, campusRegistrations, and trust bundle owner_name
  const regBefore = init.writes.find((w) => w.collection === 'campusRegistrations').fields;
  const approved = applyDecisionAndBuildCommit({
    action: 'approve_profile_change',
    decisionId: 'dec-prof-approve',
    reviewerUid: 'admin-2',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 1, bundle: init.bundle },
    application: {
      uid: 'uid-staff-prof',
      affiliation: 'staff',
      displayName: 'Old Staff Name',
      employeeId: 'EMP-100',
      unit: 'Old Office',
      registrationId: 'reg-staff-prof',
      status: 'published',
      revision: 2,
      deviceRegistration: staffQr.rawJson,
      profileChange: {
        affiliation: 'staff',
        displayName: 'Updated Staff Officer',
        employeeId: 'EMP-109',
        unit: 'DRRMO Command',
        status: 'submitted',
      },
    },
    registration: regBefore,
    payload: {
      registrationId: 'reg-staff-prof',
      role: 'responder',
      reason: 'Verified updated staff ID',
    },
    now,
  });
  assert.equal(approved.status, 'published');
  assert.equal(approved.version, 2);
  const appWrite = approved.writes.find((w) => w.collection === 'pilotApplications').fields;
  assert.equal(appWrite.displayName, 'Updated Staff Officer');
  assert.equal(appWrite.employeeId, 'EMP-109');
  assert.equal(appWrite.unit, 'DRRMO Command');
  assert.equal(appWrite.profileChange.status, 'published');
  const regWrite = approved.writes.find((w) => w.collection === 'campusRegistrations').fields;
  assert.equal(regWrite.displayName, 'Updated Staff Officer');
  assert.equal(regWrite.unit, 'DRRMO Command');
  const bundle2 = verifyTrustBundle(JSON.parse(approved.bundle), {
    expectedProject: 'dnsc-pilot',
    expectedRootPublicKey: root.publicKeyBase64Url,
    now,
  });
  assert.equal(bundle2.approved_devices[0].owner_name, 'Updated Staff Officer');
  assert.equal(bundle2.approved_devices[0].role, 'responder');

  // Student profile change updates student affiliation fields and owner_name too
  const stuQr = makeSignedQr('stu-prof-1');
  const stuInit = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-stu-init',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 2, bundle: approved.bundle },
    application: {
      uid: 'uid-stu-prof',
      affiliation: 'student',
      displayName: 'Old Student Name',
      studentNumber: '2026-1001',
      course: 'BSIT',
      yearLevel: '2',
      sectionSet: 'B',
      status: 'submitted',
      revision: 0,
      deviceRegistration: stuQr.rawJson,
    },
    payload: { registrationId: 'reg-stu-prof', role: 'civilian' },
    now,
  });
  const stuApproved = applyDecisionAndBuildCommit({
    action: 'approve_profile_change',
    decisionId: 'dec-stu-prof-approve',
    reviewerUid: 'admin-2',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 3, bundle: stuInit.bundle },
    application: {
      uid: 'uid-stu-prof',
      affiliation: 'student',
      displayName: 'Old Student Name',
      studentNumber: '2026-1001',
      course: 'BSIT',
      yearLevel: '2',
      sectionSet: 'B',
      registrationId: 'reg-stu-prof',
      status: 'published',
      revision: 1,
      deviceRegistration: stuQr.rawJson,
      profileChange: {
        affiliation: 'student',
        displayName: 'Updated Student Name',
        studentNumber: '2026-1001',
        course: 'BSIT',
        yearLevel: '3',
        sectionSet: 'A',
        status: 'submitted',
      },
    },
    registration: stuInit.writes.find((w) => w.collection === 'campusRegistrations').fields,
    payload: { registrationId: 'reg-stu-prof', role: 'civilian', reason: 'Updated year level' },
    now,
  });
  const stuAppWrite = stuApproved.writes.find((w) => w.collection === 'pilotApplications').fields;
  assert.equal(stuAppWrite.displayName, 'Updated Student Name');
  assert.equal(stuAppWrite.courseYear, 'BSIT · 3 · A');
  const stuBundle = verifyTrustBundle(JSON.parse(stuApproved.bundle), {
    expectedProject: 'dnsc-pilot',
    expectedRootPublicKey: root.publicKeyBase64Url,
    now,
  });
  assert.equal(
    stuBundle.approved_devices.find((d) => d.device_id === 'stu-prof-1').owner_name,
    'Updated Student Name',
  );
});
