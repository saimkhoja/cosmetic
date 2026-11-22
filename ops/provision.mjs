#!/usr/bin/env node
// Sets up a new client after you approve their signup. Run by .github/workflows/provision.yml, in three parts around
// the database update (ops/migrate.sh) and the Edge Function deploy:
//
//   node ops/provision.mjs start  <subdomain>         creates (or finds) their Supabase project, waits for it, sets its
//                                                     sign-in settings; prints ref=<project ref> to GITHUB_OUTPUT
//   node ops/provision.mjs finish <subdomain> <ref>   puts their URL and public key in the control project (the address
//                                                     works from then on) and emails them the link
//   node ops/provision.mjs fail   <subdomain> <why>   marks the setup failed and emails you
//
// Safe to run again after a failure: a project already made for the client (recorded in the control project, or named
// qs-<subdomain> in the organization) is reused, never made twice.
//
// Environment: SUPABASE_ACCESS_TOKEN (the provisioning token), CONTROL_PROJECT_REF, SITE_DOMAIN (getquicksales.com),
//   SUPABASE_REGION (optional; default: the control project's region), RESEND_API_KEY, MAIL_FROM, OWNER_EMAIL (optional),
//   PROVISION_POLL_MS / PROVISION_WAIT_MS (tests).
import { randomBytes } from 'node:crypto';
import { appendFileSync } from 'node:fs';
import { api, controlQuery, controlRef, die, inActions, REF, sleep } from './lib.mjs';

const DOMAIN = process.env.SITE_DOMAIN || 'getquicksales.com';
const POLL = Number(process.env.PROVISION_POLL_MS || 10_000);
const WAIT = Number(process.env.PROVISION_WAIT_MS || 15 * 60_000);
const SUB = /^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/;
const log = (m) => console.log(m);
const output = (k, v) => { if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `${k}=${v}\n`); };
const summary = (m) => { if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${m}\n`); };

async function details(sub) {
  const rows = await controlQuery('select public.signup_details($1)::text as d', [sub]);
  const d = rows[0]?.d ? JSON.parse(rows[0].d) : null;
  if (!d) die(`No signup "${sub}" in the control project.`);
  return d;
}
const projectName = (sub) => `qs-${sub}`;
// the sign-in settings of deploy/DEPLOY.md section 1 ("Auth settings"), for the client's own address
export const authSettings = (sub) => ({
  site_url: `https://${sub}.${DOMAIN}`,
  disable_signup: true,            // only the Admin creates logins, through QuickSales
  external_email_enabled: true,
  mailer_autoconfirm: true,        // "Confirm email" off: logins use private addresses that are never mailed
  external_phone_enabled: false,
  external_anonymous_users_enabled: false,
  password_min_length: 10,
  password_required_characters: 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ:0123456789',   // letters and digits
});

async function start(sub) {
  const d = await details(sub);
  if (d.status === 'active') die(`${sub} is already set up.`);
  if (d.status !== 'provisioning') die(`${sub} is ${d.status}, not approved. Approve it from the link in the signup email.`);

  const control = await api('GET', `/v1/projects/${controlRef()}`);
  const org = control.organization_slug;
  const region = process.env.SUPABASE_REGION || control.region;
  const name = projectName(sub);

  // a project already made for this client: the one recorded, or one with its name (a run that stopped half way)
  const recorded = (await controlQuery('select project_ref from public.tenants where subdomain = $1', [sub]))[0]?.project_ref;
  let ref = recorded;
  if (!ref) {
    const found = await api('GET', `/v1/organizations/${encodeURIComponent(org)}/projects?search=${encodeURIComponent(name)}&limit=100`);
    const same = (found?.projects ?? []).filter((p) => p.name === name && !['REMOVED', 'GOING_DOWN'].includes(p.status));
    if (same.length > 1) die(`More than one project is called ${name}; delete the extra one in the Supabase dashboard, then try again.`);
    ref = same[0]?.ref;
    if (ref) log(`Found the project made earlier: ${ref}`);
  }
  if (!ref) {
    const made = await api('POST', '/v1/projects', {
      name, organization_slug: org,
      db_pass: randomBytes(24).toString('base64url'),   // never used: the workflows use temporary logins
      region_selection: { type: 'specific', code: region },
    });
    ref = made?.ref;
    if (!REF.test(ref || '')) die(`Supabase did not return a project ref: ${JSON.stringify(made).slice(0, 200)}`);
    log(`Created project ${name} (${ref}) in ${region}`);
  }
  if (!recorded) await controlQuery('select public.provision_started($1, $2)', [sub, ref]);
  output('ref', ref);
  summary(`## ${sub}: project ${ref}`);

  // wait until it is up
  const until = Date.now() + WAIT;
  for (;;) {
    const p = await api('GET', `/v1/projects/${ref}`);
    if (p.status === 'ACTIVE_HEALTHY') break;
    if (['INIT_FAILED', 'REMOVED', 'GOING_DOWN', 'INACTIVE'].includes(p.status)) die(`Project ${ref} is ${p.status}.`);
    if (Date.now() > until) die(`Project ${ref} was still ${p.status} after ${Math.round(WAIT / 60000)} minutes.`);
    log(`Waiting for the project: ${p.status}`);
    await sleep(POLL);
  }
  await api('PATCH', `/v1/projects/${ref}/config/auth`, authSettings(sub));
  await api('POST', `/v1/projects/${ref}/secrets`, [{ name: 'SIM_ALLOWED_ORIGIN', value: `https://${sub}.${DOMAIN}` }]);
  log(`Project ${ref} is up; sign-in settings and SIM_ALLOWED_ORIGIN set.`);
}

