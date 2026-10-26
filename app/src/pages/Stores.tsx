// Goods in from suppliers, returns from the shops to the central store, and the stock and
// shop statements the warehouse and the shop admin can read.
import { useMemo, useState } from 'react';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useGrns, useLedgers, useProducts, useRefresh, useReturns, useSettings, useShops, useStock, useSupplierReturns, useSupplierReturnValues, useSuppliers } from '../data/queries';
import { rpc } from '../lib/supabase';
import { ctnTxt } from '../lib/units';
import { dt, fUSD, sum } from '../lib/format';
import { printHTML, supplierReturnNoteHTML } from '../lib/print';
import { Empty, Head, Modal, Note, useAction, useToast } from '../components/ui';
import { blankLine, per, StockPicker, type Line } from '../components/StockPicker';
import { QtyCell } from './Inventory';
import { BillModal, StatementView, usePayables } from './Accounts';
import type { Grn, Product, ShopReturn, SupplierReturn } from '../lib/types';

export { per, type Line };
/** Quantity entry by carton or pcs, shared by goods in and returns. */
export function useQtyLines(init: Record<string, Line> = {}) {
  const [lines, setLines] = useState<Record<string, Line>>(init);
  const pcsOf = (p: Product) => { const l = lines[p.id]; if (!l) return 0; const n = Math.max(0, parseInt(l.n) || 0); return l.u === 'ctn' ? n * per(p) : n; };
  const setLine = (p: Product, patch: Partial<Line>) => setLines((x) => ({ ...x, [p.id]: { ...(x[p.id] ?? blankLine(p)), ...patch } }));
  const cell = (p: Product) => { const l = lines[p.id] ?? blankLine(p); return (
    <div style={{ display: 'flex', gap: 6 }}><input className="input" type="number" min="0" inputMode="numeric" placeholder="0" value={l.n} style={{ minHeight: 42, width: 84 }} onChange={(e) => setLine(p, { n: e.target.value })} aria-label={`Quantity ${p.name}`} />
      {per(p) ? <select className="input" style={{ minHeight: 42, width: 'auto', padding: '0 8px' }} value={l.u} onChange={(e) => setLine(p, { u: e.target.value as Line['u'] })}><option value="ctn">ctn</option><option value="pcs">pcs</option></select> : <span className="code" style={{ alignSelf: 'center' }}>{p.stock_unit}</span>}</div>); };
  return { pcsOf, cell, setLine, lines };
}

