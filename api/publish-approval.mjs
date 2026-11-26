import crypto from 'node:crypto';
import { applyDecisionAndBuildCommit, PublisherError } from './_lib/publisher_core.mjs';

let cachedCerts = { expiresAt: 0, certs: {} };
let cachedServiceToken = { expiresAt: 0, token: null };

async function getFirebasePublicCerts() {
  if (Date.now() < cachedCerts.expiresAt && Object.keys(cachedCerts.certs).length > 0) {
    return cachedCerts.certs;
  }
  const resp = await fetch(
    'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com',
  );
  if (!resp.ok) {
    throw new PublisherError(502, 'Could not fetch Firebase signing certificates.', 'auth_certs_unavailable');
  }
  const cacheControl = resp.headers.get('cache-control') || '';
  const maxAgeMatch = /max-age=(\d+)/i.exec(cacheControl);
  const maxAgeMs = maxAgeMatch ? Number(maxAgeMatch[1]) * 1000 : 300_000;
  const certs = await resp.json();
  cachedCerts = { expiresAt: Date.now() + maxAgeMs, certs };
  return certs;
}

function decodeJwtPart(part) {
  const pad = '='.repeat((4 - (part.length % 4)) % 4);
  return JSON.parse(Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/') + pad, 'base64').toString('utf8'));
}

async function verifyFirebaseIdToken(bearerToken, projectId) {
  if (!bearerToken) {
    throw new PublisherError(401, 'Reviewer authorization header is required.', 'unauthenticated');
  }
  const parts = bearerToken.split('.');
  if (parts.length !== 3) {
    throw new PublisherError(401, 'Malformed ID token.', 'invalid_token');
  }
  const header = decodeJwtPart(parts[0]);
  const claims = decodeJwtPart(parts[1]);
  const nowSec = Math.floor(Date.now() / 1000);
  if (claims.aud !== projectId || claims.iss !== `https://securetoken.google.com/${projectId}`) {
    throw new PublisherError(403, 'Token does not belong to this Firebase project.', 'invalid_token_project');
  }
  if (!claims.sub || typeof claims.sub !== 'string') {
    throw new PublisherError(401, 'Token subject is missing.', 'invalid_token');
  }
  if (Number(claims.exp ?? 0) <= nowSec) {
    throw new PublisherError(401, 'Reviewer session expired. Sign in again.', 'token_expired');
  }

  if (process.env.FIREBASE_AUTH_EMULATOR_HOST && header.alg === 'none') {
    if (claims.admin !== true) {
      throw new PublisherError(403, 'Reviewer admin claim is required.', 'not_reviewer');
    }
    return claims;
  }

  if (header.alg !== 'RS256' || !header.kid) {
    throw new PublisherError(401, 'Unsupported ID token algorithm.', 'invalid_token_alg');
  }
  const certs = await getFirebasePublicCerts();
  const certPem = certs[header.kid];
  if (!certPem) {
    throw new PublisherError(401, 'Unknown Firebase signing key.', 'unknown_kid');
  }
  const sig = Buffer.from(
    parts[2].replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (parts[2].length % 4)) % 4),
    'base64',
  );
  const ok = crypto.verify('RSA-SHA256', Buffer.from(`${parts[0]}.${parts[1]}`, 'utf8'), certPem, sig);
  if (!ok) {
    throw new PublisherError(401, 'Invalid Firebase ID token signature.', 'invalid_token_signature');
  }
  if (claims.admin !== true) {
    throw new PublisherError(403, 'Reviewer admin claim is required.', 'not_reviewer');
  }
  return claims;
}

function getServiceAccountConfig() {
  if (process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
    const parsed = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON);
    return { clientEmail: parsed.client_email, privateKey: parsed.private_key };
  }
  return {
    clientEmail: process.env.FIREBASE_CLIENT_EMAIL,
    privateKey: process.env.FIREBASE_PRIVATE_KEY?.replace(/\\n/g, '\n'),
  };
}