/** The key the app uses: the publishable key, or the legacy anon key on projects that only have that. */
export function publicKey(keys) {
  const list = Array.isArray(keys) ? keys : [];
  const pub = list.find((k) => k.type === 'publishable' && k.api_key?.startsWith('sb_publishable_'));
  const anon = list.find((k) => k.type === 'legacy' && k.name === 'anon' && k.api_key);
  return (pub ?? anon)?.api_key ?? null;
}

async function finish(sub, ref) {
  if (!REF.test(ref || '')) die(`Not a project ref: ${ref}`);
  const key = publicKey(await api('GET', `/v1/projects/${ref}/api-keys?reveal=false`));
  if (!key) die(`No publishable or anon key found for ${ref}.`);
  const rows = await controlQuery('select public.provision_done($1, $2, $3)::text as d', [sub, `https://${ref}.supabase.co`, key]);
  const d = JSON.parse(rows[0].d);
  const link = `https://${sub}.${DOMAIN}`;
  log(`${sub} is live at ${link}`);
  summary(`**Ready:** ${link}`);
  await mail(d.email, d.lang === 'en' ? 'Your QuickSales is ready' : 'Votre QuickSales est prêt', welcome(d, link), process.env.OWNER_EMAIL);
  await mail(process.env.OWNER_EMAIL, `Ready: ${d.business} (${sub})`, frame(`<p><b>${esc(d.business)}</b> is set up and has been emailed its link:
<a href="${link}">${link}</a>.</p><p>Project: ${esc(ref)}. Backups go to the folder <b>${esc(sub)}/</b>: add an R2 lifecycle rule for
<b>${esc(sub)}/daily/</b> (30 days), as for the other clients.</p>`));
}

async function fail(sub, why) {
  const rows = await controlQuery('select public.provision_failed($1, $2)::text as d', [sub, why || 'unknown error']);
  const d = rows[0]?.d ? JSON.parse(rows[0].d) : { business: sub };
  const run = process.env.GITHUB_RUN_ID ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` : '';
  summary(`**Failed:** ${why}`);
  await mail(process.env.OWNER_EMAIL, `Setup failed: ${d.business} (${sub})`, frame(`<p>Setting up <b>${esc(d.business)}</b> (${esc(sub)}.${esc(DOMAIN)}) stopped:</p>
<p style="background:#fff3f3;padding:10px;border-radius:6px">${esc(why)}</p>${run ? `<p>Details: <a href="${run}">${run}</a></p>` : ''}
<p>Fix the cause, then open the approval link from the signup email again and press <b>Try again</b>. Nothing is made twice.</p>`));
}

// ---- email (Resend) ----
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const frame = (body) => `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:auto;color:#14213d;line-height:1.5">
<div style="background:#06328F;color:#fff;padding:14px 18px;border-radius:10px 10px 0 0;font-weight:bold;font-size:18px">QuickSales</div>
<div style="border:1px solid #dde3f0;border-top:0;padding:18px;border-radius:0 0 10px 10px">${body}</div></div>`;
const button = (href, label) => `<p style="margin:22px 0"><a href="${href}" style="background:#06328F;color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:bold">${label}</a></p>`;
export function welcome(d, link) {
  return d.lang === 'en'
    ? frame(`<p>Hello ${esc(d.name)},</p><p>QuickSales for <b>${esc(d.business)}</b> is ready at <b>${esc(link.replace('https://', ''))}</b>.</p>${button(link, 'Open QuickSales')}
<p>The first time, it asks for your name, an Admin username and password, your company details for the invoices, the exchange rate, VAT and your shops. Then you create the logins for your team.</p>
<p>Install it on each till PC from that address (the install icon in Chrome's address bar), so it also works without internet.</p><p>The QuickSales team</p>`)
    : frame(`<p>Bonjour ${esc(d.name)},</p><p>QuickSales pour <b>${esc(d.business)}</b> est prêt à l'adresse <b>${esc(link.replace('https://', ''))}</b>.</p>${button(link, 'Ouvrir QuickSales')}
<p>La première fois, il vous demande votre nom, un identifiant et un mot de passe Admin, les informations de votre société pour les factures, le taux, la TVA et vos boutiques. Vous créez ensuite les accès de votre équipe.</p>
<p>Installez-le sur chaque PC de caisse depuis cette adresse (l'icône d'installation dans la barre d'adresse de Chrome) : il fonctionne alors aussi sans internet.</p><p>L'équipe QuickSales</p>`);
}
async function mail(to, subject, html, replyTo) {
  const key = process.env.RESEND_API_KEY;
  if (!key || !to) { console.error(`${inActions ? '::warning::' : ''}Email not sent (no RESEND_API_KEY or address): ${subject}`); return; }
  const res = await fetch(process.env.RESEND_API_URL || 'https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: process.env.MAIL_FROM || 'QuickSales <hello@getquicksales.com>', to: [to], subject, html, ...(replyTo ? { reply_to: replyTo } : {}) }),
  }).catch((e) => ({ ok: false, status: 0, text: async () => e.message }));
  if (!res.ok) console.error(`${inActions ? '::warning::' : ''}Email to ${to} failed: HTTP ${res.status} ${await res.text()}`);
}

const [cmd, sub, arg] = process.argv.slice(2);
if (import.meta.url === `file://${process.argv[1]}`) {
  if (!SUB.test(sub || '')) die(`Not a subdomain: ${sub}`);
  if (cmd === 'start') await start(sub);
  else if (cmd === 'finish') await finish(sub, arg);
  else if (cmd === 'fail') await fail(sub, arg);
  else die('Usage: provision.mjs start <subdomain> | finish <subdomain> <ref> | fail <subdomain> <why>');
}
