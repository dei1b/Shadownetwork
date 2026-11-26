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
  signTrustBundle,
  toBase64UrlPadded,
  verifyDeviceRegistrationQr,
  verifyTrustBundle,
} from '../../api/_lib/publisher_core.mjs';
import { executeDecisionWithRetry } from '../../api/publish-approval.mjs';

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

const phoneRequestUpdateTime = '2026-11-26T11:59:00.123456789Z';

function reviewedPhonePayload(oldQr, newQr, updateTime = phoneRequestUpdateTime) {
  const old = JSON.parse(oldQr.rawJson);
  return {
    deviceRegistration: newQr.rawJson,
    expectedRequestUpdateTime: updateTime,
    expectedOldPhone: {
      deviceId: old.device_id,
      publicKey: old.public_key,
      signingPublicKey: old.signing_public_key,
      keyVersion: old.key_version,
    },
  };
}

function pendingPhoneReview(action) {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const oldQr = makeSignedQr('phone-s1-a');
  const newQr = makeSignedQr('phone-s1-b');
  const common = {
    reviewerUid: 'admin-s1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed.toString('base64url'),
    publisherDelegation: makeDelegation(root, publisher),
    now: new Date('2026-11-26T12:00:00.000Z'),
  };
  const initial = applyDecisionAndBuildCommit({
    ...common,
    action: 'approve_online',
    decisionId: 'dec-s1-initial',
    application: {
      uid: 'uid-s1', status: 'submitted', revision: 0,
      affiliation: 'student', displayName: 'Reviewed Student',
      studentNumber: '2026-1111', course: 'BSIT', yearLevel: '3', sectionSet: 'A',
      deviceRegistration: oldQr.rawJson,
    },
    payload: { registrationId: 'reg-s1' },
  });
  const fieldsFor = (collection) => initial.writes.find((w) => w.collection === collection).fields;
  const request = { status: 'submitted', deviceRegistration: newQr.rawJson };
  const input = {
    ...common,
    action,
    decisionId: `dec-s1-${action}`,
    existingDirectory: { version: initial.version, bundle: initial.bundle, updateTime: 'directory-v1' },
    application: {
      fields: { ...fieldsFor('pilotApplications'), ...(action === 'approve_replacement' ? { replacementRequest: request } : {}) },
      updateTime: phoneRequestUpdateTime,
    },
    registration: { fields: fieldsFor('campusRegistrations'), updateTime: 'registration-v1' },
    recoveryRequest: action === 'approve_recovery'
      ? { fields: { ...request, accountUid: 'uid-s1' }, updateTime: phoneRequestUpdateTime }
      : null,
    payload: {
      accountUid: 'uid-s1', registrationId: 'reg-s1', role: 'civilian',
      ...reviewedPhonePayload(oldQr, newQr),
    },
  };
  return { input, oldQr, newQr };
}

function phoneRequestSnapshot(input) {
  return input.action === 'approve_recovery' ? input.recoveryRequest : input.application;
}

function phoneRequestFields(input) {
  return input.action === 'approve_recovery'
    ? input.recoveryRequest.fields
    : input.application.fields.replacementRequest;
}

function assertReviewConflict(input, code = 'stale_request') {
  const before = JSON.stringify(input);
  assert.throws(
    () => applyDecisionAndBuildCommit(input),
    (err) => err instanceof PublisherError && err.statusCode === 409 && err.code === code,
  );
  assert.equal(JSON.stringify(input), before, 'conflict must leave request and directory unchanged');
}

function deletionReview() {
  const { input, oldQr, newQr } = pendingPhoneReview('approve_replacement');
  input.action = 'delete_registration';
  input.decisionId = 'delete-s1';
  input.payload = {
    registrationId: 'reg-s1', accountUid: 'uid-s1', expectedRevision: 1,
    reason: 'Remove campus registration',
  };
  input.application.fields.profileChange = { status: 'submitted', displayName: 'Unreviewed' };
  input.linkRequest = { fields: { accountUid: 'uid-s1', registrationId: 'reg-s1', status: 'submitted' }, updateTime: 'link-v1' };
  input.recoveryRequest = { fields: { accountUid: 'uid-s1', status: 'submitted', deviceRegistration: newQr.rawJson }, updateTime: 'recovery-v1' };
  return { input, oldQr, newQr };
}

function committedDeletion(input, result) {
  const snapshot = (collection) => ({
    fields: result.writes.find((w) => w.collection === collection).fields,
    updateTime: `${collection}-deleted`,
  });
  return {
    ...input,
    existingDirectory: snapshot('trustDirectory'),
    application: snapshot('pilotApplications'),
    registration: snapshot('campusRegistrations'),
  };
}

test('delete_registration tombstones both records, cancels pending requests and signs only the bound phone revocation', () => {
  const { input, oldQr } = deletionReview();
  const bundle = JSON.parse(input.existingDirectory.bundle);
  const unrelated = makeSignedQr('unrelated');
  const entry = (id, qr, status) => ({ device_id: id, owner_name: id, role: 'civilian', status,
    public_key: qr.publicKey, signing_public_key: qr.signingPublicKey, key_version: 1 });
  input.existingDirectory.bundle = JSON.stringify(signTrustBundle({
    version: 1, directoryProject: input.directoryProject,
    publisherKeyPair: ed25519KeyPairFromSeed(input.publisherSeed), delegation: input.publisherDelegation,
    approvedDevices: [...bundle.approved_devices, entry('unrelated', unrelated, 'approved')],
    revokedDevices: [entry('retired', oldQr, 'revoked')], now: input.now,
  }));
  const result = applyDecisionAndBuildCommit(input);
  assert.equal(result.status, 'published');
  assert.equal(result.version, 2);
  const signed = verifyTrustBundle(JSON.parse(result.bundle), { expectedProject: input.directoryProject, now: input.now });
  assert.deepEqual(signed.approved_devices.map((d) => d.device_id), ['unrelated']);
  assert.deepEqual(signed.revoked_devices.map((d) => d.device_id).sort(), ['phone-s1-a', 'retired']);
  for (const collection of ['campusRegistrations', 'pilotApplications']) {
    const write = result.writes.find((w) => w.collection === collection);
    assert.equal(write.fields.status, 'deleted');
    assert.equal(write.fields.revision, 2);
    assert.equal(write.fields.deviceRegistration, oldQr.rawJson);
    assert.equal(write.fields.deletedBy, input.reviewerUid);
    assert.equal(write.fields.decisionOutcomes['delete-s1'].status, 'published');
    assert.ok(write.updateTime);
  }
  const app = result.writes.find((w) => w.collection === 'pilotApplications').fields;
  assert.equal(app.profileChange.status, 'deleted');
  assert.equal(app.replacementRequest.status, 'deleted');
  for (const collection of ['registrationLinkRequests', 'registrationRecoveryRequests']) {
    const write = result.writes.find((w) => w.collection === collection);
    assert.equal(write.fields.status, 'deleted');
    assert.ok(write.updateTime);
  }
  assert.ok(result.writes.every((w) => ['campusRegistrations', 'pilotApplications', 'registrationLinkRequests', 'registrationRecoveryRequests', 'trustDirectory'].includes(w.collection)));
});

