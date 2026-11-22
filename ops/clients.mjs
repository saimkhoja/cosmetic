#!/usr/bin/env node
// Reads the list of clients from the control project and gives the workflows a way into each client's database,
// through the Supabase Management API (https://api.supabase.com). Used by .github/workflows/migrate.yml and backup.yml.
//
//   node ops/clients.mjs list [subdomain]       JSON list of clients to work on (all, or the one named)
//   node ops/clients.mjs db-url <ref> <file>    writes a connection string for that project to <file>
//
// Environment: SUPABASE_ACCESS_TOKEN (a personal access token: supabase.com → Account → Access Tokens)
//              CONTROL_PROJECT_REF   (the control project's ref)
//
// db-url asks Supabase for a temporary database login (it expires by itself; the same thing the Supabase CLI does),
// so no client's database password is stored anywhere. Inside GitHub Actions the password is masked in the logs.
import { writeFileSync } from 'node:fs';

const API = process.env.SUPABASE_API_URL || 'https://api.supabase.com';   // overridden only by the tests
const TOKEN = process.env.SUPABASE_ACCESS_TOKEN;
const inActions = process.env.GITHUB_ACTIONS === 'true';
const REF = /^[a-z0-9]{10,40}$/;

function die(msg) { console.error(inActions ? `::error::${msg}` : msg); process.exit(1); }

async function api(method, path, body) {
  if (!TOKEN) die('SUPABASE_ACCESS_TOKEN is not set (GitHub → Settings → Secrets and variables → Actions).');
  for (let attempt = 1; ; attempt++) {
    let res;
    try {
      res = await fetch(API + path, {
        method,
        headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json', Accept: 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (e) {
      if (attempt < 4) { await sleep(2000 * attempt); continue; }
      die(`Supabase API unreachable: ${e.message}`);
    }
    if ((res.status === 429 || res.status >= 500) && attempt < 4) { await sleep(3000 * attempt); continue; }
    const text = await res.text();
    if (!res.ok) {
      const hint = res.status === 401 ? ' (the access token is wrong or expired)' : res.status === 403 || res.status === 404 ? ' (the token cannot see this project: is it in the same Supabase account?)' : '';
      die(`Supabase API ${method} ${path}: HTTP ${res.status}${hint}: ${text.slice(0, 300)}`);
    }
    try { return text ? JSON.parse(text) : null; } catch { die(`Supabase API ${path}: not JSON: ${text.slice(0, 200)}`); }
  }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The folder a client's backups go in, and the GitHub secret that may hold its own database address (e.g. CLIENT2_DB_URL). */
function jobFor(t) {
  const folder = t.backup_name || t.subdomain;
  return { subdomain: t.subdomain, ref: t.project_ref, status: t.status, folder, db_secret: `${folder.toUpperCase().replace(/-/g, '_')}_DB_URL` };
}

async function list(only) {
  const control = process.env.CONTROL_PROJECT_REF;
  if (!control || !REF.test(control)) die('CONTROL_PROJECT_REF is not set, or is not a project ref (the part before .supabase.co of the control project).');
  const rows = await api('POST', `/v1/projects/${control}/database/query`, {
    read_only: true,
    query: `select subdomain, project_ref, backup_name, status from public.tenants
            where status in ('active', 'suspended') order by created_at, subdomain`,
  });
  if (!Array.isArray(rows)) die(`Unexpected answer from the control project: ${JSON.stringify(rows).slice(0, 300)}`);
  let jobs = rows.map(jobFor);
  const noRef = jobs.filter((j) => !j.ref || !REF.test(j.ref));
  for (const j of noRef) console.error(`${inActions ? '::warning::' : ''}${j.subdomain} has no project_ref in the control project, so it is skipped. Fill it in with control/scripts/add_tenant.sql.`);
  jobs = jobs.filter((j) => !noRef.includes(j));
  if (only) {
    jobs = jobs.filter((j) => j.subdomain === only.trim().toLowerCase());
    if (!jobs.length) die(`No client "${only}" with a project_ref in the control project.`);
  }
  const out = JSON.stringify(jobs);
  if (process.env.GITHUB_OUTPUT) writeFileSync(process.env.GITHUB_OUTPUT, `clients=${out}\ncount=${jobs.length}\n`, { flag: 'a' });
  console.log(out);
}

async function dbUrl(ref, file) {
  if (!REF.test(ref || '')) die(`Not a project ref: ${ref}`);
  if (!file) die('Usage: clients.mjs db-url <ref> <file>');
  const project = await api('GET', `/v1/projects/${ref}`);
  if (project?.status !== 'ACTIVE_HEALTHY') die(`Project ${ref} is ${project?.status ?? 'unknown'}, not ACTIVE_HEALTHY (paused?). Restore it in the Supabase dashboard first.`);
  // the session pooler (port 5432): reachable over IPv4 from GitHub's runners, and pg_dump works through it
  const poolers = await api('GET', `/v1/projects/${ref}/config/database/pooler`);
  const p = Array.isArray(poolers) ? poolers.find((x) => x.database_type === 'PRIMARY') : null;
  if (!p?.db_host) die(`No connection pooler found for ${ref}.`);
  const login = await api('POST', `/v1/projects/${ref}/cli/login-role`, { read_only: false });
  if (!login?.role || !login?.password) die(`Could not get a temporary login for ${ref}.`);
  if (inActions) console.log(`::add-mask::${login.password}`);
  const user = encodeURIComponent(`${login.role}.${ref}`);
  const url = `postgresql://${user}:${encodeURIComponent(login.password)}@${p.db_host}:5432/${encodeURIComponent(p.db_name || 'postgres')}?sslmode=require`;
  if (inActions) console.log(`::add-mask::${url}`);
  writeFileSync(file, url, { mode: 0o600 });
  console.log(`Temporary login ${login.role} for ${ref} via ${p.db_host} (valid ${login.ttl_seconds}s)`);
}

const [cmd, a, b] = process.argv.slice(2);
if (cmd === 'list') await list(a);
else if (cmd === 'db-url') await dbUrl(a, b);
else if (cmd) die(`Unknown command: ${cmd}`);
else die('Usage: clients.mjs list [subdomain] | db-url <ref> <file>');
