import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildWebConfigArgs } from '../../tools/vercel/build_web.mjs';

test('vercel.json invokes build_web.mjs and rejects missing Firebase defines', () => {
  const vercel = JSON.parse(fs.readFileSync(new URL('../../vercel.json', import.meta.url), 'utf8'));
  assert.equal(vercel.buildCommand, 'node tools/vercel/build_web.mjs');

  assert.throws(
    () => buildWebConfigArgs({ DNSC_FIREBASE_API_KEY: 'key-only' }),
    /DNSC_FIREBASE_PROJECT/,
  );
  assert.throws(
    () => buildWebConfigArgs({ DNSC_FIREBASE_PROJECT: 'proj-only' }),
    /DNSC_FIREBASE_API_KEY/,
  );

  const args = buildWebConfigArgs({
    DNSC_FIREBASE_PROJECT: 'dnsc-staging',
    DNSC_FIREBASE_API_KEY: 'public-api-key',
    DNSC_PUBLISHER_URL: 'https://admin.staging.example/api/publish-approval',
  });
  assert.deepEqual(args, [
    'build',
    'web',
    '--release',
    '-t',
    'lib/admin_web_main.dart',
    '--dart-define=DNSC_FIREBASE_PROJECT=dnsc-staging',
    '--dart-define=DNSC_FIREBASE_API_KEY=public-api-key',
    '--dart-define=DNSC_PUBLISHER_URL=https://admin.staging.example/api/publish-approval',
  ]);
});

test('build_web.mjs CLI fails cleanly when env vars are missing and passes defines when set', () => {
  const missingRes = spawnSync(process.execPath, ['tools/vercel/build_web.mjs'], {
    env: { PATH: process.env.PATH },
    encoding: 'utf8',
  });
  assert.notEqual(missingRes.status, 0);
  assert.match(missingRes.stderr, /DNSC_FIREBASE_PROJECT/);
  assert.match(missingRes.stderr, /DNSC_FIREBASE_API_KEY/);

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vercel-web-build-'));
  try {
    const outFile = path.join(tmpDir, 'args.txt');
    const stubScript = path.join(
      tmpDir,
      process.platform === 'win32' ? 'fake_flutter.cmd' : 'fake_flutter.sh',
    );
    if (process.platform === 'win32') {
      fs.writeFileSync(stubScript, `@echo off\r\necho %* > "${outFile}"\r\n`, 'utf8');
    } else {
      fs.writeFileSync(stubScript, `#!/bin/sh\necho "$@" > "${outFile}"\n`, 'utf8');
      fs.chmodSync(stubScript, 0o755);
    }
    const okRes = spawnSync(process.execPath, ['tools/vercel/build_web.mjs'], {
      env: {
        ...process.env,
        FLUTTER_BIN: stubScript,
        DNSC_FIREBASE_PROJECT: 'dnsc-pilot',
        DNSC_FIREBASE_API_KEY: 'web-api-key',
      },
      encoding: 'utf8',
    });
    assert.equal(okRes.status, 0);
    const captured = fs.readFileSync(outFile, 'utf8');
    assert.match(captured, /--dart-define=DNSC_FIREBASE_PROJECT=dnsc-pilot/);
    assert.match(captured, /--dart-define=DNSC_FIREBASE_API_KEY=web-api-key/);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
