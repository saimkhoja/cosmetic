// Printed documents: customer receipt, delivery note, day end slip and sales report.
// Layouts are those approved on the demo. Printing uses the browser; for one-tap printing at
// the till, start Chrome with --kiosk-printing and set the receipt printer as default.
import type { Company, Delivery, Invoice, Product, Shop, Statement } from './types';
import { ctnTxt, unitsOf } from './units';
import { dt, esc, fCDF, fUSD, sum, toCDF, today } from './format';

export function printHTML(html: string) {
  const el = document.getElementById('print-area')!;
  el.innerHTML = html;
  try { window.print(); } catch { /* printing unavailable */ }
}

// receipt amounts as on the shop's paper receipts: 2489 in the lines, 2,489.00 in the totals
const n0 = (n: number) => String(Math.round(Number(n) || 0));
const n2 = (n: number) => (Number(n) || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const rDate = (t: string) => { const d = new Date(t); return `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}/${d.getFullYear()}`; };
const rTime = (t: string) => new Date(t).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }).replace(/\s/g, '');
const NB = 'N.B. Vérifiez vos marchandises avant de sortir du magasin. Les marchandises vendues ne sont ni reprises ni échangées.';

/** Customer invoice in the layout of the shop's paper receipts: company block, boxed invoice number, item lines, boxed total. */
export function receiptHTML(inv: Invoice, c: Company, shop: Shop, opt: { copy?: 'client' | 'shop'; dup?: boolean; cash?: boolean } = {}) {
  const ed = inv.edits && inv.edits.length ? inv.edits[inv.edits.length - 1] : null;
  const tot = (a: string, b: string) => `<tr><td></td><td>${a}</td><td class="r">${b}</td></tr>`;
  const rccm = c.rccm ? (/^rccm/i.test(c.rccm) ? c.rccm : 'RCCM ' + c.rccm) : '';
  return `<div class="receipt inv"><div class="c"><div class="big">${esc((c.name || shop.name).toUpperCase())}</div>${rccm ? `<div>${esc(rccm)}</div>` : ''}${c.idnat ? `<div>ID NAT: ${esc(c.idnat)}</div>` : ''}${c.nif ? `<div>N° IMPOT: ${esc(c.nif)}</div>` : ''}<div>${esc((shop.address || c.address || '').toUpperCase())}</div>${c.phone ? `<div>Tél: ${esc(c.phone)}</div>` : ''}</div>
  <div class="c"><span class="rbox">INVOICE # : ${esc(inv.no)}</span></div>
  <div class="c small">${opt.copy === 'shop' ? 'Copie magasin' : 'Copie client'}${opt.dup ? ' · DUPLICATA' : ''}${ed ? ' · FACTURE MODIFIÉE' : ''}</div>
  ${inv.customer ? `<div class="rl"><b>Customer:</b> ${esc(inv.customer.toUpperCase())}</div>` : ''}
  <div class="rl"><b>Date:</b> ${rDate(inv.t)}&nbsp;&nbsp; <b>Time:</b> ${rTime(inv.t)}</div>
  <table class="ritems"><thead><tr><th>Item</th><th class="r">Qty</th><th class="r">Price</th><th class="r">%</th><th class="r">Total</th></tr></thead>
  <tbody>${inv.items.map((it) => `<tr><td colspan="5">${esc(it.name.toUpperCase())}</td></tr><tr><td>${esc((it.piece ? 'piece' : it.unit).toUpperCase())}</td><td class="r">${it.qty}</td><td class="r">${n0(it.price)}</td><td class="r">${inv.disc_pct}</td><td class="r">${n0(it.line)}</td></tr>`).join('')}</tbody></table>
  <table class="rsum"><tr><td class="small"><b>Total Items</b>&nbsp; ${sum(inv.items, (i) => i.qty)}</td><td>Total H.T</td><td class="r">${n2(inv.ht)}</td></tr>${tot(`TVA${inv.vat_rate ? ' ' + inv.vat_rate + '%' : ''}`, n2(inv.vat))}${tot('Remise', n2(inv.disc))}</table>
  <div class="rttc"><b>Total T.T.C - CDF</b><span class="rbox">${n2(inv.total)}</span></div>
  ${inv.paid_usd ? `<table class="rsum rcash"><tr><td></td><td>Paid USD</td><td class="r">${n2(inv.paid_usd)}</td></tr><tr><td></td><td class="small">= CDF</td><td class="r small">${n2(Math.round(inv.paid_usd * inv.rate))}</td></tr>${inv.paid_cdf ? `<tr><td></td><td>Paid CDF</td><td class="r">${n2(inv.paid_cdf)}</td></tr>` : ''}<tr><td></td><td class="small">Rate</td><td class="r small">1 USD = ${n0(inv.rate)} CDF</td></tr><tr><td></td><td><b>Change</b></td><td class="r"><b>${inv.change_usd ? `$${inv.change_usd} + ${n2(inv.change_cdf ?? 0)} CDF` : n2(inv.change)}</b></td></tr></table>`
    : opt.cash || inv.tendered > inv.total ? `<table class="rsum rcash"><tr><td></td><td>Cash received</td><td class="r">${n2(inv.tendered)}</td></tr><tr><td></td><td><b>Change</b></td><td class="r"><b>${n2(inv.change)}</b></td></tr></table>` : ''}
  <div class="rl">Sales Person&nbsp;&nbsp; ${esc(inv.cashier_name)}</div>${inv.prepared_by_name ? `<div class="rl small">Prepared by&nbsp;&nbsp; ${esc(inv.prepared_by_name)}</div>` : ''}
  ${ed ? `<div class="small">Modifiée le ${dt(ed.at)} par ${esc(ed.by_name)}</div>` : ''}
  <div class="rnb">${c.footer ? `<div class="c">${esc(c.footer)}</div>` : ''}${NB}</div></div>`;
}
export const saleCopies = (inv: Invoice, c: Company, shop: Shop, cash = false) =>
  receiptHTML(inv, c, shop, { copy: 'client', cash }) + '<div class="pagebreak"></div>' + receiptHTML(inv, c, shop, { copy: 'shop', cash });

