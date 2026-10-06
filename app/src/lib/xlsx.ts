// Excel (.xlsx) and CSV reading/writing with no outside library, so import works offline.
import { itemProblem } from './items';

export const IMPCOLS = ['Name', 'Category', 'Carton cost USD', 'Pcs per carton', 'Price per pc USD', 'Price per dozen USD', 'Price per carton USD', 'Opening cartons', 'Opening pcs', 'Reorder at (pcs)', 'SKU'];
const IMPKEYS: Record<string, string[]> = {
  name: ['name', 'item', 'itemname', 'nom', 'article', 'designation', 'produit'], category: ['category', 'categorie', 'cat'],
  cartonCost: ['cartoncost', 'costcarton', 'costofcarton', 'costofonecarton', 'coutcarton', 'prixachatcarton'],
  perCarton: ['pcspercarton', 'piecespercarton', 'percarton', 'pcscarton', 'qtypercarton', 'pcsparcarton', 'piecesparcarton'],
  pc: ['priceperpc', 'pricepc', 'pcprice', 'priceperpiece', 'prixpiece', 'prixparpiece'], dzn: ['priceperdozen', 'pricedozen', 'dozenprice', 'prixdouzaine', 'prixpardouzaine'],
  ctn: ['pricepercarton', 'pricecarton', 'cartonprice', 'prixcarton', 'prixparcarton'], openCtn: ['openingcartons', 'cartons', 'stockcartons', 'openingstockcartons'],
  openPcs: ['openingpcs', 'loosepcs', 'stockpcs', 'openingstockpcs', 'openingloosepcs'], reorder: ['reorderat', 'reorder', 'reorderlevel', 'reorderatpcs', 'reorderwhenbelow'],
  sku: ['sku', 'code', 'itemcode', 'ref', 'reference'],
};
export const hkey = (h: unknown) => String(h ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]/g, '').replace(/usd$/, '').replace(/fc$/, '');
export function inum(v: unknown): number {
  if (typeof v === 'number') return v;
  let t = String(v ?? '').replace(/[\s$ ]/g, '');
  if (!t) return NaN;
  if (t.includes(',') && !t.includes('.')) t = t.replace(',', '.'); else t = t.replace(/,/g, '');
  return Number(t);
}

