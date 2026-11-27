// Vendeurs: what the till and the Vendeurs tab say about a vendeur. What a vendeur owes is kept in USD.
import { fCDF, fUSD } from './format';
import type { VendeurState } from './types';

/** 2026-11-29 as 29/11/2026 */
export const ddmm = (d: string) => `${d.slice(8, 10)}/${d.slice(5, 7)}/${d.slice(0, 4)}`;
/** Cents, as the server keeps dollars. */
const c2 = (n: number) => Math.round((Number(n) || 0) * 100) / 100;

/** The reminders before goods are given on credit: the vendeur is overdue, or these goods take them over the limit.
 *  `adding` is the goods' value in USD (their Francs at the sales rate). The goods can still be given; the reminders only say so. */
export function creditWarnings(v: VendeurState & { name: string; credit_limit_usd: number }, adding: number): string[] {
  const w: string[] = [], after = c2(v.balance + adding);
  if (v.overdue) w.push(`${v.name}'s payment is due: ${fUSD(v.overdue_amount)} overdue for ${v.days_overdue} day${v.days_overdue === 1 ? '' : 's'} (since ${v.oldest_due ? ddmm(v.oldest_due) : '-'}).`);
  if (after > v.credit_limit_usd) w.push(`With these goods ${v.name} owes ${fUSD(after)}, over the credit limit of ${fUSD(v.credit_limit_usd)} by ${fUSD(c2(after - v.credit_limit_usd))}.`);
  return w;
}

/** A vendeur's payment in dollars, Francs or both, off what they owe in USD. Mirrors vendeur_pay on the server: dollars
 *  count one for one, Francs at `rate` (the internal rate unless the Shop Admin typed the taux agreed). Paid in Francs
 *  only, up to 49 FC over is the rounding to 50 FC; dollars worth more than is owed get the rest back in Francs, rounded
 *  down to 50 FC. `err` says why it cannot be taken; '' when it can. */
export function vendeurPayment(balance: number, usd: number | string, cdf: number | string, rate: number | string, book: number) {
  const u = Math.max(0, c2(Number(usd) || 0)), c = Number(cdf) || 0, r = c2(Number(rate) || 0), bal = c2(balance);
  const value = r > 0 ? c2(u + Math.max(0, c) / r) : u;
  let err = '', change = 0;
  if (c < 0 || u < 0) err = 'Amounts paid cannot be negative';
  else if (c % 1) err = 'Enter the Francs paid as a whole number';
  else if (c > 0 && !(r > 0)) err = 'Enter the taux for the Francs';
  else if (c > 0 && (r < book / 2 || r > book * 2)) err = `Check the exchange rate: ${fCDF(r)} is far from the internal rate (${fCDF(book)})`;
  else if (value > bal) {
    if (u === 0) { if (c - bal * r >= 50) err = `Owes only ${fUSD(bal)} (${fCDF(Math.ceil((bal * r) / 50) * 50)} at ${r})`; }
    else if (c2(c / r) >= bal) err = `The Francs alone pay all that is owed (${fUSD(bal)}): take no dollars`;
    else change = Math.floor(((value - bal) * r) / 50) * 50;
  }
  const amount = err ? 0 : Math.min(c2(u + (c - change) / (r || 1)), bal);
  return {
    usd: u, cdf: c, rate: r, value, change, amount, after: c2(bal - amount), err, typed: c > 0 && r !== book,
    // to pay it all: whole dollars, or Francs at the taux rounded up to 50 FC
    allUsd: Math.ceil(bal), allCdf: r > 0 ? Math.ceil((bal * r) / 50) * 50 : 0,
  };
}