async function getFirestoreAccessToken() {
  if (process.env.FIRESTORE_EMULATOR_HOST) {
    return 'owner';
  }
  if (cachedServiceToken.token && Date.now() < cachedServiceToken.expiresAt - 60_000) {
    return cachedServiceToken.token;
  }
  const { clientEmail, privateKey } = getServiceAccountConfig();
  if (!clientEmail || !privateKey) {
    throw new PublisherError(500, 'Firebase service account credentials are not configured.', 'server_misconfigured');
  }
  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + 3600;
  const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(
    JSON.stringify({
      iss: clientEmail,
      scope: 'https://www.googleapis.com/auth/datastore',
      aud: 'https://oauth2.googleapis.com/token',
      iat,
      exp,
    }),
  ).toString('base64url');
  const sig = crypto.sign('RSA-SHA256', Buffer.from(`${header}.${payload}`, 'utf8'), privateKey).toString('base64url');
  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${header}.${payload}.${sig}`,
    }),
  });
  if (!resp.ok) {
    throw new PublisherError(502, 'Failed to obtain Firestore service token.', 'oauth_error');
  }
  const json = await resp.json();
  cachedServiceToken = {
    token: json.access_token,
    expiresAt: Date.now() + Number(json.expires_in ?? 3600) * 1000,
  };
  return cachedServiceToken.token;
}

function firestoreOrigin() {
  if (process.env.FIRESTORE_EMULATOR_HOST) {
    return `http://${process.env.FIRESTORE_EMULATOR_HOST}`;
  }
  return 'https://firestore.googleapis.com';
}

function decodeFirestoreValue(v) {
  if (!v || typeof v !== 'object') return null;
  if ('stringValue' in v) return v.stringValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('timestampValue' in v) return v.timestampValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return Number(v.doubleValue);
  if ('nullValue' in v) return null;
  if ('arrayValue' in v) return (v.arrayValue.values ?? []).map(decodeFirestoreValue);
  if ('mapValue' in v) {
    const out = {};
    for (const [k, val] of Object.entries(v.mapValue.fields ?? {})) {
      out[k] = decodeFirestoreValue(val);
    }
    return out;
  }
  return null;
}

function encodeFirestoreValue(value, timestampKeys = new Set(['publishedAt'])) {
  if (value === null || value === undefined) return { nullValue: null };
  if (typeof value === 'boolean') return { booleanValue: value };
  if (typeof value === 'number') {
    return Number.isInteger(value) ? { integerValue: String(value) } : { doubleValue: value };
  }
  if (Array.isArray(value)) {
    return { arrayValue: { values: value.map((item) => encodeFirestoreValue(item, timestampKeys)) } };
  }
  if (typeof value === 'object') {
    const fields = {};
    for (const [k, v] of Object.entries(value)) {
      fields[k] = timestampKeys.has(k) && typeof v === 'string'
        ? { timestampValue: v }
        : encodeFirestoreValue(v, timestampKeys);
    }
    return { mapValue: { fields } };
  }
  return { stringValue: String(value) };
}

function decodeDocument(doc, idFieldName) {
  if (!doc) return null;
  const id = String(doc.name ?? '').split('/').pop();
  const out = { updateTime: doc.updateTime };
  if (idFieldName) out[idFieldName] = id;
  for (const [k, v] of Object.entries(doc.fields ?? {})) {
    out[k] = decodeFirestoreValue(v);
  }
  return out;
}

async function getDoc(origin, accessToken, projectId, collection, docId, idFieldName) {
  if (!docId) return null;
  const resp = await fetch(
    `${origin}/v1/projects/${projectId}/databases/(default)/documents/${collection}/${encodeURIComponent(docId)}`,
    { headers: { authorization: `Bearer ${accessToken}` } },
  );
  if (resp.status === 404) return null;
  if (!resp.ok) {
    throw new PublisherError(resp.status, `Could not read ${collection}/${docId}.`, 'firestore_read_error');
  }
  return decodeDocument(await resp.json(), idFieldName);
}

export function buildFirestoreCommitBody(projectId, writes) {
  const dbRoot = `projects/${projectId}/databases/(default)/documents`;
  return {
    writes: (writes ?? []).map((w) => {
      const fields = {};
      for (const [k, v] of Object.entries(w.fields)) {
        fields[k] = k === 'publishedAt' && typeof v === 'string'
          ? { timestampValue: v }
          : encodeFirestoreValue(v);
      }
      let currentDocument;
      if (w.createOnly === true) {
        currentDocument = { exists: false };
      } else if (w.updateTime) {
        currentDocument = { updateTime: w.updateTime };
      }
      return {
        update: {
          name: `${dbRoot}/${w.collection}/${w.docId}`,
          fields,
        },
        ...(currentDocument ? { currentDocument } : {}),
      };
    }),
  };
}

