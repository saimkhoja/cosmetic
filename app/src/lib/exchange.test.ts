import { describe, expect, it } from 'vitest';
import { exchangeCalc } from './exchange';

describe('money exchange at the counter', () => {
  it('the shop buys dollars: Francs out, rounded down to 50', () => {
    expect(exchangeCalc('buy', 100, 2800, 2950)).toMatchObject({ cdf: 280000, gain: 5.08, err: '' });
    expect(exchangeCalc('buy', 33.33, 2800, 2950)).toMatchObject({ exact: 93324, cdf: 93300, rounded: 24 });
  });
  it('the shop sells dollars: Francs in, rounded up to 50; below the internal rate it is a loss', () => {
    expect(exchangeCalc('sell', 33.33, 2900, 2950)).toMatchObject({ exact: 96657, cdf: 96700, rounded: 43 });
    expect(exchangeCalc('sell', 50, 2900, 2950).gain).toBe(-0.85);
  });
  it('catches a rate typed wrong', () => expect(exchangeCalc('buy', 10, 280, 2950).err).toMatch(/Check the exchange rate/));
  it('nothing to change yet', () => expect(exchangeCalc('buy', '', 2800, 2950)).toMatchObject({ cdf: 0, err: '' }));
});
