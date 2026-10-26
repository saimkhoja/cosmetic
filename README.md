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
| Warehouse Operator | Item names, units and quantities, receive goods from a chosen supplier, review the shops' stock requests (approve, edit or reject), receive returns from the shops, see every shop's stock, send and correct deliveries, stock statements of the store and each shop. No cost prices per item, no price changes |
| Shop Admin | Approves (☑), rejects (❌) or edits the till operators' orders from the review panel, without touching the sale being made; approving prints the invoice and takes the stock. Also sells directly, invoice discount (max 30%), edits a confirmed invoice (quantities, units, discount) with a reason, deletes an invoice with a reason, duplicates, stock count sheet, orders stock from the central store, receives deliveries, sends returns to the store, price tickets, the shop's cash, sales and stock statements, reports and the day end slip |
| Till Operator | Types the customer name, picks the items and sends the order for approval, which prints an order slip for the customer to take to the Shop Admin; price tickets. No cash, no invoice list, no reports |

## What it does

- **Carton pricing.** An item is entered with the cost of one carton, the pcs in a carton and a selling price per pc, per half dozen, per dozen and per carton, each optional (at least one); the till offers only the units that have a price. Stock is counted in pcs and shown as cartons + pcs. Mixed sets sell whole or one piece at a last price.
- **Categories** are made by the Admin. A seasonal category (school items, festive) has the months it sells; outside them its items go to the end of the lists.
- **Goods in, deliveries and returns to suppliers.** A scan box finds the item by any barcode or its code and puts the cursor in its quantity box with 1 filled in: type the count, press Enter and scan the next (a barcode scanned into a quantity box by mistake is caught). Rows stay where they are while quantities are typed; a search brings its matches to the top. Beside the list, *To receive* / *To send* / *To send back* lists only the lines entered, in order, in cartons and pcs, with warnings (more than the store has) and totals, to check before confirming.
- **Stock value at selling price.** On *Shop stock* the Admin sees each outlet's stock (central store and every shop) at selling price in CDF and USD, and at cost; choosing one shop adds the value of each item, and the stock count sheet window can print a stock valuation instead. The Shop Admin sees the shop's own total and the value of each item. Each pc is valued at its shop price as at the till (sets at the set price); stock sold on order counts as none. The warehouse sees quantities only.
- **Hot items first.** Inventory, shop stock and the till list the best sellers of the last 30 days first (marked Hot).
- **Delete items.** An item can be deleted once no stock is left anywhere; if it was ever received, sent or sold it is archived instead, so its history stays, and it can be restored.
- **Price tickets** for the shelves, in uniform bold capitals, on an A4 sheet (24 per page) or a 50 x 30 mm label printer, with the prices you tick: pcs, half dozen, dozen, carton or any mix.
- **Stock count sheet** for any shop or the central store: every item with the stock SIM shows and empty columns for the physical count.
- **Bulk import from Excel** (.xlsx or .csv, template included). Rows are checked first; existing names or codes are skipped; one bad row stops the import so nothing half-imports.
- **The store sends stock to the shops**, to one or more outlets at once (same quantities, one delivery note each). The Shop Admin checks what arrived and approves it, lowering a line if goods are short (with a note); only then does the stock leave the store and enter the shop. Goods already sent count as promised, so the same stock can't be sent twice. A delivery can be corrected or cancelled until it is received.
- **Orders approved by the Shop Admin.** The till operator starts each sale with the customer name, picks the items and sends the order. On the Shop Admin's till, 75% of the screen is the sale being made and 25% lists the orders waiting for review (hidden when till operators sell directly and nothing waits), each with its reference, the customer, the amount, ☑ approve, ❌ reject (with a reason the till operator sees) and Edit, which opens the order in its own window. Sending an order prints an order slip at the till (not an invoice) for the customer to take to the Shop Admin; approving prints the invoice (customer and shop copies, with the customer and who prepared it) and only then does the stock go down.
- **The till screen.** The search box (and barcode scanner), Price check and Tickets sit in the top bar; the customer name above the items. The current sale lists each line in scan order with #, item, qty (− +), unit price, amount and ✕; the line just scanned or changed is highlighted and scrolled into view (↑ ↓ in the search box walk through the sale). **Park sale** puts a sale aside on the till (it survives a restart) so the next customer can be served; *Parked* brings it back. With *Enter the cash received* or *Accept payment in USD* on, **Take payment** opens the payment window (CDF and USD received, quick notes, change to give); otherwise *Take cash and print* sells at once.
- **Suppliers and goods in.** The Admin keeps each supplier's details, credit days, credit limit, opening balance and the items it supplies. A supplier can be deleted once nothing is owed either way; one with goods received, bills or payments is made inactive instead, keeping its history. The warehouse chooses the supplier and enters the quantities received (no prices); the Admin enters the supplier's bill later, which falls due after the credit days.
- **Stock requests from the shops.** The Shop Admin asks the central store for stock (Order stock). The warehouse sees each list next to what the store can send and the shop already has, then approves it as asked, edits the quantities (with a reason the shop sees) or rejects it. An approved request becomes a delivery that the Shop Admin receives as usual, so stock only moves when it arrives.
- **Returns to suppliers.** The warehouse sends goods back (damaged, expired, wrong item, not ordered) from Goods in: they leave the central store at once, a return note prints for the supplier's driver, and what is owed to the supplier drops at item cost. The Admin settles each return at the amount the supplier credits and sets it against a bill.
- **Goods billed but not received.** When the Admin enters the bill for a goods receipt, a Billed column per item records what the bill charges for; anything billed but not received becomes a claim against the supplier, set against that bill, so only what arrived is owed.
- **Returns to the store.** A shop sends goods back with a reason; they leave the shop at once and the warehouse receives what arrived (short goods are booked as a loss).
- **Book keeping like Tally.** Ledgers in groups (capital, loans, creditors, duties and taxes, fixed and current assets, cash, bank, stock, sales, direct and indirect income and expenses), vouchers (payment, receipt, contra, journal, debit and credit note) where each line is in USD or CDF with its rate, and bill-by-bill payments. SIM books the rest on its own: sales (cash, sales, VAT, cost of goods sold), deliveries to the shops at cost, goods in and bills (with the purchase price difference), returns, stock counts, cost changes and expenses. Statements of any ledger with or without the opening balance, day book, trial balance, profit and loss, balance sheet and money owed to suppliers by age. USD is the balancing currency.
- **Offline till.** Items, prices and shop stock are kept on the till. Without internet the Shop Admin keeps selling and printing and the till operator keeps preparing orders (they reach the Shop Admin when the connection returns); each till numbers its own invoices (`GOM-T1-000123`) so tills never clash, and sales are sent automatically when the connection returns. A sale sent twice is saved once.
- **Prices locked.** Only the Admin sets prices; shops sell exactly what was set. Invoices keep the prices and rate of the moment of sale.
- **Editable invoices** by the Shop Admin, with a reason: quantities, the unit of a line (for example pcs to dozen, charged at that unit's price) and the discount; stock is adjusted and the change is logged. An invoice can also be deleted with a reason: its stock goes back to the shop and it leaves sales, reports and the books, and the activity log keeps what it was.
- **Reports** over any dates, printable or as PDF. A single day prints the **day end report** per shop in the shift end slip format: total invoices, invoice value in USD and CDF, collected, returned and balance.
- **Supermarket switches** (Settings → Till options, both off by default). **Customer name optional**: walk-in sales and orders without a name. **Barcode scanning**: items carry one or more barcodes ("+ Add another barcode" in the item form, or several in one Excel cell separated with ;); scanning any of them at the till adds 1 pc to the sale, and price check finds them too. **Till operators sell directly**: no shop admin approval; the till operator takes the cash and prints the invoice (no discounts). **Enter the cash received**: the cashier types the amount given; the till shows the change and the receipt prints the cash received and the change. **Accept payment in USD**: customers pay in dollars, Francs or both at the sales rate; change in CDF or whole dollars plus CDF; dollars are kept in each shop's Cash USD ledger and shown on the day end slip.
- **Light or dark screens.** The button next to Sign out switches between Auto (follows the device), Light and Dark; each computer or phone remembers its choice.
- **Security.** Real passwords (hashed by Supabase Auth; 10+ characters with letters and numbers), each person chooses their own at first sign-in, disabled accounts are shut out at once, the screen locks after 15 minutes, access rules on every table, every change goes through checked database functions, and a full activity log.

## Currency

All cost and selling prices are stored in USD. Francs are shown as CDF everywhere. There are two rates, each editable at any time:

- **Sales rate (taux de vente)**, in Settings or with the *Sales rate* button on the Items page: the shop price in Francs is USD × this rate, rounded to the nearest 10 CDF, so changing it reprices every shop, ticket and till at once. Each invoice keeps its Franc prices and the rate of its sale, so past invoices never change, and the sales it collects are booked at that rate.
- **Internal rate (taux interne)**, in Settings: the default for supplier bills and payments, expenses (upkeep), vouchers such as cash taken from the shops, and opening balances in Francs. Any entry can still be given its own rate.

Payments at the till are in Francs only. Reports convert Francs back to USD with each invoice's own rate.

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
