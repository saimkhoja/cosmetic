// Stock requests: the shop admin asks the central store for stock; the warehouse checks the list
// against its stock and approves it (as asked or edited) or rejects it. An approved request becomes
// a delivery that the shop admin receives as usual.
import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useDeliveries, useProducts, useRanks, useRefresh, useShops, useStock, useStockRequests } from '../data/queries';
import { rpc } from '../lib/supabase';
import { ctnTxt, hotSort } from '../lib/units';
import { dt, sum, tm } from '../lib/format';
import { Empty, Head, Modal, Note, useAction, useToast } from '../components/ui';
import { QtyCell } from './Inventory';
import { per, useQtyLines, type Line } from './Stores';
import type { Product, StockRequest } from '../lib/types';

const asLine = (p: Product | undefined, qty: number): Line => (p && per(p) && qty % per(p) === 0 ? { n: String(qty / per(p)), u: 'ctn' } : { n: String(qty), u: 'pcs' });
const units = (r: StockRequest) => sum(r.stock_request_items, (i) => i.qty);

function Status({ r }: { r: StockRequest }) {
  const edited = r.status === 'approved' && r.stock_request_items.some((i) => (i.approved_qty ?? 0) !== i.qty);
  return r.status === 'pending' ? <span className="chip warn"><Icon n="clock" /> Waiting for the warehouse</span>
    : r.status === 'approved' ? <span className={`chip ${edited ? 'warn' : 'ok'}`}><Icon n="truck" /> Approved{edited ? ' with changes' : ''}</span>
    : r.status === 'rejected' ? <span className="chip bad"><Icon n="x" /> Rejected</span> : <span className="chip">Cancelled</span>;
}

