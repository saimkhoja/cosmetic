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
import { api, controlQuery, die, inActions, REF } from './lib.mjs';

/** The folder a client's backups go in, and the GitHub secret that may hold its own database address (e.g. CLIENT2_DB_URL). */
function jobFor(t) {
  const folder = t.backup_name || t.subdomain;
  return { subdomain: t.subdomain, ref: t.project_ref, status: t.status, folder, db_secret: `${folder.toUpperCase().replace(/-/g, '_')}_DB_URL` };
}

async function list(only) {
  const rows = await controlQuery(`select subdomain, project_ref, backup_name, status from public.tenants
            where status in ('active', 'suspended') order by created_at, subdomain`, undefined, true);
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