/** Return note for goods sent back to a supplier: the driver signs it. No prices (the warehouse prints it). */
export function supplierReturnNoteHTML(r: { no: string; kind: string; reason: string; note: string; created_at: string; created_by_name: string; supplier_return_items: { product_id: string; qty: number }[] }, supplier: string, c: Company, products: Map<string, Product>) {
  return `<div class="doc"><div style="display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap"><div><h2>${esc(c.name)}</h2><div>Central store, ${esc(c.address)}</div><div>RCCM ${esc(c.rccm)}, NIF ${esc(c.nif)}</div></div><div style="text-align:right"><h2>${r.kind === 'short' ? 'Claim: billed, not received' : 'Return to supplier'}</h2><div><b>${esc(r.no)}</b></div><div>${dt(r.created_at)}</div></div></div>
  <hr style="border:0;border-top:1px solid #ccc;margin:14px 0"><div><b>Supplier:</b> ${esc(supplier)}</div><div><b>Reason:</b> ${esc(r.reason)}${r.note ? `, ${esc(r.note)}` : ''}</div>
  <div class="tw" style="margin-top:12px"><table class="t"><thead><tr><th>Item</th><th>Code</th><th class="r">Quantity</th></tr></thead><tbody>${r.supplier_return_items.map((i) => { const p = products.get(i.product_id); return `<tr><td>${esc(p?.name)}</td><td>${esc(p?.sku)}</td><td class="r">${i.qty} ${esc(p?.stock_unit)}${p && ctnTxt(p, i.qty) ? `<br><small>${ctnTxt(p, i.qty)}</small>` : ''}</td></tr>`; }).join('')}
  <tr><td colspan="2"><b>Total</b></td><td class="r"><b>${sum(r.supplier_return_items, (i) => i.qty)}</b></td></tr></tbody></table></div>
  <div style="display:flex;justify-content:space-between;margin-top:26px;gap:20px"><div>Sent by: ${esc(r.created_by_name)}<br><br>Signature ____________</div><div>Taken by (supplier):<br><br>Name and signature ____________</div></div></div>`;
}

