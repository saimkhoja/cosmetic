// Printed documents: customer receipt, delivery note, day end slip and sales report.
// Layouts are those approved on the demo. Printing uses the browser; for one-tap printing at
// the till, start Chrome with --kiosk-printing and set the receipt printer as default.
import type { Company, Delivery, Invoice, Product, PromoData, Shop, Statement, VendeurStatement } from './types';
import { mergeCurrencies } from './vouchers';
import { ctnTxt, pcValue, stockValue, unitsOf } from './units';
import { dt, esc, fCDF, fNum, fUSD, sum, toCDF, today } from './format';

export function printHTML(html: string) {
  const el = document.getElementById('print-area')!;
  el.innerHTML = html;
  pageStyle().textContent = /class="(receipt|ticket roll)/.test(html) ? rollPages(el, html) : '';
  try { window.print(); } catch { /* printing unavailable */ }
}

// Receipts, slips and roll tickets go on the 80 mm roll: no margins, and each one (a copy, a ticket) on a
// page of its own length, so a driver set to cut each page cuts just under its last line.
function pageStyle() {
  let st = document.getElementById('print-page') as HTMLStyleElement | null;
  if (!st) { st = document.createElement('style'); st.id = 'print-page'; document.head.appendChild(st); }
  return st;
}
const ROLL = '.receipt, .ticket.roll';
/** Fits each roll ticket: first its prices, all at one size, shrunk until every price row fits the width; then its
 *  name, shrunk until it fits the room left above the prices; a name that still does not fit takes room from the
 *  prices. The smallest sizes come from --tps-min and --tn-min (20 and 22 px unless the layout sets them). Offset
 *  sizes are used as they ignore the big ticket's quarter turn. Returns the [prices, name] sizes of each ticket. */
export function fitTickets(root: ParentNode) {
  const px = (e: HTMLElement) => parseFloat(getComputedStyle(e).fontSize);
  const min = (e: HTMLElement, v: string, d: number) => parseFloat(getComputedStyle(e).getPropertyValue(v)) || d;
  const shrink = (e: HTMLElement, over: () => boolean, least: number) => { for (let s = px(e); over() && s - 2 >= least; s -= 2) e.style.fontSize = s - 2 + 'px'; };
  return Array.from(root.querySelectorAll<HTMLElement>('.ticket.roll .tk'), (k) => {
    const ps = k.querySelector<HTMLElement>('.tps')!, t = k.querySelector<HTMLElement>('.tn')!, txt = t.firstElementChild as HTMLElement;
    const rows = Array.from(ps.querySelectorAll<HTMLElement>('.tp'));
    const psMin = min(k, '--tps-min', 20), tnMin = min(k, '--tn-min', 22);
    const tall = () => txt.offsetHeight > t.clientHeight || txt.scrollWidth > t.clientWidth;
    const name = () => { t.style.fontSize = ''; shrink(t, tall, tnMin); };
    ps.style.fontSize = ''; shrink(ps, () => rows.some((r) => r.scrollWidth > r.clientWidth), psMin);
    name();
    for (let s = px(ps); tall() && s - 2 >= psMin; s -= 2) { ps.style.fontSize = s - 2 + 'px'; name(); }
    return [ps.style.fontSize, t.style.fontSize];
  });
}
function rollPages(el: HTMLElement, html: string) {
  const box = document.createElement('div');
  box.style.cssText = 'position:fixed;left:-10000px;top:0;width:302px;visibility:hidden';
  box.innerHTML = html;
  document.body.appendChild(box);
  // roll tickets are fitted in the measuring box, then the sizes are copied to what prints
  const fit = fitTickets(box);
  el.querySelectorAll<HTMLElement>('.ticket.roll .tk').forEach((k, i) => {
    const [ps, tn] = fit[i] ?? [];
    if (ps) k.querySelector<HTMLElement>('.tps')!.style.fontSize = ps;
    if (tn) k.querySelector<HTMLElement>('.tn')!.style.fontSize = tn;
  });
  const mm = Array.from(box.querySelectorAll<HTMLElement>(ROLL), (r) => Math.ceil((r.getBoundingClientRect().height * 25.4) / 96) + 3);
  box.remove();
  if (!mm.length || !mm[0]) return '@page{size:80mm 297mm;margin:0}';
  el.querySelectorAll<HTMLElement>(ROLL).forEach((r, i) => { r.style.setProperty('page', 'roll' + i); });
  // a page break belongs to the page before it, or it would get a blank page of its own
  el.querySelectorAll<HTMLElement>('.pagebreak').forEach((b) => { const prev = b.previousElementSibling as HTMLElement | null; if (prev?.style.getPropertyValue('page')) b.style.setProperty('page', prev.style.getPropertyValue('page')); });
  return `@page{size:80mm ${Math.max(...mm)}mm;margin:0}` + mm.map((h, i) => `@page roll${i}{size:80mm ${h}mm;margin:0}`).join('');
}

// receipt amounts as on the shop's paper receipts: 2489 in the lines, 2,489.00 in the totals
const n0 = (n: number) => String(Math.round(Number(n) || 0));
const n2 = (n: number) => (Number(n) || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const rDate = (t: string) => { const d = new Date(t); return `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}/${d.getFullYear()}`; };
const rTime = (t: string) => new Date(t).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }).replace(/\s/g, '');
/** 2026-11-29 as 29/11/2026 */
const ymdFr = (d: string) => `${d.slice(8, 10)}/${d.slice(5, 7)}/${d.slice(0, 4)}`;
const NB = 'N.B. Vérifiez vos marchandises avant de sortir du magasin. Les marchandises vendues ne sont ni reprises ni échangées.';