test('delete_registration retries acknowledge without writes and reject reused parameters', () => {
  const { input } = deletionReview();
  const result = applyDecisionAndBuildCommit(input);
  const retry = committedDeletion(input, result);
  assert.equal(applyDecisionAndBuildCommit(retry).idempotent, true);
  assert.deepEqual(applyDecisionAndBuildCommit(retry).writes, []);
  retry.payload = { ...retry.payload, reason: 'Different decision' };
  assertReviewConflict(retry, 'decision_id_conflict');
});

test('delete_registration requires reviewed revision and rejects changed bindings or self deletion', () => {
  for (const mutate of [
    (i) => { i.payload.accountUid = 'other'; },
    (i) => { i.payload.registrationId = 'other'; },
    (i) => { i.application.fields.registrationId = 'other'; },
    (i) => { i.registration.fields.accountUid = 'other'; },
  ]) {
    const { input } = deletionReview();
    mutate(input);
    assertReviewConflict(input, 'registration_binding_mismatch');
  }
  const { input } = deletionReview();
  input.payload.expectedRevision = 0;
  assertReviewConflict(input, 'stale_revision');
  delete input.payload.expectedRevision;
  assert.throws(() => applyDecisionAndBuildCommit(input), (e) => e.code === 'missing_expected_revision');
  input.payload.expectedRevision = 1;
  input.reviewerUid = 'uid-s1';
  assert.throws(() => applyDecisionAndBuildCommit(input), (e) => e.code === 'self_review_forbidden');
});

test('delete_registration handles pending application without QR or campus record, without inventing phone keys', () => {
  const { input } = deletionReview();
  input.registration = null;
  input.application.fields.status = 'submitted';
  delete input.application.fields.deviceRegistration;
  const result = applyDecisionAndBuildCommit(input);
  for (const collection of ['campusRegistrations', 'pilotApplications']) {
    const write = result.writes.find((w) => w.collection === collection);
    assert.equal(write.fields.status, 'deleted');
    assert.equal(write.fields.publicKey, undefined);
    assert.equal(write.fields.deviceId, undefined);
  }
  assert.equal(result.writes.find((w) => w.collection === 'campusRegistrations').createOnly, true);
  assert.deepEqual(JSON.parse(result.bundle).revoked_devices, []);
});

test('delete_registration accepts local-only signed approved phone, rejects missing or unrelated keys', () => {
  const { input, oldQr } = deletionReview();
  input.registration = null;
  input.application = null;
  input.linkRequest = null;
  input.recoveryRequest = null;
  delete input.payload.accountUid;
  input.payload.expectedRevision = 0;
  input.payload.deviceRegistration = oldQr.rawJson;
  const result = applyDecisionAndBuildCommit(input);
  assert.equal(result.writes.find((w) => w.collection === 'campusRegistrations').fields.status, 'deleted');
  assert.equal(result.writes.some((w) => w.collection === 'pilotApplications'), false);
  // A local manual registration can have revisions before its first cloud record.
  input.payload.expectedRevision = 7;
  const localRevision = applyDecisionAndBuildCommit(input);
  assert.equal(localRevision.writes.find((w) => w.collection === 'campusRegistrations').fields.revision, 8);
  input.payload.deviceRegistration = makeSignedQr('phone-s1-a').rawJson;
  assertReviewConflict(input, 'phone_binding_mismatch');
  delete input.payload.deviceRegistration;
  assert.throws(() => applyDecisionAndBuildCommit(input), (e) => e.code === 'not_found');
});

test('delete_registration never revokes a roster entry whose keys differ from current binding', () => {
  const { input } = deletionReview();
  const other = makeSignedQr('phone-s1-a');
  const phone = JSON.parse(other.rawJson);
  Object.assign(input.registration.fields, { deviceRegistration: other.rawJson, publicKey: phone.public_key, signingPublicKey: phone.signing_public_key });
  assertReviewConflict(input, 'phone_binding_mismatch');
});

test('deleted registration blocks every later publisher mutation, including stale recorded approvals', () => {
  const { input } = deletionReview();
  const result = applyDecisionAndBuildCommit(input);
  const deleted = committedDeletion(input, result);
  for (const action of ['approve_online', 'sync_offline_decision', 'approve_link', 'approve_replacement', 'approve_recovery', 'approve_profile_change', 'decline_profile_change', 'request_changes', 'reject']) {
    for (const side of ['both', 'registration', 'application']) {
      const attempt = structuredClone({ ...deleted, publisherSeed: undefined });
      attempt.publisherSeed = input.publisherSeed;
      attempt.action = action;
      attempt.decisionId = 'later-decision';
      if (side === 'registration') attempt.application.fields.status = 'submitted';
      if (side === 'application') attempt.registration.fields.status = 'published';
      assertReviewConflict(attempt, 'deleted_registration');
    }
  }
  deleted.action = 'approve_online';
  deleted.decisionId = 'dec-s1-initial';
  deleted.payload = { registrationId: 'reg-s1' };
  assertReviewConflict(deleted, 'deleted_registration');
});