export function deliveryNoteHTML(d: Delivery, shop: Shop, c: Company, products: Map<string, Product>, showUSD: boolean) {
  const r = d.rate, cdf = (u: number) => Math.round((u * r) / 10) * 10, ed = d.delivery_edits?.length ? [...d.delivery_edits].sort((a, b) => a.at.localeCompare(b.at)).at(-1)! : null;
  const total = sum(d.delivery_items, (i) => i.price_usd * i.qty), totalCDF = sum(d.delivery_items, (i) => cdf(i.price_usd) * i.qty);
  return `<div class="doc"><div style="display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap"><div><h2>${esc(c.name)}</h2><div>Central store, ${esc(c.address)}</div><div>RCCM ${esc(c.rccm)}, NIF ${esc(c.nif)}</div></div><div style="text-align:right"><h2>Delivery note${ed ? ' (REVISED)' : ''}${d.status === 'cancelled' ? ' (CANCELLED)' : ''}</h2><div><b>DN-${esc(d.no.slice(4))}</b></div><div>${dt(d.created_at)}</div></div></div>
  <hr style="border:0;border-top:1px solid #ccc;margin:14px 0"><div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px"><div><b>Deliver to:</b> ${esc(shop.name)}, ${esc(shop.address)}</div><div><b>Rate:</b> 1 USD = ${fCDF(r)}</div></div>
  ${ed ? `<p style="margin:8px 0 0;color:#000">Revised ${dt(ed.at)} by ${esc(ed.by_name)}: ${esc(ed.reason)}</p>` : ''}
  <div class="tw" style="margin-top:12px"><table class="t"><thead><tr><th>Item</th><th>Code</th><th class="r">Qty sent</th>${d.status === 'received' ? '<th class="r">Received</th>' : ''}${showUSD ? '<th class="r">Price USD</th>' : ''}<th class="r">Price CDF</th>${showUSD ? '<th class="r">Total USD</th>' : ''}<th class="r">Total CDF</th></tr></thead><tbody>${d.delivery_items.map((it) => { const p = products.get(it.product_id); return `<tr><td>${esc(p?.name)}</td><td>${esc(p?.sku)}</td><td class="r">${it.qty} ${esc(p?.stock_unit)}${p && ctnTxt(p, it.qty) ? `<br><small>${ctnTxt(p, it.qty)}</small>` : ''}</td>${d.status === 'received' ? `<td class="r">${it.received_qty ?? it.qty}</td>` : ''}${showUSD ? `<td class="r">${fUSD(it.price_usd)}</td>` : ''}<td class="r">${fCDF(cdf(it.price_usd))}</td>${showUSD ? `<td class="r">${fUSD(it.price_usd * it.qty)}</td>` : ''}<td class="r">${fCDF(cdf(it.price_usd) * it.qty)}</td></tr>`; }).join('')}
  <tr><td colspan="${(showUSD ? 5 : 4) + (d.status === 'received' ? 1 : 0)}"><b>Total sent</b></td>${showUSD ? `<td class="r"><b>${fUSD(total)}</b></td>` : ''}<td class="r"><b>${fCDF(totalCDF)}</b></td></tr></tbody></table></div>
  <p style="margin:12px 0 0;color:#000"><b>Selling prices are fixed by the Admin and cannot be changed at the shop.</b></p>
  <div style="display:flex;justify-content:space-between;margin-top:26px;gap:20px"><div>Sent by: ${esc(d.created_by_name)}<br><br>Signature ____________</div><div>Received by (shop):${d.status === 'received' ? ` ${esc(d.received_by_name)}, ${dt(d.received_at!)}${d.received_note ? `<br>Note: ${esc(d.received_note)}` : ''}` : ''}<br><br>Signature ____________</div></div></div>`;
}

export interface Slip { shop_name: string; n: number; value_fc: number; value_usd: number; collected: number; returned: number; collected_usd?: number; collected_cdf?: number }
/** Day end slip in the shop's shift end format. Collected USD is what was paid in dollars (when USD payment is on); returns are in CDF. */
export function shiftSlipHTML(s: Slip, user: string, day: string, rate: number) {
  const d = new Date(), isToday = day === today();
  const ddmm = day.slice(8, 10) + '-' + day.slice(5, 7) + '-' + day.slice(0, 4);
  const when = isToday ? `${ddmm} ${d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: true })}` : ddmm;
  const u3 = (n: number) => (Math.round(n * 1000) / 1000).toFixed(3), fc = (n: number) => String(Math.round(n));
  const row = (a: string, b: string | number) => `<tr><td style="white-space:nowrap">${a}</td><td style="white-space:nowrap">: ${b}</td></tr>`;
  const cu = Number(s.collected_usd ?? 0), cc = Number(s.collected_cdf ?? s.collected);
  const hr = '<tr><td colspan="2"><hr></td></tr>', bold = (a: string, b: string) => row(a, b).replace('<tr>', '<tr style="font-weight:700;font-size:13.5px">');
  return `<div class="receipt slip"><div class="c" style="font-size:19px;font-weight:700;letter-spacing:.04em;margin:4px 0 6px">Shift End Report</div><table>${hr}
  ${row('Date', when)}${row('User', esc(user))}${row('Shop', esc(s.shop_name))}${row('TAUX', fc(rate))}${hr}
  ${row('Total Invoice', s.n)}${row('Invoice Value USD', u3(s.value_usd))}${row('Invoice Value CDF', fc(s.value_fc))}${hr}
  ${row('Collected USD', u3(cu))}${row('Collected CDF', fc(cc))}${row('Return USD', u3(0))}${row('Return CDF', fc(s.returned))}${hr}
  ${bold('Balance USD', u3(cu))}${bold('Balance CDF', fc(cc - s.returned))}</table></div>`;
}

