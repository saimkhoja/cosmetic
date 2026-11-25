import { describe, expect, it } from 'vitest';
import { navFor } from '../components/Layout';

const paths = (...a: Parameters<typeof navFor>) => navFor(...a).map((n) => n[0]);

describe('menus without a central store', () => {
  it('keeps Returns for the Shop Admin and the Admin, who decides where returned goods go', () => {
    expect(paths('admin', { no_warehouse: true })).toContain('/returns');
    expect(paths('shopadmin', { no_warehouse: true })).toContain('/returns');
  });
  it('still hides the central store\'s own pages', () => {
    for (const p of ['/requests', '/deliveries', '/received']) {
      expect(paths('admin', { no_warehouse: true })).not.toContain(p);
      expect(paths('shopadmin', { no_warehouse: true })).not.toContain(p);
    }
    expect(paths('whop', { no_warehouse: true })).not.toContain('/returns');
  });
  it('shows every store page with a central store', () => {
    expect(paths('admin', {})).toEqual(expect.arrayContaining(['/requests', '/deliveries', '/returns']));
  });
});

describe('money exchange', () => {
  it('the Exchange tab shows only when it is turned on in Settings', () => {
    expect(paths('shopadmin', {})).not.toContain('/exchange');
    expect(paths('admin', {})).not.toContain('/exchange');
    expect(paths('shopadmin', { money_exchange: true })).toContain('/exchange');
    expect(paths('admin', { money_exchange: true })).toContain('/exchange');
    expect(paths('till', { money_exchange: true })).not.toContain('/exchange');
  });
});