async function commitWrites(origin, accessToken, projectId, writes) {
  if (!writes || writes.length === 0) return;
  const dbRoot = `projects/${projectId}/databases/(default)/documents`;
  const resp = await fetch(`${origin}/v1/${dbRoot}:commit`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${accessToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(buildFirestoreCommitBody(projectId, writes)),
  });
  if (!resp.ok) {
    const body = await resp.text();
    const status = resp.status === 400 || resp.status === 409 ? 409 : resp.status;
    throw new PublisherError(status, `Directory commit conflicted or failed: ${body}`, 'firestore_commit_error');
  }
}

export async function executeDecisionWithRetry({
  readState,
  applyDecision,
  commitWritesFn,
  maxAttempts = 3,
}) {
  let lastError;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const state = await readState();
    const result = applyDecision(state);
    try {
      await commitWritesFn(result.writes);
      return result;
    } catch (err) {
      if (
        attempt < maxAttempts &&
        err instanceof PublisherError &&
        err.code === 'firestore_commit_error' &&
        err.statusCode === 409
      ) {
        lastError = err;
        continue;
      }
      throw err;
    }
  }
  throw lastError;
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'authorization, content-type');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  if (req.method === 'OPTIONS') {
    return res.status(204).end();
  }
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed.' });
  }

  try {
    const projectId = process.env.FIREBASE_PROJECT_ID || process.env.DNSC_FIREBASE_PROJECT;
    const publisherSeed = process.env.PUBLISHER_PRIVATE_KEY_SEED;
    const publisherDelegation = process.env.PUBLISHER_DELEGATION_JSON;
    if (!projectId || !publisherSeed || !publisherDelegation) {
      throw new PublisherError(500, 'Hosted publisher environment variables are incomplete.', 'server_misconfigured');
    }
    const authHeader = String(req.headers.authorization ?? '');
    const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
    const reviewer = await verifyFirebaseIdToken(token, projectId);
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : (req.body ?? {});

    const accessToken = await getFirestoreAccessToken();
    const origin = firestoreOrigin();

    const accountUid = body.accountUid ?? body.applicationUid ?? null;
    const registrationId = body.registrationId ?? null;
    const result = await executeDecisionWithRetry({
      readState: async () => {
        const [
          existingDirectory,
          application,
          registration,
          linkRequest,
          recoveryRequest,
        ] = await Promise.all([
          getDoc(origin, accessToken, projectId, 'trustDirectory', 'current'),
          getDoc(origin, accessToken, projectId, 'pilotApplications', accountUid, 'uid'),
          getDoc(origin, accessToken, projectId, 'campusRegistrations', registrationId, 'registrationId'),
          body.action === 'approve_link'
            ? getDoc(origin, accessToken, projectId, 'registrationLinkRequests', accountUid, 'accountUid')
            : null,
          body.action === 'approve_recovery'
            ? getDoc(origin, accessToken, projectId, 'registrationRecoveryRequests', accountUid, 'accountUid')
            : null,
        ]);
        return {
          existingDirectory,
          application,
          registration: registration ?? (body.registration ?? null),
          linkRequest,
          recoveryRequest,
        };
      },
      applyDecision: (state) =>
        applyDecisionAndBuildCommit({
          action: body.action,
          decisionId: body.decisionId,
          reviewerUid: reviewer.sub,
          directoryProject: projectId,
          publisherSeed,
          publisherDelegation,
          existingDirectory: state.existingDirectory,
          application: state.application,
          registration: state.registration,
          linkRequest: state.linkRequest,
          recoveryRequest: state.recoveryRequest,
          payload: body,
        }),
      commitWritesFn: (writes) =>
        commitWrites(origin, accessToken, projectId, writes),
    });

    return res.status(200).json({
      ok: true,
      status: result.status,
      idempotent: result.idempotent,
      version: result.version,
      bundle: result.bundle,
      registrationId: result.registrationId,
      decisionId: result.decisionId,
    });
  } catch (err) {
    const status = err instanceof PublisherError ? err.statusCode : 500;
    return res.status(status).json({
      ok: false,
      error: err?.message || 'Hosted publisher error.',
      code: err instanceof PublisherError ? err.code : 'internal_error',
    });
  }
}
