import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {
  applyDecisionAndBuildCommit,
  canonicalJsonEncode,
  ed25519KeyPairFromSeed,
  ed25519Sign,
  keyIdForX25519PublicKey,
  PublisherError,
  toBase64UrlPadded,
  verifyTrustBundle,
} from '../../api/_lib/publisher_core.mjs';
import {
  buildFirestoreCommitBody,
  decodeDocument,
  executeDecisionWithRetry,
} from '../../api/publish-approval.mjs';

function makeEd25519() {
  const seed = crypto.randomBytes(32);
  return { seed, ...ed25519KeyPairFromSeed(seed) };
}

function makeSignedQr(deviceId) {
  const encBytes = crypto.randomBytes(32);
  const encPub = toBase64UrlPadded(encBytes);
  const sigPair = makeEd25519();
  const unsigned = {
    registration_type: 'shadow_network_device_registration',
    schema_version: 2,
    device_id: deviceId,
    public_key: encPub,
    key_id: keyIdForX25519PublicKey(encBytes),
    key_version: 1,
    signing_public_key: sigPair.publicKeyBase64Url,
  };
  const signature = ed25519Sign(
    `shadow-network-registration-v2\n${canonicalJsonEncode(unsigned)}`,
    sigPair.privateKey,
  );
  return JSON.stringify({ ...unsigned, registration_signature: signature });
}

function makeDelegation(root, publisher, project = 'dnsc-pilot') {
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
    issued_at: '2026-11-26T00:00:00.000Z',
    expires_at: '2027-11-26T00:00:00.000Z',
  };
  const signature = ed25519Sign(
    `shadow-network-publisher-delegation-v1\n${canonicalJsonEncode(unsigned)}`,
    root.privateKey,
  );
  return { ...unsigned, signature };
}

test('simultaneous first approvals enforce exists:false on missing directory and merge without losing a phone', async () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const now = new Date('2026-11-26T12:00:00.000Z');

  // In-memory Firestore store enforcing createOnly (exists:false) and updateTime CAS preconditions.
  let seq = 0;
  const docs = new Map();
  const keyFor = (collection, docId) => `${collection}/${docId}`;
  const setDoc = (collection, docId, fields) => {
    seq += 1;
    docs.set(keyFor(collection, docId), {
      updateTime: `2026-11-26T12:00:0${seq}.000Z`,
      ...fields,
    });
  };
  setDoc('pilotApplications', 'uid-alice', {
    uid: 'uid-alice',
    affiliation: 'student',
    displayName: 'Alice',
    studentNumber: '2026-001',
    course: 'BSIT',
    yearLevel: '4',
    sectionSet: 'A',
    status: 'submitted',
    revision: 0,
    deviceRegistration: makeSignedQr('phone-alice'),
  });
  setDoc('pilotApplications', 'uid-bob', {
    uid: 'uid-bob',
    affiliation: 'student',
    displayName: 'Bob',
    studentNumber: '2026-002',
    course: 'BSIT',
    yearLevel: '4',
    sectionSet: 'B',
    status: 'submitted',
    revision: 0,
    deviceRegistration: makeSignedQr('phone-bob'),
  });

  const commitCas = (writes) => {
    const commitBody = buildFirestoreCommitBody('dnsc-pilot', writes);
    for (let i = 0; i < writes.length; i += 1) {
      const w = writes[i];
      const existing = docs.get(keyFor(w.collection, w.docId));
      const cond = commitBody.writes[i].currentDocument;
      if (w.collection === 'trustDirectory') {
        assert.ok(cond, 'trustDirectory write must always include a CAS precondition');
      }
      if (cond?.exists === false && existing) {
        throw new PublisherError(409, 'Document already exists.', 'firestore_commit_error');
      }
      if (cond?.updateTime && (!existing || existing.updateTime !== cond.updateTime)) {
        throw new PublisherError(409, 'Document updateTime conflicted.', 'firestore_commit_error');
      }
    }
    for (const w of writes) {
      setDoc(w.collection, w.docId, w.fields);
    }
  };

  // Both reviewers read BEFORE either commits (empty trustDirectory/current).
  const initialSnapshotAlice = {
    existingDirectory: null,
    application: { ...docs.get('pilotApplications/uid-alice') },
    registration: null,
  };
  const initialSnapshotBob = {
    existingDirectory: null,
    application: { ...docs.get('pilotApplications/uid-bob') },
    registration: null,
  };

  let aliceReads = 0;
  const aliceResult = await executeDecisionWithRetry({
    readState: async () => {
      aliceReads += 1;
      if (aliceReads === 1) return initialSnapshotAlice;
      return {
        existingDirectory: { ...docs.get('trustDirectory/current') },
        application: { ...docs.get('pilotApplications/uid-alice') },
        registration: null,
      };
    },
    applyDecision: (state) =>
      applyDecisionAndBuildCommit({
        action: 'approve_online',
        decisionId: 'dec-alice',
        reviewerUid: 'admin-1',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher.seed,
        publisherDelegation: delegation,
        existingDirectory: state.existingDirectory,
        application: state.application,
        registration: state.registration,
        payload: { registrationId: 'reg-alice', role: 'civilian' },
        now,
      }),
    commitWritesFn: commitCas,
  });
  assert.equal(aliceResult.version, 1);

  let bobReads = 0;
  const bobResult = await executeDecisionWithRetry({
    readState: async () => {
      bobReads += 1;
      if (bobReads === 1) return initialSnapshotBob;
      return {
        existingDirectory: { ...docs.get('trustDirectory/current') },
        application: { ...docs.get('pilotApplications/uid-bob') },
        registration: null,
      };
    },
    applyDecision: (state) =>
      applyDecisionAndBuildCommit({
        action: 'approve_online',
        decisionId: 'dec-bob',
        reviewerUid: 'admin-2',
        directoryProject: 'dnsc-pilot',
        publisherSeed: publisher.seed,
        publisherDelegation: delegation,
        existingDirectory: state.existingDirectory,
        application: state.application,
        registration: state.registration,
        payload: { registrationId: 'reg-bob', role: 'responder' },
        now,
      }),
    commitWritesFn: commitCas,
  });

  assert.equal(bobReads, 2);
  assert.equal(bobResult.version, 2);
  const finalBundle = verifyTrustBundle(JSON.parse(bobResult.bundle), {
    expectedProject: 'dnsc-pilot',
    now,
  });
  assert.deepEqual(
    finalBundle.approved_devices.map((d) => d.device_id).sort(),
    ['phone-alice', 'phone-bob'],
  );
});

