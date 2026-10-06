import { useMemo, useState } from 'react';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useDeliveries, useProducts, useRefresh, useSettings, useShops, useStock } from '../data/queries';
import { rpc } from '../lib/supabase';
import { ctnTxt } from '../lib/units';
import { dt, fCDF, sum } from '../lib/format';
import { deliveryNoteHTML, printHTML } from '../lib/print';
import { Dual, Empty, Head, Modal, Note, useAction, useToast } from '../components/ui';
import { QtyCell } from './Inventory';
import type { Delivery, Product, Shop } from '../lib/types';
import { useNavigate } from 'react-router-dom';

function DeliveryCard({ d, shop, products, store, onEdit, onNote, rate }: { d: Delivery; shop?: Shop; products: Map<string, Product>; store: boolean; onEdit?: () => void; onNote: () => void; rate: number }) {
  const { profile } = useAuth(), showUSD = store && profile!.role === 'admin';
  const ed = d.delivery_edits.length ? [...d.delivery_edits].sort((a, b) => a.at.localeCompare(b.at)).at(-1)! : null;
  const cdf = (u: number) => Math.round((u * d.rate) / 10) * 10;
  return (
    <div className="card p0">
      <div style={{ padding: '14px 16px', display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap', borderBottom: '1px solid var(--line)' }}>
        <b style={{ fontSize: 17 }}>{d.no}</b><span className="chip ok"><Icon n="truck" /> Delivered</span>{ed ? <span className="chip warn" title={ed.reason}>Edited</span> : null}
        <span style={{ color: 'var(--muted)' }}>{shop?.name}, sent by {d.created_by_name} on {dt(d.created_at)}</span><span className="sp" />
        {onEdit ? <button className="btn sm" onClick={onEdit}><Icon n="edit" /> Edit</button> : null}
        <button className="btn ghost sm" onClick={onNote}><Icon n="doc" /> Delivery note</button>
      </div>
      {ed ? <Note i="edit" warn style={{ margin: '12px 16px 0' }}>Changed by {ed.by_name} on {dt(ed.at)}: {ed.reason}</Note> : null}
      <div className="tw"><table className="t"><thead><tr><th>Item</th><th className="r">Qty</th><th>Unit price</th><th>Line value</th></tr></thead><tbody>
        {d.delivery_items.map((it) => { const p = products.get(it.product_id); return <tr key={it.product_id}><td><b>{p?.name}</b><div className="code">{p?.sku}</div></td><td className="r"><b>{it.qty}</b> {p?.stock_unit}{p && ctnTxt(p, it.qty) ? <div className="code">{ctnTxt(p, it.qty)}</div> : null}</td>
          <td>{showUSD ? <Dual usd={it.price_usd} rate={rate} /> : <b>{fCDF(cdf(it.price_usd))}</b>}</td><td>{showUSD ? <Dual usd={it.price_usd * it.qty} rate={rate} /> : <b>{fCDF(cdf(it.price_usd) * it.qty)}</b>}</td></tr>; })}
      </tbody></table></div>
      <div style={{ padding: '12px 16px', borderTop: '1px solid var(--line)', display: 'flex', justifyContent: 'flex-end', gap: 10, alignItems: 'center' }}><span style={{ color: 'var(--muted)', fontWeight: 700 }}>Value at selling price</span>
        {showUSD ? <Dual usd={sum(d.delivery_items, (i) => i.price_usd * i.qty)} rate={rate} /> : <b style={{ fontSize: 18 }}>{fCDF(sum(d.delivery_items, (i) => cdf(i.price_usd) * i.qty))}</b>}</div>
    </div>
  );
}

function NoteModal({ d, shop, products, onClose }: { d: Delivery; shop: Shop; products: Map<string, Product>; onClose: () => void }) {
  const { profile } = useAuth(), settings = useSettings();
  const html = deliveryNoteHTML(d, shop, settings.data?.company ?? {}, products, profile!.role === 'admin');
  return <Modal title="Delivery note" icon="doc" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Close</button><button className="btn primary" onClick={() => printHTML(html)}><Icon n="printer" /> Print or save as PDF</button></>}><div dangerouslySetInnerHTML={{ __html: html }} /></Modal>;
}

export default function Deliveries() {
  const shops = useShops(), products = useProducts(), dels = useDeliveries(), settings = useSettings();
  const [q, setQ] = useState(''), [open, setOpen] = useState<Delivery | 'new' | null>(null), [note, setNote] = useState<Delivery | null>(null);
  const nav = useNavigate();
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const shopOf = (id: string) => shops.data?.find((s) => s.id === id);
  const list = (dels.data ?? []).filter((d) => !q || (d.no + ' ' + (shopOf(d.shop_id)?.name ?? '')).toLowerCase().includes(q.toLowerCase()));
  return (
    <>
      <Head t="Deliveries to shops" s="Pick the outlets and the quantities, then send. Shop stock goes up at once and the selling price travels with the goods. A delivery can be corrected later."
        a={<><button className="btn ghost" onClick={() => nav('/shop-stock')}><Icon n="store" /> Shop stock</button><button className="btn primary" onClick={() => setOpen('new')}><Icon n="truck" /> New delivery</button></>} />
      <div className="toolbar"><div className="search"><Icon n="search" /><input placeholder="Delivery number or shop" value={q} onChange={(e) => setQ(e.target.value)} /></div><span className="chip">{dels.data?.length ?? 0} deliveries</span></div>
      {dels.isLoading ? <div className="card"><Empty i="refresh" t="Loading" /></div> : list.length ? list.map((d) => <DeliveryCard key={d.id} d={d} shop={shopOf(d.shop_id)} products={byId} store rate={settings.data?.rate ?? 1} onEdit={() => setOpen(d)} onNote={() => setNote(d)} />) : <div className="card"><Empty i="truck" t="No deliveries yet" /></div>}
      {open ? <DeliveryModal d={open === 'new' ? null : open} onClose={() => setOpen(null)} onSent={(d) => setNote(d)} /> : null}
      {note && shopOf(note.shop_id) ? <NoteModal d={note} shop={shopOf(note.shop_id)!} products={byId} onClose={() => setNote(null)} /> : null}
    </>
  );
}

export function Received() {
  const { profile } = useAuth();
  const shops = useShops(), products = useProducts(), dels = useDeliveries(profile!.shop_id), settings = useSettings();
  const [note, setNote] = useState<Delivery | null>(null);
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const shop = shops.data?.find((s) => s.id === profile!.shop_id);
  return (
    <>
      <Head t="Deliveries received" s="Stock sent to this shop by the central store. It is added to the shop stock as soon as the store sends it." />
      {(dels.data ?? []).length ? dels.data!.map((d) => <DeliveryCard key={d.id} d={d} shop={shop} products={byId} store={false} rate={settings.data?.rate ?? 1} onNote={() => setNote(d)} />) : <div className="card"><Empty i="truck" t={dels.isLoading ? 'Loading' : 'No deliveries received yet'} /></div>}
      {note && shop ? <NoteModal d={note} shop={shop} products={byId} onClose={() => setNote(null)} /> : null}
    </>
  );
}

type Line = { n: string; u: 'ctn' | 'pcs' };
export function DeliveryModal({ d, pid, sid, onClose, onSent }: { d: Delivery | null; pid?: string; sid?: string; onClose: () => void; onSent?: (d: Delivery) => void }) {
  const shops = useShops(), products = useProducts(), stock = useStock(), refresh = useRefresh(), toast = useToast(), a = useAction(), dels = useDeliveries();
  const per = (p: Product) => (!p.is_bundle && p.per_carton > 1 ? p.per_carton : 0);
  const init = () => {
    const l: Record<string, Line> = {};
    d?.delivery_items.forEach((it) => { const p = products.data?.find((x) => x.id === it.product_id); const k = p ? per(p) : 0; l[it.product_id] = k && it.qty % k === 0 ? { n: String(it.qty / k), u: 'ctn' } : { n: String(it.qty), u: 'pcs' }; });
    if (pid && !l[pid]) { const p = products.data?.find((x) => x.id === pid); l[pid] = { n: '', u: p && per(p) ? 'ctn' : 'pcs' }; }
    return l;
  };
  const [sel, setSel] = useState<string[]>(d ? [d.shop_id] : sid ? [sid] : []);
  const [lines, setLines] = useState<Record<string, Line>>(init);
  const [q, setQ] = useState(pid ? products.data?.find((x) => x.id === pid)?.name ?? '' : ''), [reason, setReason] = useState('');
  const pcsOf = (p: Product) => { const l = lines[p.id]; if (!l) return 0; const n = Math.max(0, parseInt(l.n) || 0); return l.u === 'ctn' ? n * per(p) : n; };
  const old = (id: string) => (d ? sum(d.delivery_items.filter((i) => i.product_id === id), (i) => i.qty) : 0);
  const stockAt = (s: string, p: string) => stock.data?.find((r) => r.shop_id === s && r.product_id === p)?.qty ?? 0;
  const all = products.data ?? [], chosen = all.filter((p) => pcsOf(p) > 0), k = sel.length;
  const short = chosen.filter((p) => p.wh_qty + old(p.id) < pcsOf(p) * Math.max(1, k));
  const ql = q.trim().toLowerCase();
  const list = all.filter((p) => pcsOf(p) > 0 || !ql || (p.name + ' ' + p.sku + ' ' + p.category).toLowerCase().includes(ql)).sort((x, y) => Number(pcsOf(y) > 0) - Number(pcsOf(x) > 0)).slice(0, 150);
  const setLine = (p: Product, patch: Partial<Line>) => setLines({ ...lines, [p.id]: { ...(lines[p.id] ?? { n: '', u: per(p) ? 'ctn' : 'pcs' }), ...patch } });
  const toggle = (s: string, on: boolean) => setSel(d ? [s] : on ? [...new Set([...sel, s])] : sel.filter((x) => x !== s));
  const save = () => a.run(async () => {
    if (!k) throw new Error('Pick at least one outlet');
    if (!chosen.length) throw new Error('Enter a quantity for at least one item');
    if (short.length) throw new Error('Not enough in the store: ' + short.map((p) => p.name).join(', '));
    const payload = chosen.map((p) => ({ product_id: p.id, qty: pcsOf(p) }));
    if (d) {
      if (reason.trim().length < 4) throw new Error('Write a short reason for the change');
      const r = await rpc<{ negative: number; from_shop: string }>('edit_delivery', { p_id: d.id, p_shop: sel[0], p_lines: payload, p_reason: reason });
      await refresh('products', 'stock', 'deliveries', 'audit');
      toast(r.negative ? `Delivery updated. ${shops.data?.find((s) => s.id === r.from_shop)?.name} is now short on ${r.negative} item${r.negative > 1 ? 's' : ''}.` : 'Delivery updated. Stock corrected.', r.negative ? 'warn' : 'ok');
      onClose(); return;
    }
    const made = await rpc<{ id: string; no: string }[]>('create_deliveries', { p_shops: sel, p_lines: payload });
    await refresh('products', 'stock', 'deliveries', 'audit');
    toast(made.length === 1 ? `${made[0].no} sent. Shop stock updated.` : `${made.length} deliveries sent: ${made.map((m) => m.no).join(', ')}`);
    onClose();
    if (made.length === 1 && onSent) { const fresh = (await dels.refetch()).data?.find((x) => x.id === made[0].id); if (fresh) onSent(fresh); }
  });
  return (
    <Modal title={d ? 'Edit delivery ' + d.no : 'New delivery to shops'} icon="truck" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> {d ? 'Save changes' : 'Send stock'}</button></>}>
      <div className="field"><label>{d ? 'Deliver to (one outlet)' : 'Send to these outlets'}</label>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>{(shops.data ?? []).filter((s) => s.active).map((s) => <label key={s.id} className="chip" style={{ cursor: 'pointer', padding: '8px 12px', fontSize: 14, ...(sel.includes(s.id) ? { background: 'var(--btn)', color: '#fff' } : {}) }}><input type={d ? 'radio' : 'checkbox'} name="dshop" checked={sel.includes(s.id)} onChange={(e) => toggle(s.id, e.target.checked)} /> {s.name}</label>)}</div>
        {d ? null : <span className="hint">Tick one or more outlets. Each ticked outlet gets the same quantities and its own delivery note.</span>}</div>
      <div className="search" style={{ maxWidth: 'none', marginBottom: 10 }}><Icon n="search" /><input placeholder="Find an item by name, code or category" value={q} onChange={(e) => setQ(e.target.value)} /></div>
      <div className="tw" style={{ maxHeight: '48vh', overflow: 'auto', border: '1px solid var(--line)', borderRadius: 12 }}>
        {list.length ? <table className="t"><thead><tr><th>Item</th><th className="r">Store has</th>{sel.map((s) => <th key={s} className="r">{shops.data?.find((x) => x.id === s)?.code} has</th>)}<th style={{ width: 200 }}>Send</th></tr></thead><tbody>
          {list.map((p) => { const l = lines[p.id] ?? { n: '', u: per(p) ? 'ctn' : 'pcs' }; return <tr key={p.id}><td><b>{p.name}</b><div className="code">{p.sku}{per(p) ? ` · ${per(p)} pcs per carton` : ''}</div></td>
            <td className="r"><QtyCell p={p} q={p.wh_qty + old(p.id)} cls={p.wh_qty + old(p.id) <= 0 ? 'bad' : ''} /></td>
            {sel.map((s) => { const v = stockAt(s, p.id); return <td key={s} className="r"><QtyCell p={p} q={v} cls={v <= 0 ? 'bad' : v <= 5 ? 'warn' : 'ok'} /></td>; })}
            <td><div style={{ display: 'flex', gap: 6 }}><input className="input" type="number" min="0" inputMode="numeric" placeholder="0" value={l.n} style={{ minHeight: 42, width: 84 }} onChange={(e) => setLine(p, { n: e.target.value })} aria-label={`Send ${p.name}`} />
              {per(p) ? <select className="input" style={{ minHeight: 42, width: 'auto', padding: '0 8px' }} value={l.u} onChange={(e) => setLine(p, { u: e.target.value as Line['u'] })}><option value="ctn">ctn</option><option value="pcs">pcs</option></select> : <span className="code" style={{ alignSelf: 'center' }}>{p.stock_unit}</span>}</div></td></tr>; })}
        </tbody></table> : <Empty i="search" t="No items match" />}
      </div>
      <div className={`note ${short.length || !k ? 'warn' : ''}`} style={{ marginTop: 12 }}><Icon n={short.length ? 'alert' : 'truck'} /><div>{chosen.length} item{chosen.length === 1 ? '' : 's'}, {sum(chosen, pcsOf)} units to {k ? (k === 1 ? 'each outlet' : `each of ${k} outlets`) : <b>no outlet yet</b>}{k > 1 ? `, ${sum(chosen, pcsOf) * k} units in all` : ''}.{short.length ? <> <b>Not enough in the store:</b> {short.map((p) => p.name).join(', ')}.</> : null}</div></div>
      {d ? <div className="field"><label>Reason for the change</label><input id="dreason" className="input" maxLength={80} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Wrong quantity counted at loading" /></div> : null}
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

export function ShopStockAll() {
  const shops = useShops(), products = useProducts(), stock = useStock();
  const [q, setQ] = useState(''), [only, setOnly] = useState('all'), [send, setSend] = useState<{ pid: string; sid?: string } | null>(null);
  const list = (products.data ?? []).filter((p) => !q || (p.name + ' ' + p.sku + ' ' + p.category).toLowerCase().includes(q.toLowerCase()));
  const cols = (shops.data ?? []).filter((s) => s.active && (only === 'all' || s.id === only));
  const at = new Map((stock.data ?? []).map((r) => [r.shop_id + '|' + r.product_id, r.qty]));
  return (
    <>
      <Head t="Shop stock" s="What each outlet has right now, next to the central store. Send stock straight from here." a={<button className="btn primary" onClick={() => setSend({ pid: '' })}><Icon n="truck" /> New delivery</button>} />
      <div className="toolbar"><div className="search"><Icon n="search" /><input placeholder="Search by name, code or category" value={q} onChange={(e) => setQ(e.target.value)} /></div>
        <select className="input" style={{ width: 'auto' }} value={only} onChange={(e) => setOnly(e.target.value)}><option value="all">All outlets</option>{(shops.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>
        <span className="chip warn">5 or fewer</span><span className="chip bad">None or sold on order</span></div>
      <div className="card p0"><div className="tw">{!list.length ? <Empty i="search" t={products.isLoading ? 'Loading' : 'No items match your search'} /> :
        <table className="t"><thead><tr><th>Item</th><th className="r">Central store</th>{cols.map((s) => <th key={s.id} className="r">{s.name}</th>)}<th /></tr></thead><tbody>
          {list.map((p) => <tr key={p.id}><td><b>{p.name}</b><div className="code">{p.sku} · {p.category}</div></td><td className="r"><QtyCell p={p} q={p.wh_qty} cls={p.wh_qty <= p.reorder ? 'bad' : ''} /></td>
            {cols.map((s) => { const v = at.get(s.id + '|' + p.id); return <td key={s.id} className="r">{v === undefined ? <span className="code">Not stocked</span> : <QtyCell p={p} q={v} cls={v <= 0 ? 'bad' : v <= 5 ? 'warn' : 'ok'} />}</td>; })}
            <td><div className="act"><button title="Send to shops" onClick={() => setSend({ pid: p.id, sid: only !== 'all' ? only : undefined })}><Icon n="truck" /></button></div></td></tr>)}
        </tbody></table>}</div></div>
      {send ? <DeliveryModal d={null} pid={send.pid || undefined} sid={send.sid} onClose={() => setSend(null)} /> : null}
    </>
  );
}
