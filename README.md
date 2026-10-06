# SIM — Smart Invoice Management

Warehouse-to-till retail system for a cosmetics general dealer in Kinshasa, DR Congo:
one central store, several shops, real logins, a database in the cloud, and tills that keep selling without internet.

- **Web app**: React + TypeScript (`app/`), installable on the till PCs, served from a VPS.
- **Backend**: Supabase Cloud (PostgreSQL + Auth) with access rules and business logic in the database (`supabase/`).
- **Deploying**: see **[deploy/DEPLOY.md](deploy/DEPLOY.md)** (Supabase project setup, VPS with automatic HTTPS, first run, tills).
- The approved click-through demo is kept in [`demo/index.html`](demo/index.html) for presentations.

## Roles

There are no demo accounts. The first visit to a new installation shows a **setup screen** that creates the Admin; the Admin then creates every other login.

| Role | Can do |
|---|---|
| Admin | Everything: carton cost, pc/dozen/carton and set/piece prices, Excel import, deliveries, upkeep, users, settings, reports, activity log |
| Warehouse Operator | Item names, units and quantities, receive stock, see every shop's stock, send and correct deliveries. No cost prices, no price changes |
| Shop Admin | Reviews the till operators' orders (add or remove items) and approves them: takes the cash and prints. Also sells directly, invoice discount (max 30%), edits a confirmed invoice with a reason, duplicates, receives deliveries from the store, shop stock, reports and the day end slip |
| Till Operator | Types the customer name, picks the items and sends the order to the Shop Admin for approval. No cash, no printing, no invoice list, no reports |

## What it does

- **Carton pricing.** An item is entered with the cost of one carton, the pcs in a carton and a selling price per pc, per dozen (optional) and per carton. Stock is counted in pcs and shown as cartons + pcs. Mixed sets sell whole or one piece at a last price.
- **Bulk import from Excel** (.xlsx or .csv, template included). Rows are checked first; existing names or codes are skipped; one bad row stops the import so nothing half-imports.
- **The store sends stock to the shops**, to one or more outlets at once (same quantities, one delivery note each). The Shop Admin checks what arrived and approves it, lowering a line if goods are short (with a note); only then does the stock leave the store and enter the shop. Goods already sent count as promised, so the same stock can't be sent twice. A delivery can be corrected or cancelled until it is received.
- **Orders approved by the Shop Admin.** The till operator starts each sale with the customer name, picks the items and sends the order. On the Shop Admin's till, 75% of the screen is the sale he is making and 25% lists the orders waiting for review; he opens one, adds or removes items, then "Approve, take cash and print" records the exact total in Francs and prints the customer and shop copies (customer name and who prepared it on the invoice). He can also reject an order with a reason, which the till operator sees.
- **Offline till.** Items, prices and shop stock are kept on the till. Without internet the Shop Admin keeps selling and printing and the till operator keeps preparing orders (they reach the Shop Admin when the connection returns); each till numbers its own invoices (`GOM-T1-000123`) so tills never clash, and sales are sent automatically when the connection returns. A sale sent twice is saved once.
- **Prices locked.** Only the Admin sets prices; shops sell exactly what was set. Invoices keep the prices and rate of the moment of sale.
- **Editable invoices** by the Shop Admin, with a reason; stock is adjusted and the change is logged.
- **Reports** over any dates, printable or as PDF. A single day prints the **day end report** per shop in the shift end slip format: total invoices, invoice value in USD and FC, collected, returned and balance.
- **Security.** Real passwords (hashed by Supabase Auth; 10+ characters with letters and numbers), each person chooses their own at first sign-in, disabled accounts are shut out at once, the screen locks after 15 minutes, access rules on every table, every change goes through checked database functions, and a full activity log.

## Currency

All cost and selling prices are stored in USD. The shop price in Francs is USD × the rate in Settings, rounded to the nearest 10 FC, so changing the rate reprices every shop at once. Each invoice keeps its Franc prices and the rate of its sale, so past invoices never change. Payments at the till are in Francs only. Reports convert Francs back to USD with each invoice's own rate.

## Repository

```
app/                  React app (Vite, TypeScript, PWA)
  src/pages/          screens, one file per area
  src/lib/            money, units, validation, Excel, print layouts (+ unit tests)
  src/offline/        till storage, outbox and sync
  e2e/                Playwright end-to-end test
supabase/
  migrations/         schema, access rules (RLS), business functions
  functions/          Edge Functions: setup, admin-users
  tests/              SQL tests for every role and rule (run.sh)
  local/              local Supabase-compatible stack for development and tests
deploy/               Dockerfile, Caddyfile, docker-compose.yml, DEPLOY.md
demo/                 the approved single-file demo
```

## Development

```bash
supabase/local/start.sh            # local database, Auth, REST and functions on http://127.0.0.1:54321 (needs Docker, Deno, psql)
cd app && npm install
cp .env.example .env.local         # URL http://127.0.0.1:54321 and the ANON_KEY printed by start.sh
npm run dev                        # http://localhost:5173
```

Checks: `supabase/tests/run.sh` (database), `npm test` and `npx tsc -b` (app), `npx playwright test` (end to end, against a fresh local stack and `vite preview` on port 4173).
