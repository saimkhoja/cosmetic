import { describe, expect, it } from 'vitest';
import { fCDF, toCDF } from './format';
import { cashNotes, ctnTxt, hotSort, marginPct, payment, pcValue, stockValue, takeLocal, totals, unitsOf, usdNotes } from './units';
import { barcodesOf, custName, findByCode, itemProblem, pickList, scanInQty, splitBarcodes } from './items';
import { crc32, impParse, inum, readCSV } from './xlsx';
import type { Product } from './types';

const P = (o: Partial<Product>): Product => ({ id: 'p', sku: 'SK-1', name: 'X', category: 'C', stock_unit: 'pcs', is_bundle: false, per_carton: 24, pieces_per_set: 0,
  price_usd: 1.5, half_dozen_usd: 0, dozen_usd: 16, carton_usd: 30, piece_usd: 0, reorder: 0, wh_qty: 0, active: true, ...o });

describe('money', () => {
  it('rounds shop prices to the nearest 10 CDF like the demo', () => {
    expect(toCDF(1.5, 2850)).toBe(4280);
    expect(toCDF(16, 2850)).toBe(45600);
    expect(toCDF(30, 2850)).toBe(85500);
    expect(fCDF(1234567)).toBe('1 234 567 CDF');
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
  it('half dozen when it has a price; carton only when it has a price', () => {
    expect(unitsOf(P({ half_dozen_usd: 8.5 })).map((u) => `${u.u}:${u.mult}`)).toEqual(['pcs:1', 'half dzn:6', 'dzn:12', 'carton:24']);
    expect(unitsOf(P({ half_dozen_usd: 8.5, per_carton: 6 })).map((u) => u.u)).toEqual(['pcs', 'dzn', 'carton']);
    expect(unitsOf(P({ carton_usd: 0 })).map((u) => u.u)).toEqual(['pcs', 'dzn']);
    expect(unitsOf(P({ price_usd: 0 })).map((u) => u.u)).toEqual(['dzn', 'carton']);
    expect(pcValue(P({ price_usd: 0 }))).toBeCloseTo(16 / 12);
  });
  it('hot items first, seasonal items out of season last', () => {
    const list = [P({ id: 'a', name: 'A' }), P({ id: 'b', name: 'B' }), P({ id: 'c', name: 'C' }), P({ id: 'd', name: 'D' })];
    const ranks = [{ product_id: 'a', sold_30: 2, in_season: true }, { product_id: 'b', sold_30: 50, in_season: false }, { product_id: 'c', sold_30: 9, in_season: true }, { product_id: 'd', sold_30: 0, in_season: true }];
    expect(hotSort(list, ranks).map((p) => p.id)).toEqual(['c', 'a', 'd', 'b']);
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
  const base = { name: 'A', category: 'B', is_bundle: false, carton_cost: 24, per_carton: 24, pc: 1.5, half: 0, dzn: 16, ctn: 30, set_cost: 0, set_price: 0, pcs: 0, piece: 0 };
  it('accepts a good carton item', () => expect(itemProblem(base)).toBeNull());
  it('refuses a price below cost', () => {
    expect(itemProblem({ ...base, pc: 0.5 })).toBe('Price per pc is below the cost of one pc ($1.00)');
    expect(itemProblem({ ...base, dzn: 10 })).toMatch(/dozen is below/);
    expect(itemProblem({ ...base, ctn: 20 })).toMatch(/carton cannot be below/);
    expect(itemProblem({ ...base, half: 5 })).toMatch(/half dozen is below/);
  });
  it('every price is optional, but one is needed', () => {
    expect(itemProblem({ ...base, ctn: 0, half: 0, dzn: 0 })).toBeNull();
    expect(itemProblem({ ...base, pc: 0 })).toBeNull();
    expect(itemProblem({ ...base, pc: 0, dzn: 0, ctn: 0 })).toMatch(/at least one selling price/);
  });
  it('takes one pc per carton, priced per pc or per carton', () => {
    const one = { ...base, carton_cost: 2, per_carton: 1, pc: 0, dzn: 0, ctn: 3 };
    expect(itemProblem(one)).toBeNull();
    expect(itemProblem({ ...one, ctn: 1.5 })).toMatch(/pc is below/);
    expect(itemProblem({ ...one, per_carton: 0 })).toMatch(/1 or more/);
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

describe('supermarket', () => {
  const list = [P({ id: 'a', sku: 'SK-101', barcode: '6001234567890' }), P({ id: 'b', sku: 'SK-102', barcode: null })];
  it('finds an item by its barcode, then by its code', () => {
    expect(findByCode(list, ' 6001234567890 ')?.id).toBe('a');
    expect(findByCode(list, 'sk-102')?.id).toBe('b');
    expect(findByCode(list, '600123')).toBeUndefined();
    expect(findByCode(list, '')).toBeUndefined();
  });
  it('shows a sale without a name as walk-in', () => { expect(custName('')).toBe('Walk-in'); expect(custName('Mama Rose')).toBe('Mama Rose'); });
  it('imports barcodes and skips those already used', () => {
    const rows = [['Name', 'Category', 'Carton cost USD', 'Pcs per carton', 'Price per pc USD', 'Barcode'],
      ['Soap A', 'Bath', 24, 24, 1.5, 6001234567890], ['Soap B', 'Bath', 24, 24, 1.5, '6009 9999'], ['Soap C', 'Bath', 24, 24, 1.5, '6009 9999'], ['Soap D', 'Bath', 24, 24, 1.5, '60*1']];
    const r = impParse(rows, [], [], ['6001234567890']);
    expect(r.map((x) => x.status)).toEqual(['skip', 'ok', 'skip', 'bad']);
    expect(r[1].barcode).toBe('60099999');
  });
});
describe('cash received', () => {
  it('offers the exact total and the next round notes', () => {
    expect(cashNotes(12550)).toEqual([12550, 13000, 15000, 20000]);
    expect(cashNotes(5000)).toEqual([5000, 10000]);
  });
});
describe('payment in USD and CDF', () => {
  it('converts dollars at the sale rate and gives change in Francs', () => {
    const p = payment(40000, 2850, 20, '', false);
    expect([p.value, p.change, p.short, p.changeUsd, p.changeCdf, p.maxDollars]).toEqual([57000, 17000, 0, 0, 17000, 5]);
    expect(p.pay).toEqual({ tendered: 57000, paid_usd: 20, paid_cdf: 0, change_usd: 0 });
  });
  it('gives whole dollars back and the rest in Francs', () => {
    const p = payment(40000, 2850, 20, 0, true);
    expect([p.changeUsd, p.changeCdf, p.pay.change_usd]).toEqual([5, 2750, 5]);
  });
  it('mixes dollars and Francs, and says what is still due', () => {
    expect(payment(40000, 2850, 10, 11500).change).toBe(0);
    expect(payment(40000, 2850, 10, 5000).short).toBe(6500);
    expect(payment(40000, 2850, 0, 0).due).toBe(14.04);
  });
  it('never gives back more dollars than were received', () => {
    expect(payment(1000, 2850, 0, 20000, true).changeUsd).toBe(0);
    expect(payment(1000, 2850, 2, 20000, true).changeUsd).toBe(2);
  });
  it('offers the USD notes that cover what is due', () => { expect(usdNotes(14.04)).toEqual([20, 50, 100]); expect(usdNotes(0.4)).toEqual([1, 5, 10]); });
});
describe('goods in and delivery lists', () => {
  const items = [P({ id: 'a', name: 'Aloe', sku: 'SK-1', barcodes: ['6001234567890'] }), P({ id: 'b', name: 'Brume', sku: 'SK-2' }), P({ id: 'c', name: 'Cologne', sku: 'SK-3', category: 'Fragrance' })];
  const ids = (r: { hits: Product[]; rest: Product[] }) => [...r.hits, ...r.rest].map((p) => p.id);
  it('keeps the order when quantities are typed', () => {
    expect(ids(pickList(items, () => true, () => false, ''))).toEqual(['a', 'b', 'c']);
    expect(ids(pickList(items, () => true, (p) => p.id === 'c', ''))).toEqual(['a', 'b', 'c']);
  });
  it('puts search matches first, then the rest', () => {
    const r = pickList(items, () => true, () => false, 'frag');
    expect(r.hits.map((p) => p.id)).toEqual(['c']); expect(r.rest.map((p) => p.id)).toEqual(['a', 'b']);
    expect(pickList(items, () => true, () => false, '6001234567890').hits.map((p) => p.id)).toEqual(['a']);
  });
  it('shows only the chosen items without a search, plus those with a quantity', () => {
    expect(ids(pickList(items, (p) => p.id === 'a', (p) => p.id === 'c', ''))).toEqual(['a', 'c']);
    expect(ids(pickList(items, () => true, (p) => p.id === 'c', '', 1))).toEqual(['a', 'c']);   // past the row limit, entered items stay
  });
  it('finds a barcode scanned into a quantity box', () => {
    expect(scanInQty(items, '126001234567890')).toMatchObject({ qty: '12', p: { id: 'a' } });
    expect(scanInQty(items, '6001234567890')).toMatchObject({ qty: '', p: { id: 'a' } });
    expect(scanInQty(items, '12')).toBeNull();
    expect(scanInQty(items, '9999999999')).toBeNull();
  });
});

describe('stock at selling price', () => {
  it('values each pc at its shop price, as at the till', () => {
    const v = stockValue([{ p: P({ price_usd: 1.5 }), qty: 10 }, { p: P({ price_usd: 0, dozen_usd: 16 }), qty: 24 }], 2850);
    expect(v.cdf).toBe(10 * 4280 + 24 * toCDF(16 / 12, 2850));   // 4 280 per pc; a dozen-only item at its dozen price / 12
    expect(v.usd).toBeCloseTo(15 + 32);
    expect(v).toMatchObject({ lines: 2, units: 34 });
  });
  it('counts no value for stock that is zero or sold on order', () => {
    expect(stockValue([{ p: P({}), qty: 0 }, { p: P({}), qty: -3 }], 2850)).toEqual({ usd: 0, cdf: 0, lines: 0, units: 0 });
  });
  it('values a mixed set at the set price', () => {
    expect(stockValue([{ p: P({ is_bundle: true, stock_unit: 'set', price_usd: 12, piece_usd: 3, pieces_per_set: 6 }), qty: 2 }], 2850).cdf).toBe(2 * 34200);
  });
});

describe('margin', () => {
  it('is the mark-up on cost: cost + margin % = selling price', () => {
    expect(marginPct(1.28, 0.9)).toBe(42);   // 0.38 / 0.90 = 42.2%
    expect(marginPct(1.29, 0.9)).toBe(43);
    expect(marginPct(2, 1)).toBe(100);
    expect(marginPct(0.8, 1)).toBe(-20);
    expect(marginPct(1, 0)).toBeNull();
  });
});
describe('several barcodes', () => {
  const items = [P({ id: 'a', sku: 'SK-1', barcode: '111111', barcodes: ['111111', '222222'] }), P({ id: 'b', sku: 'SK-2', barcode: '333333', barcodes: null })];
  it('finds an item by any of its barcodes, or by the single one of an older database', () => {
    expect(findByCode(items, '222222')?.id).toBe('a');
    expect(findByCode(items, '333333')?.id).toBe('b');
    expect(barcodesOf(items[1])).toEqual(['333333']);
  });
  it('splits barcodes typed or imported together', () => { expect(splitBarcodes('111 111; 222222,111111|333333')).toEqual(['111111', '222222', '333333']); });
  it('imports several barcodes in one cell and skips a row reusing one', () => {
    const rows = [['Name', 'Category', 'Carton cost USD', 'Pcs per carton', 'Price per pc USD', 'Barcode'],
      ['A', 'Bath', 24, 24, 1.5, '444444;555555'], ['B', 'Bath', 24, 24, 1.5, '666666, 555555'], ['C', 'Bath', 24, 24, 1.5, '222222']];
    const r = impParse(rows, [], [], ['222222']);
    expect(r.map((x) => x.status)).toEqual(['ok', 'skip', 'skip']);
    expect(r[0].barcode).toBe('444444;555555');
  });
});
