// The landing page's calls to the control project: is a name free, send a signup, act on a request (approval page).
const URL_ = (import.meta.env.VITE_CONTROL_URL as string | undefined)?.replace(/\/+$/, '') ?? '';
const KEY = (import.meta.env.VITE_CONTROL_ANON_KEY as string | undefined) ?? '';
const headers = { apikey: KEY, 'Content-Type': 'application/json' };

/** An error the page can translate: a code from the server (e.g. subdomain_taken) or 'network' / 'server'. */
export class ControlError extends Error { constructor(public code: string, message?: string) { super(message ?? code); } }

async function call<T>(path: string, body: unknown): Promise<T> {
  let res: Response;
  try { res = await fetch(`${URL_}${path}`, { method: 'POST', headers, body: JSON.stringify(body) }); }
  catch { throw new ControlError('network'); }
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new ControlError(data?.error ?? 'server', data?.message);
  return data as T;
}

export type Availability = 'ok' | 'taken' | 'reserved' | 'invalid';
export const subdomainAvailable = (s: string) => call<Availability>('/rest/v1/rpc/subdomain_available', { p_subdomain: s });
export const sendSignup = (f: Record<string, unknown>) => call<{ ok: true; subdomain: string }>('/functions/v1/signup', f);

export interface Request_ { subdomain: string; business: string; status: 'pending' | 'provisioning' | 'active' | 'suspended' | 'failed' | 'rejected';
  name: string; email: string; phone: string; shops: number; note: string; lang: 'fr' | 'en'; created_at: string; error: string | null }
export const requestAction = (s: string, t: string, action: 'info' | 'approve' | 'reject') => call<Request_>('/functions/v1/approve', { s, t, action });
