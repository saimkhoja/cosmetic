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

From the repository folder on your computer:

```bash
supabase login                                   # opens the browser
supabase link --project-ref YOUR-PROJECT-REF     # the ref is in the project URL: https://YOUR-PROJECT-REF.supabase.co
supabase db push                                 # creates the tables, access rules and functions
supabase functions deploy setup --no-verify-jwt  # first-run setup screen
supabase functions deploy admin-users            # Admin user management
```

`db push` applies the three files in `supabase/migrations/` in order. If you prefer, you can paste them one by one into the Supabase **SQL editor** instead, in file-name order.

Then in the Supabase dashboard:

1. **Authentication → Sign In / Providers → Email**: keep Email enabled, turn **Confirm email off**.
2. **Authentication → Sign In / Providers**: turn **Allow new users to sign up off**. Only the Admin creates logins, through SIM.
3. **Authentication → Sign In / Providers → Email → Password requirements**: minimum length **10**, require **letters and digits**.
4. **Authentication → URL Configuration → Site URL**: `https://your-domain` (from step 3).
5. Optional, recommended once the domain is live: limit the server functions to your domain:
   `supabase secrets set SIM_ALLOWED_ORIGIN=https://your-domain`
6. **Billing**: the Pro plan includes daily backups of the database. Recommended for real business data.

## 2. Try it on your computer (optional)

```bash
cd app
cp .env.example .env.local       # put your project URL and anon key in it (Settings → API)
npm install
npm run dev                      # open http://localhost:5173
```

The first visit shows the **Set up SIM** screen; see step 4. Anything you create here goes into the real project, so you can also do the setup from the VPS later instead.

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
