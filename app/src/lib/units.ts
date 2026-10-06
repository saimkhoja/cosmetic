import type { Product } from './types';
import { toCDF } from './format';

export interface Unit { u: string; mult: number; piece?: boolean; usd: number }

/** Selling units for an item, in the same order the server checks them. */
export function unitsOf(p: Product): Unit[] {
  if (p.is_bundle) return [{ u: 'set', mult: 1, usd: p.price_usd }, { u: 'piece', mult: 0, piece: true, usd: p.piece_usd }];
  const u: Unit[] = [{ u: 'pcs', mult: 1, usd: p.price_usd }];
  if (p.dozen_usd > 0 && p.per_carton !== 12) u.push({ u: 'dzn', mult: 12, usd: p.dozen_usd });
  u.push({ u: 'carton', mult: p.per_carton, usd: p.carton_usd });
  return u;
}
export const unitLabel = (u: Unit) => (u.piece ? '1 piece' : u.u);
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
/** Totals of a sale: discount rounded to 10 FC, VAT included in the price. */
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
