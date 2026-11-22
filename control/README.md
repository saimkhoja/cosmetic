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
| `migrations/` | the `tenants` table and `tenant_config()`, the only thing the public can call |
| `scripts/add_tenant.sql` | add or update a client by hand (until signup does it, step 3) |
| `tests/run.sh` | the tests; also run in CI |

## Setting it up (once)

1. **supabase.com → New project**, named e.g. `quicksales-control`. Any region; it is asked one tiny question per device.
2. **SQL Editor** → paste each file of `control/migrations/` in order → **Run**.
3. **Settings → API**: write down the **Project URL** and the **anon / publishable** key. These go into the shared Vercel
   project as `VITE_CONTROL_URL` and `VITE_CONTROL_ANON_KEY` (`deploy/DEPLOY.md`, section 6).
4. Add each client with `scripts/add_tenant.sql` (below).

Nothing else is needed: no Auth settings, no Edge Functions. Keep the **secret / service_role** key of this project to yourself;
signup (step 3) will use it from a server, never from the browser.

## Adding or changing a client

In the **control** project's SQL Editor, paste `scripts/add_tenant.sql`, fill in the five values from the **client's**
project (Settings → API) and **Run**. Running it again for the same subdomain updates that client.

- `subdomain`: lowercase letters, digits and single hyphens, up to 40 characters. Names the site keeps for itself
  (`www`, `app`, `api`, `admin`, `test`, `demo`, …) are refused; the list is in the migration and in `app/src/lib/tenant.ts`.
- `anon_key`: the client's **public** key. The table refuses nothing else, so check you did not paste the secret one.

**Switching a client off** (e.g. unpaid): `update public.tenants set status = 'suspended' where subdomain = '…';`
The site then shows "… is switched off". A till that is already open keeps going until it is restarted, so a sale is never cut off.
`'active'` switches it back on.

**Moving a client to another Supabase project**: update `supabase_url` and `anon_key`. Devices pick up the new database
from their next start; anything a till has not sent yet stays on the till, so first check every till shows nothing waiting to send.

## Who can see what

- The public (the app, anyone with the URL) can only call `tenant_config('<one subdomain>')` and gets the business name,
  URL, public key and active/suspended: the same things anyone gets by opening that client's site. It cannot list clients.
- The `tenants` table (contacts, project refs, backup names) is readable only in the dashboard and with the secret key.
