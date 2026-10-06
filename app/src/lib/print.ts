// Printed documents: customer receipt, delivery note, day end slip and sales report.
// Layouts are those approved on the demo. Printing uses the browser; for one-tap printing at
// the till, start Chrome with --kiosk-printing and set the receipt printer as default.
import type { Company, Delivery, Invoice, Product, Shop } from './types';
import { ctnTxt } from './units';
import { dt, esc, fCDF, fUSD, sum, today } from './format';

export function printHTML(html: string) {
  const el = document.getElementById('print-area')!;
  el.innerHTML = html;
  try { window.print(); } catch { /* printing unavailable */ }
}

export function receiptHTML(inv: Invoice, c: Company, shop: Shop, opt: { copy?: 'client' | 'shop'; dup?: boolean } = {}) {
  const row = (a: string, b: string | number) => `<tr><td>${a}</td><td class="r">${b}</td></tr>`;
  const ed = inv.edits && inv.edits.length ? inv.edits[inv.edits.length - 1] : null;
  return `<div class="receipt"><div class="c"><div class="rlogo">SIM</div><div class="big">${esc(c.name)}</div><div>${esc(shop.name)}</div><div>${esc(shop.address)}</div><div>Tél : ${esc(c.phone)}</div><div>RCCM : ${esc(c.rccm)}</div><div>ID NAT : ${esc(c.idnat)}</div><div>NIF : ${esc(c.nif)}</div></div><hr>
  <div class="c big">FACTURE${opt.dup ? ' (DUPLICATA)' : ''}</div><div class="c">${opt.copy === 'shop' ? 'Copie magasin' : 'Copie client'}</div>${ed ? '<div class="c">FACTURE MODIFIÉE</div>' : ''}<hr>
  <table>${row('N° facture', esc(inv.no))}${row('Date', dt(inv.t))}${row('Caissier', esc(inv.cashier_name))}${row('Paiement', 'Espèces')}</table><hr>
  <table>${inv.items.map((it) => `<tr><td colspan="2">${esc(it.name)}</td></tr><tr><td>&nbsp;${it.qty} x ${esc(it.piece ? '1 piece' : it.unit)} @ ${fCDF(it.price)}</td><td class="r">${fCDF(it.line)}</td></tr>`).join('')}</table><hr>
  <table>${row('Sous-total', fCDF(inv.gross))}${inv.disc ? row(`Remise ${inv.disc_pct}%`, '- ' + fCDF(inv.disc)) : ''}${row('Total HT', fCDF(inv.ht))}${row(`TVA ${inv.vat_rate}%`, fCDF(inv.vat))}</table>
  <div class="rtotal"><span>TOTAL TTC</span><span>${fCDF(inv.total)}</span></div>
  <table>${row('Espèces reçues', fCDF(inv.tendered))}${inv.change > 0 ? row('Monnaie rendue', fCDF(inv.change)) : ''}${row('Articles', sum(inv.items, (i) => i.qty))}</table><hr>
  ${ed ? `<div class="c small">Modifiée le ${dt(ed.at)} par ${esc(ed.by_name)}</div>` : ''}
  <div class="c">${esc(c.footer)}</div><div class="c small">Montants en Francs congolais (FC), TVA incluse.</div><div class="c small">Marchandise ni reprise ni échangée sans facture.</div></div>`;
}
export const saleCopies = (inv: Invoice, c: Company, shop: Shop) =>
  receiptHTML(inv, c, shop, { copy: 'client' }) + '<div class="pagebreak"></div>' + receiptHTML(inv, c, shop, { copy: 'shop' });

