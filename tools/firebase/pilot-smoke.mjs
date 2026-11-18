import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

const project = 'demo-shadownetwork-dnsc';
const auth = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1';
const records = `http://127.0.0.1:8080/v1/projects/${project}/databases/(default)/documents`;
const password = 'local-fixture-only';

async function post(url, data, token) {
  return fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token && { Authorization: `Bearer ${token}` }),
    },
    body: JSON.stringify(data),
  });
}

async function signUp() {
  const email = `${randomUUID()}@example.test`;
  const response = await post(`${auth}/accounts:signUp?key=demo`, {
    email, password, returnSecureToken: true,
  });
  assert.equal(response.status, 200, await response.clone().text());
  return response.json();
}

const [student, other, admin] = await Promise.all([signUp(), signUp(), signUp()]);
const claim = await post(`${auth}/projects/${project}/accounts:update`, {
  localId: admin.localId,
  customAttributes: JSON.stringify({ admin: true }),
}, 'owner');
assert.equal(claim.status, 200, await claim.text());
const login = await post(`${auth}/accounts:signInWithPassword?key=demo`, {
  email: admin.email, password, returnSecureToken: true,
});
assert.equal(login.status, 200, await login.clone().text());
const reviewerToken = (await login.json()).idToken;

const creation = await post(
  `${records}/pilotApplications?documentId=${student.localId}`,
  { fields: {
    displayName: { stringValue: 'Synthetic Student' },
    studentNumber: { stringValue: 'TEST-001' },
    courseYear: { stringValue: 'Test course, first year' },
    phone: { stringValue: '' },
    address: { stringValue: '' },
    deviceRegistration: { stringValue: 'synthetic-test-binding' },
    status: { stringValue: 'submitted' },
  } },
  student.idToken,
);
assert.equal(creation.status, 200, await creation.text());

