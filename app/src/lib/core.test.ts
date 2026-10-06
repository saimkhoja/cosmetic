import { describe, expect, it } from 'vitest';
import { fCDF, toCDF } from './format';
import { ctnTxt, takeLocal, totals, unitsOf } from './units';
import { itemProblem } from './items';
import { crc32, impParse, inum, readCSV } from './xlsx';
import type { Product } from './types';

const P = (o: Partial<Product>): Product => ({ id: 'p', sku: 'SK-1', name: 'X', category: 'C', stock_unit: 'pcs', is_bundle: false, per_carton: 24, pieces_per_set: 0,
  price_usd: 1.5, dozen_usd: 16, carton_usd: 30, piece_usd: 0, reorder: 0, wh_qty: 0, active: true, ...o });

describe('money', () => {
  it('rounds shop prices to the nearest 10 FC like the demo', () => {
    expect(toCDF(1.5, 2850)).toBe(4280);
    expect(toCDF(16, 2850)).toBe(45600);
    expect(toCDF(30, 2850)).toBe(85500);
    expect(fCDF(1234567)).toBe('1 234 567 FC');
  });
  it('computes discount and included VAT as the server does', () => {
    const t = totals([{ price: 85500, qty: 1 }, { price: 4000, qty: 1 }], 10, 16);
    expect(t).toMatchObject({ gross: 89500, disc: 8950, total: 80550, vat: 11110, ht: 69440 });
  });
});

describe('units', () => {
  it('pcs, dozen and carton for a carton item', () => {
    expect(unitsOf(P({})).map((u) => `${u.u}:${u.mult}`)).toEqual(['pcs:1', 'dzn:12', 'carton:24']);
  });
  it('no dozen when the carton is 12 or no dozen price', () => {
    expect(unitsOf(P({ per_carton: 12 })).map((u) => u.u)).toEqual(['pcs', 'carton']);
    expect(unitsOf(P({ dozen_usd: 0 })).map((u) => u.u)).toEqual(['pcs', 'carton']);
  });
  it('set and piece for a mixed set', () => {
    expect(unitsOf(P({ is_bundle: true, stock_unit: 'set', piece_usd: 1.8 })).map((u) => u.u)).toEqual(['set', 'piece']);
  });
  it('shows cartons plus pcs', () => {
    expect(ctnTxt(P({}), 148)).toBe('6 ctn + 4 pcs');
    expect(ctnTxt(P({}), 10)).toBe('');
  });
  it('opens sets when pieces are sold, like the server', () => {
    expect(takeLocal({ qty: 2, open_pieces: 0 }, 13, 0, true, 12)).toEqual({ qty: 1, open_pieces: 1 });
    expect(takeLocal({ qty: 10, open_pieces: 0 }, 2, 24, false, 0)).toEqual({ qty: -38, open_pieces: 0 });
  });
});

describe('item validation', () => {
  const base = { name: 'A', category: 'B', is_bundle: false, carton_cost: 24, per_carton: 24, pc: 1.5, dzn: 16, ctn: 30, set_cost: 0, set_price: 0, pcs: 0, piece: 0 };
  it('accepts a good carton item', () => expect(itemProblem(base)).toBeNull());
  it('refuses a price below cost', () => {
    expect(itemProblem({ ...base, pc: 0.5 })).toBe('Price per pc is below the cost of one pc ($1.00)');
    expect(itemProblem({ ...base, dzn: 10 })).toMatch(/dozen is below/);
    expect(itemProblem({ ...base, ctn: 20 })).toMatch(/carton cannot be below/);
  });
});

describe('import', () => {
  it('reads French-locale CSV with ; and quoted fields', () => {
    const rows = readCSV('Nom;Catégorie;Carton cost USD;Pcs per carton;Price per pc USD;Price per dozen USD;Price per carton USD;Opening cartons\n"Rose mist; 100 ml";Fragrance;84;36;3,5;38;120;3\n');
    const r = impParse(rows, [], []);
    expect(r).toHaveLength(1);
    expect(r[0]).toMatchObject({ status: 'ok', qty: 108, o: { name: 'Rose mist; 100 ml', pc: 3.5, reorder: 36 } });
  });
  it('skips names already in the catalogue and flags bad rows', () => {
    const rows = [['Name', 'Category', 'Carton cost USD', 'Pcs per carton', 'Price per pc USD', 'Price per carton USD'], ['Shea lotion', 'Skin', 76, 24, 5, 108], ['Cheap', 'X', 100, 10, 5, 90], ['New one', 'X', 10, 10, 2, 15]];
    const r = impParse(rows, ['shea lotion'], []);
    expect(r.map((x) => x.status)).toEqual(['skip', 'bad', 'ok']);
  });
  it('parses numbers written the French way', () => { expect(inum('1,80')).toBe(1.8); expect(inum('$1 500')).toBe(1500); });
  it('crc32 matches the standard value', () => expect(crc32(new TextEncoder().encode('123456789'))).toBe(0xcbf43926));
});