export function deliveryNoteHTML(d: Delivery, shop: Shop, c: Company, products: Map<string, Product>, showUSD: boolean) {
  const r = d.rate, cdf = (u: number) => Math.round((u * r) / 10) * 10, ed = d.delivery_edits?.length ? [...d.delivery_edits].sort((a, b) => a.at.localeCompare(b.at)).at(-1)! : null;
  const total = sum(d.delivery_items, (i) => i.price_usd * i.qty), totalCDF = sum(d.delivery_items, (i) => cdf(i.price_usd) * i.qty);
  return `<div class="doc"><div style="display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap"><div><h2>${esc(c.name)}</h2><div>Central store, ${esc(c.address)}</div><div>RCCM ${esc(c.rccm)}, NIF ${esc(c.nif)}</div></div><div style="text-align:right"><h2>Delivery note${ed ? ' (REVISED)' : ''}</h2><div><b>DN-${esc(d.no.slice(4))}</b></div><div>${dt(d.created_at)}</div></div></div>
  <hr style="border:0;border-top:1px solid #ccc;margin:14px 0"><div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px"><div><b>Deliver to:</b> ${esc(shop.name)}, ${esc(shop.address)}</div><div><b>Rate:</b> 1 USD = ${fCDF(r)}</div></div>
  ${ed ? `<p style="margin:8px 0 0;color:#000">Revised ${dt(ed.at)} by ${esc(ed.by_name)}: ${esc(ed.reason)}</p>` : ''}
  <div class="tw" style="margin-top:12px"><table class="t"><thead><tr><th>Item</th><th>Code</th><th class="r">Qty</th>${showUSD ? '<th class="r">Price USD</th>' : ''}<th class="r">Price FC</th>${showUSD ? '<th class="r">Total USD</th>' : ''}<th class="r">Total FC</th></tr></thead><tbody>${d.delivery_items.map((it) => { const p = products.get(it.product_id); return `<tr><td>${esc(p?.name)}</td><td>${esc(p?.sku)}</td><td class="r">${it.qty} ${esc(p?.stock_unit)}${p && ctnTxt(p, it.qty) ? `<br><small>${ctnTxt(p, it.qty)}</small>` : ''}</td>${showUSD ? `<td class="r">${fUSD(it.price_usd)}</td>` : ''}<td class="r">${fCDF(cdf(it.price_usd))}</td>${showUSD ? `<td class="r">${fUSD(it.price_usd * it.qty)}</td>` : ''}<td class="r">${fCDF(cdf(it.price_usd) * it.qty)}</td></tr>`; }).join('')}
  <tr><td colspan="${showUSD ? 5 : 4}"><b>Total</b></td>${showUSD ? `<td class="r"><b>${fUSD(total)}</b></td>` : ''}<td class="r"><b>${fCDF(totalCDF)}</b></td></tr></tbody></table></div>
  <p style="margin:12px 0 0;color:#000"><b>Selling prices are fixed by the Admin and cannot be changed at the shop.</b></p>
  <div style="display:flex;justify-content:space-between;margin-top:26px;gap:20px"><div>Sent by: ${esc(d.created_by_name)}<br><br>Signature ____________</div><div>Received by (shop):<br><br>Signature ____________</div></div></div>`;
}

export interface Slip { shop_name: string; n: number; value_fc: number; value_usd: number; collected: number; returned: number }
/** Day end slip in the shop's shift end format. Payments are FC only, so USD lines are 0. */
export function shiftSlipHTML(s: Slip, user: string, day: string, rate: number) {
  const d = new Date(), isToday = day === today();
  const ddmm = day.slice(8, 10) + '-' + day.slice(5, 7) + '-' + day.slice(0, 4);
  const when = isToday ? `${ddmm} ${d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: true })}` : ddmm;
  const u3 = (n: number) => (Math.round(n * 1000) / 1000).toFixed(3), fc = (n: number) => String(Math.round(n));
  const row = (a: string, b: string | number) => `<tr><td style="white-space:nowrap">${a}</td><td style="white-space:nowrap">: ${b}</td></tr>`;
  const hr = '<tr><td colspan="2"><hr></td></tr>', bold = (a: string, b: string) => row(a, b).replace('<tr>', '<tr style="font-weight:700;font-size:13.5px">');
  return `<div class="receipt slip"><div class="c" style="font-size:19px;font-weight:700;letter-spacing:.04em;margin:4px 0 6px">Shift End Report</div><table>${hr}
  ${row('Date', when)}${row('User', esc(user))}${row('Shop', esc(s.shop_name))}${row('TAUX', fc(rate))}${hr}
  ${row('Total Invoice', s.n)}${row('Invoice Value USD', u3(s.value_usd))}${row('Invoice Value FC', fc(s.value_fc))}${hr}
  ${row('Collected USD', u3(0))}${row('Collected FC', fc(s.collected))}${row('Return USD', u3(0))}${row('Return FC', fc(s.returned))}${hr}
  ${bold('Balance USD', u3(0))}${bold('Balance FC', fc(s.collected - s.returned))}</table></div>`;
}