/** Customer invoice in the layout of the shop's paper receipts: company block, boxed invoice number, item lines, boxed total. */
export function receiptHTML(inv: Invoice, c: Company, shop: Shop, opt: { copy?: 'client' | 'shop'; dup?: boolean; cash?: boolean } = {}) {
  const ed = inv.edits && inv.edits.length ? inv.edits[inv.edits.length - 1] : null;
  const tot = (a: string, b: string) => `<tr><td></td><td>${a}</td><td class="r">${b}</td></tr>`;
  const rccm = c.rccm ? (/^rccm/i.test(c.rccm) ? c.rccm : 'RCCM ' + c.rccm) : '';
  // goods on credit are owed in USD: every amount in dollars, at the internal rate of the sale
  const cr = inv.vendeur_id ? Number(inv.usd_rate || inv.rate) || 1 : 0;
  const m0 = (n: number) => (cr ? '$' + n2(Math.round((n / cr) * 100) / 100) : n0(n)), m2 = (n: number) => (cr ? '$' + n2(Math.round((n / cr) * 100) / 100) : n2(n));
  return `<div class="receipt inv"><div class="c"><div class="big">${esc((c.name || shop.name).toUpperCase())}</div>${rccm ? `<div>${esc(rccm)}</div>` : ''}${c.idnat ? `<div>ID NAT: ${esc(c.idnat)}</div>` : ''}${c.nif ? `<div>N° IMPOT: ${esc(c.nif)}</div>` : ''}<div>${esc((shop.address || c.address || '').toUpperCase())}</div>${c.phone ? `<div>Tél: ${esc(c.phone)}</div>` : ''}</div>
  <div class="c"><span class="rbox">INVOICE # : ${esc(inv.no)}</span></div>
  <div class="c small">${opt.copy === 'shop' ? 'Copie magasin' : 'Copie client'}${opt.dup ? ' · DUPLICATA' : ''}${ed || inv.revised_from != null ? ' · FACTURE MODIFIÉE' : ''}</div>
  ${inv.revised_from != null && !ed ? '<div class="c small">Remplace la facture imprimée à la caisse</div>' : ''}
  ${inv.customer ? `<div class="rl"><b>Customer:</b> ${esc(inv.customer.toUpperCase())}</div>` : ''}
  <div class="rl"><b>Date:</b> ${rDate(inv.t)}&nbsp;&nbsp; <b>Time:</b> ${rTime(inv.t)}</div>
  <table class="ritems"><thead><tr><th>Item</th><th class="r">Qty</th><th class="r">Price</th><th class="r">%</th><th class="r">Total</th></tr></thead>
  <tbody>${inv.items.map((it) => `<tr><td colspan="5">${esc(it.name.toUpperCase())}</td></tr><tr><td>${esc((it.piece ? 'piece' : it.unit).toUpperCase())}</td><td class="r">${it.qty}</td><td class="r">${m0(it.price)}</td><td class="r">${Number(inv.disc_pct) || 0}</td><td class="r">${m0(it.line)}</td></tr>`).join('')}</tbody></table>
  <table class="rsum"><tr><td class="small"><b>Total Items</b>&nbsp; ${sum(inv.items, (i) => i.qty)}</td><td>Total H.T</td><td class="r">${m2(inv.ht)}</td></tr>${tot(`TVA${inv.vat_rate ? ' ' + inv.vat_rate + '%' : ''}`, m2(inv.vat))}${tot('Remise', m2(inv.disc))}</table>
  <div class="rttc"><b>Total T.T.C - ${cr ? 'USD' : 'CDF'}</b><span class="rbox">${m2(inv.total)}</span></div>
  ${inv.vendeur_id ? `<div class="c" style="margin:6px 0;font-weight:700">VENTE À CRÉDIT${inv.due_date ? ` · ÉCHÉANCE ${ymdFr(inv.due_date)}` : ''}</div><div class="c small">Montant dû par le vendeur en USD, non payé à la caisse</div><div class="c small">Taux interne: 1 USD = ${n0(cr)} CDF</div>` : ''}
  ${inv.paid_usd ? `<table class="rsum rcash"><tr><td></td><td>Paid USD</td><td class="r">${n2(inv.paid_usd)}</td></tr><tr><td></td><td class="small">= CDF</td><td class="r small">${n2(Math.round(inv.paid_usd * (inv.usd_rate || inv.rate)))}</td></tr>${inv.paid_cdf ? `<tr><td></td><td>Paid CDF</td><td class="r">${n2(inv.paid_cdf)}</td></tr>` : ''}<tr><td></td><td class="small">Rate</td><td class="r small">1 USD = ${n0(inv.usd_rate || inv.rate)} CDF</td></tr><tr><td></td><td><b>Change</b></td><td class="r"><b>${inv.change_usd ? `$${inv.change_usd} + ${n2(inv.change_cdf ?? 0)} CDF` : n2(inv.change)}</b></td></tr></table>`
    : opt.cash || inv.tendered > inv.total ? `<table class="rsum rcash"><tr><td></td><td>Cash received</td><td class="r">${n2(inv.tendered)}</td></tr><tr><td></td><td><b>Change</b></td><td class="r"><b>${n2(inv.change)}</b></td></tr></table>` : ''}
  <div class="rl">Sales Person&nbsp;&nbsp; ${esc(inv.cashier_name)}</div>${inv.prepared_by_name ? `<div class="rl small">Prepared by&nbsp;&nbsp; ${esc(inv.prepared_by_name)}</div>` : ''}
  ${ed ? `<div class="small">Modifiée le ${dt(ed.at)} par ${esc(ed.by_name)}</div>` : ''}
  <div class="rnb">${c.footer ? `<div class="c">${esc(c.footer)}</div>` : ''}${NB}</div></div>`;
}
/** The copies of a new invoice: customer and shop, or only the customer's when the Admin chose one copy in Settings. */
export const saleCopies = (inv: Invoice, c: Company, shop: Shop, cash = false, one = false) =>
  receiptHTML(inv, c, shop, { copy: 'client', cash }) + (one ? '' : '<div class="pagebreak"></div>' + receiptHTML(inv, c, shop, { copy: 'shop', cash }));