export interface Report {
  from: string; to: string; n: number; total: number; total_usd: number; disc: number; vat: number; items: number; edited: number; profit_usd: number | null;
  by_day: { day: string; n: number; q: number; d: number; v: number }[]; top: { name: string; qty: number; val: number }[];
  by_cashier: { name: string; v: number }[]; slips: (Slip & { shop_id: string; code: string })[];
  invoices: { id: string; no: string; t: string; shop_id: string; cashier_name: string; customer?: string; items: number; disc: number; total: number; edited: boolean }[];
}
export function reportHTML(r: Report, c: Company, where: string, by: string, shopName: (id: string) => string, allShops: boolean, vat: number) {
  return `<div class="doc"><div style="display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap"><div><h2>${esc(c.name)}</h2><div>${esc(c.address)}</div><div>RCCM ${esc(c.rccm)}, ID NAT ${esc(c.idnat)}, NIF ${esc(c.nif)}</div></div>
  <div style="text-align:right"><h2>Sales report</h2><div>${r.from} to ${r.to}</div><div>${esc(where)}</div><div>Printed ${dt(Date.now())} by ${esc(by)}</div></div></div>
  <hr style="border:0;border-top:1px solid #ccc;margin:14px 0">
  <table class="t"><tbody><tr><td><b>Invoices</b></td><td>${r.n}</td><td><b>Items sold</b></td><td>${r.items}</td><td><b>Discounts</b></td><td>${fCDF(r.disc)}</td></tr>
  <tr><td><b>VAT included</b></td><td>${fCDF(r.vat)}</td><td><b>Sales excl. VAT</b></td><td>${fCDF(r.total - r.vat)}</td><td><b>Total sales</b></td><td><b>${fCDF(r.total)}</b></td></tr></tbody></table>
  <h3 style="margin:16px 0 6px">Day by day</h3>
  <table class="t"><thead><tr><th>Date</th><th class="r">Invoices</th><th class="r">Items</th><th class="r">Discounts</th><th class="r">Total CDF</th></tr></thead><tbody>${r.by_day.map((d) => `<tr><td>${d.day}</td><td class="r">${d.n}</td><td class="r">${d.q}</td><td class="r">${fCDF(d.d)}</td><td class="r"><b>${fCDF(d.v)}</b></td></tr>`).join('') || '<tr><td colspan="5">No sales in this period</td></tr>'}</tbody></table>
  <h3 style="margin:16px 0 6px">Items sold</h3>
  <table class="t"><thead><tr><th>Item</th><th class="r">Quantity</th><th class="r">Value CDF</th></tr></thead><tbody>${r.top.map((x) => `<tr><td>${esc(x.name)}</td><td class="r">${x.qty}</td><td class="r">${fCDF(x.val)}</td></tr>`).join('') || '<tr><td colspan="3">No items</td></tr>'}</tbody></table>
  <h3 style="margin:16px 0 6px">Invoices</h3>
  <table class="t"><thead><tr><th>Invoice</th><th>Date and time</th>${allShops ? '<th>Shop</th>' : ''}<th>Customer</th><th>Cashier</th><th class="r">Items</th><th class="r">Total CDF</th></tr></thead><tbody>${r.invoices.map((i) => `<tr><td>${esc(i.no)}${i.edited ? ' (edited)' : ''}</td><td>${dt(i.t)}</td>${allShops ? `<td>${esc(shopName(i.shop_id))}</td>` : ''}<td>${esc(i.customer || '-')}</td><td>${esc(i.cashier_name)}</td><td class="r">${i.items}</td><td class="r">${fCDF(i.total)}</td></tr>`).join('') || '<tr><td colspan="6">No invoices</td></tr>'}</tbody></table>
  <p style="margin-top:14px">All amounts in Congolese Francs, VAT ${vat}% included. Payments are in cash.</p>
  <div style="margin-top:26px">Signature ____________________</div></div>`;
}

