// Which client's database this copy of the app talks to.
//
// One build serves every client. The address decides the client: sapcongo.getquicksales.com asks the
// control project (the list of clients, see control/README.md) for sapcongo's Supabase URL and public key.
// The answer is kept on the device, so a till that starts without internet still opens on the right database,
// and a till that has it opens at once while the saved answer is checked in the background.
//
// A build with VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY set skips all of this and always uses that project
// (local development, the tests, and the older one-site-per-client installs).
//
// This file must not import lib/supabase.ts: main.tsx runs it before the rest of the app is loaded.

export interface Connection { url: string; key: string }
export interface TenantInfo { subdomain: string; name: string; url: string; key: string }

export type Resolved =
  | { kind: 'direct'; conn: Connection }                       // fixed project from the build
  | { kind: 'tenant'; tenant: TenantInfo }                     // found for this address
  | { kind: 'no-subdomain' }                                   // getquicksales.com itself, www, or an unknown host
  | { kind: 'unknown'; subdomain: string }                     // no client has this address
  | { kind: 'suspended'; subdomain: string; name: string }     // the client exists but is switched off
  | { kind: 'unreachable'; subdomain: string }                 // first visit and the control project cannot be reached
  | { kind: 'unconfigured' };                                  // the build has neither a project nor a control project

/** Names that are never a client's address. Keep in step with control/migrations (tenants_subdomain_check). */
export const RESERVED = ['www', 'app', 'api', 'admin', 'control', 'mail', 'email', 'smtp', 'ftp', 'status', 'docs', 'help', 'support',
  'billing', 'signup', 'login', 'dashboard', 'static', 'assets', 'cdn', 'dev', 'staging', 'test', 'demo'];

/**
 * The client part of the address: "sapcongo" for sapcongo.getquicksales.com.
 * Only one label in front of the domain counts; the bare domain, www and the reserved names have none.
 */
export function subdomainOf(hostname: string, domain: string): string | null {
  const host = hostname.trim().toLowerCase().replace(/\.$/, '');
  const d = domain.trim().toLowerCase().replace(/^\.+|\.+$/g, '');
  if (!d || !host.endsWith('.' + d)) return null;
  const label = host.slice(0, -(d.length + 1));
  if (!/^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/.test(label) || label.includes('--')) return null;
  return RESERVED.includes(label) ? null : label;
}

/** What the control project's tenant_config() returns: null when no client has the address. */
export interface ControlReply { name: string; url: string; anon_key: string; status: 'active' | 'suspended' }

function validReply(r: unknown): r is ControlReply {
  const o = r as Partial<ControlReply> | null;
  return !!o && typeof o.name === 'string' && typeof o.url === 'string' && typeof o.anon_key === 'string' && !!o.anon_key
    && (o.status === 'active' || o.status === 'suspended') && /^https:\/\/[^/\s]+$|^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o.url.replace(/\/+$/, ''));
}

export interface Deps {
  env: { url?: string; key?: string; controlUrl?: string; controlKey?: string; domain?: string; devTenant?: string };
  hostname: string;
  /** The control project's answer for a subdomain: a reply, null for "no such client", or a thrown error when it cannot be reached. */
  ask: (subdomain: string) => Promise<unknown>;
  load: (subdomain: string) => TenantInfo | null;
  save: (t: TenantInfo) => void;
  forget: (subdomain: string) => void;
  /** How long a first visit waits for the control project. */
  timeoutMs?: number;
}

export const cacheKey = (subdomain: string) => `qs.tenant.${subdomain}`;

/**
 * Decides which database to use. With a saved answer it returns straight away and refreshes the saved answer in
 * the background (the refreshed answer is used from the next start, never in the middle of a sale).
 * Returns the resolution and, when a background check was started, its promise (for tests).
 */
