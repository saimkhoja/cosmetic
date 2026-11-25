import { describe, expect, it } from 'vitest';
import { creditWarnings, ddmm, vendeurPayment } from './vendeurs';
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

describe('vendeur payments in dollars and Francs', () => {
  it('counts the dollars at the internal rate, with the Francs on top', () => {
    expect(vendeurPayment(28500, 5, 1000, 2800, 2800)).toMatchObject({ usdFc: 14000, value: 15000, amount: 15000, change: 0, after: 13500, typed: false, err: '' });
  });
  it('takes a taux typed by the Shop Admin and gives the rest back in Francs', () => {
    expect(vendeurPayment(13500, 20, '', 2700, 2800)).toMatchObject({ usdFc: 54000, amount: 13500, change: 40500, after: 0, typed: true, err: '' });
  });
  it('Francs only work as before', () => {
    expect(vendeurPayment(13500, '', 13500, 2800, 2800)).toMatchObject({ amount: 13500, change: 0, err: '' });
    expect(vendeurPayment(13500, '', 13501, 2800, 2800).err).toBe('Owes only 13 500 CDF');
  });
  it('catches a taux typed wrong and dollars that are not needed', () => {
    expect(vendeurPayment(13500, 5, '', 280, 2800).err).toMatch(/Check the exchange rate/);
    expect(vendeurPayment(13500, 1, 13500, 2800, 2800).err).toMatch(/Francs alone/);
  });
  it('says how many whole dollars pay it all', () => expect(vendeurPayment(13500, '', '', 2800, 2800).allUsd).toBe(5));
});
