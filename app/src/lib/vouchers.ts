// Voucher lines as the Admin types them: one ledger with an amount in CDF, in USD, or both on the same line.
import type { Ledger } from './types';

export type VLine = { account: string; side: 'Dr' | 'Cr'; cdf: string; usd: string; rate: string; memo: string };
export type ApiLine = { account: string; side: 'Dr' | 'Cr'; amount: number; currency: 'USD' | 'FC'; rate: number; memo: string };

/** Where each part of a line goes. A shop's cash is two ledgers, one per currency (Cash – shop holds Francs, Cash USD –
 *  shop dollars): either one chosen, the Francs go to the first and the dollars to the second. Any other ledger takes both. */
export function lineTargets(account: string, ledgers: Pick<Ledger, 'id' | 'code'>[]) {
  const code = ledgers.find((l) => l.id === account)?.code ?? '', id = (c: string) => ledgers.find((l) => l.code === c)?.id;
  const m = /^CASH_SHOP(_USD)?:(.+)$/.exec(code);
  if (!m) return { cdf: account, usd: account };
  return { cdf: id('CASH_SHOP:' + m[2]) ?? account, usd: id('CASH_SHOP_USD:' + m[2]) ?? account };
}
/** What a line is worth in USD: the dollars, plus the Francs at the line's rate. */
export const lineBase = (l: VLine, rate0: number) => (Number(l.usd) || 0) + (Number(l.cdf) || 0) / (Number(l.rate) || rate0 || 1);
/** The lines sent to post_voucher: a line with both currencies becomes two, each to the ledger that holds it. */
export function apiLines(lines: VLine[], ledgers: Pick<Ledger, 'id' | 'code'>[], rate0: number): ApiLine[] {
  return lines.filter((l) => l.account).flatMap((l) => {
    const t = lineTargets(l.account, ledgers), rate = Number(l.rate) || rate0, out: ApiLine[] = [];
    if (Number(l.cdf) > 0) out.push({ account: t.cdf, side: l.side, amount: Number(l.cdf), currency: 'FC', rate, memo: l.memo });
    if (Number(l.usd) > 0) out.push({ account: t.usd, side: l.side, amount: Number(l.usd), currency: 'USD', rate, memo: l.memo });
    return out;
  });
}