/** Return note for goods sent back to a supplier: the driver signs it. No prices (the warehouse prints it). */
export function supplierReturnNoteHTML(r: { no: string; kind: string; reason: string; note: string; created_at: string; created_by_name: string; supplier_return_items: { product_id: string; qty: number }[] }, supplier: string, c: Company, products: Map<string, Product>) {
  return `<div class="doc"><div style="display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap"><div><h2>${esc(c.name)}</h2><div>Central store, ${esc(c.address)}</div><div>RCCM ${esc(c.rccm)}, NIF ${esc(c.nif)}</div></div><div style="text-align:right"><h2>${r.kind === 'short' ? 'Claim: billed, not received' : 'Return to supplier'}</h2><div><b>${esc(r.no)}</b></div><div>${dt(r.created_at)}</div></div></div>
  <hr style="border:0;border-top:1px solid #ccc;margin:14px 0"><div><b>Supplier:</b> ${esc(supplier)}</div><div><b>Reason:</b> ${esc(r.reason)}${r.note ? `, ${esc(r.note)}` : ''}</div>
  <div class="tw" style="margin-top:12px"><table class="t"><thead><tr><th>Item</th><th>Code</th><th class="r">Quantity</th></tr></thead><tbody>${r.supplier_return_items.map((i) => { const p = products.get(i.product_id); return `<tr><td>${esc(p?.name)}</td><td>${esc(p?.sku)}</td><td class="r">${i.qty} ${esc(p?.stock_unit)}${p && ctnTxt(p, i.qty) ? `<br><small>${ctnTxt(p, i.qty)}</small>` : ''}</td></tr>`; }).join('')}
  <tr><td colspan="2"><b>Total</b></td><td class="r"><b>${sum(r.supplier_return_items, (i) => i.qty)}</b></td></tr></tbody></table></div>
  <div style="display:flex;justify-content:space-between;margin-top:26px;gap:20px"><div>Sent by: ${esc(r.created_by_name)}<br><br>Signature ____________</div><div>Taken by (supplier):<br><br>Name and signature ____________</div></div></div>`;
}

export function deliveryNoteHTML(d: Delivery, shop: Shop, c: Company, products: Map<string, Product>, showUSD: boolean) {
  const r = d.rate, cdf = (u: number) => toCDF(u, r), ed = d.delivery_edits?.length ? [...d.delivery_edits].sort((a, b) => a.at.localeCompare(b.at)).at(-1)! : null;
  const total = sum(d.delivery_items, (i) => i.price_usd * i.qty), totalCDF = sum(d.delivery_items, (i) => cdf(i.price_usd) * i.qty);
  return `<div class="doc"><div style="display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap"><div><h2>${esc(c.name)}</h2><div>Central store, ${esc(c.address)}</div><div>RCCM ${esc(c.rccm)}, NIF ${esc(c.nif)}</div></div><div style="text-align:right"><h2>Delivery note${ed ? ' (REVISED)' : ''}${d.status === 'cancelled' ? ' (CANCELLED)' : ''}</h2><div><b>DN-${esc(d.no.slice(4))}</b></div><div>${dt(d.created_at)}</div></div></div>
  <hr style="border:0;border-top:1px solid #ccc;margin:14px 0"><div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px"><div><b>Deliver to:</b> ${esc(shop.name)}, ${esc(shop.address)}</div><div><b>Rate:</b> 1 USD = ${fCDF(r)}</div></div>
  ${ed ? `<p style="margin:8px 0 0;color:#000">Revised ${dt(ed.at)} by ${esc(ed.by_name)}: ${esc(ed.reason)}</p>` : ''}
  <div class="tw" style="margin-top:12px"><table class="t"><thead><tr><th>Item</th><th>Code</th><th class="r">Qty sent</th>${d.status === 'received' ? '<th class="r">Received</th>' : ''}${showUSD ? '<th class="r">Price USD</th>' : ''}<th class="r">Price CDF</th>${showUSD ? '<th class="r">Total USD</th>' : ''}<th class="r">Total CDF</th></tr></thead><tbody>${d.delivery_items.map((it) => { const p = products.get(it.product_id); return `<tr><td>${esc(p?.name)}</td><td>${esc(p?.sku)}</td><td class="r">${it.qty} ${esc(p?.stock_unit)}${p && ctnTxt(p, it.qty) ? `<br><small>${ctnTxt(p, it.qty)}</small>` : ''}</td>${d.status === 'received' ? `<td class="r">${it.received_qty ?? it.qty}</td>` : ''}${showUSD ? `<td class="r">${fUSD(it.price_usd)}</td>` : ''}<td class="r">${fCDF(cdf(it.price_usd))}</td>${showUSD ? `<td class="r">${fUSD(it.price_usd * it.qty)}</td>` : ''}<td class="r">${fCDF(cdf(it.price_usd) * it.qty)}</td></tr>`; }).join('')}
  <tr><td colspan="${(showUSD ? 5 : 4) + (d.status === 'received' ? 1 : 0)}"><b>Total sent</b></td>${showUSD ? `<td class="r"><b>${fUSD(total)}</b></td>` : ''}<td class="r"><b>${fCDF(totalCDF)}</b></td></tr></tbody></table></div>
  <p style="margin:12px 0 0;color:#000"><b>Selling prices are fixed by the Admin and cannot be changed at the shop.</b></p>
  <div style="display:flex;justify-content:space-between;margin-top:26px;gap:20px"><div>Sent by: ${esc(d.created_by_name)}<br><br>Signature ____________</div><div>Received by (shop):${d.status === 'received' ? ` ${esc(d.received_by_name)}, ${dt(d.received_at!)}${d.received_note ? `<br>Note: ${esc(d.received_note)}` : ''}` : ''}<br><br>Signature ____________</div></div></div>`;
}

