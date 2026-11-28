import { describe, expect, it } from 'vitest';
import { IMPCOLS, impParse, impStock } from './xlsx';

const P = (id: string, name: string, extra = {}) => ({ id, name, sku: 'SK-' + id, active: true, is_bundle: false, per_carton: 24, barcodes: [] as string[], ...extra });
const known = [P('1', 'Shea body lotion 400 ml', { barcodes: ['6001234567890'] }), P('2', 'Brush set', { is_bundle: true, per_carton: 0 }), P('3', 'Old soap', { active: false })];
// the item template's columns: Name, Category, Gross, Net, Pcs per carton, (Cost per pc), pc, half, dozen, carton, Opening cartons, Opening pcs, Reorder, SKU, Barcode
// the rows below are written without the cost per pc; it goes in empty after the pcs per carton
const row = (...v: (string | number)[]) => [...v.slice(0, 5), '', ...v.slice(5)];

describe('adding stock from the item template', () => {
  it('has the gross and the net carton cost', () => expect(IMPCOLS.slice(2, 4)).toEqual(['Gross carton cost USD', 'Net carton cost USD']));
  it('adds the quantity of items already in the catalogue, matched by name, code or barcode, with their own pcs per carton', () => {
    const r = impStock([IMPCOLS, row('shea BODY lotion 400 ml', '', '', '', 12, '', '', '', '', 2, 5), row('Other name', '', '', '', '', '', '', '', '', 0, 3, '', '', '6001234567890'),
      row('Brushes', '', '', '', '', '', '', '', '', 9, 4, '', 'SK-2')], known);
    expect(r.map((x) => [x.kind, x.product_id, x.qty])).toEqual([['existing', '1', 53], ['existing', '1', 3], ['existing', '2', 4]]);
  });
  it('makes complete new rows into new items, with the net cost', () => {
    const r = impStock([IMPCOLS, row('Import mask', 'Face', 24, 18, 12, 2.5, '', '', 28, 2, 3)], known);
    expect(r[0]).toMatchObject({ kind: 'new', qty: 27, product_id: null });
    expect(r[0].row.o.net_cost).toBe(18);
  });
  it('flags new rows with errors, archived items and rows with nothing to add', () => {
    const r = impStock([IMPCOLS, row('Cheap', 'Face', 24, '', 12, 1), row('Soap', '', '', '', '', '', '', '', '', 1, 0, '', 'SK-3'), row('Shea body lotion 400 ml', '', '', '', '', '', '', '', '', 0, 0),
      row('Twice', 'Face', 12, '', 12, 2), row('Twice', 'Face', 12, '', 12, 2)], known);
    expect(r.map((x) => x.kind)).toEqual(['bad', 'bad', 'none', 'new', 'bad']);
    expect(r[0].msg).toMatch(/below the cost/);
    expect(r[1].msg).toMatch(/archived/);
    expect(r[4].msg).toMatch(/twice/);
  });
});

describe('the cost per pc column', () => {
  const H = ['Name', 'Category', 'Gross carton cost USD', 'Net carton cost USD', 'Pcs per carton', 'Cost per pc USD', 'Price per pc USD'];
  it('is in the template, after the pcs per carton', () => expect(IMPCOLS.slice(4, 7)).toEqual(['Pcs per carton', 'Cost per pc USD', 'Price per pc USD']));
  it('gives the gross carton cost when only the cost per pc is there', () => {
    const r = impParse([H, ['Rose mist', 'Fragrance', '', '', 36, 2.5, 3.5]], [], []);
    expect([r[0].status, r[0].o.carton_cost]).toEqual(['ok', 90]);
  });
  it('a file with a Cost per pc column and no carton cost column is read', () => {
    const r = impParse([['Name', 'Pcs per carton', 'Cost per pc USD', 'Price per pc USD'], ['Soap bar', 24, 0.5, 0.8]], [], []);
    expect([r[0].status, r[0].o.carton_cost]).toEqual(['ok', 12]);
  });
  it('refuses a carton cost and a cost per pc that do not agree', () => {
    const r = impParse([H, ['Rose mist', 'Fragrance', 100, '', 36, 2.5, 3.5]], [], []);
    expect(r[0].status).toBe('bad');
    expect(r[0].msg).toMatch(/do not agree/);
  });
});
