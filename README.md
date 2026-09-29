# SIM — Smart Invoice Management

A warehouse-to-till retail system for a cosmetics general dealer in Kinshasa, DR Congo.
This repository holds the client demo: a single self-contained HTML file with no build step,
no server and no dependencies beyond a web font.

Open `index.html` in any modern browser, or serve the folder and visit it.

## Demo logins

Password for every account: `Demo@2026`

| Username | Role | Can do |
|---|---|---|
| `admin` | Admin | Everything: carton cost, pc/dozen/carton prices, set and piece prices, Excel import, deliveries, upkeep, users, settings, reports |
| `operator` | Warehouse Operator | Item names, units and quantities, receive stock, see every shop's stock, send and correct deliveries. No cost prices, no price changes |
| `admin.gombe` | Shop Admin | Till, invoice discount, edit a confirmed invoice, duplicates, deliveries received, reports |
| `till.gombe` | Till Operator | Sell and print at the moment of the sale only |
| `admin.limete`, `till.limete` | Second shop | Same as above for Shop Limete |

## What the demo covers

- **Two shops, one central store.** The store sends stock straight to one or more outlets with a delivery note; shops do not place orders. The store sees every shop's current stock, and a delivery can be corrected later (quantities or outlet) with a reason, the stock is adjusted on both sides and the change is logged.
- **Prices locked.** Only the Admin sets cost and selling prices. Shops sell exactly what was set.
- **Carton pricing.** A new item is entered with the cost of one carton, the pcs in a carton, and a separate selling price per pc, per dozen (optional) and per carton. Stock is counted in pcs and shown as cartons + pcs.
- **Units at invoicing.** The till operator picks pc, dozen or carton and the price set for that unit is used.
- **Bulk import from Excel.** Inventory → Import from Excel creates new items from an .xlsx or .csv file (template download included). Rows are checked before import; existing names or codes are skipped. The reader is built in, so no library or internet is needed.
- **Mixed sets with a last price.** Assorted sets (brushes, clips, gift hampers) sell whole or one piece at a last price set by the Admin. Pieces are tracked against an open set.
- **Cash only, one tap.** "Take cash and print" records the sale for the exact total and prints the customer and shop copies straight away, with no cash window.
- **Selling on order.** Stock can go negative when an item is ordered in for a customer.
- **One print per sale**, customer copy and shop copy together. Duplicates are restricted to the Shop Admin.
- **Editable invoices.** The Shop Admin can correct a confirmed invoice with a reason; stock is adjusted and the change is logged.
- **Invoice discounts**, per invoice only, Shop Admin only, capped at 30%.
- **Sales reports** over any date range, printable or saveable as PDF.
- **Dual currency.** The warehouse side works in USD and Congolese Francs; customer invoices show Francs only.
- **Works offline.** Everything is saved on the device and syncs when the connection returns. Tap the connection pill to simulate losing Wi-Fi.
- **Security.** PBKDF2 password hashing with per-user salts, account lockout after five wrong attempts, 15-minute idle sign-out, role checks on every action, and a full activity log.

## Data and storage

The demo stores its data in `localStorage` on the device that opens it, so each browser has its
own copy. Two tabs of the same browser stay in sync in real time, which is a convenient way to
show the store and the till side by side. Admin → Settings → Reset demo data restores the
original sample data before a presentation.

## Production notes

This is a presentation build. For deployment the queue in `flush()` is the single place where
queued changes would be posted to a server API, and the same role rules would be enforced
server-side. Browsers always show a print dialog; for true one-tap printing at the till, start Chrome with `--kiosk-printing` and set the receipt printer as the default printer. Company details, RCCM, ID NAT, NIF, VAT rate and the exchange rate are all editable
in Settings.

## Currency

All cost and selling prices are stored in USD. The shop price in Francs is USD × the rate in Settings, rounded to the nearest 10 FC, and is worked out live, so changing the rate reprices every shop at once. Each invoice freezes its FC prices and the rate of the moment, so past invoices never change. Customer invoices show Francs only; admin screens show USD and FC. Reports convert FC back to USD with each invoice's own rate.

## Status

Demo v3: carton cost with pc, dozen and carton prices, one-tap cash sale with direct printing, warehouse-pushed and editable deliveries to any outlets, shop stock visible to the store, and Excel bulk import. Opening v3 replaces demo data saved by v2 on the device.

Demo v2 was updated after the first client review: cosmetics catalogue, Admin and Warehouse Operator
roles, units at invoicing, mixed sets with piece prices, cash-only payment, no barcode scanner,
editable invoices, controlled printing and date-range reports.
