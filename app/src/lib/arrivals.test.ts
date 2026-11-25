import { describe, expect, it } from 'vitest';
import { ago, arrivalTotals } from '../components/StockArrivals';

describe('stock arrived notice', () => {
  it('says how long ago', () => {
    const now = Date.parse('2026-11-25T12:00:00Z');
    expect(ago('2026-11-25T11:59:40Z', now)).toBe('just now');
    expect(ago('2026-11-25T11:55:00Z', now)).toBe('5 min ago');
    expect(ago('2026-11-25T09:00:00Z', now)).toBe('3 h ago');
  });
  it('counts each item once across arrivals, and every unit', () => {
    const t = arrivalTotals([
      { stock_arrival_items: [{ product_id: 'a', qty: 4 }, { product_id: 'b', qty: 2 }] },
      { stock_arrival_items: [{ product_id: 'a', qty: 5 }] },
    ]);
    expect(t).toEqual({ items: 2, units: 11 });
  });
});