export interface Report {
  from: string; to: string; n: number; total: number; total_usd: number; disc: number; vat: number; items: number; edited: number; profit_usd: number | null;
  by_day: { day: string; n: number; q: number; d: number; v: number }[]; top: { name: string; qty: number; val: number }[];
  by_cashier: { name: string; v: number }[]; slips: (Slip & { shop_id: string; code: string })[];
  invoices: { id: string; no: string; t: string; shop_id: string; cashier_name: string; items: number; disc: number; total: number; edited: boolean }[];
}
export function reportHTML(r: Report, c: Company, where: string, by: string, shopName: (id: string) => string, allShops: boolean, vat: number) {
  return `<div class="doc"><div style="display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap"><div><h2>${esc(c.name)}</h2><div>${esc(c.address)}</div><div>RCCM ${esc(c.rccm)}, ID NAT ${esc(c.idnat)}, NIF ${esc(c.nif)}</div></div>
  <div style="text-align:right"><h2>Sales report</h2><div>${r.from} to ${r.to}</div><div>${esc(where)}</div><div>Printed ${dt(Date.now())} by ${esc(by)}</div></div></div>
  <hr style="border:0;border-top:1px solid #ccc;margin:14px 0">
  <table class="t"><tbody><tr><td><b>Invoices</b></td><td>${r.n}</td><td><b>Items sold</b></td><td>${r.items}</td><td><b>Discounts</b></td><td>${fCDF(r.disc)}</td></tr>
  <tr><td><b>VAT included</b></td><td>${fCDF(r.vat)}</td><td><b>Sales excl. VAT</b></td><td>${fCDF(r.total - r.vat)}</td><td><b>Total sales</b></td><td><b>${fCDF(r.total)}</b></td></tr></tbody></table>
  <h3 style="margin:16px 0 6px">Day by day</h3>
  <table class="t"><thead><tr><th>Date</th><th class="r">Invoices</th><th class="r">Items</th><th class="r">Discounts</th><th class="r">Total FC</th></tr></thead><tbody>${r.by_day.map((d) => `<tr><td>${d.day}</td><td class="r">${d.n}</td><td class="r">${d.q}</td><td class="r">${fCDF(d.d)}</td><td class="r"><b>${fCDF(d.v)}</b></td></tr>`).join('') || '<tr><td colspan="5">No sales in this period</td></tr>'}</tbody></table>
  <h3 style="margin:16px 0 6px">Items sold</h3>
  <table class="t"><thead><tr><th>Item</th><th class="r">Quantity</th><th class="r">Value FC</th></tr></thead><tbody>${r.top.map((x) => `<tr><td>${esc(x.name)}</td><td class="r">${x.qty}</td><td class="r">${fCDF(x.val)}</td></tr>`).join('') || '<tr><td colspan="3">No items</td></tr>'}</tbody></table>
  <h3 style="margin:16px 0 6px">Invoices</h3>
  <table class="t"><thead><tr><th>Invoice</th><th>Date and time</th>${allShops ? '<th>Shop</th>' : ''}<th>Cashier</th><th class="r">Items</th><th class="r">Total FC</th></tr></thead><tbody>${r.invoices.map((i) => `<tr><td>${esc(i.no)}${i.edited ? ' (edited)' : ''}</td><td>${dt(i.t)}</td>${allShops ? `<td>${esc(shopName(i.shop_id))}</td>` : ''}<td>${esc(i.cashier_name)}</td><td class="r">${i.items}</td><td class="r">${fCDF(i.total)}</td></tr>`).join('') || '<tr><td colspan="6">No invoices</td></tr>'}</tbody></table>
  <p style="margin-top:14px">All amounts in Congolese Francs, VAT ${vat}% included. Payments are in cash.</p>
  <div style="margin-top:26px">Signature ____________________</div></div>`;
}
