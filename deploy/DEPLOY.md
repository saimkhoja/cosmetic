# Deploying SIM

SIM has two parts:

| Part | Where it runs | What it holds |
|---|---|---|
| **Database, logins and server functions** | Your **Supabase Cloud** project | All data, passwords (hashed by Supabase), access rules |
| **Web app** (what people open in the browser) | Your **VPS**, served by Caddy with automatic HTTPS | Only the app files; no data, no secrets |

You need a computer with **Git**, **Node.js 22** and the **Supabase CLI** (`npm i -g supabase` or see supabase.com/docs/guides/cli) for step 1, and the VPS for step 3.

> **Keys.** The Supabase *anon* key is public by design and goes into the web app. The *service_role* key must **never** be put in the app, in `deploy/.env`, in chat or in Git: only Supabase's own Edge Functions use it, and Supabase gives it to them automatically.

---

## 1. Set up the Supabase project (once)

Use an **empty** project (no tables of your own yet). There are two ways; pick one.

### Option A: from the Supabase dashboard, nothing to install

1. **Database.** Dashboard → **SQL Editor** → **New query**. Paste the whole content of each file below and press **Run**, one file at a time, in this order. Each should end with "Success. No rows returned".
   1. `supabase/migrations/20261006000001_schema.sql`
   2. `supabase/migrations/20261006000002_rls.sql`
   3. `supabase/migrations/20261006000003_functions.sql`

   To check, run this in a new query. It should return `16 tables, 16 functions`:
   ```sql
   select (select count(*) from information_schema.tables where table_schema = 'public') || ' tables, ' ||
          (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in
            ('setup_needed','app_setup','save_settings','save_shop','mark_password_changed','save_product','receive_stock',
             'import_products','create_deliveries','edit_delivery','register_device','submit_invoice','edit_invoice',
             'record_reprint','add_upkeep','sales_report')) || ' functions' as result;
   ```
2. **Edge Functions.** Dashboard → **Edge Functions** → **Deploy a new function** → **Via Editor**, twice:
   - Name **`setup`**: replace the sample code with the content of `supabase/functions/setup/index.ts`, then **Deploy**.
   - Name **`admin-users`**: the same with `supabase/functions/admin-users/index.ts`.
   - For **each** function, open its **Details** (or Settings) and turn **Verify JWT** (sometimes "Enforce JWT verification") **off**, then save. `setup` must work before anyone has a login, and `admin-users` checks the Admin's login itself.
3. **Check both functions.** Open `https://YOUR-REF.supabase.co/functions/v1/setup` in the browser, then the same with `admin-users` at the end. Each must show `{"error":"Method not allowed"}`. That means it is deployed and reachable. If you see:
   - `Missing authorization header` or `Invalid JWT`: **Verify JWT** is still on for that function. Turn it off and save.
   - `Requested function was not found`: the name is not exactly `setup` / `admin-users`. Deploy it again with the right name.
   - `BOOT_ERROR`: the code was not pasted completely. Paste the whole file again and deploy.
4. Continue with **Auth settings** below.

### Option B: with the Supabase CLI on your computer

```bash
supabase login                                   # opens the browser
supabase link --project-ref YOUR-PROJECT-REF     # the ref is in the project URL: https://YOUR-PROJECT-REF.supabase.co
supabase db push                                 # creates the tables, access rules and functions
supabase functions deploy setup --no-verify-jwt
supabase functions deploy admin-users --no-verify-jwt
```

### Auth settings (both options)

1. **Authentication → Sign In / Providers → Email**: keep Email enabled, turn **Confirm email off**.
2. **Authentication → Sign In / Providers**: turn **Allow new users to sign up off**. Only the Admin creates logins, through SIM.
3. **Authentication → Sign In / Providers → Email → Password requirements**: minimum length **10**, require **letters and digits**.
4. **Authentication → URL Configuration → Site URL**: `https://your-domain` (from step 3; you can set it later).
5. Optional, once the site is live: in **Edge Functions → Secrets** add `SIM_ALLOWED_ORIGIN` = `https://your-site-address`, so the functions only answer your site. Several addresses can be separated by commas; a trailing `/` does not matter.
6. **Billing**: the Pro plan includes daily database backups. Recommended for real business data.

### Keys for the web app

**Project Settings → API Keys**. You need the **Project URL** (`https://YOUR-PROJECT-REF.supabase.co`) and the **publishable** key (`sb_publishable_…`), or on older projects the **anon** key. Both are public by design. Do **not** use the **secret** / **service_role** key anywhere in SIM.

## 2. Try it on your computer (optional)

```bash
cd app
cp .env.example .env.local       # put your project URL and anon key in it (Settings → API)
npm install
npm run dev                      # open http://localhost:5173
```

