import { describe, expect, it } from 'vitest';
import { apiLines, lineBase, lineTargets, mergeCurrencies } from './vouchers';

const L = [{ id: 'ho', code: 'CASH_HO' }, { id: 'gc', code: 'CASH_SHOP:g1' }, { id: 'gu', code: 'CASH_SHOP_USD:g1' }, { id: 'bank', code: 'BANK' }];

describe('voucher lines in CDF and USD together', () => {
  it('a shop\'s cash sends the Francs to its Franc cash and the dollars to its USD cash, whichever was chosen', () => {
    expect(lineTargets('gc', L)).toEqual({ cdf: 'gc', usd: 'gu' });
    expect(lineTargets('gu', L)).toEqual({ cdf: 'gc', usd: 'gu' });
    expect(lineTargets('ho', L)).toEqual({ cdf: 'ho', usd: 'ho' });
  });
  it('one line with both currencies is posted as two', () => {
    const lines = apiLines([
      { account: 'ho', side: 'Dr', cdf: '5859100', usd: '710', rate: '2850', memo: '' },
      { account: 'gc', side: 'Cr', cdf: '5859100', usd: '710', rate: '2850', memo: 'cash taken' },
    ], L, 2850);
    expect(lines).toEqual([
      { account: 'ho', side: 'Dr', amount: 5859100, currency: 'FC', rate: 2850, memo: '' },
      { account: 'ho', side: 'Dr', amount: 710, currency: 'USD', rate: 2850, memo: '' },
      { account: 'gc', side: 'Cr', amount: 5859100, currency: 'FC', rate: 2850, memo: 'cash taken' },
      { account: 'gu', side: 'Cr', amount: 710, currency: 'USD', rate: 2850, memo: 'cash taken' },
    ]);
  });
  it('a line in one currency stays one line; empty lines are left out', () => {
    expect(apiLines([{ account: 'bank', side: 'Dr', cdf: '', usd: '100', rate: '2850', memo: '' }, { account: '', side: 'Cr', cdf: '1', usd: '', rate: '', memo: '' }], L, 2850))
      .toEqual([{ account: 'bank', side: 'Dr', amount: 100, currency: 'USD', rate: 2850, memo: '' }]);
  });
  it('is worth the dollars plus the Francs at its rate', () => expect(lineBase({ account: 'x', side: 'Dr', cdf: '28500', usd: '10', rate: '2850', memo: '' }, 2800)).toBe(20));
});

describe('one row for a line typed in CDF and USD', () => {
  const L = (no: string, side: 'Dr' | 'Cr', amount: number, currency: 'USD' | 'FC', base: number, memo = '') => ({ no, side, amount, currency, rate: 2850, base, memo });
  it('the two parts of a voucher line show as one row, value added up', () => {
    const m = mergeCurrencies([L('CV-1', 'Dr', 5859100, 'FC', 2055.82), L('CV-1', 'Dr', 710, 'USD', 710), L('CV-2', 'Dr', 100, 'USD', 100)], (l) => l.no);
    expect(m.map((r) => [r.no, r.cdf, r.usd, Math.round(r.base * 100) / 100])).toEqual([['CV-1', 5859100, 710, 2765.82], ['CV-2', 0, 100, 100]]);
  });
  it('never adds up two amounts in the same currency, other sides or other notes', () => {
    expect(mergeCurrencies([L('J-1', 'Dr', 100, 'USD', 100), L('J-1', 'Dr', 50, 'USD', 50)], (l) => l.no)).toHaveLength(2);
    expect(mergeCurrencies([L('J-1', 'Dr', 100, 'USD', 100), L('J-1', 'Cr', 28500, 'FC', 10)], (l) => l.no)).toHaveLength(2);
    expect(mergeCurrencies([L('J-1', 'Dr', 100, 'USD', 100, 'a'), L('J-1', 'Dr', 28500, 'FC', 10, 'b')], (l) => l.no)).toHaveLength(2);
  });
});
