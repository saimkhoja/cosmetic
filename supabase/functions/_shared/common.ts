// Shared helpers for SIM Edge Functions. These run on Supabase with the service role key,
// which never reaches the browser.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

export const cors = {
  'Access-Control-Allow-Origin': Deno.env.get('SIM_ALLOWED_ORIGIN') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}
export const fail = (message: string, status = 400) => json({ error: message }, status);

export function adminClient(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Usernames are what people type; Supabase Auth needs an email, so each gets a private address that is never mailed. */
export const LOGIN_DOMAIN = 'users.sim.local';
export const emailFor = (username: string) => `${username}@${LOGIN_DOMAIN}`;
export const usernameOk = (u: string) => /^[a-z0-9._-]{3,30}$/.test(u);
export const passwordProblem = (p: string): string | null =>
  typeof p !== 'string' || p.length < 10 ? 'Password needs at least 10 characters'
  : !/[A-Za-z]/.test(p) || !/\d/.test(p) ? 'Password needs letters and numbers'
  : p.length > 72 ? 'Password is too long (72 characters at most)' : null;
export const ROLES = ['admin', 'whop', 'shopadmin', 'till'] as const;
export type Role = typeof ROLES[number];