The first visit shows the **Set up SIM** screen; see step 4. Anything you create here goes into the real project, so you can also do the setup from the VPS later instead.

## 3a. Or host the web app free on Vercel (no server needed)

The app is static files, so Vercel's free plan works well until you have a VPS. The settings are in `app/vercel.json`.

1. Sign in at **vercel.com** with your GitHub account (Hobby plan, free).
2. **Add New → Project**, then **Import** the `saimkhoja/cosmetic` repository. If it isn't listed, click **Adjust GitHub App Permissions** and allow this repository.
3. On the configure screen:
   - **Root Directory**: click **Edit** and choose **`app`**. This one matters.
   - **Framework Preset**: Vite. Build and output settings come from `vercel.json`; leave them as they are.
   - **Environment Variables**: add `VITE_SUPABASE_URL` = `https://YOUR-REF.supabase.co` and `VITE_SUPABASE_ANON_KEY` = your publishable (or anon) key.
4. Click **Deploy**. After a minute or two you get a link like `https://cosmetic-xxxx.vercel.app`.
5. In Supabase, set **Authentication → URL Configuration → Site URL** to that link. Optionally add the Edge Function secret `SIM_ALLOWED_ORIGIN` with the same link.

If the setup screen says a server function **could not be reached** (or "Failed to send a request to the Edge Function"), do the function check in section 1, Option A, step 3. Also make sure any `SIM_ALLOWED_ORIGIN` secret is this site's address.

Every push to `main` deploys again automatically. If you change an environment variable later, redeploy (Deployments → ⋯ → Redeploy) because the values are built into the app.

## 3. Put the web app on the VPS

A small VPS is enough (1 vCPU, 1–2 GB RAM, Ubuntu 24.04): it only serves files.

1. Point your domain (for example `sim.yourcompany.cd`) at the VPS: an **A record** with the VPS IP address.
2. On the VPS, install Docker: `curl -fsSL https://get.docker.com | sh`
3. Get the code and settings:
   ```bash
   git clone https://github.com/saimkhoja/cosmetic.git sim && cd sim
   cp deploy/.env.example deploy/.env
   nano deploy/.env       # SIM_DOMAIN, VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY
   ```
4. Build and start:
   ```bash
   docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d --build
   ```
   Caddy gets the HTTPS certificate by itself within a minute (ports 80 and 443 must be open).

**Updating** after new code: `git pull && docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d --build`.
If the update has new files in `supabase/migrations/`, run `supabase db push` from your computer first. Tills pick up the new app automatically the next time they are online.

## 4. First run

1. Open `https://your-domain`. The **Set up SIM** screen appears (only on an empty project).
2. Enter your name, the Admin username and a strong password, the company details shown on invoices, the exchange rate, VAT and the shops with their 3-letter codes.
3. You are signed in as Admin. Next:
   - **Inventory → Import from Excel** to load the catalogue (download the template there), or add items one by one.
   - **Users → Create login** for the warehouse operator, each shop admin and each till operator. Give each person their username and first password; SIM makes them choose their own at their first sign-in.
   - **Deliveries → New delivery** to put stock into the shops.

## 5. Setting up each till

- Open `https://your-domain` in **Chrome** on the till PC and sign in **while online** once. This loads the items onto the till and registers it (it gets a till code such as T1; invoice numbers look like `GOM-T1-000123`).
- Chrome menu → **Install SIM** to put it on the desktop like an app.
- **One-tap printing**: by default the browser shows its print dialog. To print straight to the receipt printer, set it as the Windows default printer and start Chrome with `--kiosk-printing`, for example a desktop shortcut to
  `"C:\Program Files\Google\Chrome\Application\chrome.exe" --kiosk-printing --app=https://your-domain/till`
- **Without internet** the till keeps selling and printing. Sales are kept on the till and sent automatically when the connection returns; the pill at the top shows how many are waiting. Do not clear the browser data on a till that shows sales waiting.

## 6. Backups and exporting data

- Supabase Pro takes daily backups (Dashboard → Database → Backups).
- For your own copy at any time: `supabase db dump --data-only -f sim-backup.sql` from your computer.

## 7. Checking the build yourself

```bash
supabase/tests/run.sh                    # database rules and functions (needs Docker)
cd app && npm test && npx tsc -b         # app unit tests and type check
supabase/local/start.sh                  # local Supabase-compatible stack on http://127.0.0.1:54321
# then build the app against it and run the end-to-end test:
#   VITE_SUPABASE_URL=http://127.0.0.1:54321 VITE_SUPABASE_ANON_KEY=<ANON_KEY printed by start.sh> npx vite build
#   npx vite preview --port 4173 & npx playwright test
```
