// Tests for the control project's Edge Functions (signup, approve) against the real control database functions.
//   CONTROL_TEST_DB=postgresql://… deno test -A control/tests/functions_test.ts
// The database must have control/migrations applied (control/tests/run.sh does this). Supabase's REST layer is played
// by psql as service_role; Resend and GitHub are recorded instead of called.
import { assert, assertEquals, assertMatch } from 'jsr:@std/assert@1';

const DB = Deno.env.get('CONTROL_TEST_DB');
if (!DB) throw new Error('Set CONTROL_TEST_DB');

const SECRET = 'test-approve-secret-0123456789abcdef';
Deno.env.set('APPROVE_SECRET', SECRET);
Deno.env.set('SUPABASE_URL', 'http://control.test');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'eyJ.test.key');
Deno.env.set('RESEND_API_KEY', 're_test');
Deno.env.set('OWNER_EMAIL', 'owner@example.com');
Deno.env.set('MAIL_FROM', 'QuickSales <hello@getquicksales.com>');
Deno.env.set('SITE_DOMAIN', 'getquicksales.com');
Deno.env.set('GITHUB_DISPATCH_TOKEN', 'ghp_test');
Deno.env.set('GITHUB_REPO', 'saimkhoja/cosmetic');
Deno.env.set('SIGNUP_ALLOWED_ORIGIN', 'https://getquicksales.com,https://www.getquicksales.com');

const lit = (v: unknown) => v === null || v === undefined ? 'NULL' : `'${(typeof v === 'string' ? v : JSON.stringify(v)).replaceAll("'", "''")}'`;
async function psql(sql: string) {
  const out = await new Deno.Command('psql', { args: [DB!, '-XqtA', '-v', 'ON_ERROR_STOP=1', '-c', sql], stdout: 'piped', stderr: 'piped' }).output();
  return { ok: out.success, stdout: new TextDecoder().decode(out.stdout).trim(), stderr: new TextDecoder().decode(out.stderr) };
}

const mails: { to: string; subject: string; html: string }[] = [];
const dispatches: { url: string; body: { ref: string; inputs: { subdomain: string } } }[] = [];
let githubStatus = 204;
const realFetch = globalThis.fetch;
globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = String(input);
  const body = init?.body ? JSON.parse(String(init.body)) : null;
  if (url.startsWith('http://control.test/rest/v1/rpc/')) {
    const fn = url.split('/').pop()!;
    assertEquals((init!.headers as Record<string, string>).apikey, 'eyJ.test.key');
    const args = Object.entries(body ?? {}).map(([k, v]) => `${k} => ${lit(v)}`).join(', ');
    const r = await psql(`set role service_role; select coalesce(to_json(public.${fn}(${args}))::text, 'null')`);
    if (!r.ok) {
      const message = /ERROR:\s+(.*)/.exec(r.stderr)?.[1] ?? r.stderr;
      return new Response(JSON.stringify({ message }), { status: 400 });
    }
    const last = r.stdout.split('\n').pop() || 'null';
    return new Response(last === '' ? 'null' : last, { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  if (url === 'https://api.resend.com/emails') {
    mails.push({ to: body.to[0], subject: body.subject, html: body.html });
    return new Response('{"id":"x"}', { status: 200 });
  }
  if (url.startsWith('https://api.github.com/')) {
    dispatches.push({ url, body });
    return new Response(githubStatus === 204 ? null : '{"message":"Bad credentials"}', { status: githubStatus });
  }
  return realFetch(input, init);
};

// load the functions without starting servers
const serve = Deno.serve;
(Deno as unknown as { serve: unknown }).serve = () => ({}) as unknown;
const signup = await import('../supabase/functions/signup/index.ts');
const approve = await import('../supabase/functions/approve/index.ts');
(Deno as unknown as { serve: unknown }).serve = serve;

const ORIGIN = 'https://getquicksales.com';
const post = (h: (r: Request) => Promise<Response>, body: unknown, headers: Record<string, string> = {}) =>
  h(new Request('http://control.test/functions/v1/x', { method: 'POST', headers: { Origin: ORIGIN, 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) }));
const form = (sub: string, extra: Record<string, unknown> = {}) => ({
  business: 'Boutique <Mama> Rose', name: 'Rose M', email: `${sub}@example.com`, phone: '+243 81 111 2222', subdomain: sub, shops: 2,
  note: 'Deux boutiques à Gombe', lang: 'fr', website: '', ...extra,
});
const linkFrom = (html: string) => {
  const m = /https:\/\/getquicksales\.com\/approve\?s=([a-z0-9-]+)&amp;t=([0-9a-f]{40})/.exec(html);
  assert(m, 'approval link in the email');
  return { s: m[1], t: m[2] };
};

await psql(`delete from public.tenants where subdomain like 'ft-%'`);

Deno.test('signup saves the request and emails you a link, and the client a French note', async () => {
  mails.length = 0;
  const res = await post(signup.handle, form('ft-rose'), { 'x-forwarded-for': '41.0.0.1, 10.0.0.1' });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { ok: true, subdomain: 'ft-rose' });
  assertEquals(res.headers.get('Access-Control-Allow-Origin'), ORIGIN);
  const row = (await psql(`select status || '|' || (ip_hash is not null)::text || '|' || (contact->>'shops') from public.tenants where subdomain = 'ft-rose'`)).stdout;
  assertEquals(row, 'pending|true|2');
  assertEquals(mails.length, 2);
  assertEquals(mails[0].to, 'owner@example.com');
  assertMatch(mails[0].subject, /New signup: Boutique <Mama> Rose \(ft-rose\)/);
  assert(mails[0].html.includes('Boutique &lt;Mama&gt; Rose'), 'what visitors type is escaped in the email');
  assert(!mails[0].html.includes('<Mama>'));
  linkFrom(mails[0].html);
  assertEquals(mails[1].to, 'ft-rose@example.com');
  assertEquals(mails[1].subject, 'Votre demande QuickSales');
  assert(mails[1].html.includes('ft-rose.getquicksales.com'));
});

Deno.test('signup refuses a taken name with a code the page can translate', async () => {
  const res = await post(signup.handle, form('ft-rose'));
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, 'subdomain_taken');
  const bad = await post(signup.handle, form('ft-other', { email: 'nope' }));
  assertEquals((await bad.json()).error, 'email');
});