for (const [token, expected] of [[reviewerToken, 200], [other.idToken, 403]]) {
  const record = await fetch(`${records}/pilotApplications/${student.localId}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(record.status, expected, await record.text());

}

console.log('Student submission, admin retrieval, and denial for another student passed.');

const document = `${records}/pilotApplications/${student.localId}`;
async function readApplication(token) {
  const response = await fetch(document, {headers: {Authorization: `Bearer ${token}`}});
  assert.equal(response.status, 200);
  return response.json();
}
const string = value => ({stringValue: value});
const integer = value => ({integerValue: String(value)});
function decision(snapshot, status, revision, reason = 'Check student number', role) {
  return {
    status: string(status),
    revision: integer(revision),
    publicationStatus: string(status === 'approved_pending_publication' ? 'pending' : 'none'),
    reviewHistory: {arrayValue: {values: [
      ...(snapshot.fields.reviewHistory?.arrayValue.values ?? []),
      {mapValue: {fields: {
        reviewerUid: string(admin.localId), status: string(status),
        revision: integer(revision), reason: string(reason),
        ...(role && {role: string(role)}),
      }}},
    ]}},
  };
}
function patch(token, snapshot, fields) {
  return fetch(`${records}:commit`, {
    method: 'POST',
    headers: {Authorization: `Bearer ${token}`, 'Content-Type': 'application/json'},
    body: JSON.stringify({writes: [{
      update: {name: snapshot.name, fields},
      updateMask: {fieldPaths: Object.keys(fields)},
      currentDocument: {updateTime: snapshot.updateTime},
    }]}),
  });
}
const initial = await readApplication(student.idToken);
const correction = decision(initial, 'changes_requested', 1);
assert.equal((await patch(student.idToken, initial, correction)).status, 403);
const competing = await Promise.all([
  patch(reviewerToken, initial, correction),
  patch(reviewerToken, initial, correction),
]);
assert.equal(competing.filter(response => response.ok).length, 1);
const returned = await readApplication(student.idToken);
assert.equal(returned.fields.status.stringValue, 'changes_requested');
assert.equal((await patch(student.idToken, returned, {
  studentNumber: string('TEST-002'), status: string('submitted'), revision: integer(2),
})).status, 200);
const corrected = await readApplication(reviewerToken);
assert.equal((await patch(reviewerToken, corrected,
  decision(corrected, 'approved_pending_publication', 3, '', 'admin'))).status, 403);
assert.equal((await patch(reviewerToken, corrected,
  decision(corrected, 'approved_pending_publication', 3, '', 'responder'))).status, 200);
const approved = await readApplication(student.idToken);
assert.equal(approved.fields.publicationStatus.stringValue, 'pending');
assert.equal(approved.fields.reviewHistory.arrayValue.values.length, 2);
assert.equal(approved.fields.reviewHistory.arrayValue.values[1].mapValue.fields.role.stringValue, 'responder');
const secondSubmission = await post(
  `${records}/pilotApplications?documentId=${other.localId}`,
  {fields: {...initial.fields, studentNumber: string('TEST-003')}},
  other.idToken,
);
assert.equal(secondSubmission.status, 200);
const second = await secondSubmission.json();
assert.equal((await patch(reviewerToken, second, decision(second, 'rejected', 1, ''))).status, 403);
assert.equal((await patch(reviewerToken, second, decision(second, 'rejected', 1, 'Enrollment could not be confirmed'))).status, 200);
console.log('Unauthorized review, concurrent decisions, correction, rejection and approval queue passed.');

const directoryPath = approved.name.split('/pilotApplications/')[0] + '/trustDirectory/current';
const publication = {
  writes: [
    {
      update: {name: approved.name, fields: {
        status: string('published'), publicationStatus: string('published'),
      }},
      updateMask: {fieldPaths: ['status', 'publicationStatus']},
      currentDocument: {updateTime: approved.updateTime},
    },
    {
      update: {name: directoryPath, fields: {
        applicationUid: string(student.localId), version: integer(1),
        bundle: string('synthetic trust directory payload'),
      }},
      updateTransforms: [{fieldPath: 'publishedAt', setToServerValue: 'REQUEST_TIME'}],
    },
  ],
};
assert.equal((await post(`${records}:commit`, publication, student.idToken)).status, 403);
assert.equal((await patch(reviewerToken, approved, {
  status: string('published'), publicationStatus: string('published'),
})).status, 403);
const committed = await post(`${records}:commit`, publication, reviewerToken);
assert.equal(committed.status, 200, await committed.text());
for (const [token, expected] of [[student.idToken, 200], [other.idToken, 403]]) {
  const response = await fetch(`${records}/trustDirectory/current`, {
    headers: {Authorization: `Bearer ${token}`},
  });
  assert.equal(response.status, expected);
}
console.log('Atomic publication and approved-student directory access passed.');

const active = await readApplication(student.idToken);
const contact = {phone: string('09000000000'), address: string('Test address')};
assert.equal((await patch(other.idToken, active, contact)).status, 403);
assert.equal((await patch(student.idToken, active, {
  ...contact, displayName: string('Unauthorized name'),
})).status, 403);
assert.equal((await patch(student.idToken, active, contact)).status, 200);

const identityDetails = {
  displayName: string('Updated Student'),
  studentNumber: string('TEST-004'),
  courseYear: string('Test course, second year'),
};
function profileChange(status, fields = {}) {
  return {mapValue: {fields: {...identityDetails, status: string(status), ...fields}}};
}
const contactSaved = await readApplication(student.idToken);
assert.equal(contactSaved.fields.address.stringValue, 'Test address');
assert.equal((await patch(student.idToken, contactSaved, {
  profileChange: profileChange('published'),
})).status, 403);
assert.equal((await patch(student.idToken, contactSaved, {
  profileChange: profileChange('submitted'),
})).status, 200);

const pending = await readApplication(student.idToken);
assert.equal(pending.fields.displayName.stringValue, 'Synthetic Student');
assert.equal(pending.fields.status.stringValue, 'published');
const directoryWhilePending = await fetch(`${records}/trustDirectory/current`, {
  headers: {Authorization: `Bearer ${student.idToken}`},
});
assert.equal(directoryWhilePending.status, 200);
const reviewer = {reviewerUid: string(admin.localId)};
assert.equal((await patch(reviewerToken, pending, {
  profileChange: profileChange('approved_pending_publication', {
    ...reviewer, displayName: string('Altered by reviewer'),
  }),
})).status, 403);
const review = await patch(reviewerToken, pending, {
  profileChange: profileChange('approved_pending_publication', reviewer),
});
assert.equal(review.status, 200, await review.text());
const reviewed = await readApplication(student.idToken);
const publishFields = {...identityDetails, profileChange: profileChange('published', reviewer)};
assert.equal((await patch(reviewerToken, reviewed, publishFields)).status, 403);

const profilePublication = structuredClone(publication);
profilePublication.writes[0].update.fields = publishFields;
profilePublication.writes[0].updateMask.fieldPaths = Object.keys(publishFields);
profilePublication.writes[0].currentDocument.updateTime = reviewed.updateTime;
profilePublication.writes[1].update.fields.version = integer(2);
const profileCommitted = await post(`${records}:commit`, profilePublication, reviewerToken);
assert.equal(profileCommitted.status, 200, await profileCommitted.text());
const updated = await readApplication(student.idToken);
assert.equal(updated.fields.displayName.stringValue, 'Updated Student');
assert.equal(updated.fields.status.stringValue, 'published');
assert.deepEqual(updated.fields.reviewHistory, active.fields.reviewHistory);
assert.equal(updated.fields.deviceRegistration.stringValue, active.fields.deviceRegistration.stringValue);
console.log('Profile contact edits, review authorization, and atomic identity publication passed.');
