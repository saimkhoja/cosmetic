import { describe, expect, it } from 'vitest';
import { creditWarnings, ddmm } from './vendeurs';
import type { VendeurState } from './types';

const base: VendeurState & { name: string; credit_limit: number } = { name: 'Papa Jean', credit_limit: 20000, balance: 5000, available: 15000, over_limit: false,
  overdue: false, overdue_amount: 0, oldest_due: '2026-11-29', days_overdue: 0, open: [], last_payment: null, promo_open: 0, promo_open_n: 0 };

describe('goods on credit', () => {
  it('says nothing when the vendeur is on time and under the limit', () => expect(creditWarnings(base, 15000)).toEqual([]));
  it('reminds that a payment is due, but still allows the goods', () => {
    const w = creditWarnings({ ...base, overdue: true, overdue_amount: 4400, days_overdue: 3, oldest_due: '2026-11-19' }, 1000);
    expect(w).toEqual(["Papa Jean's payment is due: 4 400 CDF overdue for 3 days (since 19/11/2026)."]);
  });
  it('warns when these goods pass the credit limit', () => {
    expect(creditWarnings(base, 15001)[0]).toBe('With these goods Papa Jean owes 20 001 CDF, over the credit limit of 20 000 CDF by 1 CDF.');
    expect(creditWarnings({ ...base, overdue: true, overdue_amount: 1, days_overdue: 1 }, 20000)).toHaveLength(2);
  });
  it('writes dates the Congolese way', () => expect(ddmm('2026-01-05')).toBe('05/01/2026'));
});
