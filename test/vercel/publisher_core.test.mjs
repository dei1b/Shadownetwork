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

function makeDelegation(root, publisher, project = 'dnsc-pilot') {
  const now = new Date('2026-11-26T00:00:00.000Z');
  const exp = new Date('2027-11-26T00:00:00.000Z');
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
    issued_at: now.toISOString(),
    expires_at: exp.toISOString(),
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
