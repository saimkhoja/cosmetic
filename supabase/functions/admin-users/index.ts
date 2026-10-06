// User management for the Admin: create logins, reset passwords, change role or shop,
// and enable or disable accounts. Every call checks that the caller is an active Admin.
import { adminClient, cors, emailFor, fail, json, passwordProblem, ROLES, type Role, usernameOk } from '../_shared/common.ts';

const NEVER = '876000h'; // about 100 years: a disabled account cannot sign in or refresh

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('Method not allowed', 405);
  const db = adminClient();
  const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  const { data: who, error: ea } = await db.auth.getUser(jwt);
  if (ea || !who.user) return fail('Sign in again', 401);
  const { data: me } = await db.from('profiles').select('id, username, name, role, active').eq('id', who.user.id).maybeSingle();
  if (!me || !me.active || me.role !== 'admin') return fail('Only the Admin can manage logins', 403);

  let b: Record<string, any>;
  try { b = await req.json(); } catch { return fail('Bad request'); }
  const log = (action: string) => db.from('audit_log').insert({ user_id: me.id, username: me.username, action });
  const shopCheck = async (role: Role, shopId: string | null) => {
    if (role === 'admin' || role === 'whop') return null;
    if (!shopId) return 'Choose the shop';
    const { data } = await db.from('shops').select('id').eq('id', shopId).eq('active', true).maybeSingle();
    return data ? null : 'Shop not found';
  };

  switch (b.action) {
    case 'create': {
      const username = String(b.username ?? '').trim().toLowerCase(), name = String(b.name ?? '').trim();
      const role = String(b.role) as Role, shopId = role === 'admin' || role === 'whop' ? null : (b.shop_id ?? null);
      if (name.length < 2) return fail('Enter the full name');
      if (!usernameOk(username)) return fail('Username: 3 to 30 letters, numbers, dots or dashes');
      if (!ROLES.includes(role)) return fail('Choose a role');
      const pw = passwordProblem(String(b.password ?? '')); if (pw) return fail(pw);
      const sp = await shopCheck(role, shopId); if (sp) return fail(sp);
      const { data: taken } = await db.from('profiles').select('id').eq('username', username).maybeSingle();
      if (taken) return fail('This username is already taken');
      const { data: c, error } = await db.auth.admin.createUser({ email: emailFor(username), password: b.password, email_confirm: true, user_metadata: { username } });
      if (error || !c.user) return fail(error?.message?.includes('already') ? 'This username is already taken' : (error?.message ?? 'Could not create the login'));
      const { error: e2 } = await db.from('profiles').insert({ id: c.user.id, username, name, role, shop_id: shopId, must_change_password: true });
      if (e2) { await db.auth.admin.deleteUser(c.user.id); return fail(e2.message); }
      await log(`Created login ${username} (${role})`);
      return json({ ok: true, id: c.user.id });
    }
    case 'reset_password': {
      const pw = passwordProblem(String(b.password ?? '')); if (pw) return fail(pw);
      const { data: u } = await db.from('profiles').select('id, username').eq('id', b.user_id).maybeSingle();
      if (!u) return fail('User not found', 404);
      const { error } = await db.auth.admin.updateUserById(u.id, { password: b.password });
      if (error) return fail(error.message);
      await db.from('profiles').update({ must_change_password: u.id !== me.id }).eq('id', u.id);
      await log(`Password reset for ${u.username}`);
      return json({ ok: true });
    }
    case 'set_active': {
      if (b.user_id === me.id) return fail('You cannot disable your own account');
      const active = !!b.active;
      const { data: u } = await db.from('profiles').select('id, username').eq('id', b.user_id).maybeSingle();
      if (!u) return fail('User not found', 404);
      const { error } = await db.auth.admin.updateUserById(u.id, { ban_duration: active ? 'none' : NEVER });
      if (error) return fail(error.message);
      await db.from('profiles').update({ active }).eq('id', u.id);
      await log(`${active ? 'Enabled' : 'Disabled'} ${u.username}`);
      return json({ ok: true });
    }
    case 'update': {
      const { data: u } = await db.from('profiles').select('id, username, role').eq('id', b.user_id).maybeSingle();
      if (!u) return fail('User not found', 404);
      const role = String(b.role ?? u.role) as Role, name = String(b.name ?? '').trim();
      if (!ROLES.includes(role)) return fail('Choose a role');
      if (u.id === me.id && role !== 'admin') return fail('You cannot remove your own Admin role');
      if (name.length < 2) return fail('Enter the full name');
      const shopId = role === 'admin' || role === 'whop' ? null : (b.shop_id ?? null);
      const sp = await shopCheck(role, shopId); if (sp) return fail(sp);
      const { error } = await db.from('profiles').update({ name, role, shop_id: shopId }).eq('id', u.id);
      if (error) return fail(error.message);
      await log(`Updated login ${u.username}: ${role}`);
      return json({ ok: true });
    }
    default:
      return fail('Unknown action');
  }
});
