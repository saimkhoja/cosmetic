import { describe, expect, it } from 'vitest';
import { apiLines, lineBase, lineTargets } from './vouchers';

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
