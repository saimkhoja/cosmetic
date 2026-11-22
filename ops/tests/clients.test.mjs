// Tests for ops/clients.mjs against a stand-in for the Supabase Management API. Run: node --test ops/tests/
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { execFile } from 'node:child_process';
import { mkdtempSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CONTROL = 'controlrefaaaaaaaaaa', CLIENT = 'clientrefbbbbbbbbbbb', PAUSED = 'pausedrefcccccccccccc';
const calls = [];
let fail429 = 0;
const rows = [
  { subdomain: 'sapcongo', project_ref: CLIENT, backup_name: 'client2', status: 'active' },
  { subdomain: 'new-shop', project_ref: PAUSED, backup_name: null, status: 'suspended' },
  { subdomain: 'noref', project_ref: null, backup_name: null, status: 'active' },
];
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    calls.push({ method: req.method, url: req.url, auth: req.headers.authorization, body: body ? JSON.parse(body) : null });
    const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
    if (req.headers.authorization !== 'Bearer good-token') return send(401, { message: 'Unauthorized' });
    if (fail429 > 0) { fail429--; return send(429, { message: 'slow down' }); }
    if (req.url === `/v1/projects/${CONTROL}/database/query`) return send(201, rows);
    if (req.url === `/v1/projects/${CLIENT}`) return send(200, { ref: CLIENT, status: 'ACTIVE_HEALTHY' });
    if (req.url === `/v1/projects/${PAUSED}`) return send(200, { ref: PAUSED, status: 'INACTIVE' });
    if (req.url === `/v1/projects/${CLIENT}/config/database/pooler`) return send(200, [
      { database_type: 'READ_REPLICA', db_host: 'replica.example', db_port: 6543, db_name: 'postgres' },
      { database_type: 'PRIMARY', db_host: 'aws-0-eu-central-1.pooler.supabase.com', db_port: 6543, db_name: 'postgres', pool_mode: 'transaction' },
    ]);
    if (req.url === `/v1/projects/${CLIENT}/cli/login-role`) return send(201, { role: 'cli_login_postgres', password: 'p@ss/w:rd?#', ttl_seconds: 600 });
    send(404, { message: 'not found' });
  });
});
let base;
before(async () => { await new Promise((r) => server.listen(0, '127.0.0.1', r)); base = `http://127.0.0.1:${server.address().port}`; });
after(() => server.close());

function run(args, env = {}) {
  return new Promise((resolve) => {
    execFile(process.execPath, ['ops/clients.mjs', ...args], {
      env: { PATH: process.env.PATH, SUPABASE_API_URL: base, SUPABASE_ACCESS_TOKEN: 'good-token', CONTROL_PROJECT_REF: CONTROL, ...env },
    }, (err, stdout, stderr) => resolve({ code: err ? err.code : 0, stdout, stderr }));
  });
}

test('list: every client with a project ref, read-only, with its backup folder and secret name', async () => {
  calls.length = 0;
  const r = await run(['list']);
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(JSON.parse(r.stdout), [
    { subdomain: 'sapcongo', ref: CLIENT, status: 'active', folder: 'client2', db_secret: 'CLIENT2_DB_URL' },
    { subdomain: 'new-shop', ref: PAUSED, status: 'suspended', folder: 'new-shop', db_secret: 'NEW_SHOP_DB_URL' },
  ]);
  assert.match(r.stderr, /noref has no project_ref/);
  assert.equal(calls[0].body.read_only, true);
  assert.match(calls[0].body.query, /from public\.tenants/);
});

test('list <subdomain>: just that one, or a clear error', async () => {
  const r = await run(['list', 'SapCongo']);
  assert.equal(JSON.parse(r.stdout).length, 1);
  const missing = await run(['list', 'nobody']);
  assert.notEqual(missing.code, 0);
  assert.match(missing.stderr, /No client "nobody"/);
});

test('db-url: a temporary login through the session pooler, password encoded, file private', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'qs-'));
  const r = await run(['db-url', CLIENT, join(dir, 'db.url')], { GITHUB_ACTIONS: 'true' });
  assert.equal(r.code, 0, r.stderr);
  const url = readFileSync(join(dir, 'db.url'), 'utf8');
  assert.equal(url, `postgresql://cli_login_postgres.${CLIENT}:p%40ss%2Fw%3Ard%3F%23@aws-0-eu-central-1.pooler.supabase.com:5432/postgres?sslmode=require`);
  assert.equal(statSync(join(dir, 'db.url')).mode & 0o777, 0o600);
  assert.match(r.stdout, /::add-mask::p@ss\/w:rd\?#/);           // masked in the GitHub log
  assert.ok(!r.stdout.replace(/::add-mask::.*\n/g, '').includes('p@ss'), 'password printed outside a mask');
  const u = new URL(url);
  assert.equal(decodeURIComponent(u.password), 'p@ss/w:rd?#');
  assert.equal(calls.find((c) => c.url.endsWith('/cli/login-role')).body.read_only, false);
});

test('db-url: a paused project is refused with the reason', async () => {
  const r = await run(['db-url', PAUSED, '/tmp/never']);
  assert.notEqual(r.code, 0);
  assert.match(r.stderr, /INACTIVE, not ACTIVE_HEALTHY/);
});

test('waits and tries again when Supabase says too many requests', async () => {
  fail429 = 1;
  const r = await run(['list']);
  assert.equal(r.code, 0, r.stderr);
});

test('a wrong token or missing settings say what to fix', async () => {
  assert.match((await run(['list'], { SUPABASE_ACCESS_TOKEN: 'bad' })).stderr, /HTTP 401 \(the access token is wrong or expired\)/);
  assert.match((await run(['list'], { SUPABASE_ACCESS_TOKEN: '' })).stderr, /SUPABASE_ACCESS_TOKEN is not set/);
  assert.match((await run(['list'], { CONTROL_PROJECT_REF: '' })).stderr, /CONTROL_PROJECT_REF is not set/);
});
