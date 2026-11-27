import { describe, expect, it } from 'vitest';
import { creditWarnings, ddmm, vendeurPayment } from './vendeurs';
import type { VendeurState } from './types';

const base: VendeurState & { name: string; credit_limit_usd: number } = { name: 'Papa Jean', credit_limit_usd: 100, balance: 20, available: 80, over_limit: false,
  overdue: false, overdue_amount: 0, oldest_due: '2026-11-29', days_overdue: 0, open: [], last_payment: null, promo_open: 0, promo_open_n: 0 };

describe('goods on credit, owed in USD', () => {
  it('says nothing when the vendeur is on time and under the limit', () => expect(creditWarnings(base, 80)).toEqual([]));
  it('reminds that a payment is due, but still allows the goods', () => {
    const w = creditWarnings({ ...base, overdue: true, overdue_amount: 4.4, days_overdue: 3, oldest_due: '2026-11-19' }, 1);
    expect(w).toEqual(["Papa Jean's payment is due: $4.40 overdue for 3 days (since 19/11/2026)."]);
  });
  it('warns when these goods pass the credit limit', () => {
    expect(creditWarnings(base, 80.01)[0]).toBe('With these goods Papa Jean owes $100.01, over the credit limit of $100.00 by $0.01.');
    expect(creditWarnings({ ...base, overdue: true, overdue_amount: 1, days_overdue: 1 }, 90)).toHaveLength(2);
  });
  it('writes dates the way the shop reads them', () => expect(ddmm('2026-11-29')).toBe('29/11/2026'));
});

describe('vendeur payments off a USD debt', () => {
  it('dollars count one for one, Francs at the taux', () => {
    expect(vendeurPayment(10, 5, 1000, 2850, 2850)).toMatchObject({ value: 5.35, amount: 5.35, change: 0, after: 4.65, typed: false, err: '' });
  });
  it('dollars worth more than is owed get the rest back in Francs, rounded down to 50', () => {
    expect(vendeurPayment(4.65, 20, '', 2700, 2850)).toMatchObject({ amount: 4.65, change: 41400, after: 0, err: '' });
  });
  it('Francs only: up to 49 FC over is the rounding to 50, more is too much', () => {
    expect(vendeurPayment(4.65, '', 13300, 2850, 2850)).toMatchObject({ amount: 4.65, after: 0, err: '' }); // 4.65 x 2 850 = 13 252.5
    expect(vendeurPayment(4.65, '', 13350, 2850, 2850).err).toBe('Owes only $4.65 (13 300 CDF at 2850)');
  });
  it('catches a taux typed wrong and dollars that are not needed', () => {
    expect(vendeurPayment(10, '', 5000, 280, 2850).err).toMatch(/Check the exchange rate/);
    expect(vendeurPayment(10, 1, 28500, 2850, 2850).err).toMatch(/Francs alone/);
  });
  it('says how to pay it all: whole dollars, or Francs rounded up to 50', () => {
    expect(vendeurPayment(4.65, '', '', 2850, 2850)).toMatchObject({ allUsd: 5, allCdf: 13300 });
  });
});
