// Tests for ops/provision.mjs: a stand-in Supabase Management API whose database/query on the control project runs on a
// real control database (CONTROL_TEST_DB, with control/migrations applied), and a stand-in for Resend.
//   CONTROL_TEST_DB=postgresql://… node --test ops/tests/provision.test.mjs
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { execFile, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { publicKey, authSettings } from '../provision.mjs';

const DB = process.env.CONTROL_TEST_DB;
const CONTROL = 'controlrefaaaaaaaaaa', ORG = 'acme-org';
const lit = (v) => (v === null || v === undefined ? 'NULL' : `'${String(v).replaceAll("'", "''")}'`);
const sql = (q) => execFileSync('psql', [DB, '-XqtA', '-v', 'ON_ERROR_STOP=1', '-c', q], { encoding: 'utf8' }).trim();

const calls = [], mails = [];
let projects = {};          // ref -> { name, status, polls }
let created = 0;
function handler(req, res) {
  let raw = '';
  req.on('data', (c) => (raw += c));
  req.on('end', () => {
    const body = raw ? JSON.parse(raw) : null;
    const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
    if (req.url === '/emails') { mails.push(body); return send(200, { id: 'm' }); }
    calls.push({ method: req.method, url: req.url, body });
    if (req.url === `/v1/projects/${CONTROL}/database/query`) {
      const q = body.query.replace(/\$(\d+)/g, (_, n) => lit(body.parameters?.[n - 1]));
      try {
        const out = execFileSync('psql', [DB, '-XqtA', '-v', 'ON_ERROR_STOP=1', '-c', `select coalesce(json_agg(x), '[]') from (${q}) x`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
        return send(201, JSON.parse(out.trim()));
      } catch (e) { return send(400, { message: String(e.stderr) }); }
    }
    if (req.url === `/v1/projects/${CONTROL}`) return send(200, { ref: CONTROL, organization_slug: ORG, region: 'eu-central-1', status: 'ACTIVE_HEALTHY' });
    if (req.url.startsWith(`/v1/organizations/${ORG}/projects?search=`)) {
      return send(200, { projects: Object.entries(projects).map(([ref, p]) => ({ ref, name: p.name, status: p.status })) });
    }
    if (req.method === 'POST' && req.url === '/v1/projects') {
      created++;
      const ref = `newref${'x'.repeat(14 - String(created).length)}${created}`.replace(/\d/g, (d) => 'abcdefghij'[d]);
      projects[ref] = { name: body.name, status: 'COMING_UP', polls: 0 };
      return send(201, { ref, name: body.name, status: 'COMING_UP' });
    }
    const m = /^\/v1\/projects\/([a-z]+)(\/.*)?$/.exec(req.url);
    if (m && projects[m[1]]) {
      const p = projects[m[1]];
      if (!m[2] && req.method === 'GET') { if (++p.polls >= 2) p.status = 'ACTIVE_HEALTHY'; return send(200, { ref: m[1], status: p.status }); }
      if (m[2] === '/config/auth' && req.method === 'PATCH') return send(200, {});
      if (m[2] === '/secrets' && req.method === 'POST') return send(201, null);
      if (m[2] === '/api-keys?reveal=false') return send(200, [
        { type: 'legacy', name: 'anon', api_key: 'eyJanon' },
        { type: 'secret', name: 'default', api_key: 'sb_secret_****' },
        { type: 'publishable', name: 'default', api_key: 'sb_publishable_newkey' },
      ]);
    }
    send(404, { message: `no route ${req.method} ${req.url}` });
  });
}
const server = http.createServer(handler);
let base;
const dir = mkdtempSync(join(tmpdir(), 'qs-prov-'));
before(async () => {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
  sql(`delete from public.tenants where subdomain like 'pt-%'`);
  sql(`set role service_role; select public.request_signup('{"subdomain":"pt-shop","business":"Pt Shop","name":"Jo K","email":"jo@example.com","phone":"+243 81 000 0000","shops":1,"lang":"en"}', 'iph')`);
});
after(() => { server.close(); sql(`delete from public.tenants where subdomain like 'pt-%'`); });

function run(args) {
  const out = join(dir, `out-${Math.random()}`); writeFileSync(out, '');
  return new Promise((resolve) => {
    execFile(process.execPath, ['ops/provision.mjs', ...args], {
      env: { PATH: process.env.PATH, SUPABASE_API_URL: base, RESEND_API_URL: `${base}/emails`, SUPABASE_ACCESS_TOKEN: 't', CONTROL_PROJECT_REF: CONTROL,
        RESEND_API_KEY: 're', OWNER_EMAIL: 'owner@example.com', GITHUB_OUTPUT: out, PROVISION_POLL_MS: '5', PROVISION_WAIT_MS: '5000' },
    }, (err, stdout, stderr) => resolve({ code: err ? err.code : 0, stdout, stderr, output: readFileSync(out, 'utf8') }));
  });
}

test('the public key is the publishable one, or the legacy anon key', () => {
  assert.equal(publicKey([{ type: 'legacy', name: 'anon', api_key: 'eyJ' }, { type: 'publishable', api_key: 'sb_publishable_x' }]), 'sb_publishable_x');
  assert.equal(publicKey([{ type: 'legacy', name: 'service_role', api_key: 'eyJs' }, { type: 'legacy', name: 'anon', api_key: 'eyJa' }]), 'eyJa');
  assert.equal(publicKey([{ type: 'secret', api_key: 'sb_secret_x' }]), null);
  assert.equal(authSettings('abc').site_url, 'https://abc.getquicksales.com');
});

test('a request you have not approved is not set up', { skip: !DB }, async () => {
  const r = await run(['start', 'pt-shop']);
  assert.notEqual(r.code, 0);
  assert.match(r.stderr, /pending, not approved/);
  assert.equal(created, 0);
});

test('approved: one project is made in the control project\'s region, waited for, and given its sign-in settings', { skip: !DB }, async () => {
  sql(`set role service_role; select public.approve_signup('pt-shop')`);
  calls.length = 0;
  const r = await run(['start', 'pt-shop']);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(created, 1);
  const make = calls.find((c) => c.method === 'POST' && c.url === '/v1/projects');
  assert.deepEqual([make.body.name, make.body.organization_slug, make.body.region_selection], ['qs-pt-shop', ORG, { type: 'specific', code: 'eu-central-1' }]);
  assert.ok(make.body.db_pass.length >= 30);
  const ref = /ref=([a-z]+)/.exec(r.output)[1];
  assert.equal(sql(`select project_ref || '|' || backup_name from public.tenants where subdomain = 'pt-shop'`), `${ref}|pt-shop`);
  const auth = calls.find((c) => c.url === `/v1/projects/${ref}/config/auth`);
  assert.deepEqual(auth.body, authSettings('pt-shop'));
  assert.equal(auth.body.disable_signup, true);
  assert.deepEqual(calls.find((c) => c.url === `/v1/projects/${ref}/secrets`).body, [{ name: 'SIM_ALLOWED_ORIGIN', value: 'https://pt-shop.getquicksales.com' }]);
  const firstPatch = calls.findIndex((c) => c.method === 'PATCH');
  assert.ok(calls.slice(0, firstPatch).some((c) => c.url === `/v1/projects/${ref}` && c.method === 'GET'), 'waited before configuring');
});

test('run again: the same project is used, nothing new is made', { skip: !DB }, async () => {
  const r = await run(['start', 'pt-shop']);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(created, 1);
});

test('a run that stopped right after making the project finds it by name', { skip: !DB }, async () => {
  sql(`set role service_role; select public.request_signup('{"subdomain":"pt-lost","business":"Lost Ltd","name":"Al B","email":"al@example.com","phone":"+243 81 000 0001"}', 'iph2')`);
  sql(`set role service_role; select public.approve_signup('pt-lost')`);
  projects.orphanrefaaaaaaaaaaa = { name: 'qs-pt-lost', status: 'ACTIVE_HEALTHY', polls: 5 };
  const r = await run(['start', 'pt-lost']);
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /Found the project made earlier: orphanrefaaaaaaaaaaa/);
  assert.equal(created, 1);
  assert.equal(sql(`select project_ref from public.tenants where subdomain = 'pt-lost'`), 'orphanrefaaaaaaaaaaa');
});

test('finish: the client goes live with the publishable key and is emailed the link in their language', { skip: !DB }, async () => {
  const ref = sql(`select project_ref from public.tenants where subdomain = 'pt-shop'`);
  mails.length = 0;
  const r = await run(['finish', 'pt-shop', ref]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(sql(`select status || '|' || supabase_url || '|' || anon_key from public.tenants where subdomain = 'pt-shop'`), `active|https://${ref}.supabase.co|sb_publishable_newkey`);
  assert.equal(sql(`select public.tenant_config('pt-shop')->>'url'`), `https://${ref}.supabase.co`);
  assert.deepEqual(mails.map((m) => [m.to[0], m.subject]), [['jo@example.com', 'Your QuickSales is ready'], ['owner@example.com', 'Ready: Pt Shop (pt-shop)']]);
  assert.match(mails[0].html, /href="https:\/\/pt-shop\.getquicksales\.com"/);
  assert.match(mails[1].html, /pt-shop\/daily\//);
});

test('fail: marked failed with the reason, and you are emailed', { skip: !DB }, async () => {
  mails.length = 0;
  const r = await run(['fail', 'pt-lost', 'Pooler <not> ready']);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(sql(`select status || '|' || error from public.tenants where subdomain = 'pt-lost'`), 'failed|Pooler <not> ready');
  assert.equal(mails[0].to[0], 'owner@example.com');
  assert.match(mails[0].html, /Pooler &lt;not&gt; ready/);
});

test('an active client is never set up again', { skip: !DB }, async () => {
  const r = await run(['start', 'pt-shop']);
  assert.notEqual(r.code, 0);
  assert.match(r.stderr, /already set up/);
});

test('a bad subdomain is refused before anything is called', async () => {
  calls.length = 0;
  const r = await run(['start', 'Bad;rm -rf']);
  assert.notEqual(r.code, 0);
  assert.equal(calls.length, 0);
});
