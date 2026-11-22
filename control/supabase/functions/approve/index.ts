// The approval page (getquicksales.com/approve?s=…&t=…, opened from the email you get for each signup) talks to this.
// It shows the request, and on Approve starts the GitHub workflow that sets the client up (.github/workflows/provision.yml);
// on Reject it deletes the request. A failed setup can be started again from the same page.
// Runs on the CONTROL project, with Verify JWT off. Single file so it can be pasted into the dashboard editor.
//
// Secrets (control project → Edge Functions → Secrets):
//   APPROVE_SECRET          the same as for the signup function
//   GITHUB_DISPATCH_TOKEN   a GitHub fine-grained token for saimkhoja/cosmetic with "Actions: Read and write"
//   GITHUB_REPO             saimkhoja/cosmetic
//   SIGNUP_ALLOWED_ORIGIN   optional, as for the signup function
//
// Only someone holding the link can act on a request: the link carries an HMAC of the subdomain and the time
// the request was made, so it stops working if the request is rejected and the name asked for again.

const env = (k: string, d = '') => Deno.env.get(k) ?? d;
const norm = (s: string) => s.trim().replace(/\/+$/, '').toLowerCase();

function corsFor(req: Request): Record<string, string> {
  const allowed = env('SIGNUP_ALLOWED_ORIGIN').split(',').map(norm).filter(Boolean);
  const origin = req.headers.get('Origin') ?? '';
  return {
    'Access-Control-Allow-Origin': !allowed.length ? '*' : allowed.includes(norm(origin)) ? origin : allowed[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
}
const json = (req: Request, body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsFor(req), 'Content-Type': 'application/json' } });

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const key = env('SUPABASE_SERVICE_ROLE_KEY') || env('SUPABASE_SECRET_KEY');
  const headers: Record<string, string> = { apikey: key, 'Content-Type': 'application/json' };
  if (key.startsWith('eyJ')) headers.Authorization = `Bearer ${key}`;
  const res = await fetch(`${env('SUPABASE_URL')}/rest/v1/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(args) });
  const body = await res.json().catch(() => null);
  if (!res.ok) throw new Error((body && (body.message || body.error)) || `rpc ${fn}: HTTP ${res.status}`);
  return body as T;
}

const enc = new TextEncoder();
async function approvalToken(secret: string, subdomain: string, createdEpoch: number) {
  const k = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(`${subdomain}|${createdEpoch}`)));
  return [...sig].map((b) => b.toString(16).padStart(2, '0')).join('').slice(0, 40);
}
/** Compares without leaking how much of the token was right. */
function sameText(a: string, b: string) {
  if (a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

/** Starts the provision workflow on main for this subdomain. */
async function startWorkflow(subdomain: string) {
  const repo = env('GITHUB_REPO', 'saimkhoja/cosmetic');
  const token = env('GITHUB_DISPATCH_TOKEN');
  if (!token) throw new Error('GITHUB_DISPATCH_TOKEN is not set on the control project');
  const res = await fetch(`${env('GITHUB_API_URL', 'https://api.github.com')}/repos/${repo}/actions/workflows/provision.yml/dispatches`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': 'application/json', 'User-Agent': 'quicksales-control' },
    body: JSON.stringify({ ref: env('GITHUB_REF', 'main'), inputs: { subdomain } }),
  });
  if (res.status !== 204) throw new Error(`GitHub did not start the workflow: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
}

interface Details { subdomain: string; status: string; created_epoch: number; [k: string]: unknown }

export async function handle(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsFor(req) });
  if (req.method !== 'POST') return json(req, { error: 'method' }, 405);
  const secret = env('APPROVE_SECRET');
  if (secret.length < 24) return json(req, { error: 'server', message: 'APPROVE_SECRET is not set' }, 500);
  let body: { s?: string; t?: string; action?: string };
  try { body = await req.json(); } catch { return json(req, { error: 'bad_request' }, 400); }
  const s = String(body.s ?? '').trim().toLowerCase(), t = String(body.t ?? '');
  if (!/^[a-z0-9-]{1,40}$/.test(s) || !/^[0-9a-f]{40}$/.test(t)) return json(req, { error: 'bad_link' }, 400);

  const d = await rpc<Details | null>('signup_details', { p_subdomain: s });
  if (!d) return json(req, { error: 'not_found' }, 404);
  if (!sameText(await approvalToken(secret, d.subdomain, d.created_epoch), t)) return json(req, { error: 'bad_link' }, 403);
  const { created_epoch: _e, ...shown } = d;

  try {
    switch (body.action) {
      case 'info':
        return json(req, shown);
      case 'approve': {   // also starts a failed setup again
        const after = await rpc<Details>('approve_signup', { p_subdomain: s });
        try { await startWorkflow(s); } catch (e) {
          await rpc('unapprove_signup', { p_subdomain: s, p_error: (e as Error).message });
          return json(req, { error: 'workflow', message: (e as Error).message }, 502);
        }
        const { created_epoch: _a, ...rest } = after;
        return json(req, rest);
      }
      case 'reject':
        await rpc('reject_signup', { p_subdomain: s });
        return json(req, { ok: true, status: 'rejected' });
      default:
        return json(req, { error: 'bad_request' }, 400);
    }
  } catch (e) {
    const m = (e as Error).message;
    const code = /QS:([a-z_]+)/.exec(m)?.[1];
    if (code) return json(req, { error: code }, 409);
    console.error(m);
    return json(req, { error: 'server' }, 500);
  }
}

Deno.serve((req) => handle(req).catch((e) => { console.error(e); return json(req, { error: 'server' }, 500); }));
