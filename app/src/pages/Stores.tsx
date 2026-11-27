// Goods in from suppliers, returns from the shops to the central store, and the stock and
// shop statements the warehouse can read.
import { useEffect, useMemo, useState } from 'react';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useCosts, useGrns, useLedgers, useProducts, useRefresh, useReturns, useSettings, useShops, useStock, useSupplierReturns, useSupplierReturnValues, useSuppliers } from '../data/queries';

/** With no central store, goods from a supplier go straight into a shop. */
export const useNoStore = () => !!useSettings().data?.features?.no_warehouse;
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
  // with no central store the goods go into a shop, chosen here; with one shop it is chosen already
  const noStore = useNoStore(), shops = useShops(), stock = useStock();
  const open = useMemo(() => (shops.data ?? []).filter((x) => x.active), [shops.data]);
  const [shop, setShop] = useState('');
  const sid = noStore ? (shop || (open.length === 1 ? open[0].id : '')) : '';
  const inShop = useMemo(() => new Map((stock.data ?? []).filter((r) => r.shop_id === sid).map((r) => [r.product_id, r.qty])), [stock.data, sid]);
  const [sup, setSup] = useState(''), [ref, setRef] = useState(''), [note, setNote] = useState('');
  const qty = useQtyLines(), { pcsOf } = qty;
  const s = suppliers.data?.find((x) => x.id === sup), theirs = new Set((s?.supplier_items ?? []).map((i) => i.product_id));
  // the supplier's items first, then by name: the order stays put while quantities are typed
  const all = (products.data ?? []).filter((p) => p.active).sort((x, y) => Number(theirs.has(y.id)) - Number(theirs.has(x.id)) || x.name.localeCompare(y.name));
  const chosen = all.filter((p) => pcsOf(p) > 0), units = sum(chosen, pcsOf);
  const save = () => a.run(async () => {
    if (!sup) throw new Error('Choose the supplier first');
    if (noStore && !sid) throw new Error('Choose the shop the goods go into');
    if (!chosen.length) throw new Error('Enter a quantity for at least one item');
    const r = await rpc<{ no: string }>('receive_goods', { p: { supplier_id: sup, ref, note, ...(noStore ? { shop_id: sid } : {}), lines: chosen.map((p) => ({ product_id: p.id, qty: pcsOf(p) })) } });
    const where = noStore ? open.find((x) => x.id === sid)?.name ?? 'the shop' : 'the store';
    await refresh('products', 'stock', 'grns', 'audit'); toast(`${r.no} saved: ${units} units added to ${where}. The Admin enters the bill.`); onClose();
  });
  return (
    <Modal title="Receive goods from a supplier" icon="truck" xl onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Add to {noStore ? 'shop' : 'store'} stock{chosen.length ? ` · ${chosen.length} item${chosen.length === 1 ? '' : 's'}, ${units} units` : ''}</button></>}>
      <div className="frow"><div className="field"><label>Supplier</label><select id="gsup" className="input" value={sup} onChange={(e) => setSup(e.target.value)}><option value="">Choose the supplier</option>{(suppliers.data ?? []).filter((x) => x.active).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select>
        {suppliers.data && !suppliers.data.length ? <span className="hint">No suppliers yet. The Admin adds them under Accounts, Suppliers.</span> : null}</div>
        <div className="field"><label>Supplier's delivery note or invoice no. (optional)</label><input id="gref" className="input" maxLength={60} value={ref} onChange={(e) => setRef(e.target.value)} /></div>
        {noStore ? <div className="field"><label htmlFor="gshop">Shop the goods go into</label><select id="gshop" className="input" value={sid} onChange={(e) => setShop(e.target.value)}><option value="">Choose the shop</option>{open.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></div> : null}</div>
      <StockPicker all={all} base={theirs.size ? (p) => theirs.has(p.id) : undefined} qty={qty} codes={!!settings.data?.features?.barcode} initQ={pid ? all.find((p) => p.id === pid)?.name : ''}
        cols={[noStore ? { th: 'In shop', td: (p) => (sid ? <QtyCell p={p} q={inShop.get(p.id) ?? 0} /> : <span className="code">-</span>) } : { th: 'In store', td: (p) => <QtyCell p={p} q={p.wh_qty} /> }]} qtyHead="Received" aria={(p) => `Quantity ${p.name}`}
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
  const go = () => a.run(async () => { await rpc('cancel_supplier_return', { p_id: r.id, p_reason: why }); await refresh('products', 'sreturns', 'stock', 'returns', 'audit'); toast(`${r.no} cancelled`, 'warn'); onClose(); });
  return (
    <Modal title={`Cancel ${r.no}`} icon="x" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Keep it</button><button className="btn danger" disabled={a.busy} onClick={() => void go()}><Icon n="x" /> Cancel {r.no}</button></>}>
      <p>{r.kind === 'short' ? 'The claim is dropped and the bill is owed in full again.' : r.from_return_id ? 'The goods go back into the shop that sent them and the debit note is cancelled.' : 'The goods come back into the central store and the debit note is cancelled.'}</p>
      <div className="field"><label>Reason</label><input className="input" maxLength={80} value={why} onChange={(e) => setWhy(e.target.value)} placeholder="e.g. supplier refused the return" autoFocus /></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

export function GoodsIn() {
  const { profile } = useAuth(), isAdmin = profile!.role === 'admin';
  const grns = useGrns(), suppliers = useSuppliers(), products = useProducts();
  const noStore = useNoStore(), shops = useShops();
  const shopName = (id?: string | null) => (id ? shops.data?.find((x) => x.id === id)?.name ?? '' : '');
  const [recv, setRecv] = useState(false), [rts, setRts] = useState(false), [bill, setBill] = useState<Grn | null>(null), [f, setF] = useState<'all' | 'awaiting_bill'>('all');
  const [edit, setEdit] = useState<Grn | null>(null), [del, setDel] = useState<Grn | null>(null);
  // the Admin corrects or deletes any receipt; the warehouse only those still waiting for the bill
  const mayChange = (g: Grn) => g.status !== 'cancelled' && (isAdmin || g.status === 'awaiting_bill');
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const supName = (id: string) => suppliers.data?.find((s) => s.id === id)?.name ?? '';
  const list = (grns.data ?? []).filter((g) => f === 'all' || g.status === f), waiting = (grns.data ?? []).filter((g) => g.status === 'awaiting_bill').length;
  return (
    <>
      <Head t="Goods in" s="Every delivery from a supplier, with what came in. Each one waits for the Admin to enter the supplier's bill. A receipt can be corrected or deleted, before or after its bill." a={<>{noStore ? null : <button id="rtsbtn" className="btn ghost" onClick={() => setRts(true)}><Icon n="exchange" /> Return to supplier</button>}<button className="btn primary" onClick={() => setRecv(true)}><Icon n="truck" /> Receive from supplier</button></>} />
      <div className="toolbar"><div className="seg"><button className={f === 'all' ? 'on' : ''} onClick={() => setF('all')}>All</button><button className={f === 'awaiting_bill' ? 'on' : ''} onClick={() => setF('awaiting_bill')}>Waiting for the bill ({waiting})</button></div></div>
      <div className="card p0"><div className="tw">{list.length ? <table className="t"><thead><tr><th>Receipt</th><th>Supplier</th><th>Received</th><th>Items</th><th>Bill</th><th /></tr></thead><tbody>
        {list.map((g) => <tr key={g.id}><td><b>{g.no}</b>{g.ref ? <div className="code">{g.ref}</div> : null}</td><td>{supName(g.supplier_id)}</td><td className="nw">{dt(g.received_at)}<div className="code">{g.received_by_name}{g.shop_id ? ` · into ${shopName(g.shop_id)}` : ''}</div></td>
          <td>{g.grn_items.map((i) => { const p = byId.get(i.product_id); return <div key={i.product_id}>{i.qty} {p?.stock_unit} {p?.name}{p && ctnTxt(p, i.qty) ? <span className="code"> ({ctnTxt(p, i.qty)})</span> : null}</div>; })}{g.note ? <div className="code">{g.note}</div> : null}</td>
          <td>{g.status === 'cancelled' ? <><span className="chip bad">Deleted</span><div className="code">{g.cancelled_by_name}: {g.cancel_reason}</div></> : g.status === 'billed' ? <span className="chip ok">Bill entered</span> : <span className="chip warn">Waiting for the bill</span>}
            {g.edited_at ? <div className="code">corrected by {g.edited_by_name}, {dt(g.edited_at)}</div> : null}</td>
          {/* Enter bill is a full button beside the icon buttons, not one of them (.act squares its buttons) */}
          <td className="nw"><div style={{ display: 'flex', gap: 6, alignItems: 'center', justifyContent: 'flex-end' }}>
            {isAdmin && g.status === 'awaiting_bill' ? <button className="btn primary sm nw" onClick={() => setBill(g)}><Icon n="receipt" /> Enter bill</button> : null}
            {mayChange(g) ? <div className="act"><button title={`Correct ${g.no}`} aria-label={`Correct ${g.no}`} onClick={() => setEdit(g)}><Icon n="edit" /></button><button title={`Delete ${g.no}`} aria-label={`Delete ${g.no}`} onClick={() => setDel(g)}><Icon n="trash" /></button></div> : null}</div></td></tr>)}
      </tbody></table> : <Empty i="truck" t={grns.isLoading ? 'Loading' : 'Nothing received yet'} />}</div></div>
      {noStore ? null : <SupplierReturnsList />}
      {recv ? <ReceiveGoodsModal onClose={() => setRecv(false)} /> : null}
      {rts ? <ReturnToSupplierModal onClose={() => setRts(false)} /> : null}
      {bill ? <BillModal grn={bill} onClose={() => setBill(null)} /> : null}
      {edit ? <EditGrnModal g={edit} onClose={() => setEdit(null)} /> : null}
      {del ? <DeleteGrnModal g={del} onClose={() => setDel(null)} /> : null}
    </>
  );
}

/** A receipt with its items and, once billed, its bill as entered (from grn_detail). */
type GrnDetail = { grn: Grn; supplier: string; shop_name: string | null; items: { product_id: string; name: string; unit: string; qty: number; cost: number }[];
  bill: { voucher: string; bill_no: string; bill_date: string; due_date: string | null; currency: 'USD' | 'FC'; rate: number; amount: number; vat: number } | null;
  locked: string | null; claims: number };

/** Correcting a receipt: quantities (0 takes an item off), items added, reference and note; once billed, the bill too.
 *  The stock and both vouchers follow, in place. */
function EditGrnModal({ g, onClose }: { g: Grn; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction(), products = useProducts();
  const [d, setD] = useState<GrnDetail | null>(null), [lines, setLines] = useState<Record<string, string>>({}), [add, setAdd] = useState(''), [ref, setRef] = useState(g.ref), [note, setNote] = useState(g.note);
  const [b, setB] = useState<{ bill_no: string; bill_date: string; due_date: string; currency: 'USD' | 'FC'; rate: string; amount: string; vat: string } | null>(null);
  const load = useAction();
  useEffect(() => { void load.run(async () => {
    const x = await rpc<GrnDetail>('grn_detail', { p_id: g.id }); setD(x);
    setLines(Object.fromEntries(x.items.map((i) => [i.product_id, String(i.qty)])));
    if (x.bill) setB({ bill_no: x.bill.bill_no, bill_date: x.bill.bill_date, due_date: x.bill.due_date ?? '', currency: x.bill.currency, rate: String(x.bill.rate), amount: String(x.bill.amount), vat: String(x.bill.vat || '') });
  }); }, [g.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const byId = new Map((products.data ?? []).map((p) => [p.id, p]));
  const ids = Object.keys(lines), billed = g.status === 'billed', blocked = d?.locked ?? (billed && d && d.claims > 0 ? 'The bill has a claim for goods billed but not received. Cancel the claim under Returns to supplier first.' : null);
  const save = () => a.run(async () => {
    const l = ids.map((id) => ({ product_id: id, qty: Math.max(0, parseInt(lines[id]) || 0) }));
    if (!l.some((x) => x.qty > 0)) throw new Error('A receipt needs at least one item. To take it all back, delete it');
    await rpc('edit_grn', { p: { id: g.id, ref, note, lines: l, ...(billed && b ? { bill: { bill_no: b.bill_no, bill_date: b.bill_date, due_date: b.due_date || null, currency: b.currency,
      rate: Number(b.rate) || null, amount: Number(b.amount), vat: Number(b.vat) || 0 } } : {}) } });
    await refresh('grns', 'products', 'stock', 'audit'); toast(`${g.no} corrected${billed ? ' with its bill' : ''}`); onClose();
  });
  return (
    <Modal title={`Correct ${g.no}`} icon="edit" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" id="grnsave" disabled={a.busy || !d || !!blocked} onClick={() => void save()}><Icon n="check" /> Save changes</button></>}>
      {!d ? <Empty i={load.err ? 'alert' : 'refresh'} t={load.err || 'Loading'} /> : <>
        {blocked ? <Note warn i="lock">{blocked}</Note> : <Note i="truck">{d.supplier}{d.shop_name ? `, into ${d.shop_name}` : ''}. The stock and the goods-in voucher follow the new quantities{billed ? '; the bill is corrected in place, with the same voucher number' : ''}. A quantity of 0 takes the item off the receipt.</Note>}
        <div className="tw"><table className="t" id="grnlines"><thead><tr><th>Item</th><th className="r">Received</th><th style={{ width: 140 }}>Now</th></tr></thead><tbody>
          {ids.map((id) => { const p = byId.get(id), was = d.items.find((i) => i.product_id === id); return <tr key={id}><td><b>{p?.name ?? was?.name}</b><div className="code">{p?.stock_unit ?? was?.unit}</div></td>
            <td className="r">{was ? was.qty : <span className="chip">added</span>}</td>
            <td><input className="input" type="number" min="0" step="1" inputMode="numeric" value={lines[id]} onChange={(e) => setLines({ ...lines, [id]: e.target.value })} aria-label={`Quantity of ${p?.name ?? ''}`} /></td></tr>; })}
        </tbody></table></div>
        <div className="frow" style={{ marginTop: 8 }}><div className="field"><label htmlFor="grnadd">Add an item</label><select id="grnadd" className="input" value={add} onChange={(e) => { const v = e.target.value; setAdd(''); if (v && !(v in lines)) setLines({ ...lines, [v]: '1' }); }}>
          <option value="">Choose an item</option>{(products.data ?? []).filter((p) => p.active && !(p.id in lines)).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></div>
          <div className="field"><label htmlFor="grnref">Reference</label><input id="grnref" className="input" maxLength={60} value={ref} onChange={(e) => setRef(e.target.value)} /></div></div>
        <div className="field"><label htmlFor="grnnote">Note</label><input id="grnnote" className="input" maxLength={120} value={note} onChange={(e) => setNote(e.target.value)} /></div>
        {billed && b ? <div className="card" style={{ background: 'var(--bg)', padding: 12 }} id="grnbill"><b>Bill {d.bill?.voucher}</b>
          <div className="frow three" style={{ marginTop: 8 }}>
            <div className="field"><label htmlFor="gbno">Supplier's bill number</label><input id="gbno" className="input" maxLength={60} value={b.bill_no} onChange={(e) => setB({ ...b, bill_no: e.target.value })} /></div>
            <div className="field"><label htmlFor="gbdate">Bill date</label><input id="gbdate" className="input" type="date" value={b.bill_date} onChange={(e) => setB({ ...b, bill_date: e.target.value })} /></div>
            <div className="field"><label htmlFor="gbdue">Due date</label><input id="gbdue" className="input" type="date" value={b.due_date} onChange={(e) => setB({ ...b, due_date: e.target.value })} /></div></div>
          <div className="frow">
            <div className="field"><label htmlFor="gbamt">Amount (before VAT)</label><input id="gbamt" className="input" type="number" min="0" step="0.01" value={b.amount} onChange={(e) => setB({ ...b, amount: e.target.value })} /></div>
            <div className="field"><label htmlFor="gbvat">VAT</label><input id="gbvat" className="input" type="number" min="0" step="0.01" value={b.vat} placeholder="0" onChange={(e) => setB({ ...b, vat: e.target.value })} /></div>
            <div className="field"><label htmlFor="gbcur">Currency</label><select id="gbcur" className="input" value={b.currency} onChange={(e) => setB({ ...b, currency: e.target.value as 'USD' | 'FC' })}><option>USD</option><option value="FC">CDF</option></select></div>
            {b.currency === 'FC' ? <div className="field"><label htmlFor="gbrate">Rate</label><input id="gbrate" className="input" type="number" min="1" value={b.rate} onChange={(e) => setB({ ...b, rate: e.target.value })} /></div> : null}</div>
          <span className="hint">A bill that differs from the goods at item cost goes to Purchase price difference, as when it was entered.</span></div> : null}
      </>}
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

/** Deleting a receipt, with a reason: its goods leave the stock again; its goods-in voucher and its bill are cancelled. */
function DeleteGrnModal({ g, onClose }: { g: Grn; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction(), [why, setWhy] = useState(''), load = useAction(), [d, setD] = useState<GrnDetail | null>(null);
  useEffect(() => { void load.run(async () => setD(await rpc<GrnDetail>('grn_detail', { p_id: g.id }))); }, [g.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const go = () => a.run(async () => {
    if (why.trim().length < 4) throw new Error('Write a short reason for deleting this receipt');
    const r = await rpc<{ no: string; bill: string | null }>('delete_grn', { p_id: g.id, p_reason: why });
    await refresh('grns', 'products', 'stock', 'sreturns', 'audit'); toast(`${r.no} deleted${r.bill ? ` with its bill ${r.bill}` : ''}`, 'warn'); onClose();
  });
  return (
    <Modal title={`Delete ${g.no}?`} icon="trash" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Keep it</button><button className="btn danger" id="grndel" disabled={a.busy || !d || !!d?.locked || why.trim().length < 4} onClick={() => void go()}><Icon n="trash" /> Delete receipt</button></>}>
      {!d ? <Empty i={load.err ? 'alert' : 'refresh'} t={load.err || 'Loading'} /> : <>
        <p style={{ marginTop: 0 }}><b>{d.supplier}</b>{d.shop_name ? `, into ${d.shop_name}` : ''}: {d.items.map((i) => `${i.qty} ${i.unit} ${i.name}`).join(', ')}.</p>
        {d.locked ? <Note warn i="lock">{d.locked}</Note> : <Note warn i="alert">The goods leave the {d.shop_name ? 'shop' : 'store'}'s stock again and the goods-in voucher is cancelled{d.bill ? <>; the bill <b>{d.bill.bill_no}</b> ({d.bill.voucher}) is cancelled too{d.claims ? ', with its claim for goods not received' : ''}</> : ''}. This cannot be undone; the activity log keeps what it was.</Note>}
        <div className="field"><label htmlFor="grnwhy">Reason</label><input id="grnwhy" className="input" maxLength={120} value={why} onChange={(e) => setWhy(e.target.value)} placeholder="e.g. Entered twice" autoFocus /></div>
      </>}
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

const OUTCOME: Record<string, [string, string]> = { supplier: ['Back to the supplier', 'exchange'], shop: ['Moved to another shop', 'store'], writeoff: ['Thrown away', 'trash'] };
function ReturnCard({ x, shop, toShop, noStore, rts, decide, byId, onReceive, onCancel }: { x: ShopReturn; shop: string; toShop: string; noStore: boolean; rts?: string; decide: boolean; byId: Map<string, Product>; onReceive?: () => void; onCancel?: () => void }) {
  const short = x.status === 'received' && x.return_items.some((i) => (i.received_qty ?? i.qty) < i.qty);
  const decided = x.status === 'received' && !!x.outcome && x.outcome !== 'store', came = decided || noStore ? 'Came back' : 'Arrived';
  const status = x.status === 'pending' ? <span className="chip warn"><Icon n="clock" /> {noStore ? 'Waiting for the Admin' : 'On the way to the central store'}</span>
    : x.status === 'cancelled' ? <span className="chip bad"><Icon n="x" /> Cancelled</span>
    : decided ? <span className={`chip ${x.outcome === 'writeoff' ? 'bad' : 'ok'}`}><Icon n={OUTCOME[x.outcome!][1]} /> {x.outcome === 'shop' && toShop ? `Moved to ${toShop}` : OUTCOME[x.outcome!][0]}{rts ? `, ${rts}` : ''}{short ? ', some short' : ''}</span>
    : <span className={`chip ${short ? 'warn' : 'ok'}`}><Icon n="check" /> Received{short ? ', some short' : ''}</span>;
  const by = x.received_by_name ? `. ${decided ? 'Decided' : 'Received'} by ${x.received_by_name} on ${dt(x.received_at!)}` : '';
  return (
    <div className="card p0">
      <div style={{ padding: '14px 16px', display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap', borderBottom: '1px solid var(--line)' }}>
        <b style={{ fontSize: 17 }}>{x.no}</b>{status}
        <span style={{ color: 'var(--muted)' }}>{shop}, sent by {x.created_by_name} on {dt(x.created_at)}</span><span className="sp" />
        {onReceive && x.status === 'pending' ? <button className="btn primary sm" onClick={onReceive}><Icon n={decide ? 'exchange' : 'check'} /> {decide ? 'Decide' : 'Receive'}</button> : null}
        {onCancel && x.status === 'pending' ? <button className="btn sm" onClick={onCancel}><Icon n="x" /> Cancel</button> : null}
      </div>
      <Note i="doc" style={{ margin: '12px 16px 0' }}>Reason: {x.reason}{x.received_note ? `. ${x.status === 'cancelled' ? 'Cancelled' : decided ? 'Admin note' : 'Store note'}: ${x.received_note}` : ''}{by}{decided && x.outcome === 'supplier' && decide ? '. Settle what the supplier credits under Accounts.' : ''}</Note>
      <div className="tw"><table className="t"><thead><tr><th>Item</th><th className="r">Sent back</th>{x.status === 'received' ? <th className="r">{came}</th> : null}</tr></thead><tbody>
        {x.return_items.map((i) => { const p = byId.get(i.product_id); return <tr key={i.product_id}><td><b>{p?.name}</b><div className="code">{p?.sku}</div></td><td className="r"><b>{i.qty}</b> {p?.stock_unit}</td>{x.status === 'received' ? <td className="r"><span className={`chip ${(i.received_qty ?? i.qty) < i.qty ? 'warn' : 'ok'}`}>{i.received_qty ?? i.qty}</span></td> : null}</tr>; })}
      </tbody></table></div>
    </div>
  );
}
/** Warehouse and Admin: returns coming back from the shops. Shop admin: send goods back. Without a central store the
 *  Admin decides where returned goods go. */
export function Returns() {
  const { profile } = useAuth(), shopSide = profile!.role === 'shopadmin', noStore = useNoStore(), decides = noStore && profile!.role === 'admin';
  const rets = useReturns(), products = useProducts(), shops = useShops(), srs = useSupplierReturns(decides);
  const [recv, setRecv] = useState<ShopReturn | null>(null), [cancel, setCancel] = useState<ShopReturn | null>(null), [make, setMake] = useState(false);
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const shopName = (id?: string | null) => shops.data?.find((s) => s.id === id)?.name ?? '';
  const rtsOf = (id?: string | null) => { const r = id ? srs.data?.find((y) => y.id === id) : null; return r ? (r.status === 'cancelled' ? `${r.no} cancelled, goods back in the shop` : r.no) : undefined; };
  const list = [...(rets.data ?? [])].sort((x, y) => Number(y.status === 'pending') - Number(x.status === 'pending'));
  const waiting = list.filter((x) => x.status === 'pending').length;
  const head = noStore
    ? shopSide ? ['Returns', 'Send damaged, expired or unsold goods back. They leave the shop stock when you send them; the Admin then decides where they go: back to the supplier, to another shop, or thrown away.']
      : ['Returns from shops', 'Goods the shops sent back. Count what came back, then decide where it goes: back to the supplier, to another shop, or thrown away.']
    : shopSide ? ['Returns to the central store', 'Send damaged, expired or unsold goods back. They leave the shop stock when you send them; the central store confirms what arrived.']
      : ['Returns from shops', 'Goods the shops sent back. Count what arrived and receive it into the store.'];
  return (
    <>
      <Head t={head[0]} s={head[1]} a={shopSide ? <button className="btn primary" onClick={() => setMake(true)}><Icon n="truck" /> New return</button> : null} />
      {waiting ? <Note i={noStore ? 'clock' : 'truck'} warn>{waiting} return{waiting > 1 ? 's are' : ' is'} {!noStore ? 'on the way to the central store' : decides ? 'waiting for your decision' : 'waiting for the Admin'}.</Note> : null}
      {list.length ? list.map((x) => <ReturnCard key={x.id} x={x} shop={shopName(x.shop_id)} toShop={shopName(x.to_shop_id)} noStore={noStore} byId={byId}
        rts={rtsOf(x.supplier_return_id)} decide={decides}
        onReceive={shopSide ? undefined : () => setRecv(x)} onCancel={() => setCancel(x)} />) : <div className="card"><Empty i="truck" t={rets.isLoading ? 'Loading' : 'No returns yet'} /></div>}
      {make ? <NewReturn noStore={noStore} onClose={() => setMake(false)} /> : null}
      {recv ? decides ? <DecideReturn x={recv} shop={shopName(recv.shop_id)} byId={byId} onClose={() => setRecv(null)} /> : <ReceiveReturn x={recv} byId={byId} onClose={() => setRecv(null)} /> : null}
      {cancel ? <CancelReturn x={cancel} onClose={() => setCancel(null)} /> : null}
    </>
  );
}

function NewReturn({ noStore, onClose }: { noStore: boolean; onClose: () => void }) {
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
    await refresh('returns', 'stock', 'audit'); toast(`${r.no} sent ${noStore ? 'back: the Admin decides where it goes' : 'to the central store'}`); onClose();
  });
  return (
    <Modal title={noStore ? 'Send goods back' : 'Send goods back to the central store'} icon="truck" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Send back</button></>}>
      <div className="field"><label>Reason</label><input id="retr" className="input" maxLength={120} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Damaged packaging, expired, not selling" autoFocus /></div>
      <div className="search" style={{ maxWidth: 'none', marginBottom: 10 }}><Icon n="search" /><input placeholder="Find an item in the shop" value={q} onChange={(e) => setQ(e.target.value)} /></div>
      <div className="tw" style={{ maxHeight: '44vh', overflow: 'auto', border: '1px solid var(--line)', borderRadius: 12 }}>
        {list.length ? <table className="t"><thead><tr><th>Item</th><th className="r">In shop</th><th style={{ width: 200 }}>Send back</th></tr></thead><tbody>
          {list.map((p) => <tr key={p.id}><td><b>{p.name}</b><div className="code">{p.sku}</div></td><td className="r"><QtyCell p={p} q={at.get(p.id) ?? 0} cls={over.includes(p) ? 'bad' : ''} /></td><td>{cell(p)}</td></tr>)}
        </tbody></table> : <Empty i="box" t="No stock in the shop to send back" />}
      </div>
      <Note i="truck" warn={!!over.length} style={{ marginTop: 12 }}>{chosen.length} item{chosen.length === 1 ? '' : 's'}, {sum(chosen, pcsOf)} units leave the shop stock now{noStore ? '; the Admin decides where they go' : ''}.</Note>
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
type Dest = 'supplier' | 'shop' | 'writeoff';
const DESTS: [Dest, string, string, string][] = [
  ['supplier', 'exchange', 'Back to the supplier', 'What you owe them drops at item cost'],
  ['shop', 'store', 'To another shop', 'Goes into that shop\'s stock'],
  ['writeoff', 'trash', 'Throw away', 'Damaged or expired: booked as a loss'],
];
/** Without a central store, the Admin counts what came back and decides where it goes. */
function DecideReturn({ x, shop, byId, onClose }: { x: ShopReturn; shop: string; byId: Map<string, Product>; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction(), settings = useSettings();
  const suppliers = useSuppliers(), shops = useShops(), costs = useCosts(true);
  const [got, setGot] = useState<Record<string, string>>(Object.fromEntries(x.return_items.map((i) => [i.product_id, String(i.qty)])));
  const [dest, setDest] = useState<Dest | ''>(''), [sup, setSup] = useState(''), [to, setTo] = useState(''), [note, setNote] = useState(''), [print, setPrint] = useState(true);
  const cost = useMemo(() => new Map((costs.data ?? []).map((c) => [c.product_id, Number(c.cost_usd) || 0])), [costs.data]);
  const n = (pid: string) => Math.min(Math.max(0, parseInt(got[pid]) || 0), 9999999);
  const over = x.return_items.filter((i) => n(i.product_id) > i.qty), shortItems = x.return_items.filter((i) => n(i.product_id) < i.qty);
  const back = sum(x.return_items, (i) => Math.min(n(i.product_id), i.qty)), missing = sum(shortItems, (i) => i.qty - n(i.product_id));
  const vBack = sum(x.return_items, (i) => Math.min(n(i.product_id), i.qty) * (cost.get(i.product_id) ?? 0)), vMissing = sum(shortItems, (i) => (i.qty - n(i.product_id)) * (cost.get(i.product_id) ?? 0));
  // suppliers of these items first
  const mine = new Set(x.return_items.map((i) => i.product_id));
  const sups = (suppliers.data ?? []).filter((s) => s.active).map((s) => ({ s, fits: (s.supplier_items ?? []).some((i) => mine.has(i.product_id)) }))
    .sort((p, q) => Number(q.fits) - Number(p.fits) || p.s.name.localeCompare(q.s.name));
  const supplier = sups.find((p) => p.s.id === sup)?.s, target = (shops.data ?? []).find((s) => s.id === to);
  const others = (shops.data ?? []).filter((s) => s.active && s.id !== x.shop_id);
  const effect = !dest ? 'Choose where the goods go.'
    : dest === 'supplier' ? (supplier ? `${back} units go back to ${supplier.name}. What you owe them drops by ${fUSD(vBack)} at item cost; settle the amount they credit under Accounts.` : 'Choose the supplier.')
    : dest === 'shop' ? (target ? `${back} units go into the stock of ${target.name}.` : 'Choose the shop.')
    : `${back} units are thrown away, booked as a stock loss of ${fUSD(vBack)}.`;
  const save = () => a.run(async () => {
    if (!dest) throw new Error('Choose where the goods go');
    if (over.length) throw new Error('You cannot count more than was sent: ' + over.map((i) => byId.get(i.product_id)?.name).join(', '));
    const lines = x.return_items.map((i) => ({ product_id: i.product_id, qty: n(i.product_id) }));
    const r = await rpc<{ sent: number; received: number; supplier_return: string | null }>('decide_return', { p: { id: x.id, outcome: dest, lines, note, supplier_id: dest === 'supplier' ? sup || null : null, shop_id: dest === 'shop' ? to || null : null } });
    if (dest === 'supplier' && print && r.supplier_return) {
      printHTML(supplierReturnNoteHTML({ no: r.supplier_return, kind: 'return', reason: x.reason, note: `From ${x.no}, ${shop}`, created_at: new Date().toISOString(), created_by_name: '',
        supplier_return_items: lines.filter((l) => l.qty > 0) }, supplier?.name ?? '', settings.data?.company ?? {}, byId));
    }
    await refresh('returns', 'stock', 'sreturns', 'audit');
    toast(dest === 'supplier' ? `${x.no}: ${r.received} units back to ${supplier?.name} as ${r.supplier_return}` : dest === 'shop' ? `${x.no}: ${r.received} units moved to ${target?.name}` : `${x.no}: ${r.received} units thrown away`);
    onClose();
  });
  return (
    <Modal title={`Decide return ${x.no} from ${shop}`} icon="exchange" wide onClose={onClose}
      foot={<><button className="btn" onClick={onClose}>Not now</button><button className="btn primary" disabled={a.busy || !dest} onClick={() => void save()}><Icon n="check" /> Confirm</button></>}>
      <Note i="doc">Reason from the shop: {x.reason}</Note>
      <h4 className="step">1. Count what came back</h4>
      <div className="tw"><table className="t"><thead><tr><th>Item</th><th className="r">Sent</th><th style={{ width: 150 }}>Came back</th></tr></thead><tbody>
        {x.return_items.map((i) => { const p = byId.get(i.product_id); return <tr key={i.product_id}><td><b>{p?.name}</b><div className="code">{p?.sku}</div></td><td className="r">{i.qty} {p?.stock_unit}</td>
          <td><input className={`input${n(i.product_id) > i.qty ? ' bad' : ''}`} type="number" min="0" max={i.qty} inputMode="numeric" value={got[i.product_id]} style={{ minHeight: 42 }} onChange={(e) => setGot({ ...got, [i.product_id]: e.target.value })} aria-label={`Came back ${p?.name}`} /></td></tr>; })}
      </tbody></table></div>
      {missing > 0 ? <Note i="alert" warn style={{ marginTop: 10 }}>{missing} unit{missing === 1 ? ' is' : 's are'} missing: booked as a loss of {fUSD(vMissing)}. Write what happened in the note.</Note> : null}
      <h4 className="step">2. Where do the goods go?</h4>
      <div className="choices" role="radiogroup" aria-label="Where the goods go">
        {DESTS.map(([k, i, t, sub]) => <button key={k} type="button" role="radio" aria-checked={dest === k} className={`choice${dest === k ? ' on' : ''}`} onClick={() => setDest(k)}><Icon n={i} /><b>{t}</b><span>{sub}</span></button>)}
      </div>
      <Note warn={!dest} i={dest ? DESTS.find((d) => d[0] === dest)![1] : 'exchange'}>{effect}</Note>
      {dest === 'supplier' ? <div className="frow" style={{ marginTop: 12 }}>
        <div className="field"><label htmlFor="dsup">Supplier</label><select id="dsup" className="input" value={sup} onChange={(e) => setSup(e.target.value)}><option value="">Choose the supplier</option>
          {sups.map(({ s, fits }) => <option key={s.id} value={s.id}>{s.name}{fits ? ' (supplies these items)' : ''}</option>)}</select></div>
        <label className="switch" style={{ alignSelf: 'center' }}><input type="checkbox" checked={print} onChange={(e) => setPrint(e.target.checked)} /><span>Print a return note for the supplier</span></label>
      </div> : null}
      {dest === 'shop' ? <div className="field" style={{ marginTop: 12 }}><label htmlFor="dshop">Shop</label><select id="dshop" className="input" value={to} onChange={(e) => setTo(e.target.value)}><option value="">Choose the shop</option>
        {others.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>{others.length ? null : <span className="hint">There is no other shop.</span>}</div> : null}
      <div className="field" style={{ marginTop: 4 }}><label htmlFor="dnote">Note {missing > 0 ? '(required: what happened to the missing goods?)' : '(optional)'}</label><input id="dnote" className="input" maxLength={120} value={note} onChange={(e) => setNote(e.target.value)} /></div>
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

/** Statements for the warehouse: the stock ledgers of the store and each shop. The Shop Admin has no Statements tab. */
export function Books() {
  const ledgers = useLedgers();
  const s = 'Stock accounts at cost: the central store and each shop. Goods sent to a shop are booked against it when the shop receives them; sales and returns reduce it.';
  return (
    <>
      <Head t="Statements" s={s} />
      <StatementView ledgers={ledgers.data ?? []} loading={ledgers.isLoading} />
    </>
  );
}