type Cell = string | number | boolean;
export async function readXlsx(buf: ArrayBuffer): Promise<Cell[][]> {
  const u8 = new Uint8Array(buf), dv = new DataView(buf), dec = new TextDecoder();
  let e = -1;
  for (let i = u8.length - 22; i >= Math.max(0, u8.length - 66000); i--) if (dv.getUint32(i, true) === 0x06054b50) { e = i; break; }
  if (e < 0) throw new Error('This file is not a valid .xlsx workbook');
  const n = dv.getUint16(e + 10, true), ent: Record<string, { m: number; cs: number; lo: number }> = {};
  let p = dv.getUint32(e + 16, true);
  for (let k = 0; k < n; k++) {
    if (dv.getUint32(p, true) !== 0x02014b50) break;
    const nl = dv.getUint16(p + 28, true), el = dv.getUint16(p + 30, true), cl = dv.getUint16(p + 32, true);
    ent[dec.decode(u8.subarray(p + 46, p + 46 + nl))] = { m: dv.getUint16(p + 10, true), cs: dv.getUint32(p + 20, true), lo: dv.getUint32(p + 42, true) };
    p += 46 + nl + el + cl;
  }
  const file = async (name: string): Promise<string | null> => {
    const f = ent[name]; if (!f) return null;
    const st = f.lo + 30 + dv.getUint16(f.lo + 26, true) + dv.getUint16(f.lo + 28, true), d = u8.slice(st, st + f.cs);
    if (f.m === 0) return dec.decode(d);
    if (f.m !== 8) throw new Error('Unsupported compression in this workbook');
    if (typeof DecompressionStream === 'undefined') throw new Error('This browser cannot open .xlsx files. Save the sheet as .csv and import that.');
    return await new Response(new Blob([d]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).text();
  };
  const xml = (t: string) => new DOMParser().parseFromString(t, 'application/xml');
  const tags = (d: Document | Element, t: string) => [...d.getElementsByTagNameNS('*', t)];
  const wb = await file('xl/workbook.xml'); if (!wb) throw new Error('This file is not a valid .xlsx workbook');
  const sh = tags(xml(wb), 'sheet')[0], rid = sh && (sh.getAttributeNS('http://schemas.openxmlformats.org/officeDocument/2006/relationships', 'id') || sh.getAttribute('r:id'));
  let target = 'worksheets/sheet1.xml';
  const rels = await file('xl/_rels/workbook.xml.rels');
  if (rels && rid) { const r = tags(xml(rels), 'Relationship').find((x) => x.getAttribute('Id') === rid); if (r) target = r.getAttribute('Target') || target; }
  const path = target.startsWith('/') ? target.slice(1) : 'xl/' + target.replace(/^\.\//, '');
  const ss: string[] = [], sst = await file('xl/sharedStrings.xml');
  if (sst) tags(xml(sst), 'si').forEach((si) => ss.push(tags(si, 't').filter((t) => (t.parentNode as Element).localName !== 'rPh').map((t) => t.textContent).join('')));
  const sx = await file(path); if (!sx) throw new Error('The first sheet could not be found in this workbook');
  const out: Cell[][] = [];
  tags(xml(sx), 'row').forEach((row, ri) => {
    const rn = (parseInt(row.getAttribute('r') || '') || ri + 1) - 1, cells: Cell[] = (out[rn] = []);
    let ci = 0;
    tags(row, 'c').forEach((c) => {
      const ref = c.getAttribute('r');
      if (ref) { ci = 0; for (const ch of ref.replace(/\d+/g, '')) ci = ci * 26 + ch.charCodeAt(0) - 64; ci--; }
      const t = c.getAttribute('t'), v = tags(c, 'v')[0], vt = v ? v.textContent || '' : '';
      cells[ci] = t === 's' ? ss[+vt] ?? '' : t === 'inlineStr' ? tags(c, 't').map((x) => x.textContent).join('') : t === 'str' || t === 'e' ? vt : t === 'b' ? vt === '1' : vt === '' ? '' : Number(vt);
      ci++;
    });
  });
  return Array.from(out, (r) => r || []);
}

export function readCSV(text: string): string[][] {
  text = text.replace(/^﻿/, '');
  const lines = text.split(/\r?\n/);
  if (/^sep=.$/i.test(lines[0])) text = lines.slice(1).join('\n');
  const first = text.split(/\r?\n/)[0] || '', d = [';', ',', '\t'].sort((a, b) => first.split(b).length - first.split(a).length)[0];
  const rows: string[][] = []; let row: string[] = [], f = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (q) { if (ch === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += ch; }
    else if (ch === '"') q = true;
    else if (ch === d) { row.push(f); f = ''; }
    else if (ch === '\n' || ch === '\r') { if (ch === '\r' && text[i + 1] === '\n') i++; row.push(f); rows.push(row); row = []; f = ''; }
    else f += ch;
  }
  if (f || row.length) { row.push(f); rows.push(row); }
  return rows;
}

const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
export function crc32(u: Uint8Array) { let c = 0xffffffff; for (let i = 0; i < u.length; i++) c = CRC[(c ^ u[i]) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
/** Tiny ZIP writer (stored, no compression) used for the .xlsx template. */
export function zipStore(files: { name: string; data: string }[]): Blob {
  const enc = new TextEncoder(), parts: BlobPart[] = [], cd: BlobPart[] = []; let off = 0, cdSize = 0;
  const put = (v: DataView, spec: [number, number, number][]) => spec.forEach(([o, x, s]) => (s === 4 ? v.setUint32(o, x, true) : v.setUint16(o, x, true)));
  for (const f of files) {
    const name = enc.encode(f.name), data = enc.encode(f.data), crc = crc32(data);
    const h = new DataView(new ArrayBuffer(30));
    put(h, [[0, 0x04034b50, 4], [4, 20, 2], [6, 0x0800, 2], [8, 0, 2], [10, 0, 2], [12, 33, 2], [14, crc, 4], [18, data.length, 4], [22, data.length, 4], [26, name.length, 2], [28, 0, 2]]);
    const c = new DataView(new ArrayBuffer(46));
    put(c, [[0, 0x02014b50, 4], [4, 20, 2], [6, 20, 2], [8, 0x0800, 2], [10, 0, 2], [12, 0, 2], [14, 33, 2], [16, crc, 4], [20, data.length, 4], [24, data.length, 4], [28, name.length, 2], [30, 0, 2], [32, 0, 2], [34, 0, 2], [36, 0, 2], [38, 0, 4], [42, off, 4]]);
    parts.push(h, name, data); cd.push(c, name); off += 30 + name.length + data.length; cdSize += 46 + name.length;
  }
  const e = new DataView(new ArrayBuffer(22));
  put(e, [[0, 0x06054b50, 4], [4, 0, 2], [6, 0, 2], [8, files.length, 2], [10, files.length, 2], [12, cdSize, 4], [16, off, 4], [20, 0, 2]]);
  return new Blob([...parts, ...cd, e], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}
export function templateXlsx(): Blob {
  const X = (s: unknown) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
  const col = (i: number) => String.fromCharCode(65 + i);
  const rows: (string | number)[][] = [IMPCOLS, ['Aloe vera gel 300 ml', 'Skin care', 60, 24, 4, 45, 90, 5, 0, 24, ''], ['Argan oil shampoo 500 ml', 'Hair care', 72, 12, 9, '', 100, 2, 6, 12, ''], ['Rose body mist 100 ml', 'Fragrance', 84, 36, 3.5, 38, 120, 3, 0, 36, '']];
  const sheet = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols>${IMPCOLS.map((_, i) => `<col min="${i + 1}" max="${i + 1}" width="${i === 0 ? 34 : i === 1 ? 16 : 19}" customWidth="1"/>`).join('')}</cols><sheetData>${rows.map((r, ri) => `<row r="${ri + 1}">${r.map((v, ci) => (v === '' ? '' : typeof v === 'number' ? `<c r="${col(ci)}${ri + 1}"><v>${v}</v></c>` : `<c r="${col(ci)}${ri + 1}" t="inlineStr"><is><t>${X(v)}</t></is></c>`)).join('')}</row>`).join('')}</sheetData></worksheet>`;
  return zipStore([
    { name: '[Content_Types].xml', data: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>' },
    { name: '_rels/.rels', data: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>' },
    { name: 'xl/workbook.xml', data: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Items" sheetId="1" r:id="rId1"/></sheets></workbook>' },
    { name: 'xl/_rels/workbook.xml.rels', data: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>' },
    { name: 'xl/worksheets/sheet1.xml', data: sheet },
  ]);
}

export interface ImportRow {
  n: number; status: 'ok' | 'bad' | 'skip'; msg: string; sku: string; qty: number;
  o: { name: string; category: string; carton_cost: number; per_carton: number; pc: number; dzn: number; ctn: number; open_cartons: number; open_pcs: number; reorder: number | null };
}
/** Turns sheet rows into checked import rows; names/codes already in the catalogue are skipped. */
export function impParse(rows: Cell[][], existingNames: string[], existingSkus: string[]): ImportRow[] {
  const hi = rows.findIndex((r) => r && r.some((c) => IMPKEYS.name.includes(hkey(c))));
  if (hi < 0) throw new Error('No header row found. The first row needs column names such as Name, Category, Carton cost USD. Download the template to see them.');
  const col: Record<string, number> = {};
  rows[hi].forEach((h, i) => { const k = hkey(h); Object.entries(IMPKEYS).forEach(([f, al]) => { if (col[f] === undefined && al.includes(k)) col[f] = i; }); });
  const label: Record<string, string> = { name: 'Name', cartonCost: 'Carton cost USD', perCarton: 'Pcs per carton', pc: 'Price per pc USD', ctn: 'Price per carton USD' };
  const miss = Object.keys(label).filter((f) => col[f] === undefined);
  if (miss.length) throw new Error('Missing columns: ' + miss.map((f) => label[f]).join(', '));
  const g = (r: Cell[], f: string) => (col[f] === undefined ? '' : r[col[f]] ?? '');
  const names = new Set(existingNames.map((n) => n.trim().toLowerCase())), skus = new Set(existingSkus.map((s) => s.toLowerCase()));
  const out: ImportRow[] = [];
  rows.slice(hi + 1).forEach((r, i) => {
    if (!r || !r.some((c) => String(c ?? '').trim() !== '')) return;
    const name = String(g(r, 'name')).trim().replace(/\s+/g, ' ').slice(0, 60), sku = String(g(r, 'sku')).trim().slice(0, 20), dz = inum(g(r, 'dzn'));
    const oc = inum(g(r, 'openCtn')), op = inum(g(r, 'openPcs')), ro = inum(g(r, 'reorder'));
    const o = { name, category: String(g(r, 'category')).trim().slice(0, 30) || 'Other', carton_cost: inum(g(r, 'cartonCost')), per_carton: inum(g(r, 'perCarton')), pc: inum(g(r, 'pc')), dzn: isNaN(dz) ? 0 : dz, ctn: inum(g(r, 'ctn')),
      open_cartons: isNaN(oc) ? 0 : oc, open_pcs: isNaN(op) ? 0 : op, reorder: isNaN(ro) ? null : ro };
    const row: ImportRow = { n: hi + i + 2, o, sku, status: 'ok', msg: '', qty: 0 };
    if (name && names.has(name.toLowerCase())) { row.status = 'skip'; row.msg = 'Name already exists'; }
    else if (sku && skus.has(sku.toLowerCase())) { row.status = 'skip'; row.msg = 'Code already exists'; }
    else {
      const p = itemProblem({ ...o, is_bundle: false, set_cost: 0, set_price: 0, pcs: 0, piece: 0 });
      if (p) { row.status = 'bad'; row.msg = p; }
      else if (oc < 0 || op < 0 || ro < 0) { row.status = 'bad'; row.msg = 'Stock and reorder cannot be negative'; }
      else if ([oc, op, ro].some((x) => !isNaN(x) && x % 1)) { row.status = 'bad'; row.msg = 'Stock and reorder must be whole numbers'; }
      else { row.qty = o.open_cartons * o.per_carton + o.open_pcs; if (row.o.reorder === null) row.o.reorder = o.per_carton; names.add(name.toLowerCase()); if (sku) skus.add(sku.toLowerCase()); }
    }
    out.push(row);
  });
  if (!out.length) throw new Error('The sheet has a header row but no items under it');
  return out;
}
export function saveBlob(blob: Blob, name: string) {
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}
