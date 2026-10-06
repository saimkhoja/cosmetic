// Item form validation; the same rules run again on the server (app.product_fields).
import { fUSD } from './format';

export interface ItemInput {
  name: string; category: string; is_bundle: boolean;
  carton_cost: number; per_carton: number; pc: number; dzn: number; ctn: number;
  set_cost: number; set_price: number; pcs: number; piece: number;
}
export function itemProblem(o: ItemInput): string | null {
  if (!o.name.trim()) return 'Enter the item name';
  if (!o.category.trim()) return 'Enter the category';
  if (o.is_bundle) {
    if (!(o.set_cost >= 0) || !(o.set_price > 0)) return 'Enter the cost and selling price of one set';
    if (o.set_price < o.set_cost) return 'Set price cannot be below its cost';
    if (!(o.pcs > 1) || o.pcs % 1 || !(o.piece > 0)) return 'For a mixed set, enter the pieces per set and the last price for one piece';
    return null;
  }
  if (!(o.carton_cost >= 0)) return 'Enter the cost of one carton';
  if (!(o.per_carton >= 2) || o.per_carton % 1) return 'Enter how many pcs are in one carton (2 or more)';
  if (!(o.pc > 0)) return 'Enter the selling price per pc';
  if (!(o.ctn > 0)) return 'Enter the selling price per carton';
  if (o.dzn < 0) return 'Price per dozen cannot be negative';
  const cpc = o.carton_cost / o.per_carton, dzn = o.per_carton === 12 ? 0 : o.dzn || 0;
  if (o.pc < cpc - 1e-9) return `Price per pc is below the cost of one pc (${fUSD(cpc)})`;
  if (dzn > 0 && dzn < cpc * 12 - 1e-9) return `Price per dozen is below the cost of 12 pcs (${fUSD(cpc * 12)})`;
  if (o.ctn < o.carton_cost) return 'Price per carton cannot be below the carton cost';
  return null;
}
export const CATS = ['Skin care', 'Hair care', 'Make-up', 'Fragrance', 'Bath & body', 'Accessories'];
export const CATICON: Record<string, string> = { All: 'grid', 'Skin care': 'lotion', 'Hair care': 'comb', 'Make-up': 'lipstick', Fragrance: 'perfume', 'Bath & body': 'soap', Accessories: 'mirror' };
export const UPCATS = ['Rent', 'Electricity & fuel', 'Security', 'Salaries', 'Transport', 'Maintenance', 'Taxes & licences', 'Other'];
