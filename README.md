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
| Admin | Everything: categories, carton cost, pc/half dozen/dozen/carton and set/piece prices, Excel import, delete or archive items, stock counts, deliveries, the books (suppliers, bills, payments, vouchers, statements, trial balance, profit and loss, balance sheet), upkeep, users, settings, reports, activity log |
| Warehouse Operator | Item names, units and quantities, receive goods from a chosen supplier, receive returns from the shops, see every shop's stock, send and correct deliveries, stock statements of the store and each shop. No cost prices per item, no price changes |
| Shop Admin | Approves (☑), rejects (❌) or edits the till operators' orders from the review panel, without touching the sale being made. Also sells directly, invoice discount (max 30%), edits a confirmed invoice with a reason, duplicates, receives deliveries, sends returns to the store, price tickets, the shop's cash, sales and stock statements, reports and the day end slip |
| Till Operator | Types the customer name, picks the items and sends the order for approval; prints it once approved (once, duplicates come from the Shop Admin); price tickets. No cash, no invoice list, no reports |

## What it does

- **Carton pricing.** An item is entered with the cost of one carton, the pcs in a carton and a selling price per pc, and optionally per half dozen, per dozen and per carton; the till offers only the units that have a price. Stock is counted in pcs and shown as cartons + pcs. Mixed sets sell whole or one piece at a last price.
- **Categories** are made by the Admin. A seasonal category (school items, festive) has the months it sells; outside them its items go to the end of the lists.
- **Hot items first.** Inventory, shop stock and the till list the best sellers of the last 30 days first (marked Hot).
- **Delete items.** An item can be deleted once no stock is left anywhere; if it was ever received, sent or sold it is archived instead, so its history stays, and it can be restored.
- **Price tickets** for the shelves, on an A4 sheet (24 per page) or a 50 x 30 mm label printer.
- **Bulk import from Excel** (.xlsx or .csv, template included). Rows are checked first; existing names or codes are skipped; one bad row stops the import so nothing half-imports.
- **The store sends stock to the shops**, to one or more outlets at once (same quantities, one delivery note each). The Shop Admin checks what arrived and approves it, lowering a line if goods are short (with a note); only then does the stock leave the store and enter the shop. Goods already sent count as promised, so the same stock can't be sent twice. A delivery can be corrected or cancelled until it is received.
- **Orders approved by the Shop Admin.** The till operator starts each sale with the customer name, picks the items and sends the order. On the Shop Admin's till, 75% of the screen is the sale being made and 25% lists the orders waiting for review, each with the customer, the amount, ☑ approve, ❌ reject (with a reason the till operator sees) and Edit, which opens the order in its own window. The till operator then prints the approved invoice (customer and shop copies, with the customer and who prepared it).
- **Suppliers and goods in.** The Admin keeps each supplier's details, credit days, credit limit, opening balance and the items it supplies. The warehouse chooses the supplier and enters the quantities received (no prices); the Admin enters the supplier's bill later, which falls due after the credit days.
- **Returns to the store.** A shop sends goods back with a reason; they leave the shop at once and the warehouse receives what arrived (short goods are booked as a loss).
- **Book keeping like Tally.** Ledgers in groups (capital, loans, creditors, duties and taxes, fixed and current assets, cash, bank, stock, sales, direct and indirect income and expenses), vouchers (payment, receipt, contra, journal, debit and credit note) where each line is in USD or FC with its rate, and bill-by-bill payments. SIM books the rest on its own: sales (cash, sales, VAT, cost of goods sold), deliveries to the shops at cost, goods in and bills (with the purchase price difference), returns, stock counts, cost changes and expenses. Statements of any ledger with or without the opening balance, day book, trial balance, profit and loss, balance sheet and money owed to suppliers by age. USD is the balancing currency.
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
