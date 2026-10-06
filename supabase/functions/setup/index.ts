// First-run setup: creates the Admin login and saves company details, rate, VAT and shops.
// Works only while SIM has no users at all; after that it always refuses.
import { adminClient, cors, emailFor, fail, json, passwordProblem, usernameOk } from '../_shared/common.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
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
