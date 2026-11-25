// Money exchange at the shop counter: the shop buys dollars (takes USD, gives CDF) or sells them (takes CDF, gives USD).
import { fCDF } from './format';

export type FxDir = 'buy' | 'sell';

/** Francs for an exchange. Mirrors app.fx_cdf: Francs the shop gives out are rounded DOWN to 50 FC, Francs it takes in
 *  rounded UP to 50 FC. `exact` is before rounding; `gain` the shop's margin in USD at the internal rate (`book`), negative
 *  for a loss; `err` why it cannot be done ('' when it can). */
export function exchangeCalc(dir: FxDir, usd: number | string, rate: number | string, book: number) {
  const u = Math.round((Number(usd) || 0) * 100) / 100, r = Math.round((Number(rate) || 0) * 100) / 100;
  const exact = Math.round(u * r * 100) / 100;
  const cdf = u > 0 && r > 0 ? (dir === 'buy' ? Math.floor(exact / 50) : Math.ceil(exact / 50)) * 50 : 0;
  const gain = book > 0 && cdf > 0 ? Math.round((dir === 'buy' ? u - cdf / book : cdf / book - u) * 100) / 100 : 0;
  let err = '';
  if (u < 0 || Number(usd) < 0) err = 'Enter the dollars';
  else if (u > 100000) err = 'That is more dollars than one exchange can be';
  else if (u > 0 && !(r > 0)) err = 'Enter the exchange rate';
  else if (u > 0 && (r < book / 2 || r > book * 2)) err = `Check the exchange rate: ${fCDF(r)} is far from the internal rate (${fCDF(book)})`;
  else if (u > 0 && cdf <= 0) err = 'That is too few dollars to change';
  return { usd: u, rate: r, exact, cdf, rounded: Math.abs(cdf - exact), gain, err };
}
