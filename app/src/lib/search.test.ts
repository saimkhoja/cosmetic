import { describe, expect, it } from 'vitest';
import { hitLink, search, serverTerm, snippet, type Source } from './search';

const src: Source[] = [
  { tab: 'Inventory', route: '/inventory', icon: 'box', recs: [
    { id: '1', title: 'Nivea Soft Cream 200ml', anchor: 'NIV-200', fields: [['Name', 'Nivea Soft Cream 200ml'], ['Code', 'NIV-200'], ['Category', 'Creams']] },
    { id: '2', title: 'Dove Soap', anchor: 'DOV-1', fields: [['Name', 'Dove Soap'], ['Code', 'DOV-1'], ['Category', 'Soaps']] },
    { id: '3', title: 'Cream of Nature', anchor: 'CON-1', fields: [['Name', 'Cream of Nature'], ['Code', 'CON-1'], ['Category', 'Hair']] },
  ] },
  { tab: 'Deliveries', route: '/deliveries', icon: 'truck', recs: [
    { id: 'd1', title: 'DEL-000004', anchor: 'DEL-000004', fields: [['Delivery', 'DEL-000004'], ['Item', 'Dove Soap']] },
  ] },
];

describe('global search', () => {
  it('finds any part of a word, whatever the case, on every tab', () => {
    const g = search('OAP', src);
    expect(g.map((x) => `${x.tab}:${x.total}`)).toEqual(['Inventory:1', 'Deliveries:1']);
    expect(g[0].hits.map((h) => `${h.rec.id}:${h.field}`)).toEqual(['2:Name']);
    expect(g[1].hits[0].field).toBe('Item');
  });
  it('one result per record, the first field that has it; matches at the start come first', () => {
    const g = search('cream', src)[0];
    expect(g.hits.map((h) => h.rec.id)).toEqual(['3', '1']);
    expect(g.hits.find((h) => h.rec.id === '1')?.field).toBe('Name');
  });
  it('needs 2 characters', () => { expect(search('c', src)).toEqual([]); expect(search('  ', src)).toEqual([]); });
  it('cuts a long value around the match', () => {
    const v = 'Invoice GOM-T1-000123 for Mama Nzuzi was changed at approval by the shop admin, changed from 120 000 CDF';
    const s = snippet(v, v.indexOf('shop'), 4, 10);
    expect(s.hit).toBe('shop'); expect(s.pre.startsWith('…')).toBe(true); expect(s.post.endsWith('…')).toBe(true);
  });
  it('links to the tab with the word, the record and its filters', () => {
    expect(hitLink('/inventory', ' niv ', { id: '1', title: '', anchor: 'NIV-200', fields: [], params: { arch: '1' } })).toBe('/inventory?arch=1&find=niv&at=NIV-200');
  });
  it('keeps characters that break a server filter out of it', () => { expect(serverTerm(' a,b(c)%_* ')).toBe('a b c'); });
});