test('delete_registration uses campus authority and does not clear unrelated request bindings', () => {
  const { input } = deletionReview();
  input.payload.deviceRegistration = makeSignedQr('unrelated-proposal').rawJson;
  input.linkRequest.fields.accountUid = 'unrelated-account';
  input.linkRequest.fields.registrationId = 'unrelated-registration';
  input.recoveryRequest.fields.registrationId = 'unrelated-registration';
  const result = applyDecisionAndBuildCommit(input);
  assert.deepEqual(JSON.parse(result.bundle).revoked_devices.map((d) => d.device_id), ['phone-s1-a']);
  assert.equal(result.writes.find((w) => w.collection === 'pilotApplications').docId, 'uid-s1');
  assert.equal(result.writes.some((w) => w.collection === 'registrationLinkRequests' || w.collection === 'registrationRecoveryRequests'), false);
});

test('delete_registration clears loaded requests explicitly targeting an unlinked registration without claiming their accounts', () => {
  const { input } = deletionReview();
  delete input.registration.fields.accountUid;
  input.registration.fields.revision = 1;
  input.application = null;
  delete input.payload.accountUid;
  input.recoveryRequest.fields.registrationId = 'reg-s1';
  const result = applyDecisionAndBuildCommit(input);
  for (const collection of ['registrationLinkRequests', 'registrationRecoveryRequests']) {
    assert.equal(result.writes.find((w) => w.collection === collection)?.fields.status, 'deleted');
  }
  assert.equal(result.writes.some((w) => w.collection === 'pilotApplications'), false);
});

