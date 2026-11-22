# QuickSales control project

One small Supabase project that lists every client and where its database is. It is **not** a client's database
and holds no shop data: each client still has a Supabase project of their own (see `deploy/DEPLOY.md`, section 6).

```
sapcongo.getquicksales.com  ──►  one Vercel project (every client)  ──►  control: tenant_config('sapcongo')
                                                                          └─► https://<sapcongo's ref>.supabase.co + public key
```

The app asks the control project once, keeps the answer on the device, and from then on opens straight away
(also offline) while it checks the answer in the background. A changed answer is used from the next start.

| What | Where |
|---|---|
| `migrations/` | the `tenants` table, `tenant_config()` and `subdomain_available()` (all the public can call), and the signup functions |
| `scripts/add_tenant.sql` | add or update a client by hand (new clients normally come through signup) |
| `supabase/functions/` | the Edge Functions `signup` and `approve` (signups from getquicksales.com) |
| `tests/` | the tests (SQL, Edge Functions); also run in CI |

## Signups from getquicksales.com

```
visitor fills the form ──► signup function ──► tenants row, status pending ──► email to you (Review and approve)
                                                                              └► email to them (request received)
you open the link ──► getquicksales.com/approve ──► approve function ──► status provisioning
                                                                      └► GitHub: "Set up a new client" (provision.yml)
provision.yml ──► their Supabase project, sign-in settings, migrations, Edge Functions ──► status active ──► welcome email
```

- **Reject** deletes the request and frees the name. **Failed** setups keep their project; "Try again" on the same page
  continues where it stopped (nothing is made twice).
- Limits: 3 open requests a day from one internet address, 30 a day in all; a hidden field catches simple robots.
- Only active and suspended clients are served, updated and backed up; requests never are.
- The approval link carries a signature (HMAC with `APPROVE_SECRET`) of the name and the moment it was asked for. Keep the
  emails private: anyone with the link can approve or reject that one request.
- One-time setup: `deploy/DEPLOY.md`, section 6d.

## Setting it up (once)

1. **supabase.com → New project**, named e.g. `quicksales-control`. Any region; it is asked one tiny question per device.
2. **SQL Editor** → paste `control/migrations/20261122000001_tenants.sql` → **Run**. Later files are applied by the
   **Update control project** workflow (`.github/workflows/control.yml`), with the Edge Functions; don't paste them by hand.
3. **Settings → API**: write down the **Project URL** and the **anon / publishable** key. These go into the shared Vercel
   project as `VITE_CONTROL_URL` and `VITE_CONTROL_ANON_KEY` (`deploy/DEPLOY.md`, section 6).
4. Add each client with `scripts/add_tenant.sql` (below).

No Auth settings are needed. Keep the **secret / service_role** key of this project to yourself; only its Edge Functions
use it, inside Supabase.

## Adding or changing a client

In the **control** project's SQL Editor, paste `scripts/add_tenant.sql`, fill in the five values from the **client's**
project (Settings → API) and **Run**. Running it again for the same subdomain updates that client.

- `subdomain`: lowercase letters, digits and single hyphens, up to 40 characters. Names the site keeps for itself
  (`www`, `app`, `api`, `admin`, `test`, `demo`, …) are refused; the list is in the migration and in `app/src/lib/tenant.ts`.
- `anon_key`: the client's **public** key. The table refuses nothing else, so check you did not paste the secret one.
- `project_ref` and `backup_name`: the database updates and nightly backups (`.github/workflows/migrate.yml` and
  `backup.yml`) go through every client that has a `project_ref`, and save its backups in the `backup_name` folder.
  A client without a `project_ref` is skipped, with a warning in the run.

**Switching a client off** (e.g. unpaid): `update public.tenants set status = 'suspended' where subdomain = '…';`
The site then shows "… is switched off". A till that is already open keeps going until it is restarted, so a sale is never cut off.
`'active'` switches it back on.

**Moving a client to another Supabase project**: update `supabase_url` and `anon_key`. Devices pick up the new database
from their next start; anything a till has not sent yet stays on the till, so first check every till shows nothing waiting to send.

## Who can see what

- The public (the app, the signup form) can call `subdomain_available('<name>')` (free, taken, reserved or invalid) and
  `tenant_config('<one subdomain>')` and gets the business name,
  URL, public key and active/suspended: the same things anyone gets by opening that client's site. It cannot list clients.
- The `tenants` table (contacts, project refs, backup names) is readable only in the dashboard and with the secret key.