export function ReceiveGoodsModal({ pid, onClose }: { pid?: string; onClose: () => void }) {
  const products = useProducts(), suppliers = useSuppliers(), settings = useSettings(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const [sup, setSup] = useState(''), [ref, setRef] = useState(''), [note, setNote] = useState('');
  const qty = useQtyLines(), { pcsOf } = qty;
  const s = suppliers.data?.find((x) => x.id === sup), theirs = new Set((s?.supplier_items ?? []).map((i) => i.product_id));
  // the supplier's items first, then by name: the order stays put while quantities are typed
  const all = (products.data ?? []).filter((p) => p.active).sort((x, y) => Number(theirs.has(y.id)) - Number(theirs.has(x.id)) || x.name.localeCompare(y.name));
  const chosen = all.filter((p) => pcsOf(p) > 0), units = sum(chosen, pcsOf);
  const save = () => a.run(async () => {
    if (!sup) throw new Error('Choose the supplier first');
    if (!chosen.length) throw new Error('Enter a quantity for at least one item');
    const r = await rpc<{ no: string }>('receive_goods', { p: { supplier_id: sup, ref, note, lines: chosen.map((p) => ({ product_id: p.id, qty: pcsOf(p) })) } });
    await refresh('products', 'grns', 'audit'); toast(`${r.no} saved: ${units} units added to the store. The Admin enters the bill.`); onClose();
  });
  return (
    <Modal title="Receive goods from a supplier" icon="truck" xl onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Add to store stock{chosen.length ? ` · ${chosen.length} item${chosen.length === 1 ? '' : 's'}, ${units} units` : ''}</button></>}>
      <div className="frow"><div className="field"><label>Supplier</label><select id="gsup" className="input" value={sup} onChange={(e) => setSup(e.target.value)}><option value="">Choose the supplier</option>{(suppliers.data ?? []).filter((x) => x.active).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select>
        {suppliers.data && !suppliers.data.length ? <span className="hint">No suppliers yet. The Admin adds them under Accounts, Suppliers.</span> : null}</div>
        <div className="field"><label>Supplier's delivery note or invoice no. (optional)</label><input id="gref" className="input" maxLength={60} value={ref} onChange={(e) => setRef(e.target.value)} /></div></div>
      <StockPicker all={all} base={theirs.size ? (p) => theirs.has(p.id) : undefined} qty={qty} codes={!!settings.data?.features?.barcode} initQ={pid ? all.find((p) => p.id === pid)?.name : ''}
        cols={[{ th: 'In store', td: (p) => <QtyCell p={p} q={p.wh_qty} /> }]} qtyHead="Received" aria={(p) => `Quantity ${p.name}`}
        badge={(p) => (theirs.has(p.id) ? <> <span className="chip ok">from this supplier</span></> : null)} sideTitle="To receive" sideNote={s ? `From ${s.name}${ref ? `, ${ref}` : ''}` : 'Choose the supplier'} />
      <div className="field" style={{ marginTop: 12 }}><label>Note (optional)</label><input className="input" maxLength={120} value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. 2 cartons damaged, refused" /></div>
      <Note>No prices here: the Admin enters the supplier's bill and its amounts.</Note>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

const RTS_REASONS = ['Damaged', 'Expired', 'Wrong item', 'Not ordered', 'Other'];
/** The warehouse (or Admin) sends goods back to a supplier: they leave the store at once and a return note prints. */
export function ReturnToSupplierModal({ onClose }: { onClose: () => void }) {
  const products = useProducts(), suppliers = useSuppliers(), settings = useSettings(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const [sup, setSup] = useState(''), [reason, setReason] = useState(''), [note, setNote] = useState('');
  const qty = useQtyLines(), { pcsOf } = qty;
  const s = suppliers.data?.find((x) => x.id === sup), theirs = new Set((s?.supplier_items ?? []).map((i) => i.product_id));
  const all = (products.data ?? []).filter((p) => p.active).sort((x, y) => Number(theirs.has(y.id)) - Number(theirs.has(x.id)) || x.name.localeCompare(y.name)), byId = new Map(all.map((p) => [p.id, p]));
  const chosen = all.filter((p) => pcsOf(p) > 0), over = chosen.filter((p) => pcsOf(p) > p.wh_qty);
  const save = () => a.run(async () => {
    if (!sup) throw new Error('Choose the supplier first');
    if (!reason) throw new Error('Choose why the goods go back');
    if (!chosen.length) throw new Error('Enter a quantity for at least one item');
    const lines = chosen.map((p) => ({ product_id: p.id, qty: pcsOf(p) }));
    const r = await rpc<{ id: string; no: string }>('create_supplier_return', { p: { supplier_id: sup, reason, note, lines } });
    printHTML(supplierReturnNoteHTML({ no: r.no, kind: 'return', reason, note, created_at: new Date().toISOString(), created_by_name: '', supplier_return_items: lines }, s?.name ?? '', settings.data?.company ?? {}, byId));
    await refresh('products', 'sreturns', 'audit'); toast(`${r.no}: ${sum(chosen, pcsOf)} units sent back to ${s?.name}. Printing the return note.`); onClose();
  });
  return (
    <Modal title="Return goods to a supplier" icon="exchange" xl onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy || over.length > 0} onClick={() => void save()}><Icon n="check" /> Send back and print</button></>}>
      <div className="frow"><div className="field"><label>Supplier</label><select id="rsup" className="input" value={sup} onChange={(e) => setSup(e.target.value)}><option value="">Choose the supplier</option>{(suppliers.data ?? []).filter((x) => x.active).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></div>
        <div className="field"><label>Why</label><select id="rreason2" className="input" value={reason} onChange={(e) => setReason(e.target.value)}><option value="">Choose the reason</option>{RTS_REASONS.map((x) => <option key={x}>{x}</option>)}</select></div></div>
      <StockPicker all={all} base={(p) => (!theirs.size || theirs.has(p.id)) && p.wh_qty > 0} qty={qty} codes={!!settings.data?.features?.barcode}
        cols={[{ th: 'In store', td: (p) => <QtyCell p={p} q={p.wh_qty} cls={pcsOf(p) > p.wh_qty ? 'bad' : ''} /> }]} qtyHead="Send back" aria={(p) => `Quantity ${p.name}`}
        badge={(p) => (theirs.has(p.id) ? <> <span className="chip ok">from this supplier</span></> : null)} warn={(p) => (pcsOf(p) > p.wh_qty ? `More than the store has (${p.wh_qty})` : null)}
        sideTitle="To send back" sideNote={s ? `To ${s.name}${reason ? `, ${reason.toLowerCase()}` : ''}` : 'Choose the supplier'} />
      <div className="field" style={{ marginTop: 12 }}><label>Note (optional)</label><input className="input" maxLength={160} value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. caps broken in 2 cartons" /></div>
      {over.length ? <Note i="alert" warn>More than the store has: {over.map((p) => p.name).join(', ')}.</Note>
        : <Note i="exchange">They leave the central store now, and what you owe the supplier drops at item cost. The Admin settles the amount the supplier credits.</Note>}
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

/** Returns to suppliers and claims for goods billed but not received; the Admin sees values and settles or cancels. */
export function SupplierReturnsList({ openOnly = false }: { openOnly?: boolean }) {
  const { profile } = useAuth(), isAdmin = profile!.role === 'admin';
  const list0 = useSupplierReturns(), vals = useSupplierReturnValues(isAdmin), suppliers = useSuppliers(), products = useProducts(), settings = useSettings();
  const [settle, setSettle] = useState<SupplierReturn | null>(null), [cancel, setCancel] = useState<SupplierReturn | null>(null);
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const val = new Map((vals.data ?? []).map((v) => [v.id, v])), supName = (id: string) => suppliers.data?.find((s) => s.id === id)?.name ?? '';
  const list = (list0.data ?? []).filter((r) => !openOnly || r.status === 'open');
  if (openOnly && !list.length) return null;
  return (
    <div className="card p0"><div style={{ padding: '16px 16px 0' }}><h3><Icon n="exchange" /> {openOnly ? `Returns and claims to settle (${list.length})` : 'Returns to suppliers and claims'}</h3></div>
      {list.length ? <div className="tw"><table className="t" id="rtslist"><thead><tr><th>No.</th><th>Supplier</th><th>Items</th><th>Reason</th>{isAdmin ? <th className="r">Value</th> : null}<th>Status</th><th /></tr></thead><tbody>
        {list.map((r) => { const v = val.get(r.id); return <tr key={r.id}><td><b>{r.no}</b><div className="code">{dt(r.created_at)}, {r.created_by_name}</div></td><td>{supName(r.supplier_id)}</td>
          <td>{r.supplier_return_items.map((i) => { const p = byId.get(i.product_id); return <div key={i.product_id}>{i.qty} {p?.stock_unit} {p?.name}</div>; })}</td>
          <td>{r.kind === 'short' ? <span className="chip warn">Billed, not received</span> : r.reason}{r.note ? <div className="code">{r.note}</div> : null}</td>
          {isAdmin ? <td className="r nw">{v ? <>{fUSD(v.amount_usd)}{Math.abs(v.amount_usd - v.value_usd) > 0.005 ? <div className="code">cost {fUSD(v.value_usd)}</div> : null}{v.bill_no ? <div className="code">on {v.bill_no}</div> : null}</> : '-'}</td> : null}
          <td>{r.status === 'open' ? <span className="chip warn">Open</span> : r.status === 'settled' ? <span className="chip ok">Settled</span> : <span className="chip bad" title={r.cancel_reason ?? ''}>Cancelled</span>}</td>
          <td className="nw"><button className="btn sm" title="Print the return note" onClick={() => printHTML(supplierReturnNoteHTML(r, supName(r.supplier_id), settings.data?.company ?? {}, byId))}><Icon n="printer" /></button>
            {isAdmin && r.status !== 'cancelled' ? <button className="btn primary sm" onClick={() => setSettle(r)}><Icon n="check" /> {r.status === 'open' ? 'Settle' : 'Change'}</button> : null}
            {isAdmin && r.status === 'open' ? <button className="btn sm" onClick={() => setCancel(r)}><Icon n="x" /></button> : null}</td></tr>; })}
      </tbody></table></div> : <Empty i="exchange" t={list0.isLoading ? 'Loading' : 'Nothing sent back to suppliers'} />}
      {settle ? <SettleReturnModal r={settle} value={val.get(settle.id)} supplier={supName(settle.supplier_id)} onClose={() => setSettle(null)} /> : null}
      {cancel ? <CancelReturnModal r={cancel} onClose={() => setCancel(null)} /> : null}
    </div>
  );
}
function SettleReturnModal({ r, value, supplier, onClose }: { r: SupplierReturn; value?: { value_usd: number; amount_usd: number }; supplier: string; onClose: () => void }) {
  const pay = usePayables(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const sup = useSuppliers().data?.find((s) => s.id === r.supplier_id);
  const bills = (pay.data ?? []).find((p) => p.id === r.supplier_id || p.id === sup?.account_id || p.name === supplier)?.bills ?? [];
  const [amt, setAmt] = useState(String(value?.amount_usd ?? '')), [bill, setBill] = useState(r.bill_id ?? '');
  const go = () => a.run(async () => {
    await rpc('settle_supplier_return', { p: { id: r.id, amount_usd: Number(amt), bill_id: bill || null } });
    await refresh('sreturns', 'audit'); toast(`${r.no} settled with ${supplier}`); onClose();
  });
  return (
    <Modal title={`Settle ${r.no} with ${supplier}`} icon="check" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void go()}><Icon n="check" /> Settle</button></>}>
      <div className="frow"><div className="field"><label htmlFor="ramt">Amount the supplier credits (USD)</label><input id="ramt" className="input" type="number" min="0" step="0.01" value={amt} onChange={(e) => setAmt(e.target.value)} /><span className="hint">At item cost: {fUSD(value?.value_usd ?? 0)}. A different amount goes to Purchase price difference.</span></div>
        <div className="field"><label>Set against the bill</label><select id="rbill" className="input" value={bill} onChange={(e) => setBill(e.target.value)}><option value="">No bill (on account)</option>
          {bills.map((b) => <option key={b.id} value={b.id}>{b.bill_ref} ({b.no}), still to pay {fUSD(b.outstanding)}</option>)}</select></div></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}
function CancelReturnModal({ r, onClose }: { r: SupplierReturn; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction(), [why, setWhy] = useState('');
  const go = () => a.run(async () => { await rpc('cancel_supplier_return', { p_id: r.id, p_reason: why }); await refresh('products', 'sreturns', 'audit'); toast(`${r.no} cancelled`, 'warn'); onClose(); });
  return (
    <Modal title={`Cancel ${r.no}`} icon="x" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Keep it</button><button className="btn danger" disabled={a.busy} onClick={() => void go()}><Icon n="x" /> Cancel {r.no}</button></>}>
      <p>{r.kind === 'return' ? 'The goods come back into the central store and the debit note is cancelled.' : 'The claim is dropped and the bill is owed in full again.'}</p>
      <div className="field"><label>Reason</label><input className="input" maxLength={80} value={why} onChange={(e) => setWhy(e.target.value)} placeholder="e.g. supplier refused the return" autoFocus /></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

export function GoodsIn() {
  const { profile } = useAuth(), isAdmin = profile!.role === 'admin';
  const grns = useGrns(), suppliers = useSuppliers(), products = useProducts();
  const [recv, setRecv] = useState(false), [rts, setRts] = useState(false), [bill, setBill] = useState<Grn | null>(null), [f, setF] = useState<'all' | 'awaiting_bill'>('all');
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const supName = (id: string) => suppliers.data?.find((s) => s.id === id)?.name ?? '';
  const list = (grns.data ?? []).filter((g) => f === 'all' || g.status === f), waiting = (grns.data ?? []).filter((g) => g.status === 'awaiting_bill').length;
  return (
    <>
      <Head t="Goods in" s="Every delivery from a supplier, with what came in. Each one waits for the Admin to enter the supplier's bill." a={<><button id="rtsbtn" className="btn ghost" onClick={() => setRts(true)}><Icon n="exchange" /> Return to supplier</button><button className="btn primary" onClick={() => setRecv(true)}><Icon n="truck" /> Receive from supplier</button></>} />
      <div className="toolbar"><div className="seg"><button className={f === 'all' ? 'on' : ''} onClick={() => setF('all')}>All</button><button className={f === 'awaiting_bill' ? 'on' : ''} onClick={() => setF('awaiting_bill')}>Waiting for the bill ({waiting})</button></div></div>
      <div className="card p0"><div className="tw">{list.length ? <table className="t"><thead><tr><th>Receipt</th><th>Supplier</th><th>Received</th><th>Items</th><th>Bill</th><th /></tr></thead><tbody>
        {list.map((g) => <tr key={g.id}><td><b>{g.no}</b>{g.ref ? <div className="code">{g.ref}</div> : null}</td><td>{supName(g.supplier_id)}</td><td className="nw">{dt(g.received_at)}<div className="code">{g.received_by_name}</div></td>
          <td>{g.grn_items.map((i) => { const p = byId.get(i.product_id); return <div key={i.product_id}>{i.qty} {p?.stock_unit} {p?.name}{p && ctnTxt(p, i.qty) ? <span className="code"> ({ctnTxt(p, i.qty)})</span> : null}</div>; })}{g.note ? <div className="code">{g.note}</div> : null}</td>
          <td>{g.status === 'billed' ? <span className="chip ok">Bill entered</span> : <span className="chip warn">Waiting for the bill</span>}</td>
          <td>{isAdmin && g.status === 'awaiting_bill' ? <button className="btn primary sm" onClick={() => setBill(g)}><Icon n="receipt" /> Enter bill</button> : null}</td></tr>)}
      </tbody></table> : <Empty i="truck" t={grns.isLoading ? 'Loading' : 'Nothing received yet'} />}</div></div>
      <SupplierReturnsList />
      {recv ? <ReceiveGoodsModal onClose={() => setRecv(false)} /> : null}
      {rts ? <ReturnToSupplierModal onClose={() => setRts(false)} /> : null}
      {bill ? <BillModal grn={bill} onClose={() => setBill(null)} /> : null}
    </>
  );
}

function ReturnCard({ x, shop, byId, onReceive, onCancel }: { x: ShopReturn; shop: string; byId: Map<string, Product>; onReceive?: () => void; onCancel?: () => void }) {
  const short = x.status === 'received' && x.return_items.some((i) => (i.received_qty ?? i.qty) < i.qty);
  return (
    <div className="card p0">
      <div style={{ padding: '14px 16px', display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap', borderBottom: '1px solid var(--line)' }}>
        <b style={{ fontSize: 17 }}>{x.no}</b>{x.status === 'pending' ? <span className="chip warn"><Icon n="clock" /> On the way to the central store</span> : x.status === 'cancelled' ? <span className="chip bad"><Icon n="x" /> Cancelled</span> : <span className={`chip ${short ? 'warn' : 'ok'}`}><Icon n="check" /> Received{short ? ', some short' : ''}</span>}
        <span style={{ color: 'var(--muted)' }}>{shop}, sent by {x.created_by_name} on {dt(x.created_at)}</span><span className="sp" />
        {onReceive && x.status === 'pending' ? <button className="btn primary sm" onClick={onReceive}><Icon n="check" /> Receive</button> : null}
        {onCancel && x.status === 'pending' ? <button className="btn sm" onClick={onCancel}><Icon n="x" /> Cancel</button> : null}
      </div>
      <Note i="doc" style={{ margin: '12px 16px 0' }}>Reason: {x.reason}{x.received_note ? `. ${x.status === 'cancelled' ? 'Cancelled' : 'Store note'}: ${x.received_note}` : ''}{x.received_by_name ? `. Received by ${x.received_by_name} on ${dt(x.received_at!)}` : ''}</Note>
      <div className="tw"><table className="t"><thead><tr><th>Item</th><th className="r">Sent back</th>{x.status === 'received' ? <th className="r">Arrived</th> : null}</tr></thead><tbody>
        {x.return_items.map((i) => { const p = byId.get(i.product_id); return <tr key={i.product_id}><td><b>{p?.name}</b><div className="code">{p?.sku}</div></td><td className="r"><b>{i.qty}</b> {p?.stock_unit}</td>{x.status === 'received' ? <td className="r"><span className={`chip ${(i.received_qty ?? i.qty) < i.qty ? 'warn' : 'ok'}`}>{i.received_qty ?? i.qty}</span></td> : null}</tr>; })}
      </tbody></table></div>
    </div>
  );
}

/** Warehouse and Admin: returns coming back from the shops. Shop admin: send goods back. */
export function Returns() {
  const { profile } = useAuth(), shopSide = profile!.role === 'shopadmin';
  const rets = useReturns(), products = useProducts(), shops = useShops();
  const [recv, setRecv] = useState<ShopReturn | null>(null), [cancel, setCancel] = useState<ShopReturn | null>(null), [make, setMake] = useState(false);
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const list = [...(rets.data ?? [])].sort((x, y) => Number(y.status === 'pending') - Number(x.status === 'pending'));
  const waiting = list.filter((x) => x.status === 'pending').length;
  return (
    <>
      <Head t={shopSide ? 'Returns to the central store' : 'Returns from shops'} s={shopSide ? 'Send damaged, expired or unsold goods back. They leave the shop stock when you send them; the central store confirms what arrived.' : 'Goods the shops sent back. Count what arrived and receive it into the store.'}
        a={shopSide ? <button className="btn primary" onClick={() => setMake(true)}><Icon n="truck" /> New return</button> : null} />
      {waiting ? <Note i="truck" warn>{waiting} return{waiting > 1 ? 's are' : ' is'} on the way to the central store.</Note> : null}
      {list.length ? list.map((x) => <ReturnCard key={x.id} x={x} shop={shops.data?.find((s) => s.id === x.shop_id)?.name ?? ''} byId={byId} onReceive={shopSide ? undefined : () => setRecv(x)} onCancel={() => setCancel(x)} />) : <div className="card"><Empty i="truck" t={rets.isLoading ? 'Loading' : 'No returns yet'} /></div>}
      {make ? <NewReturn onClose={() => setMake(false)} /> : null}
      {recv ? <ReceiveReturn x={recv} byId={byId} onClose={() => setRecv(null)} /> : null}
      {cancel ? <CancelReturn x={cancel} onClose={() => setCancel(null)} /> : null}
    </>
  );
}

function NewReturn({ onClose }: { onClose: () => void }) {
  const { profile } = useAuth(), products = useProducts(), stock = useStock(profile!.shop_id), refresh = useRefresh(), toast = useToast(), a = useAction();
  const [reason, setReason] = useState(''), [q, setQ] = useState('');
  const { pcsOf, cell } = useQtyLines();
  const at = new Map((stock.data ?? []).map((r) => [r.product_id, r.qty]));
  const ql = q.trim().toLowerCase(), all = (products.data ?? []).filter((p) => p.active && (at.get(p.id) ?? 0) > 0);
  const chosen = all.filter((p) => pcsOf(p) > 0), over = chosen.filter((p) => pcsOf(p) > (at.get(p.id) ?? 0));
  const list = all.filter((p) => pcsOf(p) > 0 || !ql || (p.name + ' ' + p.sku).toLowerCase().includes(ql)).slice(0, 150);
  const save = () => a.run(async () => {
    if (!chosen.length) throw new Error('Enter a quantity for at least one item');
    if (over.length) throw new Error('The shop does not have that many: ' + over.map((p) => p.name).join(', '));
    const r = await rpc<{ no: string }>('create_return', { p: { reason, lines: chosen.map((p) => ({ product_id: p.id, qty: pcsOf(p) })) } });
    await refresh('returns', 'stock', 'audit'); toast(`${r.no} sent to the central store`); onClose();
  });
  return (
    <Modal title="Send goods back to the central store" icon="truck" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Send back</button></>}>
      <div className="field"><label>Reason</label><input id="retr" className="input" maxLength={120} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Damaged packaging, expired, not selling" autoFocus /></div>
      <div className="search" style={{ maxWidth: 'none', marginBottom: 10 }}><Icon n="search" /><input placeholder="Find an item in the shop" value={q} onChange={(e) => setQ(e.target.value)} /></div>
      <div className="tw" style={{ maxHeight: '44vh', overflow: 'auto', border: '1px solid var(--line)', borderRadius: 12 }}>
        {list.length ? <table className="t"><thead><tr><th>Item</th><th className="r">In shop</th><th style={{ width: 200 }}>Send back</th></tr></thead><tbody>
          {list.map((p) => <tr key={p.id}><td><b>{p.name}</b><div className="code">{p.sku}</div></td><td className="r"><QtyCell p={p} q={at.get(p.id) ?? 0} cls={over.includes(p) ? 'bad' : ''} /></td><td>{cell(p)}</td></tr>)}
        </tbody></table> : <Empty i="box" t="No stock in the shop to send back" />}
      </div>
      <Note i="truck" warn={!!over.length} style={{ marginTop: 12 }}>{chosen.length} item{chosen.length === 1 ? '' : 's'}, {sum(chosen, pcsOf)} units leave the shop stock now.</Note>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

function ReceiveReturn({ x, byId, onClose }: { x: ShopReturn; byId: Map<string, Product>; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction();
  const [got, setGot] = useState<Record<string, string>>(Object.fromEntries(x.return_items.map((i) => [i.product_id, String(i.qty)])));
  const [note, setNote] = useState('');
  const n = (pid: string) => Math.max(0, parseInt(got[pid]) || 0), short = x.return_items.filter((i) => n(i.product_id) < i.qty);
  const save = () => a.run(async () => {
    const r = await rpc<{ sent: number; received: number }>('receive_return', { p_id: x.id, p_lines: x.return_items.map((i) => ({ product_id: i.product_id, qty: n(i.product_id) })), p_note: note });
    await refresh('returns', 'products', 'audit'); toast(`${x.no} received: ${r.received} of ${r.sent} units back in the store`); onClose();
  });
  return (
    <Modal title={`Receive return ${x.no}`} icon="truck" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Receive into the store</button></>}>
      <Note i="box">Count what arrived; lower a line if goods are missing. What is missing is booked as a loss.</Note>
      <div className="tw"><table className="t"><thead><tr><th>Item</th><th className="r">Sent</th><th style={{ width: 150 }}>Arrived</th></tr></thead><tbody>
        {x.return_items.map((i) => { const p = byId.get(i.product_id); return <tr key={i.product_id}><td><b>{p?.name}</b></td><td className="r">{i.qty} {p?.stock_unit}</td><td><input className="input" type="number" min="0" max={i.qty} value={got[i.product_id]} style={{ minHeight: 42 }} onChange={(e) => setGot({ ...got, [i.product_id]: e.target.value })} aria-label={`Arrived ${p?.name}`} /></td></tr>; })}
      </tbody></table></div>
      <div className="field" style={{ marginTop: 12 }}><label>Note {short.length ? '(required, what happened?)' : '(optional)'}</label><input className="input" maxLength={120} value={note} onChange={(e) => setNote(e.target.value)} /></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}
function CancelReturn({ x, onClose }: { x: ShopReturn; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction();
  const [r, setR] = useState('');
  const go = () => a.run(async () => { await rpc('cancel_return', { p_id: x.id, p_reason: r }); await refresh('returns', 'stock', 'audit'); toast(`${x.no} cancelled. The goods are back in the shop stock.`, 'warn'); onClose(); });
  return (
    <Modal title={`Cancel return ${x.no}`} icon="x" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Back</button><button className="btn danger" disabled={a.busy} onClick={() => void go()}><Icon n="x" /> Cancel return</button></>}>
      <p>The goods go back into the shop's stock.</p><div className="field"><label>Reason</label><input className="input" maxLength={80} value={r} onChange={(e) => setR(e.target.value)} autoFocus /></div><div className="lerr">{a.err}</div>
    </Modal>
  );
}

/** Statements for the warehouse (stock ledgers of the store and each shop) and the shop admin (the shop's own ledgers). */
export function Books() {
  const { profile } = useAuth(), ledgers = useLedgers();
  const s = profile!.role === 'whop'
    ? 'Stock accounts at cost: the central store and each shop. Goods sent to a shop are booked against it when the shop receives them; sales and returns reduce it.'
    : 'Your shop\'s accounts: cash, sales and the stock you hold at cost, with every delivery received, sale and return.';
  return (
    <>
      <Head t="Statements" s={s} />
      <StatementView ledgers={ledgers.data ?? []} loading={ledgers.isLoading} />
    </>
  );
}