test('hosted delete resolves omitted accountUid, enforces CAS retries and remote tombstones over stale local records', async () => {
  const { default: handler, buildFirestoreCommitBody } = await import('../../api/publish-approval.mjs');
  const { input } = deletionReview();
  const env = {
    FIREBASE_PROJECT_ID: input.directoryProject,
    PUBLISHER_PRIVATE_KEY_SEED: input.publisherSeed,
    PUBLISHER_DELEGATION_JSON: JSON.stringify(input.publisherDelegation),
    FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099',
    FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
  };
  const previous = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
  const oldFetch = globalThis.fetch;
  const docs = new Map();
  for (const [collection, docId, snap] of [
    ['trustDirectory', 'current', { fields: { version: 1, bundle: input.existingDirectory.bundle } }],
    ['campusRegistrations', 'reg-s1', input.registration],
    ['pilotApplications', 'uid-s1', input.application],
    ['registrationLinkRequests', 'uid-s1', input.linkRequest],
    ['registrationRecoveryRequests', 'uid-s1', input.recoveryRequest],
  ]) {
    const update = buildFirestoreCommitBody(input.directoryProject, [{ collection, docId, fields: snap.fields }]).writes[0].update;
    docs.set(`${collection}/${docId}`, { ...update, updateTime: `${collection}-v1` });
  }
  const b64 = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const token = `${b64({ alg: 'none' })}.${b64({ sub: input.reviewerUid, admin: true,
    aud: input.directoryProject, iss: `https://securetoken.google.com/${input.directoryProject}`,
    exp: Math.floor(Date.now() / 1000) + 3600 })}.`;
  let commits = 0;
  globalThis.fetch = async (url, options) => {
    const path = String(url).split('/documents/')[1];
    if (path) return docs.has(path)
      ? new Response(JSON.stringify(docs.get(path)), { status: 200 })
      : new Response('{}', { status: 404 });
    assert.ok(String(url).endsWith('/documents:commit'), 'No Auth deletion or other network writes');
    const { writes } = JSON.parse(options.body);
    commits++;
    if (commits === 1) {
      docs.get('registrationRecoveryRequests/uid-s1').updateTime = 'recovery-newer';
      return new Response('{}', { status: 409 });
    }
    for (const write of writes) {
      const key = write.update.name.split('/documents/')[1];
      const existing = docs.get(key);
      assert.ok(write.currentDocument, `${key} must have a precondition`);
      if (write.currentDocument.exists === false) assert.equal(existing, undefined);
      else assert.equal(write.currentDocument.updateTime, existing.updateTime);
    }
    for (const write of writes) {
      const key = write.update.name.split('/documents/')[1];
      docs.set(key, { ...write.update, updateTime: `${key}-deleted` });
    }
    return new Response('{}', { status: 200 });
  };
  const invoke = async (body) => {
    const result = {};
    await handler({ method: 'POST', headers: { authorization: `Bearer ${token}` }, body }, {
      setHeader() {}, status(code) { result.code = code; return this; },
      json(value) { result.body = value; return this; }, end() {},
    });
    return result;
  };
  try {
    Object.assign(process.env, env);
    const { accountUid: _unused, ...payload } = input.payload;
    const body = { ...payload, action: 'delete_registration', decisionId: input.decisionId };
    const first = await invoke(body);
    assert.equal(first.code, 200);
    assert.equal(first.body.status, 'published');
    assert.equal(commits, 2);
    for (const collection of ['campusRegistrations', 'pilotApplications', 'registrationLinkRequests', 'registrationRecoveryRequests']) {
      const id = collection === 'campusRegistrations' ? 'reg-s1' : 'uid-s1';
      assert.equal(docs.get(`${collection}/${id}`).fields.status.stringValue, 'deleted');
    }
    const retry = await invoke(body);
    assert.equal(retry.code, 200);
    assert.equal(retry.body.idempotent, true);
    assert.equal(commits, 2);
    // Omitted registrationId must still discover the application's remote tombstone.
    const staleApproval = await invoke({ action: 'approve_online', accountUid: 'uid-s1', decisionId: 'stale-online' });
    assert.equal(staleApproval.code, 409);
    assert.equal(staleApproval.body.code, 'deleted_registration');
    const staleSync = await invoke({ action: 'sync_offline_decision', registrationId: 'reg-s1',
      decisionId: 'stale-sync', registration: input.registration.fields });
    assert.equal(staleSync.code, 409);
    assert.equal(staleSync.body.code, 'deleted_registration');
    const embeddedSync = await invoke({ action: 'sync_offline_decision',
      decisionId: 'stale-embedded-sync', registration: input.registration.fields });
    assert.equal(embeddedSync.code, 409);
    assert.equal(embeddedSync.body.code, 'deleted_registration');
  } finally {
    globalThis.fetch = oldFetch;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});

for (const action of ['approve_replacement', 'approve_recovery']) {
  test(`S1 ${action}: preserves an identical recorded decision from before review tokens existed`, () => {
    const legacyFingerprint = action === 'approve_replacement'
      ? 'a6c1a007578b12a0e5cd45ca81df4011280cdd62c34664d42eecc24abd48bc2e'
      : '47de4770daa68b02fd1acf689350dbe4858fb22c3de8f7ac0b654461cc1f5b67';
    const result = applyDecisionAndBuildCommit({
      action, decisionId: 'legacy-decision', reviewerUid: 'admin-s1', directoryProject: 'dnsc-pilot',
      application: {
        uid: 'uid-legacy-s1', status: 'published',
        decisionOutcomes: {
          'legacy-decision': { action, requestFingerprint: legacyFingerprint, status: 'published', version: 2, registrationId: 'reg-legacy-s1' },
        },
      },
      payload: { accountUid: 'uid-legacy-s1', registrationId: 'reg-legacy-s1', deviceRegistration: 'legacy-reviewed-qr' },
    });
    assert.equal(result.idempotent, true);
    assert.deepEqual(result.writes, []);
  });

  test(`S1 ${action}: accepts only the reviewed pending QR and retains atomic snapshot preconditions`, () => {
    for (const status of ['submitted', 'approved_pending_publication']) {
      const { input } = pendingPhoneReview(action);
      phoneRequestFields(input).status = status;
      // A fallback profile publication already aligned both records at revision 2.
      input.application.fields.revision = 2;
      input.registration.fields.revision = 2;
      // JSON formatting does not change the exact signed QR that was reviewed.
      input.payload.deviceRegistration = JSON.stringify(JSON.parse(input.payload.deviceRegistration), null, 2);
      const result = applyDecisionAndBuildCommit(input);
      assert.equal(result.version, 2);
      assert.equal(result.idempotent, false);
      const bundle = verifyTrustBundle(JSON.parse(result.bundle), { expectedProject: 'dnsc-pilot', now: input.now });
      assert.deepEqual(bundle.approved_devices.map((d) => d.device_id), ['phone-s1-b']);
      assert.deepEqual(bundle.revoked_devices.map((d) => d.device_id), ['phone-s1-a']);
      assert.equal(result.writes.find((w) => w.collection === 'pilotApplications').updateTime, phoneRequestUpdateTime);
      assert.equal(result.writes.find((w) => w.collection === 'campusRegistrations').updateTime, 'registration-v1');
      const appWrite = result.writes.find((w) => w.collection === 'pilotApplications');
      const campusWrite = result.writes.find((w) => w.collection === 'campusRegistrations');
      assert.equal(appWrite.fields.revision, 3);
      assert.equal(campusWrite.fields.revision, appWrite.fields.revision);
      if (action === 'approve_recovery') {
        const recoveryWrite = result.writes.find((w) => w.collection === 'registrationRecoveryRequests');
        assert.equal(recoveryWrite.updateTime, phoneRequestUpdateTime);
        assert.equal(recoveryWrite.fields.status, 'published');
      }
    }
  });

  test(`S1 ${action}: rejects rejected, completed, nonpending and absent requests`, () => {
    for (const status of ['rejected', 'published', 'pending', 'changes_requested', null]) {
      const { input } = pendingPhoneReview(action);
      phoneRequestFields(input).status = status;
      assertReviewConflict(input);
    }
    const { input } = pendingPhoneReview(action);
    if (action === 'approve_recovery') input.recoveryRequest = null;
    else delete input.application.fields.replacementRequest;
    assertReviewConflict(input);
  });

  test(`S1 ${action}: never substitutes C for reviewed B, even with a current timestamp`, () => {
    const { input } = pendingPhoneReview(action);
    phoneRequestFields(input).deviceRegistration = makeSignedQr('phone-s1-c').rawJson;
    assertReviewConflict(input);
  });

  test(`S1 ${action}: requires the reviewed QR and exact request metadata, including same-QR resubmission`, () => {
    for (const mutation of [
      (input) => { delete input.payload.deviceRegistration; },
      (input) => { delete input.payload.expectedRequestUpdateTime; },
      (input) => { input.payload.expectedRequestUpdateTime = ''; },
      (input) => { input.payload.expectedRequestUpdateTime = '2026-11-26T11:59:00.123456788Z'; },
      (input) => { phoneRequestSnapshot(input).updateTime = '2026-11-26T12:00:01Z'; },
      (input) => { delete phoneRequestSnapshot(input).updateTime; },
      (input) => { phoneRequestFields(input).deviceRegistration = '{invalid'; },
      (input) => { input.payload.deviceRegistration = '{invalid'; },
    ]) {
      const { input } = pendingPhoneReview(action);
      mutation(input);
      assertReviewConflict(input);
    }
  });

  test(`S1 ${action}: requires every reviewed old binding field and rejects a changed current phone`, () => {
    for (const field of ['deviceId', 'publicKey', 'signingPublicKey', 'keyVersion']) {
      for (const missing of [false, true]) {
        const { input } = pendingPhoneReview(action);
        if (missing) delete input.payload.expectedOldPhone[field];
        else input.payload.expectedOldPhone[field] = field === 'keyVersion' ? 2 : 'changed';
        assertReviewConflict(input, 'stale_phone_binding');
      }
    }
    const { input } = pendingPhoneReview(action);
    delete input.payload.expectedOldPhone;
    assertReviewConflict(input, 'stale_phone_binding');
    const changed = pendingPhoneReview(action).input;
    const other = makeSignedQr('phone-s1-a');
    Object.assign(changed.registration.fields, {
      deviceRegistration: other.rawJson, publicKey: other.publicKey, signingPublicKey: other.signingPublicKey,
    });
    assertReviewConflict(changed, 'stale_phone_binding');
  });

  test(`S1 ${action}: rejects second reviewers but replays the identical decision after a newer request`, () => {
    const { input } = pendingPhoneReview(action);
    const first = applyDecisionAndBuildCommit(input);
    const committed = structuredClone(input);
    for (const write of first.writes) {
      const key = { trustDirectory: 'existingDirectory', pilotApplications: 'application', campusRegistrations: 'registration', registrationRecoveryRequests: 'recoveryRequest' }[write.collection];
      committed[key] = { fields: write.fields, updateTime: 'after-commit' };
    }
    assertReviewConflict({ ...committed, decisionId: 'second-reviewer-decision', reviewerUid: 'second-admin' });
    phoneRequestFields(committed).status = 'submitted';
    phoneRequestFields(committed).deviceRegistration = makeSignedQr('phone-s1-c').rawJson;
    const retry = applyDecisionAndBuildCommit(committed);
    assert.equal(retry.idempotent, true);
    assert.equal(retry.version, first.version);
    assert.deepEqual(retry.writes, []);
    assert.equal(phoneRequestFields(committed).status, 'submitted');
    for (const mutatePayload of [
      (payload) => { payload.expectedRequestUpdateTime = 'different-review'; },
      (payload) => { payload.expectedOldPhone.publicKey = 'different-old-key'; },
    ]) {
      const different = structuredClone(committed);
      mutatePayload(different.payload);
      assertReviewConflict(different, 'decision_id_conflict');
    }
  });

  test(`S1 ${action}: a commit retry cannot approve a rejected or superseding request`, async () => {
    for (const nextRequest of ['rejected', 'different-qr', 'same-qr-resubmitted']) {
      const { input } = pendingPhoneReview(action);
      let commits = 0;
      let reads = 0;
      const beforeDirectory = JSON.stringify(input.existingDirectory);
      await assert.rejects(
        executeDecisionWithRetry({
          readState: async () => { reads++; return input; },
          applyDecision: (state) => applyDecisionAndBuildCommit(state),
          commitWritesFn: async () => {
            commits++;
            phoneRequestSnapshot(input).updateTime = '2026-11-26T12:00:02Z';
            if (nextRequest === 'rejected') phoneRequestFields(input).status = 'rejected';
            if (nextRequest === 'different-qr') phoneRequestFields(input).deviceRegistration = makeSignedQr('phone-s1-c').rawJson;
            throw new PublisherError(409, 'Snapshot changed during commit.', 'firestore_commit_error');
          },
        }),
        (err) => err instanceof PublisherError && err.statusCode === 409 && err.code === 'stale_request',
      );
      assert.equal(reads, 2);
      assert.equal(commits, 1, 'freshness failure must stop the next commit');
      assert.equal(JSON.stringify(input.existingDirectory), beforeDirectory);
    }
  });
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
      updateTime: phoneRequestUpdateTime,
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
    payload: { registrationId: 'reg-carlos', role: 'civilian', ...reviewedPhonePayload(oldQr, newQr) },
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
      updateTime: phoneRequestUpdateTime,
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
    payload: { registrationId: 'reg-cleared-node', role: 'civilian', ...reviewedPhonePayload(firstQr, secondQr) },
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

test('R1: returning to an earlier phone removes superseded revocation and signTrustBundle rejects overlapping device IDs', () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const now = new Date('2026-11-26T12:00:00.000Z');
  const qrA = makeSignedQr('phone-aba-a');
  const qrB = makeSignedQr('phone-aba-b');
  const qrOtherApproved = makeSignedQr('phone-other-approved');
  const qrOtherRevoked = makeSignedQr('phone-other-revoked');

  const v1 = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-aba-1',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    application: {
      uid: 'uid-other-app',
      affiliation: 'student',
      displayName: 'Unrelated Student',
      studentNumber: '2026-1111',
      course: 'BSIT',
      yearLevel: '1',
      sectionSet: 'A',
      status: 'submitted',
      revision: 0,
      deviceRegistration: qrOtherApproved.rawJson,
    },
    payload: { registrationId: 'reg-other-app', role: 'civilian' },
    now,
  });

  const v2 = applyDecisionAndBuildCommit({
    action: 'sync_offline_decision',
    decisionId: 'dec-aba-2',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 1, bundle: v1.bundle },
    registration: {
      registrationId: 'reg-other-revoked',
      source: 'qr',
      status: 'revoked',
      affiliation: 'student',
      displayName: 'Unrelated Revoked',
      studentNumber: '2026-1112',
      course: 'BSIT',
      yearLevel: '1',
      sectionSet: 'A',
      deviceRegistration: qrOtherRevoked.rawJson,
    },
    payload: { registrationId: 'reg-other-revoked', role: 'civilian', targetStatus: 'revoked' },
    now,
  });

  // Approve phone A -> v3
  const v3 = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-aba-3',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 2, bundle: v2.bundle },
    application: {
      uid: 'uid-aba-owner',
      affiliation: 'student',
      displayName: 'Returning Phone Student',
      studentNumber: '2026-2222',
      course: 'BSIT',
      yearLevel: '2',
      sectionSet: 'B',
      status: 'submitted',
      revision: 0,
      deviceRegistration: qrA.rawJson,
    },
    payload: { registrationId: 'reg-aba-owner', role: 'civilian' },
    now,
  });
  const regAfterV3 = v3.writes.find((w) => w.collection === 'campusRegistrations').fields;
  const appAfterV3 = v3.writes.find((w) => w.collection === 'pilotApplications').fields;

  // Replace A -> B -> v4 (A revoked, B approved)
  const v4 = applyDecisionAndBuildCommit({
    action: 'approve_replacement',
    decisionId: 'dec-aba-4',
    reviewerUid: 'admin-2',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 3, bundle: v3.bundle },
    application: {
      ...appAfterV3,
      replacementRequest: { status: 'submitted', deviceRegistration: qrB.rawJson },
      updateTime: phoneRequestUpdateTime,
    },
    registration: regAfterV3,
    payload: { registrationId: 'reg-aba-owner', accountUid: 'uid-aba-owner', role: 'civilian', reason: 'Temporary spare phone', ...reviewedPhonePayload(qrA, qrB) },
    now,
  });
  const b4 = JSON.parse(v4.bundle);
  assert.deepEqual(b4.approved_devices.map((d) => d.device_id).sort(), ['phone-aba-b', 'phone-other-approved']);
  assert.deepEqual(b4.revoked_devices.map((d) => d.device_id).sort(), ['phone-aba-a', 'phone-other-revoked']);

  const regAfterV4 = v4.writes.find((w) => w.collection === 'campusRegistrations').fields;
  const appAfterV4 = v4.writes.find((w) => w.collection === 'pilotApplications').fields;

  // Return B -> A -> v5 (A approved cleanly, A removed from revoked, B revoked, unrelated kept)
  const v5 = applyDecisionAndBuildCommit({
    action: 'approve_replacement',
    decisionId: 'dec-aba-5',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 4, bundle: v4.bundle },
    application: {
      ...appAfterV4,
      replacementRequest: { status: 'submitted', deviceRegistration: qrA.rawJson },
      updateTime: phoneRequestUpdateTime,
    },
    registration: regAfterV4,
    payload: { registrationId: 'reg-aba-owner', accountUid: 'uid-aba-owner', role: 'civilian', reason: 'Returned to primary phone', ...reviewedPhonePayload(qrB, qrA) },
    now,
  });
  const b5 = verifyTrustBundle(JSON.parse(v5.bundle), {
    expectedProject: 'dnsc-pilot',
    expectedRootPublicKey: root.publicKeyBase64Url,
    now,
  });
  assert.deepEqual(b5.approved_devices.map((d) => d.device_id).sort(), ['phone-aba-a', 'phone-other-approved']);
  assert.deepEqual(b5.revoked_devices.map((d) => d.device_id).sort(), ['phone-aba-b', 'phone-other-revoked']);
  const regAfterV5 = v5.writes.find((w) => w.collection === 'campusRegistrations').fields;
  assert.equal(regAfterV5.retiredKeys.length, 2);
  assert.equal(regAfterV5.deviceId, 'phone-aba-a');

  // signTrustBundle itself enforces disjoint approved/revoked device IDs.
  assert.throws(
    () =>
      signTrustBundle({
        version: 6,
        directoryProject: 'dnsc-pilot',
        publisherKeyPair: publisher,
        delegation,
        approvedDevices: [{ device_id: 'Phone-Dup', status: 'approved' }],
        revokedDevices: [{ device_id: 'phone-dup', status: 'revoked' }],
        now,
      }),
    (err) => err instanceof PublisherError && err.code === 'duplicate_device_id',
  );
});

test('R2: legacy campusRegistrations with only deviceRegistration retires old phone on replacement and recovery', () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const now = new Date('2026-11-26T12:00:00.000Z');
  const oldQr = makeSignedQr('phone-legacy-old');
  const newQr = makeSignedQr('phone-legacy-new');
  const unrelatedQr = makeSignedQr('phone-legacy-other');

  const baseDir = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-r2-init',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    application: {
      uid: 'uid-r2-other',
      affiliation: 'student',
      displayName: 'Other User',
      studentNumber: '2026-1000',
      course: 'BSIT',
      yearLevel: '1',
      sectionSet: 'A',
      status: 'submitted',
      revision: 0,
      deviceRegistration: unrelatedQr.rawJson,
    },
    payload: { registrationId: 'reg-r2-other', role: 'civilian' },
    now,
  });

  const withOld = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-r2-old',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 1, bundle: baseDir.bundle },
    application: {
      uid: 'uid-r2-owner',
      affiliation: 'student',
      displayName: 'Legacy Replacement Owner',
      studentNumber: '2026-2000',
      course: 'BSIT',
      yearLevel: '2',
      sectionSet: 'A',
      status: 'submitted',
      revision: 0,
      deviceRegistration: oldQr.rawJson,
    },
    payload: { registrationId: 'reg-r2-owner', role: 'civilian' },
    now,
  });

  // Strip flat top-level deviceId/publicKey/signingPublicKey/keyVersion to simulate legacy record.
  const replaced = applyDecisionAndBuildCommit({
    action: 'approve_replacement',
    decisionId: 'dec-r2-rep',
    reviewerUid: 'admin-2',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 2, bundle: withOld.bundle },
    application: {
      uid: 'uid-r2-owner',
      affiliation: 'student',
      displayName: 'Legacy Replacement Owner',
      studentNumber: '2026-2000',
      course: 'BSIT',
      yearLevel: '2',
      sectionSet: 'A',
      registrationId: 'reg-r2-owner',
      status: 'published',
      revision: 1,
      deviceRegistration: oldQr.rawJson,
      replacementRequest: { status: 'submitted', deviceRegistration: newQr.rawJson },
      updateTime: phoneRequestUpdateTime,
    },
    registration: {
      registrationId: 'reg-r2-owner',
      accountUid: 'uid-r2-owner',
      affiliation: 'student',
      displayName: 'Legacy Replacement Owner',
      studentNumber: '2026-2000',
      course: 'BSIT',
      yearLevel: '2',
      sectionSet: 'A',
      deviceRegistration: oldQr.rawJson,
      revision: 1,
    },
    payload: { registrationId: 'reg-r2-owner', accountUid: 'uid-r2-owner', role: 'civilian', reason: 'New handset', ...reviewedPhonePayload(oldQr, newQr) },
    now,
  });

  const bundle = verifyTrustBundle(JSON.parse(replaced.bundle), {
    expectedProject: 'dnsc-pilot',
    expectedRootPublicKey: root.publicKeyBase64Url,
    now,
  });
  assert.deepEqual(
    bundle.approved_devices.map((d) => d.device_id).sort(),
    ['phone-legacy-new', 'phone-legacy-other'],
  );
  assert.deepEqual(
    bundle.revoked_devices.map((d) => d.device_id),
    ['phone-legacy-old'],
  );
  assert.equal(bundle.revoked_devices[0].public_key, oldQr.publicKey);
});

test('R4: sync_offline_decision honors explicit published targetStatus over revoked registration and rejects stale expectedConflictVersion', () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const now = new Date('2026-11-26T12:00:00.000Z');
  const qr = makeSignedQr('phone-reinstate-1');
  const unrelatedRevokedQr = makeSignedQr('phone-unrelated-revoked');

  const baseRevoked = applyDecisionAndBuildCommit({
    action: 'sync_offline_decision',
    decisionId: 'dec-r4-unrelated-revoke',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    registration: {
      registrationId: 'reg-r4-unrelated',
      affiliation: 'student',
      displayName: 'Other Revoked',
      studentNumber: '2026-4400',
      course: 'BSIT',
      yearLevel: '2',
      sectionSet: 'A',
      status: 'revoked',
      revision: 1,
      deviceRegistration: unrelatedRevokedQr.rawJson,
    },
    payload: { registrationId: 'reg-r4-unrelated', role: 'civilian', targetStatus: 'revoked' },
    now,
  });

  const initial = applyDecisionAndBuildCommit({
    action: 'sync_offline_decision',
    decisionId: 'dec-r4-revoke',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 1, bundle: baseRevoked.bundle },
    registration: {
      registrationId: 'reg-r4-1',
      affiliation: 'student',
      displayName: 'Reinstate Student',
      studentNumber: '2026-4401',
      course: 'BSIT',
      yearLevel: '3',
      sectionSet: 'A',
      status: 'revoked',
      revision: 1,
      deviceRegistration: qr.rawJson,
    },
    payload: { registrationId: 'reg-r4-1', role: 'civilian', targetStatus: 'revoked' },
    now,
  });

  // Remote registration still says status: 'revoked', while signed correction sets targetStatus: 'published'.
  const reinstated = applyDecisionAndBuildCommit({
    action: 'sync_offline_decision',
    decisionId: 'dec-r4-reinstate',
    reviewerUid: 'admin-2',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 2, bundle: initial.bundle },
    registration: {
      registrationId: 'reg-r4-1',
      affiliation: 'student',
      displayName: 'Reinstate Student',
      studentNumber: '2026-4401',
      course: 'BSIT',
      yearLevel: '3',
      sectionSet: 'A',
      status: 'revoked',
      revision: 2,
      deviceRegistration: qr.rawJson,
    },
    payload: {
      registrationId: 'reg-r4-1',
      role: 'civilian',
      targetStatus: 'published',
      overrideConflict: true,
      expectedConflictVersion: 2,
    },
    now,
  });

  const bundle = verifyTrustBundle(JSON.parse(reinstated.bundle), {
    expectedProject: 'dnsc-pilot',
    expectedRootPublicKey: root.publicKeyBase64Url,
    now,
  });
  assert.deepEqual(bundle.approved_devices.map((d) => d.device_id), ['phone-reinstate-1']);
  assert.deepEqual(bundle.revoked_devices.map((d) => d.device_id), ['phone-unrelated-revoked']);
  const regWrite = reinstated.writes.find((w) => w.collection === 'campusRegistrations');
  assert.equal(regWrite.fields.status, 'published');
  assert.equal(regWrite.fields.decisionOutcomes['dec-r4-reinstate'].targetStatus, 'published');

  // Idempotent retry of the identical reinstatement produces zero writes.
  const retrySame = applyDecisionAndBuildCommit({
    action: 'sync_offline_decision',
    decisionId: 'dec-r4-reinstate',
    reviewerUid: 'admin-2',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: { version: 3, bundle: reinstated.bundle },
    registration: regWrite.fields,
    payload: {
      registrationId: 'reg-r4-1',
      role: 'civilian',
      targetStatus: 'published',
      overrideConflict: true,
      expectedConflictVersion: 2,
    },
    now,
  });
  assert.equal(retrySame.idempotent, true);
  assert.equal(retrySame.writes.length, 0);
  assert.equal(retrySame.version, 3);

  assert.throws(
    () =>
      applyDecisionAndBuildCommit({
        action: 'sync_offline_decision',
        decisionId: 'dec-r4-stale',
        reviewerUid: 'admin-3',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher.seed,
        publisherDelegation: delegation,
        existingDirectory: { version: 3, bundle: reinstated.bundle },
        registration: regWrite.fields,
        payload: {
          registrationId: 'reg-r4-1',
          role: 'civilian',
          targetStatus: 'published',
          overrideConflict: true,
          expectedConflictVersion: 2,
        },
        now,
      }),
    (err) => err instanceof PublisherError && err.code === 'stale_conflict_resolution',
  );
});

test('R6: reusing a decisionId across different actions or canonical payloads throws 409 decision_id_conflict while identical retries remain idempotent', () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const now = new Date('2026-11-26T12:00:00.000Z');
  const qr = makeSignedQr('phone-r6-1');

  const initialApp = {
    uid: 'uid-r6-1',
    affiliation: 'student',
    displayName: 'Carlos Replay',
    studentNumber: '2026-6601',
    course: 'BSIT',
    yearLevel: '3',
    sectionSet: 'A',
    status: 'submitted',
    revision: 0,
    deviceRegistration: qr.rawJson,
  };
  const approvePayload = { role: 'civilian', expectedRevision: 0 };

  const approved = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-r6-approve',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    application: initialApp,
    payload: approvePayload,
    now,
  });
  const appAfter = approved.writes.find((w) => w.collection === 'pilotApplications').fields;
  const regAfter = approved.writes.find((w) => w.collection === 'campusRegistrations').fields;

  // Identical retry remains idempotent with zero writes and version unchanged.
  const idempotentRetry = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-r6-approve',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    existingDirectory: {
      version: 1,
      bundle: approved.bundle,
      lastDecisionId: 'dec-r6-approve',
    },
    application: appAfter,
    registration: regAfter,
    payload: approvePayload,
    now,
  });
  assert.equal(idempotentRetry.idempotent, true);
  assert.equal(idempotentRetry.writes.length, 0);
  assert.equal(idempotentRetry.version, 1);

  // Reusing the approval decisionId to revoke must fail with 409 decision_id_conflict.
  assert.throws(
    () =>
      applyDecisionAndBuildCommit({
        action: 'sync_offline_decision',
        decisionId: 'dec-r6-approve',
        reviewerUid: 'admin-1',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher.seed,
        publisherDelegation: delegation,
        existingDirectory: {
          version: 1,
          bundle: approved.bundle,
          lastDecisionId: 'dec-r6-approve',
        },
        application: appAfter,
        registration: regAfter,
        payload: {
          registrationId: regAfter.registrationId,
          role: 'civilian',
          targetStatus: 'revoked',
          overrideConflict: true,
          reason: 'Lost phone',
        },
        now,
      }),
    (err) => err instanceof PublisherError && err.code === 'decision_id_conflict',
  );

  // Reusing a reject decisionId with a different action or reason must fail.
  const rejected = applyDecisionAndBuildCommit({
    action: 'reject',
    decisionId: 'dec-r6-reject',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    application: initialApp,
    payload: { expectedRevision: 0, reason: 'Unreadable ID' },
    now,
  });
  const rejectedApp = rejected.writes.find((w) => w.collection === 'pilotApplications').fields;
  assert.throws(
    () =>
      applyDecisionAndBuildCommit({
        action: 'request_changes',
        decisionId: 'dec-r6-reject',
        reviewerUid: 'admin-1',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher.seed,
        publisherDelegation: delegation,
        application: rejectedApp,
        payload: { expectedRevision: 0, reason: 'Please resubmit' },
        now,
      }),
    (err) => err instanceof PublisherError && err.code === 'decision_id_conflict',
  );
  assert.throws(
    () =>
      applyDecisionAndBuildCommit({
        action: 'reject',
        decisionId: 'dec-r6-reject',
        reviewerUid: 'admin-1',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher.seed,
        publisherDelegation: delegation,
        application: rejectedApp,
        payload: { expectedRevision: 0, reason: 'Different reason' },
        now,
      }),
    (err) => err instanceof PublisherError && err.code === 'decision_id_conflict',
  );
});

test('R9: decline_profile_change handles legacy published applications lacking registrationId without ReferenceError via HTTP handler', async () => {
  const { default: handler } = await import('../../api/publish-approval.mjs');
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const qr = makeSignedQr('phone-r9-legacy');

  // Legacy published pilotApplication intentionally has NO registrationId property.
  let appDoc = {
    name: 'projects/dnsc-pilot/databases/(default)/documents/pilotApplications/uid-r9-legacy',
    updateTime: '2026-11-26T10:00:00Z',
    fields: {
      uid: { stringValue: 'uid-r9-legacy' },
      affiliation: { stringValue: 'student' },
      displayName: { stringValue: 'Legacy Active Student' },
      studentNumber: { stringValue: '2026-9001' },
      course: { stringValue: 'BSIT' },
      yearLevel: { stringValue: '3' },
      sectionSet: { stringValue: 'A' },
      status: { stringValue: 'published' },
      revision: { integerValue: '1' },
      deviceRegistration: { stringValue: qr.rawJson },
      profileChange: {
        mapValue: {
          fields: {
            status: { stringValue: 'submitted' },
            affiliation: { stringValue: 'student' },
            displayName: { stringValue: 'Proposed Renamed Student' },
            studentNumber: { stringValue: '2026-9002' },
          },
        },
      },
    },
  };

  let commitCount = 0;
  const prevEnv = {
    FIREBASE_PROJECT_ID: process.env.FIREBASE_PROJECT_ID,
    PUBLISHER_PRIVATE_KEY_SEED: process.env.PUBLISHER_PRIVATE_KEY_SEED,
    PUBLISHER_DELEGATION_JSON: process.env.PUBLISHER_DELEGATION_JSON,
    FIREBASE_AUTH_EMULATOR_HOST: process.env.FIREBASE_AUTH_EMULATOR_HOST,
    FIRESTORE_EMULATOR_HOST: process.env.FIRESTORE_EMULATOR_HOST,
  };
  const prevFetch = globalThis.fetch;

  process.env.FIREBASE_PROJECT_ID = 'dnsc-pilot';
  process.env.PUBLISHER_PRIVATE_KEY_SEED = publisher.seed;
  process.env.PUBLISHER_DELEGATION_JSON = JSON.stringify(delegation);
  process.env.FIREBASE_AUTH_EMULATOR_HOST = '127.0.0.1:9099';
  process.env.FIRESTORE_EMULATOR_HOST = '127.0.0.1:8080';

  const b64u = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const token = `${b64u({ alg: 'none', typ: 'JWT' })}.${b64u({
    sub: 'admin-r9',
    admin: true,
    aud: 'dnsc-pilot',
    iss: 'https://securetoken.google.com/dnsc-pilot',
    exp: Math.floor(Date.now() / 1000) + 3600,
  })}.`;

  globalThis.fetch = async (url, init) => {
    const u = String(url);
    if (u.endsWith('/documents/pilotApplications/uid-r9-legacy')) {
      return new Response(JSON.stringify(appDoc), { status: 200 });
    }
    if (u.includes('/documents/trustDirectory/current') || u.includes('/documents/campusRegistrations/')) {
      return new Response(JSON.stringify({ error: { status: 'NOT_FOUND' } }), { status: 404 });
    }
    if (u.endsWith('/documents:commit')) {
      commitCount++;
      const parsedBody = JSON.parse(init.body);
      assert.equal(parsedBody.writes.length, 1);
      appDoc = {
        name: appDoc.name,
        updateTime: '2026-11-26T10:05:00Z',
        fields: parsedBody.writes[0].update.fields,
      };
      return new Response(JSON.stringify({ writeResults: [{}] }), { status: 200 });
    }
    throw new Error(`Unexpected fetch URL: ${u}`);
  };

  async function invokeDecline() {
    const result = { statusCode: 200, headers: {}, body: null };
    const req = {
      method: 'POST',
      headers: { authorization: `Bearer ${token}` },
      body: {
        action: 'decline_profile_change',
        decisionId: 'dec-r9-decline',
        accountUid: 'uid-r9-legacy',
        expectedRevision: 1,
        reason: 'Missing registrar endorsement',
      },
    };
    const res = {
      setHeader(k, v) {
        result.headers[k] = v;
      },
      status(code) {
        result.statusCode = code;
        return this;
      },
      json(obj) {
        result.body = obj;
        return this;
      },
      end() {
        return this;
      },
    };
    await handler(req, res);
    return result;
  }

  try {
    const first = await invokeDecline();
    assert.equal(first.statusCode, 200);
    assert.equal(first.body.ok, true);
    assert.equal(first.body.status, 'rejected');
    assert.equal(first.body.idempotent, false);
    assert.equal(first.body.registrationId, null);
    assert.equal(commitCount, 1);
    assert.equal(appDoc.fields.displayName.stringValue, 'Legacy Active Student');
    assert.equal(
      appDoc.fields.profileChange.mapValue.fields.status.stringValue,
      'rejected',
    );
    assert.equal(
      appDoc.fields.profileChange.mapValue.fields.reason.stringValue,
      'Missing registrar endorsement',
    );

    const retry = await invokeDecline();
    assert.equal(retry.statusCode, 200);
    assert.equal(retry.body.ok, true);
    assert.equal(retry.body.status, 'rejected');
    assert.equal(retry.body.idempotent, true);
    assert.equal(retry.body.registrationId, null);
    assert.equal(commitCount, 1);
  } finally {
    globalThis.fetch = prevFetch;
    for (const [k, v] of Object.entries(prevEnv)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
});
