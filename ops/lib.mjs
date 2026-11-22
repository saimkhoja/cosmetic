// Shared by ops/clients.mjs and ops/provision.mjs: calls to the Supabase Management API and the control project.
export const API = process.env.SUPABASE_API_URL || 'https://api.supabase.com';   // overridden only by the tests
export const inActions = process.env.GITHUB_ACTIONS === 'true';
export const REF = /^[a-z0-9]{10,40}$/;
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function die(msg) { console.error(inActions ? `::error::${msg}` : msg); process.exit(1); }

/** A Management API call with SUPABASE_ACCESS_TOKEN; retries when Supabase is busy, stops with a readable message otherwise. */
export async function api(method, path, body) {
  const token = process.env.SUPABASE_ACCESS_TOKEN;
  if (!token) die('SUPABASE_ACCESS_TOKEN is not set (GitHub → Settings → Secrets and variables → Actions).');
  for (let attempt = 1; ; attempt++) {
    let res;
    try {
      res = await fetch(API + path, {
        method,
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (e) {
      if (attempt < 4) { await sleep(2000 * attempt); continue; }
      die(`Supabase API unreachable: ${e.message}`);
    }
    if ((res.status === 429 || res.status >= 500) && attempt < 4) { await sleep(3000 * attempt); continue; }
    const text = await res.text();
    if (!res.ok) {
      const hint = res.status === 401 ? ' (the access token is wrong or expired)'
        : res.status === 403 ? ' (the token is missing a permission for this, or cannot see this project)'
        : res.status === 404 ? ' (the token cannot see this project: is it in the same Supabase organization?)' : '';
      die(`Supabase API ${method} ${path}: HTTP ${res.status}${hint}: ${text.slice(0, 300)}`);
    }
    try { return text ? JSON.parse(text) : null; } catch { die(`Supabase API ${path}: not JSON: ${text.slice(0, 200)}`); }
  }
}

export function controlRef() {
  const control = process.env.CONTROL_PROJECT_REF;
  if (!control || !REF.test(control)) die('CONTROL_PROJECT_REF is not set, or is not a project ref (the part before .supabase.co of the control project).');
  return control;
}

/** Runs SQL on the control project as postgres, with $1, $2… parameters; returns the rows. */
export async function controlQuery(query, parameters, readOnly = false) {
  const rows = await api('POST', `/v1/projects/${controlRef()}/database/query`, { query, ...(parameters ? { parameters } : {}), read_only: readOnly });
  if (!Array.isArray(rows)) die(`Unexpected answer from the control project: ${JSON.stringify(rows).slice(0, 300)}`);
  return rows;
}
