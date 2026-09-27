# SIM — Smart Invoice Management

A warehouse-to-till retail system for a cosmetics general dealer in Kinshasa, DR Congo.
This repository holds the client demo: a single self-contained HTML file with no build step,
no server and no dependencies beyond a web font.

Open `index.html` in any modern browser, or serve the folder and visit it.

## Demo logins

Password for every account: `Demo@2026`

| Username | Role | Can do |
|---|---|---|
| `admin` | Admin | Everything: cost prices, selling prices, set and piece prices, upkeep, users, settings, reports |
| `operator` | Warehouse Operator | Item names, units and quantities, receive stock, dispatch shop orders. No cost prices, no price changes |
| `admin.gombe` | Shop Admin | Till, invoice discount, edit a confirmed invoice, duplicates, stock orders, reports |
| `till.gombe` | Till Operator | Sell and print at the moment of the sale only |
| `admin.limete`, `till.limete` | Second shop | Same as above for Shop Limete |

## What the demo covers

- **Two shops, one central store.** Shops request stock, the store dispatches it with a delivery note, and the selling price travels with the goods.
- **Prices locked.** Only the Admin sets cost and selling prices. Shops sell exactly what was set.
- **Units at invoicing.** Each item can be sold by piece, dozen, box or carton, with the price for each unit.
- **Mixed sets with a last price.** Assorted sets (brushes, clips, gift hampers) sell whole or one piece at a last price set by the Admin. Pieces are tracked against an open set.
- **Cash only**, with quick note buttons and change calculation.
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
server-side. Company details, RCCM, ID NAT, NIF, VAT rate and the exchange rate are all editable
in Settings.

## Status

Demo v2, updated after the client review: cosmetics catalogue, Admin and Warehouse Operator
roles, units at invoicing, mixed sets with piece prices, cash-only payment, no barcode scanner,
editable invoices, controlled printing and date-range reports.