test('decodeDocument and publisher never persist updateTime as a field and ignore legacy field updateTime', () => {
  const root = makeEd25519();
  const publisher = makeEd25519();
  const delegation = makeDelegation(root, publisher);
  const now = new Date('2026-11-26T12:00:00.000Z');
  const qrJson = makeSignedQr('phone-meta-check');

  const rawFirestoreDoc = {
    name: 'projects/dnsc-pilot/databases/(default)/documents/pilotApplications/uid-meta',
    updateTime: '2026-11-26T12:05:00.000Z',
    fields: {
      affiliation: { stringValue: 'student' },
      displayName: { stringValue: 'Meta Check' },
      studentNumber: { stringValue: '2026-777' },
      course: { stringValue: 'BSIT' },
      yearLevel: { stringValue: '3' },
      sectionSet: { stringValue: 'C' },
      status: { stringValue: 'submitted' },
      revision: { integerValue: '0' },
      deviceRegistration: { stringValue: qrJson },
      // Simulate a legacy doc poisoned with a persisted updateTime field.
      updateTime: { stringValue: '1999-01-01T00:00:00.000Z' },
    },
  };
  const decoded = decodeDocument(rawFirestoreDoc, 'uid');
  assert.equal(decoded.updateTime, '2026-11-26T12:05:00.000Z');
  assert.equal(Object.hasOwn(decoded.fields, 'updateTime'), false);

  const correction = applyDecisionAndBuildCommit({
    action: 'request_changes',
    decisionId: 'dec-corr-meta',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    application: decoded,
    payload: { reason: 'Check ID number' },
    now,
  });
  assert.equal(correction.writes[0].updateTime, '2026-11-26T12:05:00.000Z');
  assert.equal(Object.hasOwn(correction.writes[0].fields, 'updateTime'), false);
  const commitCorrection = buildFirestoreCommitBody('dnsc-pilot', correction.writes);
  assert.equal(commitCorrection.writes[0].currentDocument.updateTime, '2026-11-26T12:05:00.000Z');
  assert.equal(Object.hasOwn(commitCorrection.writes[0].update.fields, 'updateTime'), false);

  // Applicant resubmits -> reviewer approves online cleanly.
  const resubmitted = {
    id: 'uid-meta',
    updateTime: '2026-11-26T12:06:00.000Z',
    fields: {
      ...correction.writes[0].fields,
      status: 'submitted',
      revision: 2,
    },
  };
  const approved = applyDecisionAndBuildCommit({
    action: 'approve_online',
    decisionId: 'dec-app-meta',
    reviewerUid: 'admin-1',
    directoryProject: 'dnsc-pilot',
    publisherSeed: publisher.seed,
    publisherDelegation: delegation,
    application: resubmitted,
    payload: { role: 'civilian', registrationId: 'reg-meta' },
    now,
  });
  const commitApproved = buildFirestoreCommitBody('dnsc-pilot', approved.writes);
  for (const w of commitApproved.writes) {
    assert.equal(Object.hasOwn(w.update.fields, 'updateTime'), false);
  }
  assert.equal(commitApproved.writes[0].currentDocument.updateTime, '2026-11-26T12:06:00.000Z');
});