export type TicketUnit = 'pcs' | 'half dzn' | 'dzn' | 'carton';
/** Price tickets: an A4 sheet (3 x 8 tickets of 70 x 37 mm) or one 50 x 30 mm label per ticket for a label printer.
 *  Only the chosen units are printed (pcs also covers a set and its piece). Items with none of them are left out. */
export function ticketsHTML(items: { p: Product; copies: number }[], rate: number, layout: 'a4' | 'label', shopName = '', units: TicketUnit[] = ['pcs', 'half dzn', 'dzn', 'carton']) {
  const want = (u: { u: string; piece?: boolean }) => units.includes((u.u === 'set' || u.piece ? 'pcs' : u.u) as TicketUnit);
  const label = (u: { u: string; mult: number; piece?: boolean }) => (u.piece ? '1 piece' : u.u === 'pcs' ? 'pc' : u.u === 'half dzn' ? 'half dozen (6)' : u.u === 'dzn' ? 'dozen (12)' : u.u === 'carton' ? `carton (${u.mult})` : u.u);
  const one = (p: Product) => {
    const us = unitsOf(p).filter(want);
    if (!us.length) return '';
    const up = (t: string) => esc(t.toLocaleUpperCase('fr'));   // tickets are printed in capitals
    return `<div class="ticket ${layout}"><div class="tn">${up(p.name)}</div><div class="tl">${us.map((u) => `<div class="tu"><span>${up(label(u))}</span><b>${fCDF(toCDF(u.usd, rate))}</b></div>`).join('')}</div><div class="tf"><span>${up(p.sku)}</span><span>${up(shopName)}</span></div></div>`;
  };
  const all = items.flatMap((x) => { const t = one(x.p); return t ? Array.from({ length: Math.max(0, Math.min(200, x.copies)) }, () => t) : []; });
  if (layout === 'label') return all.join('<div class="pagebreak"></div>');
  const pages: string[] = [];
  for (let i = 0; i < all.length; i += 24) pages.push(`<div class="tsheet">${all.slice(i, i + 24).join('')}</div>`);
  return pages.join('<div class="pagebreak"></div>');
}

/** Order slip printed at the till when the order is sent: the customer takes it to the shop admin, who prints the invoice. */
export function orderSlipHTML(o: { ref: string; customer: string; t: string; by: string; lines: { name: string; unit: string; qty: number; price: number }[]; total: number }, c: Company, shop: Shop) {
  return `<div class="receipt"><div class="c"><div class="big">${esc(c.name)}</div><div>${esc(shop.name)}</div></div><hr>
  <div class="c big">BON DE COMMANDE</div><div class="c small">Ce bon n'est pas une facture. Payez à la caisse.</div><hr>
  <table><tr><td>Réf.</td><td class="r"><b>${esc(o.ref)}</b></td></tr><tr><td>Date</td><td class="r">${dt(o.t)}</td></tr>${o.customer ? `<tr><td>Client</td><td class="r">${esc(o.customer)}</td></tr>` : ''}<tr><td>Préparé par</td><td class="r">${esc(o.by)}</td></tr></table><hr>
  <table>${o.lines.map((l) => `<tr><td colspan="2">${esc(l.name)}</td></tr><tr><td>&nbsp;${l.qty} x ${esc(l.unit)} @ ${fCDF(l.price)}</td><td class="r">${fCDF(l.price * l.qty)}</td></tr>`).join('')}</table><hr>
  <div class="rtotal"><span>TOTAL À PAYER</span><span>${fCDF(o.total)}</span></div>
  <div class="c small">Articles : ${sum(o.lines, (l) => l.qty)}. TVA incluse. Montant indicatif ; la facture de la caisse fait foi.</div></div>`;
}
/** Short reference of an order, the same on the till's slip and in the shop admin's review list. */
export const orderRef = (id: string) => '#' + id.replace(/-/g, '').slice(0, 6).toUpperCase();

