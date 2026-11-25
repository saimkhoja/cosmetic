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

/** A vendeur's payment in Francs, dollars or both. Mirrors vendeur_pay on the server: the dollars count at `rate`
 *  (the internal rate unless the Shop Admin typed the taux agreed), the payment takes off at most what is owed, and
 *  dollars worth more than that get the rest back in Francs. `err` says why it cannot be taken; '' when it can. */
export function vendeurPayment(balance: number, usd: number | string, cdf: number | string, rate: number | string, book: number) {
  const u = Math.max(0, Math.round((Number(usd) || 0) * 100) / 100), c = Number(cdf) || 0, r = Math.round((Number(rate) || 0) * 100) / 100;
  const usdFc = u > 0 && r > 0 ? Math.round(u * r) : 0, value = Math.max(0, c) + usdFc;
  let err = '';
  if (c < 0 || u < 0) err = 'Amounts paid cannot be negative';
  else if (c % 1) err = 'Enter the Francs paid as a whole number';
  else if (u > 0 && !(r > 0)) err = 'Enter the exchange rate for the dollars';
  else if (u > 0 && (r < book / 2 || r > book * 2)) err = `Check the exchange rate: ${fCDF(r)} is far from the internal rate (${fCDF(book)})`;
  else if (value > balance && u === 0) err = `Owes only ${fCDF(balance)}`;
  else if (value > balance && c >= balance) err = `The Francs alone pay all that is owed (${fCDF(balance)}): take no dollars`;
  const change = !err && value > balance ? value - balance : 0, amount = value - change;
  // the whole dollars that pay it all at this rate (the rest comes back in Francs)
  const allUsd = r > 0 ? Math.ceil(balance / r) : 0;
  return { usd: u, cdf: c, rate: r, usdFc, value, amount, change, after: balance - amount, allUsd, typed: u > 0 && r !== book, err };
}