Deno.test('a robot filling the hidden field gets "ok" and nothing is saved', async () => {
  mails.length = 0;
  const res = await post(signup.handle, form('ft-robot', { website: 'http://spam' }));
  assertEquals(res.status, 200);
  assertEquals((await psql(`select count(*) from public.tenants where subdomain = 'ft-robot'`)).stdout, '0');
  assertEquals(mails.length, 0);
});

Deno.test('three open requests a day from one address, then "too many"', async () => {
  for (const s of ['ft-ip-a', 'ft-ip-b']) assertEquals((await post(signup.handle, form(s), { 'x-forwarded-for': '41.0.0.1' })).status, 200);
  const res = await post(signup.handle, form('ft-ip-c'), { 'x-forwarded-for': '41.0.0.1' });
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error, 'too_many');
});

Deno.test('the approval link shows the request; a wrong or old link is refused', async () => {
  mails.length = 0;
  await post(signup.handle, form('ft-link', { lang: 'en' }), { 'x-forwarded-for': '41.0.0.9' });
  const { s, t } = linkFrom(mails[0].html);
  assertEquals(mails[1].subject, 'Your QuickSales request');
  const info = await (await post(approve.handle, { s, t, action: 'info' })).json();
  assertEquals([info.status, info.business, info.phone, info.lang], ['pending', 'Boutique <Mama> Rose', '+243 81 111 2222', 'en']);
  assertEquals(info.created_epoch, undefined);
  const wrong = await post(approve.handle, { s, t: t.replace(/.$/, (c) => (c === '0' ? '1' : '0')), action: 'info' });
  assertEquals(wrong.status, 403);
  const otherName = await post(approve.handle, { s: 'ft-rose', t, action: 'approve' });
  assertEquals(otherName.status, 403);
  // rejected and asked for again: the old link no longer works
  assertEquals((await (await post(approve.handle, { s, t, action: 'reject' })).json()).status, 'rejected');
  await psql(`select pg_sleep(1.1)`);
  mails.length = 0;
  await post(signup.handle, form('ft-link'), { 'x-forwarded-for': '41.0.0.8' });
  assertEquals((await post(approve.handle, { s, t, action: 'info' })).status, 403);
  assert(linkFrom(mails[0].html).t !== t);
});

Deno.test('approve starts the provision workflow on main for that name', async () => {
  mails.length = 0; dispatches.length = 0; githubStatus = 204;
  await post(signup.handle, form('ft-go'), { 'x-forwarded-for': '41.0.0.7' });
  const { s, t } = linkFrom(mails[0].html);
  const res = await post(approve.handle, { s, t, action: 'approve' });
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, 'provisioning');
  assertEquals(dispatches.length, 1);
  assertEquals(dispatches[0].url, 'https://api.github.com/repos/saimkhoja/cosmetic/actions/workflows/provision.yml/dispatches');
  assertEquals(dispatches[0].body, { ref: 'main', inputs: { subdomain: 'ft-go' } });
  const again = await post(approve.handle, { s, t, action: 'approve' });
  assertEquals([again.status, (await again.json()).error], [409, 'already_provisioning']);
  assertEquals(dispatches.length, 1, 'approving twice starts nothing more');
});

Deno.test('if GitHub refuses, the request is marked failed with the reason, and can be approved again', async () => {
  mails.length = 0; dispatches.length = 0; githubStatus = 401;
  await post(signup.handle, form('ft-gh'), { 'x-forwarded-for': '41.0.0.6' });
  const { s, t } = linkFrom(mails[0].html);
  const res = await post(approve.handle, { s, t, action: 'approve' });
  assertEquals(res.status, 502);
  assertMatch((await res.json()).message, /HTTP 401/);
  const info = await (await post(approve.handle, { s, t, action: 'info' })).json();
  assertEquals(info.status, 'failed');
  assertMatch(info.error, /HTTP 401/);
  githubStatus = 204;
  assertEquals((await (await post(approve.handle, { s, t, action: 'approve' })).json()).status, 'provisioning');
});

Deno.test('cleanup', async () => { await psql(`delete from public.tenants where subdomain like 'ft-%'`); });