/** Stock count sheet: what the system shows, with empty columns to write the physical count. */
export function stockCountHTML(c: Company, where: string, by: string, rows: { p: Product; qty: number }[]) {
  const body = `<table class="t count"><thead><tr><th>#</th><th>Item</th><th>Code</th><th>Category</th><th class="r">System stock</th><th style="width:22%">Counted</th><th style="width:14%">Difference</th></tr></thead><tbody>
  ${rows.map((r, i) => `<tr><td>${i + 1}</td><td><b>${esc(r.p.name)}</b></td><td>${esc(r.p.sku)}</td><td>${esc(r.p.category)}</td><td class="r"><b>${r.qty} ${esc(r.p.stock_unit)}</b>${ctnTxt(r.p, r.qty) ? `<br><small>${ctnTxt(r.p, r.qty)}</small>` : ''}</td><td></td><td></td></tr>`).join('') || '<tr><td colspan="7">No items</td></tr>'}</tbody></table>
  <p style="color:#000;margin-top:14px">${rows.length} items, ${sum(rows, (r) => r.qty)} units in the system. Write what you count; the difference is Counted minus System stock.</p>
  <div style="display:flex;justify-content:space-between;margin-top:28px;gap:20px"><div>Counted by: ____________________<br><br>Signature ____________</div><div>Checked by: ____________________<br><br>Signature ____________</div></div>`;
  return bookHTML(c, 'Stock count sheet', where + ', ' + today(), body, by);
}

/** A plain A4 document with the company heading, used by the book keeping reports. */
export function bookHTML(c: Company, title: string, sub: string, body: string, by: string) {
  return `<div class="doc"><div style="display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap"><div><h2>${esc(c.name)}</h2><div>${esc(c.address)}</div><div>RCCM ${esc(c.rccm)}, NIF ${esc(c.nif)}</div></div>
  <div style="text-align:right"><h2>${esc(title)}</h2><div>${esc(sub)}</div><div>Printed ${dt(Date.now())} by ${esc(by)}</div></div></div><hr style="border:0;border-top:1px solid #ccc;margin:14px 0">${body}</div>`;
}
const drcr = (n: number) => (Math.abs(n) < 0.005 ? '0.00' : `${fUSD(Math.abs(n))} ${n > 0 ? 'Dr' : 'Cr'}`);
export const balTxt = drcr;
export function statementHTML(st: Statement, c: Company, by: string) {
  let run = st.brought_forward;
  const rows = st.lines.map((l) => { run += l.side === 'Dr' ? l.base : -l.base; return `<tr><td>${l.date}</td><td>${esc(l.no)}</td><td>${esc(l.narration)}${l.memo ? `<br><small>${esc(l.memo)}</small>` : ''}${l.bill_ref ? `<br><small>Bill ${esc(l.bill_ref)}${l.due_date ? ', due ' + l.due_date : ''}</small>` : ''}</td><td class="r">${l.currency === 'FC' ? fCDF(l.amount) + `<br><small>@ ${l.rate}</small>` : ''}</td><td class="r">${l.side === 'Dr' ? fUSD(l.base) : ''}</td><td class="r">${l.side === 'Cr' ? fUSD(l.base) : ''}</td><td class="r">${drcr(run)}</td></tr>`; }).join('');
  const body = `<p style="color:#000;margin:0 0 8px"><b>${esc(st.account.name)}</b>, ${esc(st.account.group)}</p>
  <table class="t"><thead><tr><th>Date</th><th>Voucher</th><th>Particulars</th><th class="r">CDF</th><th class="r">Debit USD</th><th class="r">Credit USD</th><th class="r">Balance</th></tr></thead><tbody>
  ${st.with_opening ? `<tr><td>${st.from}</td><td></td><td><b>Opening balance</b></td><td></td><td class="r">${st.brought_forward > 0 ? fUSD(st.brought_forward) : ''}</td><td class="r">${st.brought_forward < 0 ? fUSD(-st.brought_forward) : ''}</td><td class="r">${drcr(st.brought_forward)}</td></tr>` : ''}
  ${rows || '<tr><td colspan="7">No entries in this period</td></tr>'}
  <tr><td colspan="4"><b>Totals for the period</b></td><td class="r"><b>${fUSD(st.total_dr)}</b></td><td class="r"><b>${fUSD(st.total_cr)}</b></td><td class="r"><b>${drcr(st.closing)}</b></td></tr></tbody></table>
  <p style="margin-top:12px">Amounts in USD; lines entered in Francs show the CDF amount and its rate.${st.with_opening ? '' : ' Opening balance not included.'}</p>`;
  return bookHTML(c, 'Statement of account', `${st.from} to ${st.to}`, body, by);
}
