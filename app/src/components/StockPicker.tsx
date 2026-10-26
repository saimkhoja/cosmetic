// The item list of goods in, deliveries and returns to suppliers: scan or search and type quantities on the
// left, and on the right the lines entered so far, to check before confirming.
import { useRef, useState, type ReactNode } from 'react';
import { Icon } from '../lib/icons';
import { findByCode, pickList, scanInQty } from '../lib/items';
import { Empty } from './ui';
import type { Product } from '../lib/types';

export type Line = { n: string; u: 'ctn' | 'pcs' };
export const per = (p: Product) => (!p.is_bundle && p.per_carton > 1 ? p.per_carton : 0);
export const blankLine = (p: Product): Line => ({ n: '', u: per(p) ? 'ctn' : 'pcs' });
export interface PickCol { th: ReactNode; td: (p: Product) => ReactNode }
export interface PickQty { lines: Record<string, Line>; setLine: (p: Product, patch: Partial<Line>) => void; pcsOf: (p: Product) => number }
const qtyText = (p: Product, l: Line, pcs: number) => (l.u === 'ctn' && per(p) ? `${parseInt(l.n) || 0} ctn (${pcs} pcs)` : `${pcs} ${p.stock_unit}`);

export function StockPicker({ all, base, qty, cols, qtyHead, aria, sideTitle, sideNote, warn, badge, codes, initQ = '' }: {
  all: Product[]; base?: (p: Product) => boolean; qty: PickQty; cols: PickCol[]; qtyHead: string; aria: (p: Product) => string;
  sideTitle: string; sideNote?: ReactNode; warn?: (p: Product) => string | null; badge?: (p: Product) => ReactNode; codes: boolean; initQ?: string;
}) {
  const { lines, setLine, pcsOf } = qty;
  const [q, setQ] = useState(initQ), [on, setOn] = useState<string | null>(null), [miss, setMiss] = useState('');
  const scanIn = useRef<HTMLInputElement>(null), box = useRef<HTMLDivElement>(null), before = useRef('');
  const { hits, rest } = pickList(all, (p) => !base || base(p), (p) => pcsOf(p) > 0, q);
  const picked = Object.keys(lines).map((id) => all.find((p) => p.id === id)).filter((p): p is Product => !!p && pcsOf(p) > 0);
  // the cursor goes to the item's quantity box; only the list scrolls to its row
  const focusQty = (p: Product) => {
    setOn(p.id);
    setTimeout(() => {
      const el = document.getElementById('pq-' + p.id) as HTMLInputElement | null, b = box.current; if (!el || !b) return;
      const r = el.closest('tr')!.getBoundingClientRect(), c = b.getBoundingClientRect(), head = 44;
      if (r.top < c.top + head) b.scrollTop -= c.top + head - r.top; else if (r.bottom > c.bottom) b.scrollTop += r.bottom - c.bottom;
      el.focus({ preventScroll: true }); el.select();
    }, 30);
  };
  // a scan (or Enter on a search) puts 1 in the item's unit, or adds 1 when it already has a quantity
  const add = (p: Product) => { setLine(p, { n: String(pcsOf(p) > 0 ? (parseInt(lines[p.id]?.n ?? '') || 0) + 1 : 1) }); focusQty(p); };
  const scan = () => {
    const code = q.trim(); if (!code) return;
    const p = findByCode(all, code) ?? hits[0];
    if (!p) { setMiss(/^\d{6,}$/.test(code) ? `No item has the barcode ${code}` : 'No item matches'); return; }
    setQ(''); setMiss(''); add(p);
  };
  // Enter in a quantity box goes back to the scan box; a barcode scanned into it by mistake is handled as a scan
  const qtyKey = (p: Product) => (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    const hit = scanInQty(all, e.currentTarget.value);
    if (hit) {
      const kept = hit.qty || before.current;
      if (hit.p.id === p.id) { setLine(p, { n: String((parseInt(kept) || 0) + 1) }); focusQty(p); } else { setLine(p, { n: kept }); add(hit.p); }
      return;
    }
    setOn(null); scanIn.current?.focus();
  };
  const row = (p: Product) => { const l = lines[p.id] ?? blankLine(p); return (
    <tr key={p.id} className={on === p.id ? 'on' : ''}><td><b>{p.name}</b>{badge?.(p)}<div className="code">{p.sku}{per(p) ? ` · ${per(p)} pcs per carton` : ''}</div></td>
      {cols.map((c, i) => <td key={i} className="r">{c.td(p)}</td>)}
      <td><div className="pqty"><input id={'pq-' + p.id} className="input" type="number" min="0" inputMode="numeric" placeholder="0" value={l.n} aria-label={aria(p)}
        onFocus={(e) => { before.current = e.target.value; setOn(p.id); }} onChange={(e) => setLine(p, { n: e.target.value })} onKeyDown={qtyKey(p)} />
        {per(p) ? <select className="input" value={l.u} onChange={(e) => setLine(p, { u: e.target.value as Line['u'] })} aria-label={`Unit ${p.name}`}><option value="ctn">ctn</option><option value="pcs">pcs</option></select> : <span className="code">{p.stock_unit}</span>}</div></td></tr>); };
  const units = picked.reduce((s, p) => s + pcsOf(p), 0);
  return (
    <div className="picker">
      <div className="pleft">
        <div className="search pscan"><Icon n="search" /><input id="pscan" ref={scanIn} autoFocus autoComplete="off" spellCheck={false} aria-label="Scan or search items" value={q}
          placeholder={codes ? 'Scan a barcode, or search by name, code or category' : 'Search by name, code or category, then press Enter'}
          onChange={(e) => { setQ(e.target.value); setMiss(''); }} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); scan(); } }} />
          {q ? <button className="hclear" onClick={() => { setQ(''); scanIn.current?.focus(); }} aria-label="Clear the search"><Icon n="x" /></button> : null}</div>
        {miss ? <div className="lerr" role="alert">{miss}</div> : null}
        <div className="tw plist" ref={box}>{hits.length || rest.length ? <table className="t"><thead><tr><th>Item</th>{cols.map((c, i) => <th key={i} className="r">{c.th}</th>)}<th style={{ width: 190 }}>{qtyHead}</th></tr></thead><tbody>
          {hits.map(row)}{hits.length && rest.length ? <tr className="psep"><td colSpan={cols.length + 2}>Other items</td></tr> : null}{rest.map(row)}
        </tbody></table> : <Empty i="search" t="No items match" />}</div>
      </div>
      <aside className="pside" id="picked" aria-label={sideTitle}>
        <div className="psh"><b>{sideTitle}</b><span className="chip">{picked.length}</span></div>
        <div className="psl">{picked.length ? picked.map((p, i) => { const w = warn?.(p); return (
          <div key={p.id} className={`prow ${on === p.id ? 'on' : ''} ${w ? 'bad' : ''}`} onClick={() => { setQ(''); focusQty(p); }}>
            <span className="no">{i + 1}</span><div className="pn"><b>{p.name}</b><div className="pq">{qtyText(p, lines[p.id]!, pcsOf(p))}</div>{w ? <div className="pw">{w}</div> : null}</div>
            <button className="rm" onClick={(e) => { e.stopPropagation(); setLine(p, { n: '' }); }} title="Remove this line" aria-label={`Remove ${p.name}`}><Icon n="x" /></button></div>); })
          : <Empty i="layers" t={codes ? 'Scan or find an item, then type the quantity' : 'Find an item, then type the quantity'} />}</div>
        <div className="pst"><b>{picked.length} item{picked.length === 1 ? '' : 's'}, {units} units</b>{sideNote ? <div className="code">{sideNote}</div> : null}</div>
      </aside>
    </div>
  );
}
