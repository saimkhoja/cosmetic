// Vendeurs: what the till and the Vendeurs tab say about a vendeur before goods are given on credit.
import { fCDF } from './format';
import type { VendeurState } from './types';

/** 2026-11-29 as 29/11/2026 */
export const ddmm = (d: string) => `${d.slice(8, 10)}/${d.slice(5, 7)}/${d.slice(0, 4)}`;

/** The reminders before goods are given on credit: the vendeur is overdue, or these goods take them over the limit.
 *  The goods can still be given; the reminders only say so. */
export function creditWarnings(v: VendeurState & { name: string; credit_limit: number }, adding: number): string[] {
  const w: string[] = [];
  if (v.overdue) w.push(`${v.name}'s payment is due: ${fCDF(v.overdue_amount)} overdue for ${v.days_overdue} day${v.days_overdue === 1 ? '' : 's'} (since ${v.oldest_due ? ddmm(v.oldest_due) : '-'}).`);
  if (v.balance + adding > v.credit_limit) w.push(`With these goods ${v.name} owes ${fCDF(v.balance + adding)}, over the credit limit of ${fCDF(v.credit_limit)} by ${fCDF(v.balance + adding - v.credit_limit)}.`);
  return w;
}
