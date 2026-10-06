// First-run setup: creates the Admin login and saves company details, rate, VAT and shops.
// Works only while SIM has no users at all; after that it always refuses.
// Single file so it can be pasted into the Supabase dashboard editor as is.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

// SIM_ALLOWED_ORIGIN: unset = any site; otherwise one or more addresses, comma-separated.
// A trailing slash or capital letters in the secret do not matter.
const norm = (s: string) => s.trim().replace(/\/+$/, '').toLowerCase();
const ALLOWED = (Deno.env.get('SIM_ALLOWED_ORIGIN') ?? '').split(',').map(norm).filter(Boolean);
function corsFor(req: Request): Record<string, string> {
  const origin = req.headers.get('Origin') ?? '';
  return {
    'Access-Control-Allow-Origin': !ALLOWED.length ? '*' : ALLOWED.includes(norm(origin)) ? origin : ALLOWED[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
}
/** Every reply, errors included, carries the CORS headers so the browser shows the real message. */
function serveWithCors(handle: (req: Request) => Promise<Response>) {
  Deno.serve(async (req) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: corsFor(req) });
    let res: Response;
    try { res = await handle(req); } catch (e) { res = fail((e as Error).message || 'Unexpected error', 500); }
    const h = new Headers(res.headers);
    for (const [k, v] of Object.entries(corsFor(req))) h.set(k, v);
    return new Response(res.body, { status: res.status, headers: h });
  });
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}
const fail = (message: string, status = 400) => json({ error: message }, status);

function adminClient(): SupabaseClient {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY');
  return createClient(Deno.env.get('SUPABASE_URL')!, key!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Usernames are what people type; Supabase Auth needs an email, so each gets a private address that is never mailed. */
const LOGIN_DOMAIN = 'users.sim.local';
const emailFor = (username: string) => `${username}@${LOGIN_DOMAIN}`;
const usernameOk = (u: string) => /^[a-z0-9._-]{3,30}$/.test(u);
const passwordProblem = (p: string): string | null =>
  typeof p !== 'string' || p.length < 10 ? 'Password needs at least 10 characters'
  : !/[A-Za-z]/.test(p) || !/\d/.test(p) ? 'Password needs letters and numbers'
  : p.length > 72 ? 'Password is too long (72 characters at most)' : null;
const ROLES = ['admin', 'whop', 'shopadmin', 'till'] as const;
type Role = typeof ROLES[number];


serveWithCors(async (req) => {
  if (req.method !== 'POST') return fail('Method not allowed', 405);
  const db = adminClient();
  const { data: needed, error: e0 } = await db.rpc('setup_needed');
  if (e0) return fail('Could not reach the database', 500);
  if (!needed) return fail('SIM is already set up. Sign in instead.', 409);

  let b: Record<string, any>;
  try { b = await req.json(); } catch { return fail('Bad request'); }
  const username = String(b.username ?? '').trim().toLowerCase();
  const name = String(b.name ?? '').trim();
  const password = String(b.password ?? '');
  if (name.length < 2) return fail('Enter your full name');
  if (!usernameOk(username)) return fail('Username: 3 to 30 letters, numbers, dots or dashes');
  const pw = passwordProblem(password); if (pw) return fail(pw);
  const rate = Number(b.rate), vat = Number(b.vat);
  if (!(rate > 0)) return fail('Enter a valid exchange rate');
  if (!(vat >= 0 && vat <= 30)) return fail('VAT must be between 0 and 30');
  const shops = Array.isArray(b.shops) ? b.shops : [];
  if (!shops.length) return fail('Add at least one shop');
  const codes = new Set<string>();
  for (const s of shops) {
    const code = String(s.code ?? '').trim().toUpperCase();
    if (!/^[A-Z]{3}$/.test(code) || codes.has(code)) return fail('Each shop needs its own 3-letter code');
    if (String(s.name ?? '').trim().length < 2) return fail('Enter a name for every shop');
    codes.add(code);
  }
  const company = typeof b.company === 'object' && b.company ? b.company : {};

  const { data: created, error: e1 } = await db.auth.admin.createUser({
    email: emailFor(username), password, email_confirm: true, user_metadata: { username },
  });
  if (e1 || !created.user) return fail(e1?.message ?? 'Could not create the login', 400);
  const { error: e2 } = await db.rpc('app_setup', {
    p_user: created.user.id, p_username: username, p_name: name, p: { rate, vat, company, shops },
  });
  if (e2) {
    await db.auth.admin.deleteUser(created.user.id);
    return fail(e2.message, 409);
  }
  return json({ ok: true, username });
});
