import type { Product, Rank } from './types';
import { toCDF } from './format';

export interface Unit { u: string; mult: number; piece?: boolean; usd: number }

/** Selling units for an item, in the same order the server checks them. */
export function unitsOf(p: Product): Unit[] {
  if (p.is_bundle) return [{ u: 'set', mult: 1, usd: p.price_usd }, { u: 'piece', mult: 0, piece: true, usd: p.piece_usd }];
  const u: Unit[] = p.price_usd > 0 ? [{ u: 'pcs', mult: 1, usd: p.price_usd }] : [];
  if (p.half_dozen_usd > 0 && p.per_carton !== 6) u.push({ u: 'half dzn', mult: 6, usd: p.half_dozen_usd });
  if (p.dozen_usd > 0 && p.per_carton !== 12) u.push({ u: 'dzn', mult: 12, usd: p.dozen_usd });
  if (p.carton_usd > 0) u.push({ u: 'carton', mult: p.per_carton, usd: p.carton_usd });
  return u;
}
export const unitLabel = (u: Unit) => (u.piece ? '1 piece' : u.u);
/** Value of one pc (or set) at selling price, from the first unit that has a price. Mirrors app.pc_value. */
export function pcValue(p: Product) {
  if (p.is_bundle || p.price_usd > 0) return p.price_usd;
  if (p.half_dozen_usd > 0) return p.half_dozen_usd / 6;
  if (p.dozen_usd > 0) return p.dozen_usd / 12;
  return p.carton_usd > 0 && p.per_carton > 0 ? p.carton_usd / p.per_carton : 0;
}
export function unitNote(p: Product, u: Unit) {
  return u.piece ? `single piece from an open ${p.stock_unit}` : u.mult > 1 ? `${u.mult} ${p.stock_unit}` : `single ${p.stock_unit}`;
}
/** "3 ctn + 4 pcs" for carton items, '' otherwise. */
export function ctnTxt(p: Pick<Product, 'is_bundle' | 'per_carton'>, q: number) {
  const per = p.per_carton || 0, a = Math.abs(q || 0);
  if (p.is_bundle || per < 2 || a < per) return '';
  const c = Math.floor(a / per), r = a % per;
  return `${q < 0 ? '-' : ''}${c} ctn${r ? ` + ${r} pcs` : ''}`;
}

export interface CartLine { pid: string; ui: number; qty: number }
/** Totals of a sale: discount rounded to 10 CDF, VAT included in the price. */
export function totals(lines: { price: number; qty: number }[], dp: number, vatRate: number) {
  const gross = lines.reduce((s, l) => s + l.price * l.qty, 0);
  const disc = Math.round((gross * (dp || 0)) / 1000) * 10, total = gross - disc, vat = Math.round((total * vatRate) / (100 + vatRate));
  return { gross, disc, total, vat, ht: total - vat, count: lines.reduce((s, l) => s + l.qty, 0) };
}
export function cartPriced(cart: CartLine[], byId: Map<string, Product>, rate: number) {
  return cart.map((l) => { const p = byId.get(l.pid)!, u = unitsOf(p)[l.ui] ?? unitsOf(p)[0]; return { ...l, p, u, price: toCDF(u.usd, rate) }; });
}

/** Stock taken by a sold line (pieces of a mixed set open a set when needed). Mirrors app.take on the server. */
export function takeLocal(st: { qty: number; open_pieces: number }, qty: number, mult: number, piece: boolean, per: number) {
  if (piece) { const o = st.open_pieces + qty, k = Math.floor(o / Math.max(per, 1)); return { qty: st.qty - k, open_pieces: o % Math.max(per, 1) }; }
  return { qty: st.qty - qty * mult, open_pieces: st.open_pieces };
}

/** Hot items first: in-season items by units sold in the last 30 days, then the rest; seasonal items out of season last. */
export function hotSort<T extends Pick<Product, 'id' | 'name'>>(list: T[], ranks?: Rank[] | null): T[] {
  if (!ranks?.length) return list;
  const r = new Map(ranks.map((x) => [x.product_id, x]));
  const key = (p: T) => { const x = r.get(p.id); return { s: x ? (x.in_season ? 0 : 1) : 0, n: x ? Number(x.sold_30) : 0 }; };
  return [...list].sort((a, b) => { const x = key(a), y = key(b); return x.s - y.s || y.n - x.n || a.name.localeCompare(b.name); });
}
/** "Hot" when it is among the 12 best sellers of the last 30 days. */
export function hotSet(ranks?: Rank[] | null) {
  return new Set((ranks ?? []).filter((x) => x.in_season && Number(x.sold_30) > 0).sort((a, b) => Number(b.sold_30) - Number(a.sold_30)).slice(0, 12).map((x) => x.product_id));
}
/** Quick amounts for the cash received: the exact total, then the next round 1 000, 5 000 and 10 000 CDF above it. */
export function cashNotes(total: number) {
  const up = (n: number) => Math.ceil(total / n) * n;
  return [...new Set([total, up(1000), up(5000), up(10000)])].filter((n) => n >= total && n > 0);
}
/** Cash handed over at the till, in Francs and (when allowed) dollars at the sale's rate. Mirrors submit_invoice. */
export interface PayIn { tendered: number; paid_usd: number; paid_cdf: number; change_usd: number }
export function payment(total: number, rate: number, usd: number | string, cdf: number | string, dollarsBack = false) {
  const u = Math.max(0, Math.round((Number(usd) || 0) * 100) / 100), c = Math.max(0, Math.round(Number(cdf) || 0));
  const value = c + Math.round(u * rate), change = Math.max(0, value - total), short = Math.max(0, total - value);
  // whole dollars that fit in the change, never more than the dollars received
  const maxDollars = rate > 0 ? Math.max(0, Math.min(Math.floor(u), Math.floor(change / rate))) : 0;
  const changeUsd = dollarsBack ? maxDollars : 0, changeCdf = change - Math.round(changeUsd * rate);
  const pay: PayIn = { tendered: value, paid_usd: u, paid_cdf: c, change_usd: changeUsd };
  return { usd: u, cdf: c, value, change, short, maxDollars, changeUsd, changeCdf, pay, due: rate > 0 ? Math.ceil((total / rate) * 100) / 100 : 0 };
}
/** USD notes worth offering: the smallest ones that cover what is due, and the common bigger ones. */
export const usdNotes = (due: number) => { const up = [1, 5, 10, 20, 50, 100].filter((n) => n >= due).slice(0, 3); return up.length ? up : [100]; };
/** Margin as a mark-up on cost: cost + margin % = selling price (cost 0.90, price 1.28 -> 42%). Null when there is no cost. */
export const marginPct = (price: number, cost: number) => (cost > 0 ? Math.round(((price - cost) / cost) * 100) : null);
