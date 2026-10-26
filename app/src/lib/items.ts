// Item form validation; the same rules run again on the server (app.product_fields).
import { fUSD } from './format';

export interface ItemInput {
  name: string; category: string; is_bundle: boolean;
  carton_cost: number; per_carton: number; pc: number; half: number; dzn: number; ctn: number;
  set_cost: number; set_price: number; pcs: number; piece: number;
}
export function itemProblem(o: ItemInput): string | null {
  if (!o.name.trim()) return 'Enter the item name';
  if (!o.category.trim()) return 'Choose the category';
  if (o.is_bundle) {
    if (!(o.set_cost >= 0) || !(o.set_price > 0)) return 'Enter the cost and selling price of one set';
    if (o.set_price < o.set_cost) return 'Set price cannot be below its cost';
    if (!(o.pcs > 1) || o.pcs % 1 || !(o.piece > 0)) return 'For a mixed set, enter the pieces per set and the last price for one piece';
    return null;
  }
  if (!(o.carton_cost >= 0)) return 'Enter the cost of one carton';
  if (!(o.per_carton >= 1) || o.per_carton % 1) return 'Enter how many pcs are in one carton (1 or more)';
  // one pc per carton: the carton price is the price per pc, as on the server
  const pc = o.pc || (o.per_carton === 1 ? o.ctn || 0 : 0);
  if (pc < 0 || (o.dzn || 0) < 0 || (o.half || 0) < 0 || (o.ctn || 0) < 0) return 'Prices cannot be negative';
  // a carton of 12 (or 6) is the dozen (or half dozen): that price is the carton price, as on the server
  const cpc = o.carton_cost / o.per_carton, dzn = o.per_carton === 12 ? 0 : o.dzn || 0, half = o.per_carton === 6 ? 0 : o.half || 0;
  const ctn = o.per_carton === 1 ? 0 : o.ctn || (o.per_carton === 12 ? o.dzn || 0 : o.per_carton === 6 ? o.half || 0 : 0);
  if (!pc && !half && !dzn && !ctn) return 'Enter at least one selling price: per pc, half dozen, dozen or carton';
  if (pc > 0 && pc < cpc - 1e-9) return `Price per pc is below the cost of one pc (${fUSD(cpc)})`;
  if (half > 0 && half < cpc * 6 - 1e-9) return `Price per half dozen is below the cost of 6 pcs (${fUSD(cpc * 6)})`;
  if (dzn > 0 && dzn < cpc * 12 - 1e-9) return `Price per dozen is below the cost of 12 pcs (${fUSD(cpc * 12)})`;
  if (ctn > 0 && ctn < o.carton_cost) return 'Price per carton cannot be below the carton cost';
  return null;
}
const CATICON: Record<string, string> = { all: 'grid', skin: 'lotion', hair: 'comb', make: 'lipstick', lip: 'lipstick', frag: 'perfume', perf: 'perfume', bath: 'soap', soap: 'soap', body: 'soap', acc: 'mirror', brush: 'mirror', school: 'doc', station: 'doc', gift: 'gift' };
/** Icon for a category the Admin named: matched on the first word. */
export const catIcon = (c: string) => { const k = c.toLowerCase(); const hit = Object.keys(CATICON).find((x) => k.startsWith(x) || k.includes(' ' + x)); return hit ? CATICON[hit] : 'box'; };
export const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
export const UPCATS = ['Rent', 'Electricity & fuel', 'Security', 'Salaries', 'Transport', 'Maintenance', 'Taxes & licences', 'Other'];
/** An item's barcodes: all of them, or the single one an older database keeps. */
export const barcodesOf = (p: { barcode?: string | null; barcodes?: string[] | null }) => (p.barcodes?.length ? p.barcodes : p.barcode ? [p.barcode] : []);
/** Barcodes as typed or imported: separated by , ; or | (or new lines), spaces removed, repeats dropped. */
export const splitBarcodes = (v: string) => [...new Set(v.split(/[,;|\n\r]+/).map((x) => x.replace(/\s+/g, '')).filter(Boolean))];
/** A scanned or typed code: the item with that barcode (any of its barcodes), else the item with that SIM code. */
export const findByCode = <T extends { sku: string; barcode?: string | null; barcodes?: string[] | null }>(products: T[], code: string): T | undefined => {
  const c = code.replace(/\s+/g, ''); if (!c) return undefined;
  return products.find((p) => barcodesOf(p).includes(c)) ?? products.find((p) => p.sku.toLowerCase() === c.toLowerCase());
};
/** How a sale or order without a customer name is shown. */
export const custName = (c?: string | null) => c || 'Walk-in';
/** A barcode scanned into a quantity box by mistake: the item it names and the digits typed before it, or null. */
export const scanInQty = <T extends { barcode?: string | null; barcodes?: string[] | null }>(products: T[], v: string): { qty: string; p: T } | null => {
  const s = v.replace(/\s+/g, '');
  for (let i = 0; i + 6 <= s.length && /^\d*$/.test(s.slice(0, i)); i++) { const p = products.find((x) => barcodesOf(x).includes(s.slice(i))); if (p) return { qty: s.slice(0, i), p }; }
  return null;
};
/** Rows of a goods in, delivery or return list in a fixed order that never changes when a quantity is typed.
 *  A search puts its matches first; the rest follow. Rows with a quantity are always kept. */
export function pickList<T extends { id: string; name: string; sku: string; category: string; barcode?: string | null; barcodes?: string[] | null }>(all: T[], shown: (p: T) => boolean, keep: (p: T) => boolean, q: string, max = 200) {
  const ql = q.trim().toLowerCase();
  const hit = (p: T) => (p.name + ' ' + p.sku + ' ' + p.category + ' ' + barcodesOf(p).join(' ')).toLowerCase().includes(ql);
  const hits = ql ? all.filter(hit).slice(0, max) : [], ids = new Set(hits.map((p) => p.id));
  let n = hits.length;
  const rest = all.filter((p) => !ids.has(p.id) && (keep(p) || (shown(p) && n++ < max)));
  return { hits, rest };
}