export interface Slip {
  shop_name: string; n: number; value_fc: number; value_usd: number; collected: number; returned: number; collected_usd?: number; collected_cdf?: number;
  /** goods on credit to vendeurs (in the invoice value, not in the cash collected), and the vendeurs' payments (in the cash) */
  on_credit?: number; vendeur_paid?: number;
  /** the vendeurs' payments split by how they were paid (part of Collected USD and Collected CDF) */
  vendeur_usd?: number; vendeur_cdf?: number;
  /** each vendeur who paid: the dollars and the Francs kept */
  vendeurs?: { name: string; usd: number; cdf: number }[];
  /** money changed at the counter: net dollars and Francs into the drawer (negative: out), and how many exchanges */
  fx_usd?: number; fx_cdf?: number; fx_n?: number;
  /** expenses the Admin paid from this shop's cash, taken off the balance */
  exp_usd?: number; exp_cdf?: number; exp_n?: number;
  /** from the second shift of the day: today's shift slips added up line by line, and where the first one started */
  day?: Omit<Slip, 'shop_name' | 'day'> & { from: string; shifts: number };
}
/** Day end slip in the shop's shift end format. Collected USD is what was paid in dollars (when USD payment is on); returns are in CDF. */
/** extra: the till (combined when absent) and the shift (number and times) of a shift end report. */
export function shiftSlipHTML(s: Slip, user: string, day: string, rate: number, extra?: { till?: string | null; shift?: string }) {
  const d = new Date(), isToday = day === today();
  const ddmm = day.slice(8, 10) + '-' + day.slice(5, 7) + '-' + day.slice(0, 4);
  const when = isToday ? `${ddmm} ${d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: true })}` : ddmm;
  const u3 = (n: number) => (Math.round(n * 1000) / 1000).toFixed(3), fc = (n: number) => String(Math.round(n));
  const row = (a: string, b: string | number) => `<tr><td style="white-space:nowrap">${a}</td><td style="white-space:nowrap">: ${b}</td></tr>`;
  const cu = Number(s.collected_usd ?? 0), cc = Number(s.collected_cdf ?? s.collected);
  const xu = Number(s.fx_usd ?? 0), xc = Number(s.fx_cdf ?? 0), eu = Number(s.exp_usd ?? 0), ec = Number(s.exp_cdf ?? 0);
  const vu = Number(s.vendeur_usd ?? 0), vc = Number(s.vendeur_cdf ?? (s.vendeur_usd == null ? s.vendeur_paid ?? 0 : 0));
  const sg = (n: number, f: (n: number) => string) => (n > 0 ? '+' : n < 0 ? '-' : '') + f(Math.abs(n));
  const hr = '<tr><td colspan="2"><hr></td></tr>', bold = (a: string, b: string) => row(a, b).replace('<tr>', '<tr style="font-weight:700;font-size:13.5px">');
  return `<div class="receipt slip"><div class="c" style="font-size:19px;font-weight:700;letter-spacing:.04em;margin:4px 0 6px">Shift End Report</div><table>${hr}
  ${row('Date', when)}${row('User', esc(user))}${row('Shop', esc(s.shop_name))}${extra ? row('Till', esc(extra.till ? 'Till ' + extra.till : 'All tills')) : ''}${extra?.shift ? row('Shift', esc(extra.shift)) : ''}${row('TAUX', fc(rate))}${hr}
  ${row('Total Invoice', s.n)}${row('Invoice Value USD', u3(s.value_usd))}${row('Invoice Value CDF', fc(s.value_fc))}${Number(s.on_credit) ? row('On credit CDF', fc(Number(s.on_credit))) : ''}${hr}
  ${vu || vc ? vendeurRows(s, cu - vu, cc - vc, row, u3, fc, hr) : ''}${row('Collected USD', u3(cu))}${row('Collected CDF', fc(cc))}${row('Return USD', u3(0))}${row('Return CDF', fc(s.returned))}${hr}
  ${Number(s.fx_n) || xu || xc ? row('Exchange USD', sg(xu, u3)) + row('Exchange CDF', sg(xc, fc)) : ''}${eu || ec ? row('Expenses USD', sg(-eu, u3)) + row('Expenses CDF', sg(-ec, fc)) : ''}${Number(s.fx_n) || xu || xc || eu || ec ? hr : ''}
  ${bold('Balance USD', u3(cu + xu - eu))}${bold('Balance CDF', fc(cc - s.returned + xc - ec))}${s.day ? daySoFar(s.day, bold, hr, fc) : ''}</table></div>`;
}
/** With vendeurs' payments: the cash sales apart, then each vendeur by name in USD and CDF (only the currencies they paid in). */
function vendeurRows(s: Slip, saleUsd: number, saleCdf: number, row: (a: string, b: string | number) => string, u3: (n: number) => string, fc: (n: number) => string, hr: string) {
  const list = (s.vendeurs ?? []).map((v) => (Number(v.usd) ? row(esc(v.name) + ' USD', u3(Number(v.usd))) : '') + (Number(v.cdf) ? row(esc(v.name) + ' CDF', fc(Number(v.cdf))) : '')).join('');
  return `${row('Cash sales USD', u3(saleUsd))}${row('Cash sales CDF', fc(saleCdf))}<tr><td colspan="2" style="font-weight:700;padding-top:4px">Vendeurs</td></tr>${list || row('Vendeurs USD', u3(Number(s.vendeur_usd ?? 0))) + row('Vendeurs CDF', fc(Number(s.vendeur_cdf ?? 0)))}${hr}`;
}
/** From the second shift of the day: one line with the total of the day, which is today's shift slips added up. */
function daySoFar(d: NonNullable<Slip['day']>, bold: (a: string, b: string) => string, hr: string, fc: (n: number) => string) {
  // the vendeurs' payments of the whole day so far, so the cash they brought shows on every shift's slip
  const vu = Number(d.vendeur_usd ?? 0), vc = Number(d.vendeur_cdf ?? 0), row = (a: string, b: string) => `<tr><td style="white-space:nowrap">${a}</td><td style="white-space:nowrap">: ${b}</td></tr>`;
  return `${hr}${bold('Total of the day', fc(d.value_fc))}${vu || vc ? row('Vendeurs today USD', (Math.round(vu * 1000) / 1000).toFixed(3)) + row('Vendeurs today CDF', fc(vc)) : ''}`;
}