function RequestCard({ r, byId, shop, delNo, onCancel, actions }: { r: StockRequest; byId: Map<string, Product>; shop: string; delNo?: string; onCancel?: () => void; actions?: React.ReactNode }) {
  const sent = r.status === 'approved';
  return (
    <div className="card p0">
      <div style={{ padding: '14px 16px', display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap', borderBottom: '1px solid var(--line)' }}>
        <b style={{ fontSize: 17 }}>{r.no}</b><Status r={r} /><span style={{ color: 'var(--muted)' }}>{shop}, asked by {r.created_by_name} on {dt(r.created_at)}</span><span className="sp" />
        {onCancel && r.status === 'pending' ? <button className="btn sm" onClick={onCancel}><Icon n="x" /> Cancel</button> : null}{actions}
      </div>
      {r.note ? <Note i="doc" style={{ margin: '12px 16px 0' }}>Note from the shop: {r.note}</Note> : null}
      {r.status !== 'pending' && (r.reason || sent) ? <Note i={r.status === 'rejected' ? 'x' : 'truck'} warn={r.status === 'rejected' || !!r.reason} style={{ margin: '12px 16px 0' }}>
        {r.status === 'approved' ? <>Approved by {r.reviewed_by_name} on {dt(r.reviewed_at!)}{delNo ? <>: sent as delivery <b>{delNo}</b>, to receive under Deliveries</> : null}.</> : r.status === 'rejected' ? <>Rejected by {r.reviewed_by_name} on {dt(r.reviewed_at!)}.</> : <>Cancelled on {dt(r.reviewed_at!)}.</>}
        {r.reason ? <> Reason: <b>{r.reason}</b></> : null}</Note> : null}
      <div className="tw"><table className="t"><thead><tr><th>Item</th><th className="r">Asked</th>{sent ? <th className="r">Sent</th> : null}</tr></thead><tbody>
        {r.stock_request_items.map((i) => { const p = byId.get(i.product_id); return <tr key={i.product_id}><td><b>{p?.name}</b><div className="code">{p?.sku}</div></td>
          <td className="r">{i.qty ? <>{i.qty} {p?.stock_unit}{p && ctnTxt(p, i.qty) ? <div className="code">{ctnTxt(p, i.qty)}</div> : null}</> : <span className="code">added by the store</span>}</td>
          {sent ? <td className="r"><span className={`chip ${(i.approved_qty ?? 0) < i.qty ? 'warn' : 'ok'}`}>{i.approved_qty ?? 0}</span></td> : null}</tr>; })}
      </tbody></table></div>
    </div>
  );
}

export default function Requests() {
  const { profile } = useAuth();
  return profile!.role === 'shopadmin' ? <ShopRequests /> : <StoreRequests />;
}

// ---------- shop admin ----------
function ShopRequests() {
  const { profile } = useAuth(), reqs = useStockRequests(), products = useProducts(), shops = useShops(), dels = useDeliveries(profile!.shop_id);
  const [make, setMake] = useState(false), [cancel, setCancel] = useState<StockRequest | null>(null);
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const shop = shops.data?.find((s) => s.id === profile!.shop_id)?.name ?? '';
  const delNo = (id: string | null) => dels.data?.find((d) => d.id === id)?.no;
  const list = reqs.data ?? [];
  return (
    <>
      <Head t="Order stock" s="Ask the central store for the stock you need. The warehouse checks it against the store and approves, changes or rejects it. What it approves arrives as a delivery that you receive under Deliveries."
        a={<button className="btn primary" onClick={() => setMake(true)}><Icon n="plus" /> New request</button>} />
      {list.length ? list.map((r) => <RequestCard key={r.id} r={r} byId={byId} shop={shop} delNo={delNo(r.delivery_id)} onCancel={() => setCancel(r)} />)
        : <div className="card"><Empty i="truck" t={reqs.isLoading ? 'Loading' : 'No requests yet. Press New request to order stock.'} /></div>}
      {make ? <NewRequest onClose={() => setMake(false)} /> : null}
      {cancel ? <ReasonModal title={`Cancel request ${cancel.no}`} text="The warehouse will no longer see it." button="Cancel request" optional fn="cancel_stock_request" id={cancel.id} done="Request cancelled" onClose={() => setCancel(null)} /> : null}
    </>
  );
}

function NewRequest({ onClose }: { onClose: () => void }) {
  const { profile } = useAuth(), products = useProducts(), stock = useStock(profile!.shop_id), ranks = useRanks(profile!.shop_id), refresh = useRefresh(), toast = useToast(), a = useAction();
  const [note, setNote] = useState(''), [q, setQ] = useState('');
  const { pcsOf, cell } = useQtyLines();
  const at = new Map((stock.data ?? []).map((r) => [r.product_id, r.qty]));
  const all = hotSort((products.data ?? []).filter((p) => p.active), ranks.data), ql = q.trim().toLowerCase();
  const chosen = all.filter((p) => pcsOf(p) > 0);
  const list = all.filter((p) => pcsOf(p) > 0 || !ql || (p.name + ' ' + p.sku + ' ' + p.category).toLowerCase().includes(ql)).sort((x, y) => Number(pcsOf(y) > 0) - Number(pcsOf(x) > 0)).slice(0, 150);
  const save = () => a.run(async () => {
    if (!chosen.length) throw new Error('Enter a quantity for at least one item');
    const r = await rpc<{ no: string }>('create_stock_request', { p: { note, lines: chosen.map((p) => ({ product_id: p.id, qty: pcsOf(p) })) } });
    await refresh('requests', 'audit'); toast(`${r.no} sent to the warehouse`); onClose();
  });
  return (
    <Modal title="Ask the central store for stock" icon="truck" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" id="reqsend" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Send request</button></>}>
      <div className="search" style={{ maxWidth: 'none', marginBottom: 10 }}><Icon n="search" /><input placeholder="Find an item by name, code or category. Best sellers come first" value={q} onChange={(e) => setQ(e.target.value)} autoFocus /></div>
      <div className="tw" style={{ maxHeight: '46vh', overflow: 'auto', border: '1px solid var(--line)', borderRadius: 12 }}>
        {list.length ? <table className="t"><thead><tr><th>Item</th><th className="r">In shop</th><th style={{ width: 200 }}>Ask for</th></tr></thead><tbody>
          {list.map((p) => { const v = at.get(p.id) ?? 0; return <tr key={p.id}><td><b>{p.name}</b><div className="code">{p.sku}{per(p) ? ` · ${per(p)} pcs per carton` : ''}</div></td><td className="r"><QtyCell p={p} q={v} cls={v <= 0 ? 'bad' : v <= 5 ? 'warn' : 'ok'} /></td><td>{cell(p)}</td></tr>; })}
        </tbody></table> : <Empty i="search" t="No items match" />}
      </div>
      <div className="field" style={{ marginTop: 12 }}><label>Note for the warehouse (optional)</label><input id="reqnote" className="input" maxLength={120} value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Needed before Saturday" /></div>
      <Note i="truck">{chosen.length} item{chosen.length === 1 ? '' : 's'}, {sum(chosen, pcsOf)} units. Nothing moves until the warehouse approves and you receive the delivery.</Note>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

// ---------- warehouse and Admin ----------
function useStoreCanSend() {
  const dels = useDeliveries();
  // store stock not yet promised to deliveries waiting at a shop, as on the delivery form
  return (p: Product) => p.wh_qty - sum((dels.data ?? []).filter((d) => d.status === 'pending'), (d) => sum(d.delivery_items.filter((i) => i.product_id === p.id), (i) => i.qty));
}

function StoreRequests() {
  const reqs = useStockRequests(), products = useProducts(), shops = useShops(), dels = useDeliveries(), refresh = useRefresh(), toast = useToast(), nav = useNavigate();
  const canSend = useStoreCanSend();
  const [edit, setEdit] = useState<StockRequest | null>(null), [reject, setReject] = useState<StockRequest | null>(null), [busy, setBusy] = useState('');
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const shopName = (id: string) => shops.data?.find((s) => s.id === id)?.name ?? '';
  const delNo = (id: string | null) => dels.data?.find((d) => d.id === id)?.no;
  const waiting = (reqs.data ?? []).filter((r) => r.status === 'pending').sort((x, y) => x.created_at.localeCompare(y.created_at));
  const done = (reqs.data ?? []).filter((r) => r.status !== 'pending');
  const shortOf = (r: StockRequest) => r.stock_request_items.filter((i) => { const p = byId.get(i.product_id); return !p || canSend(p) < i.qty; });
  const approve = async (r: StockRequest) => {
    const s = shortOf(r);
    if (s.length) { toast(`Not enough in the store for ${s.map((i) => byId.get(i.product_id)?.name ?? 'an item').join(', ')}. Use Edit to send less.`, 'warn'); setEdit(r); return; }
    setBusy(r.id);
    try { const x = await rpc<{ delivery_no: string }>('approve_stock_request', { p_id: r.id }); await refresh('requests', 'deliveries', 'products', 'audit'); toast(`${r.no} approved: ${x.delivery_no} is on its way to ${shopName(r.shop_id)}`); }
    catch (e) { toast((e as Error).message, 'bad'); } finally { setBusy(''); }
  };
  return (
    <>
      <Head t="Stock requests" s="What the shops have asked for. Check each list against the store: approve it as asked, edit the quantities first, or reject it with a reason. An approved request becomes a delivery that the shop admin receives."
        a={<button className="btn ghost" onClick={() => nav('/deliveries')}><Icon n="truck" /> Deliveries</button>} />
      <div className="card p0"><div style={{ padding: '16px 16px 0' }}><h3><Icon n="clock" /> Waiting for review ({waiting.length})</h3></div>
        {waiting.length ? <div className="tw"><table className="t"><thead><tr><th>Request</th><th>Shop</th><th className="r">Items</th><th>Store</th><th style={{ width: 160 }} /></tr></thead><tbody>
          {waiting.map((r) => { const s = shortOf(r); return <tr key={r.id} className="reqrow">
            <td><b>{r.no}</b><div className="code">{r.created_by_name}, {tm(r.created_at)} {dt(r.created_at).slice(0, 11)}</div>{r.note ? <div className="code">“{r.note}”</div> : null}</td>
            <td><b>{shopName(r.shop_id)}</b></td>
            <td className="r">{r.stock_request_items.length}<div className="code">{units(r)} units</div></td>
            <td>{s.length ? <span className="chip bad"><Icon n="alert" /> Short: {s.map((i) => byId.get(i.product_id)?.name).join(', ')}</span> : <span className="chip ok"><Icon n="check" /> Can send all</span>}</td>
            <td><div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
              <button className="rbtn ok" title="Approve and send as asked" aria-label={`Approve ${r.no}`} disabled={busy === r.id} onClick={() => void approve(r)}><Icon n="check" /></button>
              <button className="rbtn bad" title="Reject this request" aria-label={`Reject ${r.no}`} onClick={() => setReject(r)}><Icon n="x" /></button>
              <button className="rbtn ed" title="Check and change before approving" aria-label={`Edit ${r.no}`} onClick={() => setEdit(r)}><Icon n="edit" /></button></div></td></tr>; })}
        </tbody></table></div> : <Empty i="check" t={reqs.isLoading ? 'Loading' : 'No requests waiting'} />}</div>
      {done.length ? <><h3 style={{ margin: '18px 0 10px' }}>Earlier requests</h3>{done.slice(0, 40).map((r) => <RequestCard key={r.id} r={r} byId={byId} shop={shopName(r.shop_id)} delNo={delNo(r.delivery_id)} />)}</> : null}
      {edit ? <EditRequest r={edit} shop={shopName(edit.shop_id)} onClose={() => setEdit(null)} onReject={() => { setReject(edit); setEdit(null); }} /> : null}
      {reject ? <ReasonModal title={`Reject request ${reject.no}`} text={`${shopName(reject.shop_id)} will see the reason. Nothing is sent.`} button="Reject request" fn="reject_stock_request" id={reject.id} done={`${reject.no} rejected`} onClose={() => setReject(null)} /> : null}
    </>
  );
}

function EditRequest({ r, shop, onClose, onReject }: { r: StockRequest; shop: string; onClose: () => void; onReject: () => void }) {
  const products = useProducts(), stock = useStock(r.shop_id), refresh = useRefresh(), toast = useToast(), a = useAction(), canSend = useStoreCanSend();
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const asked = new Map(r.stock_request_items.map((i) => [i.product_id, i.qty]));
  const { pcsOf, cell } = useQtyLines(Object.fromEntries(r.stock_request_items.map((i) => [i.product_id, asLine(byId.get(i.product_id), i.qty)])));
  const [q, setQ] = useState(''), [reason, setReason] = useState('');
  const at = new Map((stock.data ?? []).map((x) => [x.product_id, x.qty]));
  const ql = q.trim().toLowerCase(), all = (products.data ?? []).filter((p) => p.active || asked.has(p.id));
  const list = all.filter((p) => asked.has(p.id) || pcsOf(p) > 0 || (ql && (p.name + ' ' + p.sku + ' ' + p.category).toLowerCase().includes(ql)))
    .sort((x, y) => Number(asked.has(y.id)) - Number(asked.has(x.id)) || x.name.localeCompare(y.name)).slice(0, 150);
  const chosen = all.filter((p) => pcsOf(p) > 0), short = chosen.filter((p) => canSend(p) < pcsOf(p));
  const changed = all.some((p) => pcsOf(p) !== (asked.get(p.id) ?? 0));
  const save = () => a.run(async () => {
    if (!chosen.length) throw new Error('Nothing to send. Reject the request instead');
    if (short.length) throw new Error('Not enough in the store: ' + short.map((p) => p.name).join(', '));
    if (changed && reason.trim().length < 4) throw new Error('You changed the request. Write a short reason, the shop admin will see it');
    const x = await rpc<{ delivery_no: string }>('approve_stock_request', { p_id: r.id, p_lines: chosen.map((p) => ({ product_id: p.id, qty: pcsOf(p) })), p_note: reason });
    await refresh('requests', 'deliveries', 'products', 'audit'); toast(`${r.no} approved: ${x.delivery_no} is on its way to ${shop}`); onClose();
  });
  return (
    <Modal title={`Request ${r.no} from ${shop}`} icon="truck" wide onClose={onClose} foot={<><button className="btn danger" onClick={onReject}><Icon n="x" /> Reject</button><span className="sp" /><button className="btn" onClick={onClose}>Close</button><button className="btn primary" id="reqapprove" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> {changed ? 'Approve with changes' : 'Approve'} and send</button></>}>
      <p>Asked by {r.created_by_name} on {dt(r.created_at)}.{r.note ? <> Note: <b>{r.note}</b>.</> : null} Change what you send, remove a line (0) or add an item, then approve: a delivery is made for {shop}.</p>
      <div className="tw" style={{ maxHeight: '44vh', overflow: 'auto', border: '1px solid var(--line)', borderRadius: 12 }}><table className="t"><thead><tr><th>Item</th><th className="r">Asked</th><th className="r">Store can send</th><th className="r">{shop} has</th><th style={{ width: 200 }}>Send</th></tr></thead><tbody>
        {list.map((p) => { const c = canSend(p), v = at.get(p.id) ?? 0, ask = asked.get(p.id) ?? 0; return <tr key={p.id}><td><b>{p.name}</b><div className="code">{p.sku}{per(p) ? ` · ${per(p)} pcs per carton` : ''}</div></td>
          <td className="r">{ask ? <QtyCell p={p} q={ask} /> : <span className="code">not asked</span>}</td>
          <td className="r"><QtyCell p={p} q={c} cls={c < pcsOf(p) ? 'bad' : c <= 0 ? 'bad' : ''} /></td>
          <td className="r"><QtyCell p={p} q={v} cls={v <= 0 ? 'bad' : v <= 5 ? 'warn' : 'ok'} /></td><td>{cell(p)}</td></tr>; })}
      </tbody></table></div>
      <div className="search" style={{ maxWidth: 'none', margin: '10px 0' }}><Icon n="search" /><input placeholder="Add another item" value={q} onChange={(e) => setQ(e.target.value)} /></div>
      {changed ? <div className="field"><label>Reason for the change (the shop admin sees it)</label><input id="reqreason" className="input" maxLength={120} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Only one carton left in the store" /></div> : null}
      <div className={`note ${short.length ? 'warn' : ''}`}><Icon n={short.length ? 'alert' : 'truck'} /><div>{chosen.length} item{chosen.length === 1 ? '' : 's'}, {sum(chosen, pcsOf)} units to send.{short.length ? <> <b>Not enough in the store:</b> {short.map((p) => p.name).join(', ')}.</> : null}</div></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

function ReasonModal({ title, text, button, fn, id, done, optional, onClose }: { title: string; text: string; button: string; fn: string; id: string; done: string; optional?: boolean; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction();
  const [r, setR] = useState('');
  const go = () => a.run(async () => { await rpc(fn, { p_id: id, p_reason: r }); await refresh('requests', 'audit'); toast(done, 'warn'); onClose(); });
  return (
    <Modal title={title} icon="x" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Back</button><button className="btn danger" id="reqreject" disabled={a.busy} onClick={() => void go()}><Icon n="x" /> {button}</button></>}>
      <p>{text}</p><div className="field"><label>Reason{optional ? ' (optional)' : ''}</label><input id="reqwhy" className="input" maxLength={120} value={r} onChange={(e) => setR(e.target.value)} autoFocus /></div><div className="lerr">{a.err}</div>
    </Modal>
  );
}
