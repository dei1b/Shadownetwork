import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export function buildWebConfigArgs(env = process.env) {
  const project = String(env.DNSC_FIREBASE_PROJECT ?? '').trim();
  const apiKey = String(env.DNSC_FIREBASE_API_KEY ?? '').trim();
  const publisherUrl = String(env.DNSC_PUBLISHER_URL ?? '').trim();
  const missing = [];
  if (!project) missing.push('DNSC_FIREBASE_PROJECT');
  if (!apiKey) missing.push('DNSC_FIREBASE_API_KEY');
  if (missing.length > 0) {
    throw new Error(
      `Missing required Firebase web build variable(s): ${missing.join(', ')}.`,
    );
  }
  const args = [
    'build',
    'web',
    '--release',
    '-t',
    'lib/admin_web_main.dart',
    `--dart-define=DNSC_FIREBASE_PROJECT=${project}`,
    `--dart-define=DNSC_FIREBASE_API_KEY=${apiKey}`,
  ];
  if (publisherUrl) {
    args.push(`--dart-define=DNSC_PUBLISHER_URL=${publisherUrl}`);
  }
  return args;
}

export function runWebBuild(env = process.env) {
  const args = buildWebConfigArgs(env);
  const flutterBin = String(env.FLUTTER_BIN ?? '').trim() || 'flutter';
  const result = spawnSync(flutterBin, args, {
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });
  if (result.error) {
    throw result.error;
  }
  return result.status ?? 1;
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  try {
    const code = runWebBuild(process.env);
    process.exit(code);
  } catch (err) {
    console.error(err?.message || String(err));
    process.exit(1);
  }
}