export interface Report {
  from: string; to: string; n: number; total: number; total_usd: number; disc: number; vat: number; items: number; edited: number; profit_usd: number | null;
  by_day: { day: string; n: number; q: number; d: number; v: number }[]; top: { name: string; qty: number; val: number }[];
  by_cashier: { name: string; v: number }[]; slips: (Slip & { shop_id: string; code: string })[];
  invoices: { id: string; no: string; t: string; shop_id: string; cashier_name: string; customer?: string; items: number; disc: number; total: number; edited: boolean }[];
  /** true when sales were left out to keep the figures under the shop's daily limit (the Shop Admin only) */
  capped?: boolean;
  /** sales of each category, biggest first, with its items (missing before migration 21) */
  by_category?: CategorySales[];
}
export interface CategorySales {
  category: string; val: number; pcs: number;
  items: { product_id: string; name: string; val: number; pcs: number; pieces: number; units: Record<string, number> }[];
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
export type TicketLayout = 'a4' | 'label' | 'roll' | 'rollsm';
/** Price tickets: an A4 sheet (3 x 8 tickets of 70 x 37 mm), one 50 x 30 mm label per ticket for a label printer, or
 *  one big bold ticket per cut on the receipt printer's 80 mm roll, lying sideways (every price large, all at one size, in black boxes).
 *  Only the chosen units are printed (pcs also covers a set and its piece). Items with none of them are left out. */
export function ticketsHTML(items: { p: Product; copies: number }[], rate: number, layout: TicketLayout, shopName = '', units: TicketUnit[] = ['pcs', 'half dzn', 'dzn', 'carton']) {
  const want = (u: { u: string; piece?: boolean }) => units.includes((u.u === 'set' || u.piece ? 'pcs' : u.u) as TicketUnit);
  const label = (u: { u: string; mult: number; piece?: boolean }) => (u.piece ? '1 piece' : u.u === 'pcs' ? 'pc' : u.u === 'half dzn' ? 'half dozen (6)' : u.u === 'dzn' ? 'dozen (12)' : u.u === 'carton' ? `carton (${u.mult})` : u.u);
  const one = (p: Product) => {
    const us = unitsOf(p).filter(want);
    if (!us.length) return '';
    const up = (t: string) => esc(t.toLocaleUpperCase('fr'));   // tickets are printed in capitals
    const price = (u: (typeof us)[number]) => `${fNum(toCDF(u.usd, rate))} <small>CDF</small>`;
    // on the roll the ticket lies sideways, 100 x 70 mm, turned to run along the paper
    if (layout === 'roll' || layout === 'rollsm') return `<div class="ticket roll${layout === 'rollsm' ? ' sm' : ''}"><div class="tk"><div class="tn"><div>${up(p.name).split(' ').map((w) => `<span>${w}</span>`).join(' ')}</div></div><div class="tps n${us.length}">${us.map((u) => `<div class="tp"><span>${up(label(u))}</span><b>${price(u)}</b></div>`).join('')}</div><div class="tf"><span>${up(p.sku)}</span><span>${up(shopName)}</span></div></div></div>`;
    return `<div class="ticket ${layout}"><div class="tn">${up(p.name)}</div><div class="tl">${us.map((u) => `<div class="tu"><span>${up(label(u))}</span><b>${fCDF(toCDF(u.usd, rate))}</b></div>`).join('')}</div><div class="tf"><span>${up(p.sku)}</span><span>${up(shopName)}</span></div></div>`;
  };
  const all = items.flatMap((x) => { const t = one(x.p); return t ? Array.from({ length: Math.max(0, Math.min(200, x.copies)) }, () => t) : []; });
  if (layout !== 'a4') return all.join('<div class="pagebreak"></div>');
  const pages: string[] = [];
  for (let i = 0; i < all.length; i += 24) pages.push(`<div class="tsheet">${all.slice(i, i + 24).join('')}</div>`);
  return pages.join('<div class="pagebreak"></div>');
}

/** Short reference of an order sent by a till with the old app, which printed no invoice for it. */
export const orderRef = (id: string) => '#' + id.replace(/-/g, '').slice(0, 6).toUpperCase();

/** Stock count sheet: what the system shows, with empty columns to write the physical count. */
export function stockCountHTML(c: Company, where: string, by: string, rows: { p: Product; qty: number }[]) {
  const body = `<table class="t count"><thead><tr><th>#</th><th>Item</th><th>Code</th><th>Category</th><th class="r">System stock</th><th style="width:22%">Counted</th><th style="width:14%">Difference</th></tr></thead><tbody>
  ${rows.map((r, i) => `<tr><td>${i + 1}</td><td><b>${esc(r.p.name)}</b></td><td>${esc(r.p.sku)}</td><td>${esc(r.p.category)}</td><td class="r"><b>${r.qty} ${esc(r.p.stock_unit)}</b>${ctnTxt(r.p, r.qty) ? `<br><small>${ctnTxt(r.p, r.qty)}</small>` : ''}</td><td></td><td></td></tr>`).join('') || '<tr><td colspan="7">No items</td></tr>'}</tbody></table>
  <p style="color:#000;margin-top:14px">${rows.length} items, ${sum(rows, (r) => r.qty)} units in the system. Write what you count; the difference is Counted minus System stock.</p>
  <div style="display:flex;justify-content:space-between;margin-top:28px;gap:20px"><div>Counted by: ____________________<br><br>Signature ____________</div><div>Checked by: ____________________<br><br>Signature ____________</div></div>`;
  return bookHTML(c, 'Stock count sheet', where + ', ' + today(), body, by);
}

/** Stock valuation: each item's stock at its selling price per pc (as at the till), the total at selling price and, for the Admin, at cost. */
export function stockValueHTML(c: Company, where: string, by: string, rows: { p: Product; qty: number }[], rate: number, costOf?: (p: Product) => number) {
  const v = stockValue(rows, rate), cost = costOf ? sum(rows.filter((r) => r.qty > 0), (r) => costOf(r.p) * r.qty) : null;
  const body = `<table class="t"><thead><tr><th>#</th><th>Item</th><th>Category</th><th class="r">Stock</th><th class="r">Price per pc</th><th class="r">Value</th></tr></thead><tbody>
  ${rows.map((r, i) => { const pr = toCDF(pcValue(r.p), rate); return `<tr><td>${i + 1}</td><td><b>${esc(r.p.name)}</b><br><small>${esc(r.p.sku)}</small></td><td>${esc(r.p.category)}</td><td class="r">${r.qty} ${esc(r.p.stock_unit)}</td><td class="r">${fCDF(pr)}</td><td class="r"><b>${r.qty > 0 ? fCDF(pr * r.qty) : '-'}</b></td></tr>`; }).join('') || '<tr><td colspan="6">No items</td></tr>'}</tbody></table>
  <p style="color:#000;margin-top:14px"><b>Total at selling price: ${fCDF(v.cdf)} (${fUSD(v.usd)})</b>, ${v.lines} items, ${v.units} units in stock, at 1 USD = ${fCDF(rate)}.${cost !== null ? ` At cost: ${fUSD(cost)}.` : ''} Stock sold on order counts as none.</p>`;
  return bookHTML(c, 'Stock valuation', where + ', ' + today(), body, by);
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
  // a line typed in CDF and USD together is one row again, the two amounts side by side
  const rows = mergeCurrencies(st.lines, (l) => l.no).map((l) => { run += l.side === 'Dr' ? l.base : -l.base; return `<tr><td>${l.date}</td><td>${esc(l.no)}</td><td>${esc(l.narration)}${l.memo ? `<br><small>${esc(l.memo)}</small>` : ''}${l.bill_ref ? `<br><small>Bill ${esc(l.bill_ref)}${l.due_date ? ', due ' + l.due_date : ''}</small>` : ''}</td><td class="r">${l.cdf ? fCDF(l.cdf) + `<br><small>@ ${l.cdf_rate}</small>` : ''}</td><td class="r">${l.usd ? fUSD(l.usd) : ''}</td><td class="r">${l.side === 'Dr' ? fUSD(l.base) : ''}</td><td class="r">${l.side === 'Cr' ? fUSD(l.base) : ''}</td><td class="r">${drcr(run)}</td></tr>`; }).join('');
  const body = `<p style="color:#000;margin:0 0 8px"><b>${esc(st.account.name)}</b>, ${esc(st.account.group)}</p>
  <table class="t"><thead><tr><th>Date</th><th>Voucher</th><th>Particulars</th><th class="r">CDF</th><th class="r">USD</th><th class="r">Debit USD</th><th class="r">Credit USD</th><th class="r">Balance</th></tr></thead><tbody>
  ${st.with_opening ? `<tr><td>${st.from}</td><td></td><td><b>Opening balance</b></td><td></td><td></td><td class="r">${st.brought_forward > 0 ? fUSD(st.brought_forward) : ''}</td><td class="r">${st.brought_forward < 0 ? fUSD(-st.brought_forward) : ''}</td><td class="r">${drcr(st.brought_forward)}</td></tr>` : ''}
  ${rows || '<tr><td colspan="8">No entries in this period</td></tr>'}
  <tr><td colspan="5"><b>Totals for the period</b></td><td class="r"><b>${fUSD(st.total_dr)}</b></td><td class="r"><b>${fUSD(st.total_cr)}</b></td><td class="r"><b>${drcr(st.closing)}</b></td></tr></tbody></table>
  <p style="margin-top:12px">Amounts in USD; lines entered in Francs show the CDF amount and its rate.${st.with_opening ? '' : ' Opening balance not included.'}</p>`;
  return bookHTML(c, 'Statement of account', `${st.from} to ${st.to}`, body, by);
}

/** A vendeur's statement in CDF: goods on credit, payments and the running balance; the promo items apart (not owed). */
export function vendeurStatementHTML(st: VendeurStatement, c: Company, by: string) {
  let run = st.brought_forward;
  const v = st.vendeur, o = st.state;
  const rows = st.lines.map((l) => { run += l.dr - l.cr; return `<tr><td>${esc(l.date)}</td><td>${esc(l.no)}</td><td>${esc(l.what)}${(l.items ?? []).map((it) => `<br><small>${it.qty} ${esc(it.unit)} ${esc(it.name)}: ${fUSD(it.amount)}</small>`).join('')}${l.due ? `<br><small>due ${esc(l.due)}</small>` : ''}</td><td class="r">${l.dr ? fUSD(l.dr) : ''}</td><td class="r">${l.cr ? fUSD(l.cr) : ''}</td><td class="r">${fUSD(run)}</td></tr>`; }).join('');
  const promos = st.promos.length ? `<h3 style="margin:18px 0 6px">Promo items given (not owed)</h3><table class="t"><thead><tr><th>Date</th><th>Promo</th><th>Items</th><th class="r">Value CDF</th><th>Status</th></tr></thead><tbody>
    ${st.promos.map((p) => `<tr><td>${esc(p.date)}</td><td>${esc(p.no)}${p.invoice ? `<br><small>with ${esc(p.invoice)}</small>` : ''}</td><td>${(p.items ?? []).map((i) => `${i.qty} ${esc(i.unit)} ${esc(i.name)}`).join(', ')}${p.note ? `<br><small>${esc(p.note)}</small>` : ''}</td><td class="r">${fCDF(p.value)}</td><td>${p.status === 'settled' ? 'Settled' : 'Open'}</td></tr>`).join('')}
    <tr><td colspan="3"><b>Total promo items</b></td><td class="r"><b>${fCDF(sum(st.promos, (p) => p.value))}</b></td><td></td></tr></tbody></table>` : '';
  const body = `<p style="color:#000;margin:0 0 8px"><b>${esc(v.name)}</b>, vendeur of ${esc(v.shop_name)}${v.phone ? `, ${esc(v.phone)}` : ''}<br>Credit ${v.credit_days} days, limit ${fUSD(Number(o.credit_limit_usd ?? 0))}</p>
  <table class="t"><thead><tr><th>Date</th><th>No.</th><th>Particulars</th><th class="r">Goods USD</th><th class="r">Paid USD</th><th class="r">Balance USD</th></tr></thead><tbody>
  <tr><td>${esc(st.from)}</td><td></td><td><b>Brought forward</b></td><td></td><td></td><td class="r">${fUSD(st.brought_forward)}</td></tr>
  ${rows || '<tr><td colspan="6">No entries in this period</td></tr>'}
  <tr><td colspan="3"><b>Totals for the period</b></td><td class="r"><b>${fUSD(st.total_dr)}</b></td><td class="r"><b>${fUSD(st.total_cr)}</b></td><td class="r"><b>${fUSD(st.closing)}</b></td></tr></tbody></table>
  <p style="margin-top:10px">Owed today: <b>${fUSD(o.balance)}</b>; credit left ${fUSD(o.available)}${o.overdue ? `; <b>overdue ${fUSD(o.overdue_amount)}</b> (since ${esc(o.oldest_due ?? '')})` : ''}.</p>${promos}`;
  return bookHTML(c, 'Vendeur statement', `${st.from} to ${st.to}`, body, by);
}

/** The receipt a vendeur takes away for a payment: the amount, what was owed before and what is still owed. */
export function vendeurPaymentHTML(x: { no: string; at: string; amount: number; by_name: string; vendeur: string; before: number; state: { balance: number; overdue: boolean; overdue_amount: number };
  paid_usd?: number; paid_cdf?: number; usd_rate?: number | null; change_cdf?: number }, c: Company, shop: Shop) {
  const row = (a: string, b: string) => `<tr><td>${a}</td><td class="r">${b}</td></tr>`;
  return `<div class="receipt inv"><div class="c"><div class="big">${esc((c.name || shop.name).toUpperCase())}</div><div>${esc((shop.address || c.address || '').toUpperCase())}</div>${c.phone ? `<div>Tél: ${esc(c.phone)}</div>` : ''}</div>
  <div class="c"><span class="rbox">REÇU # : ${esc(x.no)}</span></div>
  <div class="rl"><b>Vendeur:</b> ${esc(x.vendeur.toUpperCase())}</div><div class="rl"><b>Date:</b> ${rDate(x.at)}&nbsp;&nbsp; <b>Time:</b> ${rTime(x.at)}</div>
  <table class="rsum">${row('Dû avant - USD', '$' + n2(x.before))}</table>
  <div class="rttc"><b>Payé - USD</b><span class="rbox">$${n2(x.amount)}</span></div>
  <table class="rsum rcash">${x.paid_usd ? row('Reçu USD', '$' + n2(x.paid_usd)) : ''}${x.paid_cdf ? row('Reçu CDF', n2(x.paid_cdf)) + row('<span class="small">Taux</span>', `<span class="small">1 USD = ${n0(x.usd_rate ?? 0)} CDF</span>`) : ''}${x.change_cdf ? row('<b>Monnaie rendue</b>', `<b>${n2(x.change_cdf)} CDF</b>`) : ''}</table>
  <table class="rsum">${row('<b>Reste à payer - USD</b>', `<b>$${n2(x.state.balance)}</b>`)}${x.state.overdue ? row('Dont en retard', '$' + n2(x.state.overdue_amount)) : ''}</table>
  <div class="rl">Reçu par&nbsp;&nbsp; ${esc(x.by_name)}</div></div>`;
}

/** The promo report of a month: each item given out free and how many pieces, all vendeurs together. */
export function promoReportHTML(d: PromoData, c: Company, shopName: string, by: string, status: 'open' | 'kept' | 'settled') {
  const m = new Date(d.month + 'T00:00:00').toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
  const body = `<p style="color:#000;margin:0 0 8px"><b>${esc(shopName)}</b>: promo items given out, open at the end of ${esc(m)}${d.carried_pcs ? `, ${d.carried_pcs} pieces of them from earlier months` : ''}. ${status === 'settled' ? '<b>Settled.</b>' : status === 'kept' ? 'Kept, not settled.' : 'Not yet kept or settled.'}</p>
  <table class="t"><thead><tr><th>Item</th><th class="r">Pieces given out</th><th class="r">From cash sales</th><th class="r">From credit sales</th></tr></thead><tbody>
  ${(d.items ?? []).map((i) => `<tr><td>${esc(i.name)}</td><td class="r">${i.qty}${i.unit !== 'pcs' ? ' ' + esc(i.unit) : ''}</td><td class="r">${i.cash_qty ?? '-'}</td><td class="r">${i.credit_qty ?? i.qty}</td></tr>`).join('') || '<tr><td colspan="4">No promo items</td></tr>'}
  <tr><td><b>Total</b></td><td class="r"><b>${d.pcs ?? 0}</b></td><td class="r"><b>${d.cash_pcs ?? '-'}</b></td><td class="r"><b>${d.credit_pcs ?? d.pcs ?? 0}</b></td></tr></tbody></table>
  <p style="margin-top:10px">Promo items are given free: they are not invoiced, and the vendeurs do not owe them.</p>`;
  return bookHTML(c, 'Promo report', m, body, by);
}

/** A receipt for money changed at the counter. */
export function exchangeReceiptHTML(x: { no: string; at: string; dir: 'buy' | 'sell'; usd: number; cdf: number; rate: number; customer: string; by_name: string }, c: Company, shop: Shop) {
  const row = (a: string, b: string) => `<tr><td>${a}</td><td class="r">${b}</td></tr>`, buy = x.dir === 'buy';
  return `<div class="receipt inv"><div class="c"><div class="big">${esc((c.name || shop.name).toUpperCase())}</div><div>${esc((shop.address || c.address || '').toUpperCase())}</div>${c.phone ? `<div>Tél: ${esc(c.phone)}</div>` : ''}</div>
  <div class="c"><span class="rbox">CHANGE # : ${esc(x.no)}</span></div>
  ${x.customer ? `<div class="rl"><b>Client:</b> ${esc(x.customer.toUpperCase())}</div>` : ''}<div class="rl"><b>Date:</b> ${rDate(x.at)}&nbsp;&nbsp; <b>Time:</b> ${rTime(x.at)}</div>
  <table class="rsum">${row(buy ? 'Reçu USD' : 'Reçu CDF', buy ? '$' + n2(x.usd) : n2(x.cdf))}${row('<span class="small">Taux</span>', `<span class="small">1 USD = ${n0(x.rate)} CDF</span>`)}</table>
  <div class="rttc"><b>${buy ? 'Rendu - CDF' : 'Rendu - USD'}</b><span class="rbox">${buy ? n2(x.cdf) : '$' + n2(x.usd)}</span></div>
  <div class="rl">Servi par&nbsp;&nbsp; ${esc(x.by_name)}</div></div>`;
}

/** The shop's cash book: every move of its two cash drawers (CDF and USD side by side), from cash_book. */
export interface CashBook {
  shop_id: string; shop_name: string; from: string; to: string; opening: { cdf: number; usd: number };
  rows: { date: string; ord: number; what: string; kind: string; in_cdf: number; in_usd: number; out_cdf: number; out_usd: number }[];
}
/** The Admin's daily cash report of a shop: cash sales, credit collections, exchanges, expenses and other moves, with the
 *  running balance in CDF and USD, a total for each day when there are several, and the summary at the end. */
export function cashBookHTML(cb: CashBook, c: Company, by: string) {
  const d2 = (d: string) => new Date(d + 'T12:00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });
  const C = (n: number) => (Math.abs(n) < 0.5 ? '' : fNum(n)), U = (n: number) => (Math.abs(n) < 0.005 ? '' : fUSD(n));
  const bC = (n: number) => fNum(n), bU = (n: number) => fUSD(n);
  let bc = Number(cb.opening.cdf), bu = Number(cb.opening.usd);
  const sum = { sales: [0, 0], credit: [0, 0], fx: [0, 0], exp: [0, 0], other: [0, 0] } as Record<string, [number, number]>;
  const grp = (o: number) => (o === 1 ? 'sales' : o === 2 ? 'credit' : o === 3 ? 'fx' : o === 4 ? 'exp' : 'other');
  const days = [...new Set(cb.rows.map((r) => r.date))], many = days.length > 1;
  const td = (v: string, cls = 'r') => `<td class="${cls}">${v}</td>`;
  let body = '';
  if (Math.abs(bc) >= 0.5 || Math.abs(bu) >= 0.005) body += `<tr class="cbbf"><td>${d2(cb.from)}</td><td><b>Brought forward</b></td>${td('')}${td('')}${td('')}${td('')}${td(bC(bc))}${td(bU(bu))}<td></td></tr>`;
  for (const day of days) {
    const rows = cb.rows.filter((r) => r.date === day), t = [0, 0, 0, 0];
    for (const r of rows) {
      const ic = Number(r.in_cdf), iu = Number(r.in_usd), oc = Number(r.out_cdf), ou = Number(r.out_usd);
      bc += ic - oc; bu += iu - ou; t[0] += ic; t[1] += iu; t[2] += oc; t[3] += ou;
      const g = sum[grp(r.ord)]; g[0] += ic - oc; g[1] += iu - ou;
      body += `<tr><td class="nw">${d2(day)}</td><td>${esc(r.what.toUpperCase())}</td>${td(C(ic))}${td(U(iu))}${td(C(oc))}${td(U(ou))}${td(bC(bc))}${td(bU(bu))}<td>${esc(r.kind.toUpperCase())}</td></tr>`;
    }
    if (many) body += `<tr class="cbday"><td></td><td><b>Total ${d2(day)}</b></td>${td(`<b>${C(t[0])}</b>`)}${td(`<b>${U(t[1])}</b>`)}${td(`<b>${C(t[2])}</b>`)}${td(`<b>${U(t[3])}</b>`)}${td(`<b>${bC(bc)}</b>`)}${td(`<b>${bU(bu)}</b>`)}<td></td></tr>`;
  }
  if (!cb.rows.length) body += `<tr><td colspan="9">No cash moved in these dates.</td></tr>`;
  const line = (l: string, k: [number, number], sign = '') => `<tr><td>${l}</td>${td((Math.abs(k[0]) >= 0.5 ? sign : '') + fNum(Math.abs(k[0])))}${td((Math.abs(k[1]) >= 0.005 ? sign : '') + fUSD(Math.abs(k[1])))}</tr>`;
  const net = (l: string, k: [number, number]) => `<tr><td>${l}</td>${td((k[0] < 0 ? '-' : '+') + fNum(Math.abs(k[0])))}${td((k[1] < 0 ? '-' : '+') + fUSD(Math.abs(k[1])))}</tr>`;
  const S = `<table class="t cbsum"><thead><tr><th>Summary</th><th class="r">CDF</th><th class="r">USD</th></tr></thead><tbody>
    ${line('Brought forward', [Number(cb.opening.cdf), Number(cb.opening.usd)])}
    ${line('+ Cash sales', sum.sales)}${sum.credit[0] || sum.credit[1] ? line('+ Credit sales collected (vendeurs)', sum.credit) : ''}
    <tr><td><b>Cash collected</b></td>${td(`<b>${fNum(Number(cb.opening.cdf) + sum.sales[0] + sum.credit[0])}</b>`)}${td(`<b>${fUSD(Number(cb.opening.usd) + sum.sales[1] + sum.credit[1])}</b>`)}</tr>
    ${sum.fx[0] || sum.fx[1] ? net('± Money exchanged', sum.fx) : ''}${sum.exp[0] || sum.exp[1] ? line('- Expenses', [-sum.exp[0], -sum.exp[1]], '-') : ''}${sum.other[0] || sum.other[1] ? net('± Other (cash taken to head office, transfers)', sum.other) : ''}
    <tr class="cbend"><td><b>Cash in hand at the end</b></td>${td(`<b>${fNum(bc)}</b>`)}${td(`<b>${fUSD(bu)}</b>`)}</tr></tbody></table>`;
  const table = `<style>.cb td,.cb th{font-size:11.5px;padding:4px 6px}.cb .r{text-align:right;white-space:nowrap}.cb .nw{white-space:nowrap}.cbday td{border-top:1.5px solid #000}.cbsum{max-width:560px;margin-top:16px}.cbsum td,.cbsum th{font-size:12.5px}.cbend td{border-top:2px solid #000}@page{size:A4 landscape}</style>
    <table class="t cb"><thead><tr><th rowspan="2">Date</th><th rowspan="2">Particulars</th><th colspan="2" class="r">In</th><th colspan="2" class="r">Out</th><th colspan="2" class="r">Balance</th><th rowspan="2">Type</th></tr>
    <tr><th class="r">CDF</th><th class="r">USD</th><th class="r">CDF</th><th class="r">USD</th><th class="r">CDF</th><th class="r">USD</th></tr></thead><tbody>${body}</tbody></table>${S}`;
  return bookHTML(c, 'Daily cash report', `${cb.shop_name}, ${cb.from === cb.to ? d2(cb.from) : `${d2(cb.from)} to ${d2(cb.to)}`}`, table, by);
}
