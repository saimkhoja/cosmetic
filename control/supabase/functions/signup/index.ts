// Signup from getquicksales.com: saves the request (public.request_signup) and emails you an approval link, and
// the visitor a "we received your request". Runs on the CONTROL project, with Verify JWT off.
// Single file so it can be pasted into the Supabase dashboard editor as is. See control/README.md.
//
// Secrets (control project → Edge Functions → Secrets):
//   APPROVE_SECRET   long random text; signs the approval links (and salts the hashed addresses)
//   RESEND_API_KEY   from resend.com; without it nothing is emailed (the request is still saved)
//   OWNER_EMAIL      where new requests are announced
//   MAIL_FROM        e.g. QuickSales <hello@getquicksales.com> (a domain verified in Resend)
//   SITE_DOMAIN      getquicksales.com
//   SIGNUP_ALLOWED_ORIGIN  optional: https://getquicksales.com,https://www.getquicksales.com

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

/** Calls a database function with the project's secret key; returns its result or throws its message. */
async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const key = env('SUPABASE_SERVICE_ROLE_KEY') || env('SUPABASE_SECRET_KEY');
  const headers: Record<string, string> = { apikey: key, 'Content-Type': 'application/json' };
  if (key.startsWith('eyJ')) headers.Authorization = `Bearer ${key}`;   // a legacy JWT key; the new sb_secret_ keys go in apikey only
  const res = await fetch(`${env('SUPABASE_URL')}/rest/v1/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(args) });
  const body = await res.json().catch(() => null);
  if (!res.ok) throw new Error((body && (body.message || body.error)) || `rpc ${fn}: HTTP ${res.status}`);
  return body as T;
}

async function hex(buf: ArrayBuffer) { return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join(''); }
const enc = new TextEncoder();
async function sha256(s: string) { return hex(await crypto.subtle.digest('SHA-256', enc.encode(s))); }
/** The approval link's signature: HMAC-SHA256 of the subdomain and the moment the request was made. */
export async function approvalToken(secret: string, subdomain: string, createdEpoch: number) {
  const k = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return (await hex(await crypto.subtle.sign('HMAC', k, enc.encode(`${subdomain}|${createdEpoch}`)))).slice(0, 40);
}

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
async function sendMail(to: string, subject: string, html: string, replyTo?: string) {
  const key = env('RESEND_API_KEY');
  if (!key || !to) { console.warn(`email not sent (no RESEND_API_KEY or address): ${subject}`); return false; }
  const res = await fetch(env('RESEND_API_URL', 'https://api.resend.com/emails'), {   // overridden only by the tests
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: env('MAIL_FROM', 'QuickSales <hello@getquicksales.com>'), to: [to], subject, html, ...(replyTo ? { reply_to: replyTo } : {}) }),
  });
  if (!res.ok) { console.error(`email to ${to} failed: HTTP ${res.status} ${await res.text()}`); return false; }
  return true;
}
const frame = (body: string) => `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:auto;color:#14213d;line-height:1.5">
<div style="background:#06328F;color:#fff;padding:14px 18px;border-radius:10px 10px 0 0;font-weight:bold;font-size:18px">QuickSales</div>
<div style="border:1px solid #dde3f0;border-top:0;padding:18px;border-radius:0 0 10px 10px">${body}</div></div>`;

interface Details { subdomain: string; business: string; name: string; email: string; phone: string; shops: number; note: string; lang: 'fr' | 'en'; created_epoch: number }

function ownerMail(d: Details, link: string, domain: string) {
  const row = (k: string, v: unknown) => `<tr><td style="padding:4px 10px 4px 0;color:#5b6785">${k}</td><td style="padding:4px 0"><b>${esc(v)}</b></td></tr>`;
  return frame(`<p>New QuickSales signup waiting for your approval:</p><table>
${row('Business', d.business)}${row('Address', `${d.subdomain}.${domain}`)}${row('Name', d.name)}${row('Phone', d.phone)}
${row('Email', d.email)}${row('Shops', d.shops)}${row('Language', d.lang === 'en' ? 'English' : 'French')}${d.note ? row('Message', d.note) : ''}</table>
<p style="margin:22px 0"><a href="${esc(link)}" style="background:#06328F;color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:bold">Review and approve</a></p>
<p style="color:#5b6785;font-size:13px">Approving creates their database (about $10/month in Supabase) and emails them their link in about 5 minutes.</p>`);
}
function clientMail(d: Details, domain: string) {
  const fr = d.lang !== 'en';
  return fr
    ? frame(`<p>Bonjour ${esc(d.name)},</p><p>Merci pour votre inscription à QuickSales pour <b>${esc(d.business)}</b>. Nous avons bien reçu votre demande pour l'adresse <b>${esc(d.subdomain)}.${esc(domain)}</b>.</p><p>Nous la vérifions et vous recevrez un e-mail avec votre lien dès que votre espace est prêt, en général dans la journée.</p><p>L'équipe QuickSales</p>`)
    : frame(`<p>Hello ${esc(d.name)},</p><p>Thank you for signing up to QuickSales for <b>${esc(d.business)}</b>. We have received your request for <b>${esc(d.subdomain)}.${esc(domain)}</b>.</p><p>We check every request; you will get an email with your link as soon as it is ready, usually the same day.</p><p>The QuickSales team</p>`);
}

const FIELDS = ['business', 'name', 'email', 'phone', 'subdomain', 'shops', 'note', 'lang'] as const;

export async function handle(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsFor(req) });
  if (req.method !== 'POST') return json(req, { error: 'method' }, 405);
  const secret = env('APPROVE_SECRET');
  if (secret.length < 24) return json(req, { error: 'server', message: 'APPROVE_SECRET is not set (24 characters or more)' }, 500);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(req, { error: 'bad_request' }, 400); }
  // a field people never see: only robots fill it in. Pretend it worked.
  if (String(body.website ?? '').trim()) return json(req, { ok: true, subdomain: String(body.subdomain ?? '') });

  const p: Record<string, unknown> = {};
  for (const k of FIELDS) if (body[k] !== undefined) p[k] = typeof body[k] === 'string' ? (body[k] as string).slice(0, 600) : body[k];
  const ip = (req.headers.get('x-forwarded-for') ?? '').split(',')[0].trim() || req.headers.get('cf-connecting-ip') || '';
  let d: Details;
  try {
    d = await rpc<Details>('request_signup', { p, p_ip_hash: ip ? await sha256(`${secret}|${ip}`) : null });
  } catch (e) {
    const m = (e as Error).message;
    const code = /QS:([a-z_]+)/.exec(m)?.[1];
    if (code) return json(req, { error: code }, code === 'too_many' || code === 'busy' ? 429 : 400);
    console.error('request_signup failed:', m);
    return json(req, { error: 'server' }, 500);
  }

  const domain = env('SITE_DOMAIN', 'getquicksales.com');
  const link = `https://${domain}/approve?s=${encodeURIComponent(d.subdomain)}&t=${await approvalToken(secret, d.subdomain, d.created_epoch)}`;
  await sendMail(env('OWNER_EMAIL'), `New signup: ${d.business} (${d.subdomain})`, ownerMail(d, link, domain), d.email);
  await sendMail(d.email, d.lang === 'en' ? 'Your QuickSales request' : 'Votre demande QuickSales', clientMail(d, domain), env('OWNER_EMAIL') || undefined);
  return json(req, { ok: true, subdomain: d.subdomain });
}

Deno.serve((req) => handle(req).catch((e) => { console.error(e); return json(req, { error: 'server' }, 500); }));
