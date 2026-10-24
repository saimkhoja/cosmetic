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
   4. `supabase/migrations/20261007000001_review_flows.sql` (orders approved by the shop admin, customer names, deliveries received by the shop)
   5. `supabase/migrations/20261011000001_catalogue.sql` (categories made by the Admin, half dozen and optional carton prices, deleting and archiving items, hot items first, the till printing approved orders)
   6. `supabase/migrations/20261011000002_accounts.sql` (book keeping: suppliers, goods in and bills, payments, returns from shops, ledgers, statements and reports)
   7. `supabase/migrations/20261015000001_shop_changes.sql` (price per pc optional, changing the unit when editing an invoice, deleting an invoice or a supplier)
   8. `supabase/migrations/20261015000002_statement_order.sql` (statements and the day book list same-day entries in the order they were made)
   9. `supabase/migrations/20261016000001_stock_requests.sql` (the shop admin orders stock; the warehouse approves, edits or rejects the request)
   10. `supabase/migrations/20261018000001_supermarket.sql` (two switches in Settings, both off until the Admin turns them on: the customer name optional, and barcode scanning)
   11. `supabase/migrations/20261019000001_till_sells.sql` (a third switch: till operators sell directly, without the shop admin's approval; the activity log writes amounts in CDF)
   12. `supabase/migrations/20261020000001_cash_change.sql` (a fourth switch: the cashier enters the cash received; the till shows the change and the receipt prints both)
   13. `supabase/migrations/20261022000001_two_rates.sql` (two exchange rates: the sales rate for prices, tickets and tills, and the internal rate for suppliers, expenses and vouchers; the internal rate starts equal to today's rate)
   14. `supabase/migrations/20261023000001_usd_payment.sql` (a fifth switch: the till accepts payment in USD, CDF or both; change in CDF or whole dollars plus CDF; the day end slip shows Collected USD)
   15. `supabase/migrations/20261024000001_supplier_returns.sql` (returns to suppliers, and claims for goods a bill charges for but the warehouse did not receive)
   16. `supabase/migrations/20261025000001_one_per_carton.sql` (an item can come one pc per carton: pcs in one carton takes 1 or more)

   **Already running SIM?** Run only the files you have not run yet, in order (for example only 16). Run it **before** the new app goes live. They keep your data:
   - the categories your items already use are kept, so nothing breaks; edit or add more under **Inventory → Categories**;
   - the stock already in the store and in each shop is booked once, at cost, as the opening stock of the books (voucher OPN-00001). Sales, deliveries and expenses from before are not booked; the books start on the day you run file 6;
   - enter the opening balances (cash in hand, bank, capital, what you owe each supplier) under **Accounts → Ledgers** and **Accounts → Suppliers**.

   To check, run this in a new query. It should return `32 tables, 49 functions`:
   ```sql
   select (select count(*) from information_schema.tables where table_schema = 'public') || ' tables, ' ||
          (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in
            ('setup_needed','app_setup','save_settings','save_shop','mark_password_changed','save_product','import_products',
             'create_deliveries','edit_delivery','register_device','submit_invoice','edit_invoice','record_reprint','add_upkeep',
             'sales_report','submit_order','reject_order','receive_delivery','cancel_delivery','save_category','delete_category',
             'delete_product','restore_product','item_ranks','record_till_print','save_supplier','receive_goods','enter_bill',
             'post_voucher','cancel_voucher','save_account','delete_account','adjust_stock','create_return','cancel_return',
             'receive_return','account_statement','ledger_list','trial_balance','profit_loss','balance_sheet','day_book','payables',
             'delete_invoice','delete_supplier','create_stock_request','cancel_stock_request','reject_stock_request',
             'approve_stock_request')) || ' functions' as result;
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
   - **Inventory → Categories** to make the categories (mark seasonal ones such as school items with the months they sell).
   - **Inventory → Import from Excel** to load the catalogue (download the template there), or add items one by one. A category named in the sheet that does not exist yet is created.
   - **Accounts → Suppliers** to add the suppliers with their credit days and the items each one supplies, and **Accounts → Ledgers** for the opening balances (cash, bank, capital).
   - **Users → Create login** for the warehouse operator, each shop admin and each till operator. Give each person their username and first password; SIM makes them choose their own at their first sign-in.
   - **Deliveries → New delivery** to put stock into the shops.

## 5. Setting up each till

- Open `https://your-domain` in **Chrome** on the till PC and sign in **while online** once. This loads the items onto the till and registers it (it gets a till code such as T1; invoice numbers look like `GOM-T1-000123`).
- Chrome menu → **Install SIM** to put it on the desktop like an app.
- **One-tap printing**: by default the browser shows its print dialog. To print straight to the receipt printer, set it as the Windows default printer and start Chrome with `--kiosk-printing`, for example a desktop shortcut to
  `"C:\Program Files\Google\Chrome\Application\chrome.exe" --kiosk-printing --app=https://your-domain/till`
- **Without internet** the till keeps selling and printing. Sales are kept on the till and sent automatically when the connection returns; the pill at the top shows how many are waiting. Do not clear the browser data on a till that shows sales waiting.

## 6. Another client (a separate installation)

Each client has **their own Supabase project and their own website**, built from the same code. Their data, logins and backups are completely separate: a site only talks to the project whose URL and key it was built with. Nothing you do for a new client touches an existing client's project.

1. **New Supabase project** in the client's name (supabase.com → New project). Do all of section 1 for it: every migration file, the `setup` and `admin-users` functions with **Verify JWT off**, and the Auth settings. Write down its Project URL and publishable key.
2. **New Vercel project** for the same repository (section 3a again: Add New → Project → import `saimkhoja/cosmetic`, Root Directory `app`). Give it a name such as `sim-clientname`, and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` to **the new project's** values. Optionally add the client's own domain under Settings → Domains.
3. In the **new** Supabase project set **Site URL** (and the `SIM_ALLOWED_ORIGIN` secret if you use it) to the new site's address.
4. The client opens the new site: the **Set up SIM** screen asks for their name, Admin username and password, company details for the invoices, rate, VAT and their shops (section 4). Their Admin then creates the other logins.
5. Features they need are turned on under **Settings → Till options**:
   - **Customer name optional**: walk-in sales and orders without typing a name. The invoice then has no Client line, and lists show "Walk-in".
   - **Till operators sell directly**: the till operator takes the cash and prints the invoice without the shop admin approving an order. Only the shop admin gives discounts; the invoice names the till operator as the Sales Person.
   - **Enter the cash received**: under "To pay" the cashier types the amount the customer gives (or taps Exact or a round note); the till shows the change to give and won't print until the cash covers the total. The receipt prints "Cash received" and "Change".
   - **Accept payment in USD (and CDF)**: the till shows what is due in USD at the sales rate; the cashier enters the dollars and/or Francs received (or taps a note), sees what is still due or the change, and can give whole dollars back with the rest in CDF. The receipt shows Paid USD, Paid CDF, the rate and the change; the dollars go to the shop's "Cash USD" ledger and the day end slip shows Collected USD and Collected CDF.
   - **Barcode scanning**: a Barcode field in the item form and a `Barcode` column in the Excel template. At the till a USB scanner (it works as a keyboard, no driver needed) scans into the search box: the item goes into the sale as 1 pc, and the unit can be changed in the cart. Price check finds barcodes too.

**Updating every client.** Every Vercel project redeploys by itself when `main` changes. A new migration file has to be run on **each** client's Supabase project (section 1, only the new files), at the same time; back up that client's database first (section 8). The app keeps working on a project that has not run the newest file yet, but the new features stay off there.

## 7. Going live: clearing the test data

When a client has finished setting up and testing and starts selling for real, `supabase/scripts/reset_go_live.sql` clears the test data.

- **It clears:** invoices, orders, deliveries, goods in, returns (from the shops and to suppliers), stock requests, upkeep, supplier bills, payments, every voucher, all stock (store and shops), the opening balances, and the registered tills.
- **It keeps:** items with their prices, cost prices and barcodes, categories, suppliers, ledger names, shops, logins and passwords, settings and the activity log.

It is not a migration and never runs on its own.

1. **Back up** the database (section 8).
2. On every till, check that the pill at the top shows **nothing waiting to send**.
3. Supabase → **SQL Editor** → paste the whole file → **Run**. The result at the end must show 0 invoices, 0 vouchers and 0 stock, plus the number of items, logins, shops and suppliers kept.
4. On **every till PC**, clear SIM's site data once: in Chrome, click the icon left of the address → **Site settings** → **Delete data**. Then sign in again **while online**. The till registers again as T1, T2… and invoices restart at `000001`.
5. Enter the real starting stock through **Goods in** (or the stock count button in Inventory), and the opening balances (cash, bank, capital, what is owed to each supplier) under **Accounts → Ledgers** and **Accounts → Suppliers**.

## 8. Backups and exporting data

The live database keeps all data for ever: every invoice and voucher from the first day stays in it. Backups are for getting back to an earlier state: after a mistake, a deletion noticed late, or when a client asks for the data as it was on a given date.

- **Supabase Pro** takes a daily backup and keeps the last 7 days (Dashboard → Database → Backups). Good for "undo yesterday".
- **SIM's own nightly backup** (`.github/workflows/backup.yml`) keeps much more. Every night at 02:17 Kinshasa time it dumps the whole database (data, settings, logins), encrypts it with your passphrase and stores it in Cloudflare R2:
  - **daily** copies for 30 days;
  - the copy of the 1st of each month **for ever**.
  - It costs a few cents a month; R2's first 10 GB are free.

### Setting up the nightly backup (once)

1. **Cloudflare R2.** Sign up at cloudflare.com, then go to **R2 Object Storage** and create a bucket, e.g. `sim-backups`.
   - **Manage R2 API Tokens → Create API token**: permission **Object Read & Write**, limited to that bucket. Copy the **Access Key ID**, the **Secret Access Key** and the **S3 endpoint** (`https://<account-id>.r2.cloudflarestorage.com`).
   - Bucket → **Settings → Object lifecycle rules → Add rule**: prefix `client1/daily/`, *delete objects 30 days after upload*. Add the same rule for `client2/daily/` later. Don't add a rule for `monthly/`.
2. **The database address.** In client 1's Supabase project, click **Connect** and copy the **Session pooler** URI, then put in the database password. (If you don't know the password, reset it under Project Settings → Database. SIM doesn't use it.)
3. **A backup passphrase.** Make up a long one (5 or more random words). **Write it down and keep it somewhere safe off the computer.** Without it no backup can be opened, by you or anyone else.
4. **GitHub secrets.** In the repository on GitHub, go to **Settings → Secrets and variables → Actions → New repository secret**, and add these six:

   | Name | Value |
   |---|---|
   | `CLIENT1_DB_URL` | the Session pooler URI from step 2 |
   | `BACKUP_PASSPHRASE` | the passphrase from step 3 |
   | `R2_ENDPOINT` | `https://<account-id>.r2.cloudflarestorage.com` |
   | `R2_ACCESS_KEY_ID` | from step 1 |
   | `R2_SECRET_ACCESS_KEY` | from step 1 |
   | `R2_BUCKET` | `sim-backups` |

5. **Test it now.** GitHub → **Actions → Backup → Run workflow**. After a minute or two the run is green and says `client1 backup saved: client1/daily/client1-2026-…dump.gpg`; the file shows in the R2 bucket. A red run sends an email to the repository owner; the log says which step failed (for example a secret that isn't set).
6. **Client 2** is in the workflow too: add the secret `CLIENT2_DB_URL` (client 2's Session pooler URI) and an R2 lifecycle rule for `client2/daily/`. Each client runs as its own job, so one failing never stops the other. **Another client:** add a `CLIENTn_DB_URL` secret and two lines (`- client: clientn` / `db_secret: CLIENTn_DB_URL`) under `matrix.include` in `.github/workflows/backup.yml`.

GitHub pauses scheduled jobs in a repository that has had **no commit for 60 days**. It emails a warning first; re-enable the job under **Actions → Backup** with one click (or make any commit). A backup can also be taken at any moment with **Run workflow**.

### Getting data back, or giving it to the client

1. In Cloudflare R2, open the bucket, go to `client1/daily/` or `client1/monthly/`, and download the file for the date you need (`client1-YYYY-MM-DD-HHMM.dump.gpg`).
2. Create a **new, empty** Supabase project and run all the files in `supabase/migrations` on it (section 1). Don't do the setup screen.
3. On a computer with PostgreSQL 17 tools (`psql`, `pg_restore`) and `gpg`, run:
   ```bash
   supabase/scripts/restore_backup.sh client1-2026-11-01-0117.dump.gpg "<Session pooler URI of the NEW project>"
   ```
   It asks for the passphrase, then for the word `RESTORE`, and ends with the number of items, invoices, vouchers and logins, and the date of the last sale. It refuses any database that already has logins or invoices, so a live installation can't be overwritten by mistake.
4. To look at that data in SIM: in Vercel, open the project's **Deployments**, pick the latest, choose **Redeploy** with the new project's URL and key as environment variables (or create a separate Vercel project for it). Everyone signs in with the passwords they had on that date. Reports, statements and the books show the data as it was, and can be printed or saved as PDF for the client.
5. To **replace** a damaged live installation, restore into a new project as above, check it, then point client 1's Vercel project at the new project's URL and key, and redeploy.

For a quick copy without the nightly job: `pg_dump "<Session pooler URI>" --format=custom --schema=public --schema=app --schema=auth -f sim-backup.dump`.

## 9. Checking the build yourself

```bash
supabase/tests/run.sh                    # database rules and functions (needs Docker)
cd app && npm test && npx tsc -b         # app unit tests and type check
supabase/local/start.sh                  # local Supabase-compatible stack on http://127.0.0.1:54321
# then build the app against it and run the end-to-end test:
#   VITE_SUPABASE_URL=http://127.0.0.1:54321 VITE_SUPABASE_ANON_KEY=<ANON_KEY printed by start.sh> npx vite build
#   npx vite preview --port 4173 & npx playwright test
```
