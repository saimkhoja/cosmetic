import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;
export const configured = !!(url && key);
export const supabase = createClient(url || 'http://localhost:54321', key || 'missing-anon-key', {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: 'sim-auth' },
});
export const LOGIN_DOMAIN = 'users.sim.local';
export const emailFor = (username: string) => `${username.trim().toLowerCase()}@${LOGIN_DOMAIN}`;

/** Calls a database function and throws its readable message on failure. */
export async function rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(cleanError(error.message));
  return data as T;
}
export async function invoke<T = unknown>(fn: string, body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke(fn, { body });
  if (error) {
    let msg = error.message;
    try { const j = await (error as { context?: Response }).context?.json(); if (j?.error) msg = j.error; } catch { /* keep message */ }
    throw new Error(msg);
  }
  return data as T;
}
export const cleanError = (m: string) => (/Failed to fetch|NetworkError|Load failed/i.test(m) ? 'No connection to the server. Try again when the internet is back.' : m);
/** Throws on a query error; returns rows. */
export function rows<T>(r: { data: T[] | null; error: { message: string } | null }): T[] {
  if (r.error) throw new Error(cleanError(r.error.message));
  return r.data ?? [];
}
