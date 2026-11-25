import { useMemo, useState } from 'react';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useCosts, useDeliveries, useProducts, useRanks, useRefresh, useSettings, useShops, useStock, useStockRequests } from '../data/queries';
import { rpc } from '../lib/supabase';
import { ctnTxt, hotSort, pcValue, stockValue } from '../lib/units';
import { dt, fCDF, fUSD, sum, toCDF } from '../lib/format';
import { deliveryNoteHTML, printHTML, stockCountHTML, stockValueHTML } from '../lib/print';
import { Dual, Dual2, Empty, Head, Kpi, Modal, Note, useAction, useToast } from '../components/ui';
import { QtyCell } from './Inventory';
import { blankLine, per, StockPicker, type Line } from '../components/StockPicker';
import type { Delivery, Product, Shop } from '../lib/types';
import { useNavigate } from 'react-router-dom';
import { impStock, readCSV, readXlsx, saveBlob, templateXlsx, type StockImportRow } from '../lib/xlsx';
import { useNoStore } from './Stores';

function DeliveryCard({ d, shop, products, store, onEdit, onCancel, onReceive, onNote, rate }: { d: Delivery; shop?: Shop; products: Map<string, Product>; store: boolean; onEdit?: () => void; onCancel?: () => void; onReceive?: () => void; onNote: () => void; rate: number }) {
  const { profile } = useAuth(), showUSD = store && profile!.role === 'admin';
  const ed = d.delivery_edits.length ? [...d.delivery_edits].sort((a, b) => a.at.localeCompare(b.at)).at(-1)! : null;
  const cdf = (u: number) => toCDF(u, d.rate), got = d.status === 'received';
  const shortLines = got && d.delivery_items.some((i) => (i.received_qty ?? i.qty) < i.qty);
  const status = d.status === 'pending' ? <span className="chip warn"><Icon n="clock" /> Waiting for the shop to receive</span>
    : d.status === 'cancelled' ? <span className="chip bad"><Icon n="x" /> Cancelled</span>
    : <span className={`chip ${shortLines ? 'warn' : 'ok'}`}><Icon n="truck" /> Received{shortLines ? ', some short' : ''}</span>;
  return (
    <div className="card p0">
      <div style={{ padding: '14px 16px', display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap', borderBottom: '1px solid var(--line)' }}>
        <b style={{ fontSize: 17 }}>{d.no}</b>{status}{ed ? <span className="chip warn" title={ed.reason}>Edited</span> : null}
        <span style={{ color: 'var(--muted)' }}>{shop?.name}, sent by {d.created_by_name} on {dt(d.created_at)}</span><span className="sp" />
        {onReceive && d.status === 'pending' ? <button className="btn primary sm" onClick={onReceive}><Icon n="check" /> Receive</button> : null}
        {onEdit && d.status === 'pending' ? <button className="btn sm" onClick={onEdit}><Icon n="edit" /> Edit</button> : null}
        {onCancel && d.status === 'pending' ? <button className="btn sm" onClick={onCancel}><Icon n="x" /> Cancel</button> : null}
        <button className="btn ghost sm" onClick={onNote}><Icon n="doc" /> Delivery note</button>
      </div>
      {ed ? <Note i="edit" warn style={{ margin: '12px 16px 0' }}>Changed by {ed.by_name} on {dt(ed.at)}: {ed.reason}</Note> : null}
      {got ? <Note i="check" warn={shortLines} style={{ margin: '12px 16px 0' }}>Received by {d.received_by_name} on {dt(d.received_at!)}.{d.received_note ? ` Note: ${d.received_note}` : ''}</Note> : null}
      {d.status === 'cancelled' ? <Note i="x" warn style={{ margin: '12px 16px 0' }}>Cancelled{d.received_note ? `: ${d.received_note}` : ''}. Nothing left the store.</Note> : null}
      <div className="tw"><table className="t"><thead><tr><th>Item</th><th className="r">Sent</th>{got ? <th className="r">Received</th> : null}<th>Unit price</th><th>Line value</th></tr></thead><tbody>
        {d.delivery_items.map((it) => { const p = products.get(it.product_id); return <tr key={it.product_id}><td><b>{p?.name}</b><div className="code">{p?.sku}</div></td><td className="r"><b>{it.qty}</b> {p?.stock_unit}{p && ctnTxt(p, it.qty) ? <div className="code">{ctnTxt(p, it.qty)}</div> : null}</td>
          {got ? <td className="r"><span className={`chip ${(it.received_qty ?? it.qty) < it.qty ? 'warn' : 'ok'}`}>{it.received_qty ?? it.qty}</span></td> : null}
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
  const [q, setQ] = useState(''), [open, setOpen] = useState<Delivery | 'new' | null>(null), [note, setNote] = useState<Delivery | null>(null), [cancel, setCancel] = useState<Delivery | null>(null);
  const nav = useNavigate();
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const shopOf = (id: string) => shops.data?.find((s) => s.id === id);
  const list = (dels.data ?? []).filter((d) => !q || (d.no + ' ' + (shopOf(d.shop_id)?.name ?? '')).toLowerCase().includes(q.toLowerCase()));
  const reqs = (useStockRequests().data ?? []).filter((r) => r.status === 'pending').length;
  return (
    <>
      <Head t="Deliveries to shops" s="Pick the outlets and the quantities, then send. Each shop admin checks the goods and approves them; only then do they leave the store stock and enter the shop. A delivery can be corrected or cancelled until it is received."
        a={<><button className="btn ghost" onClick={() => nav('/shop-stock')}><Icon n="store" /> Shop stock</button><button className="btn primary" onClick={() => setOpen('new')}><Icon n="truck" /> New delivery</button></>} />
      {reqs ? <Note i="receipt" warn><span>{reqs} stock request{reqs > 1 ? 's' : ''} from the shops waiting for review. <button className="linkbtn" onClick={() => nav('/requests')}>Open Requests</button></span></Note> : null}
      <div className="toolbar"><div className="search"><Icon n="search" /><input placeholder="Delivery number or shop" value={q} onChange={(e) => setQ(e.target.value)} /></div><span className="chip">{dels.data?.length ?? 0} deliveries</span></div>
      {dels.isLoading ? <div className="card"><Empty i="refresh" t="Loading" /></div> : list.length ? list.map((d) => <DeliveryCard key={d.id} d={d} shop={shopOf(d.shop_id)} products={byId} store rate={settings.data?.rate ?? 1} onEdit={() => setOpen(d)} onCancel={() => setCancel(d)} onNote={() => setNote(d)} />) : <div className="card"><Empty i="truck" t="No deliveries yet" /></div>}
      {cancel ? <ReasonModal title={`Cancel delivery ${cancel.no}`} text="Nothing has left the store yet, so no stock moves. The shop admin will see it as cancelled." button="Cancel delivery" fn="cancel_delivery" id={cancel.id} done="Delivery cancelled" onClose={() => setCancel(null)} /> : null}
      {open ? <DeliveryModal d={open === 'new' ? null : open} onClose={() => setOpen(null)} onSent={(d) => setNote(d)} /> : null}
      {note && shopOf(note.shop_id) ? <NoteModal d={note} shop={shopOf(note.shop_id)!} products={byId} onClose={() => setNote(null)} /> : null}
    </>
  );
}

export function Received() {
  const { profile } = useAuth();
  const shops = useShops(), products = useProducts(), dels = useDeliveries(profile!.shop_id), settings = useSettings();
  const [note, setNote] = useState<Delivery | null>(null), [recv, setRecv] = useState<Delivery | null>(null);
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const shop = shops.data?.find((s) => s.id === profile!.shop_id);
  const list = [...(dels.data ?? [])].sort((x, y) => Number(y.status === 'pending') - Number(x.status === 'pending'));
  const waiting = list.filter((d) => d.status === 'pending').length;
  return (
    <>
      <Head t="Deliveries" s="Stock sent by the central store. Check the goods, enter what actually arrived and approve: only then is it added to this shop's stock." />
      {waiting ? <Note i="truck" warn>{waiting} deliver{waiting > 1 ? 'ies are' : 'y is'} waiting for you to receive.</Note> : null}
      {list.length ? list.map((d) => <DeliveryCard key={d.id} d={d} shop={shop} products={byId} store={false} rate={settings.data?.rate ?? 1} onReceive={() => setRecv(d)} onNote={() => setNote(d)} />) : <div className="card"><Empty i="truck" t={dels.isLoading ? 'Loading' : 'No deliveries yet'} /></div>}
      {note && shop ? <NoteModal d={note} shop={shop} products={byId} onClose={() => setNote(null)} /> : null}
      {recv ? <ReceiveModal d={recv} products={byId} onClose={() => setRecv(null)} /> : null}
    </>
  );
}

function ReceiveModal({ d, products, onClose }: { d: Delivery; products: Map<string, Product>; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction();
  const [got, setGot] = useState<Record<string, string>>(Object.fromEntries(d.delivery_items.map((i) => [i.product_id, String(i.qty)])));
  const [note, setNoteTxt] = useState('');
  const n = (pid: string) => Math.max(0, parseInt(got[pid]) || 0);
  const short = d.delivery_items.filter((i) => n(i.product_id) < i.qty), over = d.delivery_items.filter((i) => n(i.product_id) > i.qty);
  const save = () => a.run(async () => {
    if (over.length) throw new Error('You cannot receive more than was sent');
    if (short.length && note.trim().length < 4) throw new Error('Some items arrived short. Write a short note saying what happened');
    const r = await rpc<{ sent: number; received: number }>('receive_delivery', { p_id: d.id, p_lines: d.delivery_items.map((i) => ({ product_id: i.product_id, qty: n(i.product_id) })), p_note: note });
    await refresh('deliveries', 'stock', 'products', 'audit');
    toast(`${d.no} received: ${r.received} of ${r.sent} units added to the shop stock`); onClose();
  });
  return (
    <Modal title={`Receive delivery ${d.no}`} icon="truck" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Approve and add to shop stock</button></>}>
      <Note i="box">Count what arrived. Each line starts with the quantity sent; lower it if goods are missing or damaged. Only what you approve is added to the shop stock and taken from the central store.</Note>
      <div className="tw"><table className="t"><thead><tr><th>Item</th><th className="r">Sent</th><th style={{ width: 150 }}>Received</th></tr></thead><tbody>
        {d.delivery_items.map((i) => { const p = products.get(i.product_id); return <tr key={i.product_id}><td><b>{p?.name}</b><div className="code">{p?.sku}{p && p.per_carton > 1 && !p.is_bundle ? ` · ${p.per_carton} pcs per carton` : ''}</div></td>
          <td className="r"><b>{i.qty}</b> {p?.stock_unit}{p && ctnTxt(p, i.qty) ? <div className="code">{ctnTxt(p, i.qty)}</div> : null}</td>
          <td><input className="input" type="number" min="0" max={i.qty} inputMode="numeric" value={got[i.product_id]} style={{ minHeight: 42 }} onChange={(e) => setGot({ ...got, [i.product_id]: e.target.value })} aria-label={`Received ${p?.name}`} /></td></tr>; })}
      </tbody></table></div>
      {short.length ? <Note i="alert" warn style={{ marginTop: 12 }}>Short: {short.map((i) => `${products.get(i.product_id)?.name} (${n(i.product_id)} of ${i.qty})`).join(', ')}. The missing goods stay in the central store.</Note> : null}
      <div className="field"><label>Note {short.length ? '(required, what happened?)' : '(optional)'}</label><input id="rnote" className="input" maxLength={120} value={note} onChange={(e) => setNoteTxt(e.target.value)} placeholder="e.g. 1 carton damaged in transport" /></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

function ReasonModal({ title, text, button, fn, id, done, onClose }: { title: string; text: string; button: string; fn: string; id: string; done: string; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction();
  const [r, setR] = useState('');
  const go = () => a.run(async () => { await rpc(fn, { p_id: id, p_reason: r }); await refresh('deliveries', 'audit'); toast(done, 'warn'); onClose(); });
  return (
    <Modal title={title} icon="x" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Back</button><button className="btn danger" disabled={a.busy} onClick={() => void go()}><Icon n="x" /> {button}</button></>}>
      <p>{text}</p><div className="field"><label>Reason</label><input className="input" maxLength={80} value={r} onChange={(e) => setR(e.target.value)} autoFocus /></div><div className="lerr">{a.err}</div>
    </Modal>
  );
}

export function DeliveryModal({ d, pid, sid, onClose, onSent }: { d: Delivery | null; pid?: string; sid?: string; onClose: () => void; onSent?: (d: Delivery) => void }) {
  const shops = useShops(), products = useProducts(), stock = useStock(), settings = useSettings(), refresh = useRefresh(), toast = useToast(), a = useAction(), dels = useDeliveries();
  const init = () => {
    const l: Record<string, Line> = {};
    d?.delivery_items.forEach((it) => { const p = products.data?.find((x) => x.id === it.product_id); const k = p ? per(p) : 0; l[it.product_id] = k && it.qty % k === 0 ? { n: String(it.qty / k), u: 'ctn' } : { n: String(it.qty), u: 'pcs' }; });
    const p = pid && !l[pid] ? products.data?.find((x) => x.id === pid) : undefined; if (p) l[p.id] = blankLine(p);
    return l;
  };
  const [sel, setSel] = useState<string[]>(d ? [d.shop_id] : sid ? [sid] : []);
  const [lines, setLines] = useState<Record<string, Line>>(init);
  const [reason, setReason] = useState('');
  const pcsOf = (p: Product) => { const l = lines[p.id]; if (!l) return 0; const n = Math.max(0, parseInt(l.n) || 0); return l.u === 'ctn' ? n * per(p) : n; };
  // store stock not yet promised to deliveries waiting at a shop (this one excluded when editing)
  const avail = (p: Product) => p.wh_qty - sum((dels.data ?? []).filter((x) => x.status === 'pending' && x.id !== d?.id), (x) => sum(x.delivery_items.filter((i) => i.product_id === p.id), (i) => i.qty));
  const stockAt = (s: string, p: string) => stock.data?.find((r) => r.shop_id === s && r.product_id === p)?.qty ?? 0;
  const all = (products.data ?? []).filter((p) => p.active), chosen = all.filter((p) => pcsOf(p) > 0), k = sel.length;
  const short = chosen.filter((p) => avail(p) < pcsOf(p) * Math.max(1, k));
  const units = sum(chosen, pcsOf);
  const setLine = (p: Product, patch: Partial<Line>) => setLines((x) => ({ ...x, [p.id]: { ...(x[p.id] ?? blankLine(p)), ...patch } }));
  const toggle = (s: string, on: boolean) => setSel(d ? [s] : on ? [...new Set([...sel, s])] : sel.filter((x) => x !== s));
  const save = () => a.run(async () => {
    if (!k) throw new Error('Pick at least one outlet');
    if (!chosen.length) throw new Error('Enter a quantity for at least one item');
    if (short.length) throw new Error('Not enough in the store: ' + short.map((p) => p.name).join(', '));
    const payload = chosen.map((p) => ({ product_id: p.id, qty: pcsOf(p) }));
    if (d) {
      if (reason.trim().length < 4) throw new Error('Write a short reason for the change');
      await rpc('edit_delivery', { p_id: d.id, p_shop: sel[0], p_lines: payload, p_reason: reason });
      await refresh('products', 'stock', 'deliveries', 'audit');
      toast('Delivery updated. It is still waiting for the shop to receive it.');
      onClose(); return;
    }
    const made = await rpc<{ id: string; no: string }[]>('create_deliveries', { p_shops: sel, p_lines: payload });
    await refresh('products', 'stock', 'deliveries', 'audit');
    toast(made.length === 1 ? `${made[0].no} sent. It is added to the shop stock when the shop admin receives it.` : `${made.length} deliveries sent: ${made.map((m) => m.no).join(', ')}. Each shop admin receives them.`);
    onClose();
    if (made.length === 1 && onSent) { const fresh = (await dels.refetch()).data?.find((x) => x.id === made[0].id); if (fresh) onSent(fresh); }
  });
  return (
    <Modal title={d ? 'Edit delivery ' + d.no : 'New delivery to shops'} icon="truck" xl onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> {d ? 'Save changes' : 'Send stock'}{chosen.length ? ` · ${chosen.length} item${chosen.length === 1 ? '' : 's'}` : ''}</button></>}>
      <div className="field"><label>{d ? 'Deliver to (one outlet)' : 'Send to these outlets'}</label>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>{(shops.data ?? []).filter((s) => s.active).map((s) => <label key={s.id} className="chip" style={{ cursor: 'pointer', padding: '8px 12px', fontSize: 14, ...(sel.includes(s.id) ? { background: 'var(--btn)', color: '#fff' } : {}) }}><input type={d ? 'radio' : 'checkbox'} name="dshop" checked={sel.includes(s.id)} onChange={(e) => toggle(s.id, e.target.checked)} /> {s.name}</label>)}</div>
        {d ? null : <span className="hint">Tick one or more outlets. Each ticked outlet gets the same quantities and its own delivery note.</span>}</div>
      <StockPicker all={all} qty={{ lines, setLine, pcsOf }} codes={!!settings.data?.features?.barcode} initQ={pid ? all.find((p) => p.id === pid)?.name : ''}
        cols={[{ th: 'Store can send', td: (p) => <><QtyCell p={p} q={avail(p)} cls={avail(p) <= 0 ? 'bad' : ''} />{avail(p) !== p.wh_qty ? <div className="code">{p.wh_qty - avail(p)} promised</div> : null}</> },
          ...sel.map((s) => ({ th: `${shops.data?.find((x) => x.id === s)?.code} has`, td: (p: Product) => { const v = stockAt(s, p.id); return <QtyCell p={p} q={v} cls={v <= 0 ? 'bad' : v <= 5 ? 'warn' : 'ok'} />; } }))]}
        qtyHead="Send" aria={(p) => `Send ${p.name}`} warn={(p) => (avail(p) < pcsOf(p) * Math.max(1, k) ? `The store can send only ${avail(p)}` : null)}
        sideTitle="To send" sideNote={k ? (k === 1 ? `To ${shops.data?.find((x) => x.id === sel[0])?.name}` : `To each of ${k} outlets, ${units * k} units in all`) : 'No outlet ticked yet'} />
      <div className={`note ${short.length || !k ? 'warn' : ''}`} style={{ marginTop: 12 }}><Icon n={short.length ? 'alert' : 'truck'} /><div>{chosen.length} item{chosen.length === 1 ? '' : 's'}, {units} units to {k ? (k === 1 ? 'each outlet' : `each of ${k} outlets`) : <b>no outlet yet</b>}{k > 1 ? `, ${units * k} units in all` : ''}.{short.length ? <> <b>Not enough in the store:</b> {short.map((p) => p.name).join(', ')}.</> : null}</div></div>
      {d ? <div className="field"><label>Reason for the change</label><input id="dreason" className="input" maxLength={80} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Wrong quantity counted at loading" /></div> : null}
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

export function ShopStockAll() {
  const shops = useShops(), products = useProducts(), stock = useStock(), settings = useSettings(), { profile } = useAuth();
  const [q, setQ] = useState(''), [only, setOnly] = useState('all'), [send, setSend] = useState<{ pid: string; sid?: string } | null>(null), [count, setCount] = useState(false);
  const ranks = useRanks(only === 'all' ? null : only);
  const list = hotSort((products.data ?? []).filter((p) => p.active), ranks.data).filter((p) => !q || (p.name + ' ' + p.sku + ' ' + p.category).toLowerCase().includes(q.toLowerCase()));
  const cols = (shops.data ?? []).filter((s) => s.active && (only === 'all' || s.id === only));
  const at = new Map((stock.data ?? []).map((r) => [r.shop_id + '|' + r.product_id, r.qty]));
  const dels = useDeliveries(), coming = new Map<string, number>();
  (dels.data ?? []).filter((x) => x.status === 'pending').forEach((x) => x.delivery_items.forEach((i) => coming.set(x.shop_id + '|' + i.product_id, (coming.get(x.shop_id + '|' + i.product_id) ?? 0) + i.qty)));
  // the Admin sees each outlet's stock at selling price and at cost; the warehouse sees quantities only
  const isAdmin = profile!.role === 'admin', costs = useCosts(isAdmin), rate = settings.data?.rate ?? 0;
  const cost = new Map((costs.data ?? []).map((c) => [c.product_id, Number(c.cost_usd)])), live = (products.data ?? []).filter((p) => p.active);
  const qtyAt = (sid: string | null, p: Product) => (sid ? at.get(sid + '|' + p.id) ?? 0 : p.wh_qty);
  const worth = (sid: string | null) => { const r = live.map((p) => ({ p, qty: qtyAt(sid, p) })); return { v: stockValue(r, rate), cost: sum(r.filter((x) => x.qty > 0), (x) => (cost.get(x.p.id) ?? 0) * x.qty) }; };
  const one = only !== 'all' && isAdmin ? only : null;
  // without a central store nothing is sent from it: the Admin adds stock straight into the shops (typed or from Excel)
  const noStore = useNoStore(), [stockIn, setStockIn] = useState(false);
  return (
    <>
      <Head t="Shop stock" s={noStore ? 'What each shop has right now, best sellers of the last 30 days first. Add stock straight into the shops from here, typed or from an Excel file.' : 'What each outlet has right now, next to the central store, best sellers of the last 30 days first. Send stock straight from here.'} a={<><button className="btn ghost" onClick={() => setCount(true)}><Icon n="printer" /> Print stock count sheet</button>{noStore ? (isAdmin ? <button className="btn primary" id="stockin" onClick={() => setStockIn(true)}><Icon n="plus" /> Add stock to shops</button> : null)
          : <button className="btn primary" onClick={() => setSend({ pid: '' })}><Icon n="truck" /> New delivery</button>}</>} />
      <div className="toolbar"><div className="search"><Icon n="search" /><input placeholder="Search by name, code or category" value={q} onChange={(e) => setQ(e.target.value)} /></div>
        <select className="input" style={{ width: 'auto' }} value={only} onChange={(e) => setOnly(e.target.value)}><option value="all">All outlets</option>{(shops.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>
        <span className="chip warn">5 or fewer</span><span className="chip bad">None or sold on order</span></div>
      {isAdmin ? <div className="kpis" id="stockvalue">{[{ id: null, name: 'Central store' }, ...cols].map((o) => { const { v, cost: c } = worth(o.id); return (
        <Kpi key={o.id ?? 'store'} i={o.id ? 'store' : 'warehouse'} l={o.name}><Dual2 b={fCDF(v.cdf)} s={`at selling price, ${fUSD(v.usd)}`} /><div className="code">At cost {fUSD(c)} · {v.lines} items in stock</div></Kpi>); })}</div> : null}
      <div className="card p0"><div className="tw">{!list.length ? <Empty i="search" t={products.isLoading ? 'Loading' : 'No items match your search'} /> :
        <table className="t"><thead><tr><th>Item</th><th className="r">Central store</th>{cols.map((s) => <th key={s.id} className="r">{s.name}</th>)}{one ? <th className="r">Value at selling price</th> : null}<th /></tr></thead><tbody>
          {list.map((p) => <tr key={p.id}><td><b>{p.name}</b><div className="code">{p.sku} · {p.category}</div></td><td className="r"><QtyCell p={p} q={p.wh_qty} cls={p.wh_qty <= p.reorder ? 'bad' : ''} /></td>
            {cols.map((s) => { const v = at.get(s.id + '|' + p.id), c = coming.get(s.id + '|' + p.id); return <td key={s.id} className="r">{v === undefined ? <span className="code">Not stocked</span> : <QtyCell p={p} q={v} cls={v <= 0 ? 'bad' : v <= 5 ? 'warn' : 'ok'} />}{c ? <div className="code">+{c} on the way</div> : null}</td>; })}
            {one ? (() => { const q = qtyAt(one, p), pr = toCDF(pcValue(p), rate); return <td className="r nw"><b>{q > 0 ? fCDF(pr * q) : '-'}</b><div className="code">{fCDF(pr)} per {p.is_bundle ? 'set' : 'pc'}</div></td>; })() : null}
            <td>{noStore ? null : <div className="act"><button title="Send to shops" onClick={() => setSend({ pid: p.id, sid: only !== 'all' ? only : undefined })}><Icon n="truck" /></button></div>}</td></tr>)}
        </tbody></table>}</div></div>
      {send ? <DeliveryModal d={null} pid={send.pid || undefined} sid={send.sid} onClose={() => setSend(null)} /> : null}
      {stockIn ? <StockInModal sid={only !== 'all' ? only : undefined} onClose={() => setStockIn(false)} /> : null}
      {count ? <CountSheet onClose={() => setCount(false)} first={only} values={isAdmin} print={(where, sid, zero, values) => {
        const all = live.map((p) => ({ p, qty: qtyAt(sid, p) })).filter((r) => zero || r.qty !== 0).sort((a, b) => a.p.category.localeCompare(b.p.category) || a.p.name.localeCompare(b.p.name));
        printHTML(values ? stockValueHTML(settings.data?.company ?? {}, where, profile!.name, all, rate, (p) => cost.get(p.id) ?? 0) : stockCountHTML(settings.data?.company ?? {}, where, profile!.name, all)); setCount(false);
      }} /> : null}
    </>
  );
}

function CountSheet({ first, values, onClose, print }: { first: string; values: boolean; onClose: () => void; print: (where: string, sid: string | null, zero: boolean, values: boolean) => void }) {
  const shops = useShops();
  const [w, setW] = useState(first === 'all' ? 'store' : first), [zero, setZero] = useState(true), [val, setVal] = useState(false);
  const name = w === 'store' ? 'Central store' : shops.data?.find((s) => s.id === w)?.name ?? '';
  return (
    <Modal title="Print stock count sheet" icon="printer" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" id="cntprint" onClick={() => print(name, w === 'store' ? null : w, zero, val)}><Icon n="printer" /> Print</button></>}>
      <p>A sheet with every item and the stock SIM shows, and empty columns to write what you count, to check the system against the shelves.</p>
      <div className="field"><label>Where</label><select id="cntwhere" className="input" value={w} onChange={(e) => setW(e.target.value)}><option value="store">Central store</option>{(shops.data ?? []).filter((s) => s.active).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></div>
      <label className="switch"><input type="checkbox" checked={zero} onChange={(e) => setZero(e.target.checked)} /><span>Include items with no stock in the system</span></label>
      {values ? <label className="switch"><input id="cntvalue" type="checkbox" checked={val} onChange={(e) => setVal(e.target.checked)} /><span>Print the stock valuation instead: price per pc, value of each item, totals at selling price and at cost</span></label> : null}
    </Modal>
  );
}

/** Without a central store: stock goes straight into the shops ticked, typed item by item or read from an Excel file in
 *  the item template. Items not in the catalogue are made from the file with its details (gross and net cost, prices);
 *  items already in it only get the quantity. Booked at cost as opening stock. */
function StockInModal({ sid, onClose }: { sid?: string; onClose: () => void }) {
  const shops = useShops(), products = useProducts(), stock = useStock(), settings = useSettings(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const [sel, setSel] = useState<string[]>(sid ? [sid] : []), [lines, setLines] = useState<Record<string, Line>>({});
  const [imp, setImp] = useState<{ file: string; rows: StockImportRow[] } | null>(null), [reading, setReading] = useState(false), [impErr, setImpErr] = useState('');
  const pcsOf = (p: Product) => { const l = lines[p.id]; if (!l) return 0; const n = Math.max(0, parseInt(l.n) || 0); return l.u === 'ctn' ? n * per(p) : n; };
  const setLine = (p: Product, patch: Partial<Line>) => setLines((x) => ({ ...x, [p.id]: { ...(x[p.id] ?? blankLine(p)), ...patch } }));
  const stockAt = (s: string, p: string) => stock.data?.find((r) => r.shop_id === s && r.product_id === p)?.qty ?? 0;
  const all = (products.data ?? []).filter((p) => p.active), chosen = all.filter((p) => pcsOf(p) > 0), k = sel.length;
  const newRows = imp?.rows.filter((r) => r.kind === 'new') ?? [], bad = imp?.rows.filter((r) => r.kind === 'bad') ?? [], none = imp?.rows.filter((r) => r.kind === 'none') ?? [];
  const units = sum(chosen, pcsOf) + sum(newRows, (r) => r.qty);
  const toggle = (s: string, on: boolean) => setSel(on ? [...new Set([...sel, s])] : sel.filter((x) => x !== s));
  const pick = async (f?: File) => {
    if (!f) return; setImpErr(''); setImp(null); setReading(true);
    try {
      const ext = f.name.toLowerCase().split('.').pop();
      if (ext === 'xls') throw new Error('Old .xls files are not supported. In Excel choose File, Save As, Excel Workbook (.xlsx).');
      const sheet = ext === 'xlsx' ? await readXlsx(await f.arrayBuffer()) : ext === 'csv' || ext === 'txt' ? readCSV(await f.text()) : null;
      if (!sheet) throw new Error('Choose an .xlsx or .csv file');
      const rows = impStock(sheet, products.data ?? []);
      // items already in the catalogue: the file's quantities go into the list (in cartons when they come to whole cartons)
      const tot = new Map<string, number>();
      rows.filter((r) => r.kind === 'existing').forEach((r) => tot.set(r.product_id!, (tot.get(r.product_id!) ?? 0) + r.qty));
      setLines((x) => { const n = { ...x }; tot.forEach((q, id) => { const p = all.find((y) => y.id === id); const c = p ? per(p) : 0; n[id] = c && q % c === 0 ? { n: String(q / c), u: 'ctn' } : { n: String(q), u: 'pcs' }; }); return n; });
      setImp({ file: f.name, rows });
    } catch (e) { setImpErr((e as Error).message); } finally { setReading(false); }
  };
  const save = () => a.run(async () => {
    if (!k) throw new Error('Tick at least one shop');
    if (bad.length) throw new Error(`${bad.length} row${bad.length === 1 ? '' : 's'} of ${imp!.file} ${bad.length === 1 ? 'has an error' : 'have errors'}. Fix ${bad.length === 1 ? 'it' : 'them'} in Excel and choose the file again`);
    if (!chosen.length && !newRows.length) throw new Error('Enter a quantity for at least one item, or import an Excel file');
    const res = await rpc<{ created: number; items: number; units: number; shops: number }>('stock_in_shops', {
      p_shops: sel, p_lines: chosen.map((p) => ({ product_id: p.id, qty: pcsOf(p) })),
      p_new: newRows.map(({ n, row: { o, sku, barcode } }) => ({ row: n, name: o.name, category: o.category, carton_cost: o.carton_cost, net_cost: isNaN(o.net_cost) ? null : o.net_cost,
        per_carton: o.per_carton, pc: o.pc, half: o.half, dzn: o.dzn, ctn: o.ctn, open_cartons: o.open_cartons, open_pcs: o.open_pcs, reorder: o.reorder, sku, barcode })),
      p_file: imp?.file ?? '' });
    await refresh('products', 'costs', 'stock', 'audit', 'categories');
    toast(`${res.units} units of ${res.items} items added to ${res.shops === 1 ? shops.data?.find((s) => s.id === sel[0])?.name : `each of ${res.shops} shops`}${res.created ? `; ${res.created} new item${res.created === 1 ? '' : 's'} made` : ''}`);
    onClose();
  });
  return (
    <Modal title="Add stock to shops" icon="plus" xl onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" id="stockgo" disabled={a.busy || reading} onClick={() => void save()}><Icon n="check" /> Add stock{chosen.length + newRows.length ? ` · ${chosen.length + newRows.length} items` : ''}</button></>}>
      <div className="field"><label>Add to these shops</label>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>{(shops.data ?? []).filter((s) => s.active).map((s) => <label key={s.id} className="chip" style={{ cursor: 'pointer', padding: '8px 12px', fontSize: 14, ...(sel.includes(s.id) ? { background: 'var(--btn)', color: '#fff' } : {}) }}><input type="checkbox" checked={sel.includes(s.id)} onChange={(e) => toggle(s.id, e.target.checked)} /> {s.name}</label>)}</div>
        <span className="hint">There is no central store: the stock goes straight into each shop ticked, the same quantities in each.</span></div>
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'center', margin: '4px 0 12px' }}>
        <label className="btn" style={{ cursor: 'pointer' }}><Icon n="download" /> Import from Excel<input id="stockfile" type="file" accept=".xlsx,.csv,.txt" style={{ display: 'none' }} onChange={(e) => { void pick(e.target.files?.[0]); e.target.value = ''; }} /></label>
        <button className="btn ghost" onClick={() => saveBlob(templateXlsx(), 'QuickSales-items-template.xlsx')}><Icon n="download" /> Download Excel template</button>
        <span className="hint">The item template: gross and net carton cost, prices, and the cartons and pcs to add (Opening cartons, Opening pcs). Items not in the catalogue are made from the file; items already in it only get the quantity.</span>
      </div>
      {reading ? <Empty i="refresh" t="Reading the file" /> : null}
      {impErr ? <Note i="alert" warn>{impErr}</Note> : null}
      {imp ? <div className={`note ${bad.length ? 'warn' : ''}`} id="stockimp" style={{ marginBottom: 12 }}><Icon n={bad.length ? 'alert' : 'doc'} /><div style={{ flex: 1, minWidth: 0 }}>
        <b>{imp.file}</b>: {(() => { const n = imp.rows.filter((r) => r.kind === 'existing').length; return `${n} item${n === 1 ? '' : 's'}`; })()} already in the catalogue (their quantities are in the list below), {newRows.length} new item{newRows.length === 1 ? '' : 's'} to make{none.length ? `, ${none.length} with no quantity` : ''}{bad.length ? <>, <b>{bad.length} with errors</b></> : null}.
        {newRows.length || bad.length ? <div className="tw" style={{ marginTop: 8, maxHeight: '30vh', overflow: 'auto' }}><table className="t" style={{ fontSize: 13 }}><thead><tr><th>Row</th><th>Item</th><th>Carton cost</th><th className="r">Per pc</th><th className="r">Per dozen</th><th className="r">Per carton</th><th className="r">To add</th><th>Status</th></tr></thead><tbody>
          {[...bad, ...newRows].map((r) => { const o = r.row.o; return <tr key={r.n}><td className="code">{r.n}</td><td><b>{r.name || '(no name)'}</b><div className="code">{o.category}{r.row.sku ? ' · ' + r.row.sku : ''}</div></td>
            <td className="nw">{isNaN(o.carton_cost) ? '-' : fUSD(o.carton_cost)}{!isNaN(o.net_cost) ? <div className="code">net {fUSD(o.net_cost)}</div> : null}<div className="code">{isNaN(o.per_carton) ? '-' : o.per_carton} pcs</div></td>
            <td className="r nw">{o.pc ? fUSD(o.pc) : '-'}</td><td className="r nw">{o.dzn ? fUSD(o.dzn) : '-'}</td><td className="r nw">{o.ctn ? fUSD(o.ctn) : '-'}</td><td className="r nw">{r.kind === 'new' ? `${r.qty} pcs` : ''}</td>
            <td>{r.kind === 'new' ? <span className="chip ok">New item</span> : <span className="chip bad">{r.msg}</span>}</td></tr>; })}
        </tbody></table></div> : null}
      </div></div> : null}
      <StockPicker all={all} qty={{ lines, setLine, pcsOf }} codes={!!settings.data?.features?.barcode}
        cols={sel.map((s) => ({ th: `${shops.data?.find((x) => x.id === s)?.code} has`, td: (p: Product) => { const v = stockAt(s, p.id); return <QtyCell p={p} q={v} cls={v <= 0 ? 'bad' : v <= 5 ? 'warn' : 'ok'} />; } }))}
        qtyHead="Add" aria={(p) => `Add ${p.name}`} sideTitle="To add" sideNote={k ? (k === 1 ? `Into ${shops.data?.find((x) => x.id === sel[0])?.name}` : `Into each of ${k} shops`) : 'No shop ticked yet'} />
      <div className={`note ${!k ? 'warn' : ''}`} style={{ marginTop: 12 }}><Icon n="store" /><div>{chosen.length + newRows.length} item{chosen.length + newRows.length === 1 ? '' : 's'}{newRows.length ? ` (${newRows.length} new)` : ''}, {units} units into {k ? (k === 1 ? shops.data?.find((x) => x.id === sel[0])?.name : `each of ${k} shops`) : <b>no shop yet</b>}. Booked at cost as opening stock.</div></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}
