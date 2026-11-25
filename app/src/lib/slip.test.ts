import { describe, expect, it } from 'vitest';
import { shiftSlipHTML, type Slip } from './print';

const text = (h: string) => h.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
const base: Slip = { shop_name: 'Gombe', n: 3, value_fc: 60000, value_usd: 21.05, collected: 60000, returned: 0, collected_usd: 0, collected_cdf: 60000 };

describe('shift end report', () => {
  it('a shop without vendeurs, exchanges or expenses gets the slip it always had', () => {
    const t = text(shiftSlipHTML({ ...base, vendeur_usd: 0, vendeur_cdf: 0, vendeur_paid: 0, fx_usd: 0, fx_cdf: 0, fx_n: 0, exp_usd: 0, exp_cdf: 0, exp_n: 0, vendeurs: [] }, 'shopadmin', '2026-11-20', 2850));
    for (const w of ['Vendeurs', 'Cash sales', 'Exchange', 'Expenses']) expect(t).not.toContain(w);
    expect(t).toContain('Balance USD : 0.000');
    expect(t).toContain('Balance CDF : 60000');
    // and the same from a server that does not send the new figures yet
    expect(text(shiftSlipHTML(base, 'shopadmin', '2026-11-20', 2850))).toBe(t);
  });
  it('shows the cash sales, each vendeur by name, the exchanges and the expenses, and a balance that matches the drawer', () => {
    const t = text(shiftSlipHTML({ ...base, collected: 120000, collected_usd: 45, collected_cdf: 90000, vendeur_paid: 85000, vendeur_usd: 25, vendeur_cdf: 30000,
      vendeurs: [{ name: 'Papa Jean', usd: 25, cdf: 0 }, { name: 'Maman Rose', usd: 0, cdf: 30000 }],
      fx_usd: 50, fx_cdf: -135000, fx_n: 2, exp_usd: 5, exp_cdf: 20000, exp_n: 2 }, 'shopadmin', '2026-11-20', 2850));
    expect(t).toContain('Cash sales USD : 20.000');
    expect(t).toContain('Cash sales CDF : 60000');
    expect(t).toContain('Papa Jean USD : 25.000');
    expect(t).toContain('Maman Rose CDF : 30000');
    expect(t).not.toContain('Papa Jean CDF');
    expect(t).toContain('Exchange USD : +50.000');
    expect(t).toContain('Exchange CDF : -135000');
    expect(t).toContain('Expenses USD : -5.000');
    expect(t).toContain('Expenses CDF : -20000');
    expect(t).toContain('Balance USD : 90.000');       // 45 + 50 - 5
    expect(t).toContain('Balance CDF : -65000');      // 90 000 + (-135 000) - 20 000
  });
});
