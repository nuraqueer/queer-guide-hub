import { mkdirSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
// Disposable certificate fixtures, never a production trust-policy override.
mkdirSync('tmp/webhook-tls', { recursive: true });
const run = (command, args) => execFileSync(command, args, { stdio: ['ignore', 'pipe', 'pipe'] });
run('openssl', [
  'req',
  '-x509',
  '-newkey',
  'rsa:2048',
  '-nodes',
  '-keyout',
  'tmp/webhook-tls/ca-key.pem',
  '-out',
  'tmp/webhook-tls/ca.pem',
  '-days',
  '1',
  '-subj',
  '/CN=RedirectTestCA',
  '-addext',
  'basicConstraints=critical,CA:TRUE',
]);
run('openssl', [
  'req',
  '-newkey',
  'rsa:2048',
  '-nodes',
  '-keyout',
  'tmp/webhook-tls/key.pem',
  '-out',
  'tmp/webhook-tls/receiver.csr',
  '-subj',
  '/CN=receiver.example.org',
]);
writeFileSync(
  'tmp/webhook-tls/extensions.cnf',
  'subjectAltName=DNS:receiver.example.org\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n',
);
run('openssl', [
  'x509',
  '-req',
  '-in',
  'tmp/webhook-tls/receiver.csr',
  '-CA',
  'tmp/webhook-tls/ca.pem',
  '-CAkey',
  'tmp/webhook-tls/ca-key.pem',
  '-CAcreateserial',
  '-out',
  'tmp/webhook-tls/cert.pem',
  '-days',
  '1',
  '-extfile',
  'tmp/webhook-tls/extensions.cnf',
]);
execFileSync(
  process.env.REDIRECT_DENO_BIN ?? 'deno',
  [
    'test',
    '--no-config',
    '--node-modules-dir=none',
    '--allow-net=127.0.0.1',
    '--allow-read=tmp/webhook-tls',
    'supabase/functions/redirect-webhooks-dispatch/tests',
  ],
  { stdio: 'inherit' },
);