export async function resolveTenant(d: Deps): Promise<{ resolved: Resolved; refresh?: Promise<void> }> {
  const { env } = d;
  if (env.url && env.key) return { resolved: { kind: 'direct', conn: { url: env.url, key: env.key } } };
  if (!env.controlUrl || !env.controlKey) return { resolved: { kind: 'unconfigured' } };

  const sub = (env.devTenant || '').trim().toLowerCase() || subdomainOf(d.hostname, env.domain || 'getquicksales.com');
  if (!sub) return { resolved: { kind: 'no-subdomain' } };

  const apply = (r: unknown): Resolved => {
    if (r === null) { d.forget(sub); return { kind: 'unknown', subdomain: sub }; }
    if (!validReply(r)) throw new Error('The list of clients gave an unexpected answer');
    if (r.status === 'suspended') { d.forget(sub); return { kind: 'suspended', subdomain: sub, name: r.name }; }
    const tenant: TenantInfo = { subdomain: sub, name: r.name, url: r.url.replace(/\/+$/, ''), key: r.anon_key };
    d.save(tenant);
    return { kind: 'tenant', tenant };
  };

  const saved = d.load(sub);
  if (saved) {
    // a failed check keeps the saved answer: the till may simply be offline
    const refresh = d.ask(sub).then(apply).then(() => undefined, () => undefined);
    return { resolved: { kind: 'tenant', tenant: saved }, refresh };
  }

  try {
    const r = await withTimeout(d.ask(sub), d.timeoutMs ?? 12_000);
    return { resolved: apply(r) };
  } catch {
    return { resolved: { kind: 'unreachable', subdomain: sub } };
  }
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  return new Promise((ok, fail) => {
    const t = setTimeout(() => fail(new Error('timeout')), ms);
    p.then((v) => { clearTimeout(t); ok(v); }, (e) => { clearTimeout(t); fail(e); });
  });
}

// ---- in the browser -------------------------------------------------------------------------------------------

let current: Resolved = { kind: 'unconfigured' };

/** The resolution main.tsx made at start; lib/supabase.ts builds its client from it. */
export const resolved = () => current;
export function connection(): Connection | null {
  if (current.kind === 'direct') return current.conn;
  if (current.kind === 'tenant') return { url: current.tenant.url, key: current.tenant.key };
  return null;
}

function readSaved(subdomain: string): TenantInfo | null {
  try {
    const t = JSON.parse(localStorage.getItem(cacheKey(subdomain)) || 'null') as TenantInfo | null;
    return t && t.subdomain === subdomain && t.url && t.key ? t : null;
  } catch { return null; }
}

async function askControl(controlUrl: string, controlKey: string, subdomain: string): Promise<unknown> {
  const res = await fetch(`${controlUrl.replace(/\/+$/, '')}/rest/v1/rpc/tenant_config`, {
    method: 'POST',
    headers: { apikey: controlKey, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ p_subdomain: subdomain }),
    cache: 'no-store',
  });
  if (!res.ok) throw new Error(`control ${res.status}`);
  return res.json();
}

export async function loadTenant(): Promise<Resolved> {
  const e = import.meta.env;
  const env = {
    url: e.VITE_SUPABASE_URL as string | undefined, key: e.VITE_SUPABASE_ANON_KEY as string | undefined,
    controlUrl: e.VITE_CONTROL_URL as string | undefined, controlKey: e.VITE_CONTROL_ANON_KEY as string | undefined,
    domain: e.VITE_TENANT_DOMAIN as string | undefined,
    // only in `vite dev`, so a production build can never be pointed at another client from the address bar
    devTenant: e.DEV ? (e.VITE_DEV_TENANT as string | undefined) : undefined,
  };
  const { resolved: r } = await resolveTenant({
    env, hostname: location.hostname,
    ask: (s) => askControl(env.controlUrl!, env.controlKey!, s),
    load: readSaved,
    save: (t) => { try { localStorage.setItem(cacheKey(t.subdomain), JSON.stringify(t)); } catch { /* storage full or blocked */ } },
    forget: (s) => { try { localStorage.removeItem(cacheKey(s)); } catch { /* ignore */ } },
  });
  current = r;
  return r;
}
