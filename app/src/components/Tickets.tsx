// Price tickets for the shelves: pick items and copies, then print on A4 or a label printer.
import { useState } from 'react';
import { Icon } from '../lib/icons';
import { fCDF, toCDF } from '../lib/format';
import { ticketsHTML, printHTML, type TicketUnit } from '../lib/print';
import { unitLabel, unitsOf } from '../lib/units';
import { Empty, Modal, Note } from './ui';
import type { Product } from '../lib/types';

export function TicketsModal({ products, rate, shopName, onClose }: { products: Product[]; rate: number; shopName: string; onClose: () => void }) {
  const [q, setQ] = useState(''), [n, setN] = useState<Record<string, string>>({}), [layout, setLayout] = useState<'a4' | 'label'>(() => { try { return (localStorage.getItem('sim.tickets') as 'a4' | 'label') || 'a4'; } catch { return 'a4'; } });
  const [units, setUnits] = useState<TicketUnit[]>(() => { try { const v = JSON.parse(localStorage.getItem('sim.ticketunits') ?? 'null'); return Array.isArray(v) && v.length ? v : ['pcs', 'dzn', 'carton']; } catch { return ['pcs', 'dzn', 'carton']; } });
  const toggle = (u: TicketUnit) => { const n = units.includes(u) ? units.filter((x) => x !== u) : [...units, u]; setUnits(n); try { localStorage.setItem('sim.ticketunits', JSON.stringify(n)); } catch { /* not saved */ } };
  const has = (p: Product) => unitsOf(p).some((u) => units.includes((u.u === 'set' || u.piece ? 'pcs' : u.u) as TicketUnit));
  const ql = q.trim().toLowerCase();
  const copies = (id: string) => Math.max(0, Math.min(200, parseInt(n[id]) || 0));
  const chosen = products.filter((p) => copies(p.id) > 0 && has(p)), skipped = products.filter((p) => copies(p.id) > 0 && !has(p));
  const list = products.filter((p) => copies(p.id) > 0 || !ql || (p.name + ' ' + p.sku + ' ' + p.category).toLowerCase().includes(ql)).slice(0, 120);
  const total = chosen.reduce((s, p) => s + copies(p.id), 0);
  const html = chosen.length ? ticketsHTML(chosen.map((p) => ({ p, copies: copies(p.id) })), rate, layout, shopName, units) : '';
  const pick = (l: 'a4' | 'label') => { setLayout(l); try { localStorage.setItem('sim.tickets', l); } catch { /* not saved */ } };
  return (
    <Modal title="Print price tickets" icon="tag" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Close</button><button className="btn primary" id="tprint" disabled={!total} onClick={() => printHTML(html)}><Icon n="printer" /> Print {total} ticket{total === 1 ? '' : 's'}</button></>}>
      <div className="toolbar"><div className="seg"><button className={layout === 'a4' ? 'on' : ''} onClick={() => pick('a4')}>A4 sheet, 24 per page</button><button className={layout === 'label' ? 'on' : ''} onClick={() => pick('label')}>Label printer, 50 x 30 mm</button></div>
        <button className="btn sm" onClick={() => setN(Object.fromEntries(list.map((p) => [p.id, '1'])))}>1 of each shown</button>{chosen.length ? <button className="btn sm" onClick={() => setN({})}>Clear</button> : null}</div>
      <div className="field"><label>Prices on the ticket</label><div className="mchips" id="tunits">{([['pcs', 'Pcs'], ['half dzn', 'Half dozen'], ['dzn', 'Dozen'], ['carton', 'Carton']] as [TicketUnit, string][]).map(([u, l]) => <label key={u} className="chip" style={{ padding: '8px 12px', fontSize: 14, ...(units.includes(u) ? { background: 'var(--btn)', color: '#fff' } : {}) }}><input type="checkbox" checked={units.includes(u)} onChange={() => toggle(u)} /> {l}</label>)}</div>
        <span className="hint">Tick one or more. Each ticket shows only the ticked prices the item has.</span></div>
      <div className="search" style={{ maxWidth: 'none', marginBottom: 10 }}><Icon n="search" /><input placeholder="Find items" value={q} onChange={(e) => setQ(e.target.value)} autoFocus /></div>
      <div className="tw" style={{ maxHeight: '36vh', overflow: 'auto', border: '1px solid var(--line)', borderRadius: 12 }}>
        {list.length ? <table className="t"><thead><tr><th>Item</th><th>Prices</th><th style={{ width: 110 }}>Tickets</th></tr></thead><tbody>
          {list.map((p) => <tr key={p.id}><td><b>{p.name}</b><div className="code">{p.sku}</div></td><td className="code">{unitsOf(p).map((u) => `${unitLabel(u)} ${fCDF(toCDF(u.usd, rate))}`).join(' · ')}</td>
            <td><input className="input" type="number" min="0" max="200" placeholder="0" style={{ minHeight: 40 }} value={n[p.id] ?? ''} onChange={(e) => setN({ ...n, [p.id]: e.target.value })} aria-label={`Tickets for ${p.name}`} /></td></tr>)}
        </tbody></table> : <Empty i="search" t="No items match" />}
      </div>
      {skipped.length ? <Note i="alert" warn style={{ marginTop: 12 }}>No ticked price for: {skipped.map((p) => p.name).join(', ')}. Tick another unit to print them.</Note> : null}
      {html ? <div className="tprev" style={{ marginTop: 12 }} dangerouslySetInnerHTML={{ __html: html }} /> : <Note i="tag" style={{ marginTop: 12 }}>Enter how many tickets you want for each item. Prices are today's shop prices in Francs, from the Admin's price list.</Note>}
    </Modal>
  );
}
