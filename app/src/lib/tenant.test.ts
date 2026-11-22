import { describe, expect, it } from 'vitest';
import { resolveTenant, subdomainOf, type Deps, type TenantInfo } from './tenant';

describe('subdomainOf', () => {
  const D = 'getquicksales.com';
  it('takes the one label in front of the domain', () => {
    expect(subdomainOf('sapcongo.getquicksales.com', D)).toBe('sapcongo');
    expect(subdomainOf('SapCongo.GetQuickSales.com.', D)).toBe('sapcongo');
    expect(subdomainOf('shop-2.getquicksales.com', D)).toBe('shop-2');
  });
  it('has none for the bare domain, www, reserved names, deeper names and other hosts', () => {
    for (const h of ['getquicksales.com', 'www.getquicksales.com', 'admin.getquicksales.com', 'a.b.getquicksales.com',
      'xgetquicksales.com', 'sapcongo.getquicksales.com.evil.com', 'localhost', 'sim-client.vercel.app', '-bad.getquicksales.com', 'a--b.getquicksales.com']) {
      expect(subdomainOf(h, D), h).toBeNull();
    }
  });
});

const ENV = { controlUrl: 'https://control.supabase.co', controlKey: 'ck', domain: 'getquicksales.com' };
const ACTIVE = { name: 'SAP Congo', url: 'https://abc.supabase.co/', anon_key: 'k1', status: 'active' };

function deps(over: Partial<Deps> & { store?: Map<string, TenantInfo> } = {}) {
  const store = over.store ?? new Map<string, TenantInfo>();
  const asked: string[] = [];
  const d: Deps = {
    env: ENV, hostname: 'sapcongo.getquicksales.com',
    ask: async (s) => { asked.push(s); return ACTIVE; },
    load: (s) => store.get(s) ?? null, save: (t) => store.set(t.subdomain, t), forget: (s) => store.delete(s),
    ...over,
  };
  return { d, store, asked };
}

describe('resolveTenant', () => {
  it('uses the build\'s own project when one is set, without asking anyone', async () => {
    const { d, asked } = deps({ env: { ...ENV, url: 'https://one.supabase.co', key: 'k' } });
    expect((await resolveTenant(d)).resolved).toEqual({ kind: 'direct', conn: { url: 'https://one.supabase.co', key: 'k' } });
    expect(asked).toEqual([]);
  });
  it('is unconfigured with neither a project nor a control project', async () => {
    const { d } = deps({ env: {} });
    expect((await resolveTenant(d)).resolved.kind).toBe('unconfigured');
  });
  it('has no client on the bare domain', async () => {
    const { d, asked } = deps({ hostname: 'getquicksales.com' });
    expect((await resolveTenant(d)).resolved.kind).toBe('no-subdomain');
    expect(asked).toEqual([]);
  });
  it('asks the control project on a first visit and saves the answer', async () => {
    const { d, store, asked } = deps();
    const { resolved } = await resolveTenant(d);
    expect(resolved).toEqual({ kind: 'tenant', tenant: { subdomain: 'sapcongo', name: 'SAP Congo', url: 'https://abc.supabase.co', key: 'k1' } });
    expect(asked).toEqual(['sapcongo']);
    expect(store.get('sapcongo')?.url).toBe('https://abc.supabase.co');
  });
  it('opens at once from the saved answer and refreshes it in the background', async () => {
    const store = new Map([['sapcongo', { subdomain: 'sapcongo', name: 'Old', url: 'https://old.supabase.co', key: 'k0' }]]);
    const { d } = deps({ store });
    const { resolved, refresh } = await resolveTenant(d);
    expect(resolved).toMatchObject({ kind: 'tenant', tenant: { url: 'https://old.supabase.co' } });
    await refresh;
    expect(store.get('sapcongo')).toMatchObject({ name: 'SAP Congo', url: 'https://abc.supabase.co', key: 'k1' });
  });
  it('keeps working offline from the saved answer', async () => {
    const store = new Map([['sapcongo', { subdomain: 'sapcongo', name: 'SAP Congo', url: 'https://abc.supabase.co', key: 'k1' }]]);
    const { d } = deps({ store, ask: () => Promise.reject(new TypeError('Failed to fetch')) });
    const { resolved, refresh } = await resolveTenant(d);
    expect(resolved.kind).toBe('tenant');
    await refresh;
    expect(store.has('sapcongo')).toBe(true);
  });
  it('says unreachable on a first visit without a connection', async () => {
    const { d } = deps({ ask: () => Promise.reject(new TypeError('Failed to fetch')) });
    expect((await resolveTenant(d)).resolved).toEqual({ kind: 'unreachable', subdomain: 'sapcongo' });
  });
  it('gives up waiting after the timeout', async () => {
    const { d } = deps({ ask: () => new Promise(() => {}), timeoutMs: 20 });
    expect((await resolveTenant(d)).resolved.kind).toBe('unreachable');
  });
  it('knows an address no client has', async () => {
    const { d } = deps({ ask: async () => null });
    expect((await resolveTenant(d)).resolved).toEqual({ kind: 'unknown', subdomain: 'sapcongo' });
  });
  it('stops a suspended client and forgets the saved answer, so the next start is blocked too', async () => {
    const store = new Map([['sapcongo', { subdomain: 'sapcongo', name: 'SAP Congo', url: 'https://abc.supabase.co', key: 'k1' }]]);
    const { d } = deps({ store, ask: async () => ({ ...ACTIVE, status: 'suspended' }) });
    const first = await resolveTenant(d);
    expect(first.resolved.kind).toBe('tenant');      // a sale in progress is never cut off
    await first.refresh;
    expect(store.has('sapcongo')).toBe(false);
    expect((await resolveTenant(d)).resolved).toEqual({ kind: 'suspended', subdomain: 'sapcongo', name: 'SAP Congo' });
  });
  it('refuses an answer that does not look like a Supabase project', async () => {
    for (const bad of [{ ...ACTIVE, url: 'http://abc.supabase.co' }, { ...ACTIVE, url: 'javascript:alert(1)' }, { ...ACTIVE, anon_key: '' }, { ...ACTIVE, status: 'x' }, 'nope']) {
      const { d, store } = deps({ ask: async () => bad });
      expect((await resolveTenant(d)).resolved.kind).toBe('unreachable');
      expect(store.size).toBe(0);
    }
  });
});
