import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useDeliveries, useInvoices, useOrders, useProducts, useRefresh, useReport, useSettings, useShops, useStock } from '../data/queries';
import { rpc } from '../lib/supabase';
import { ctnTxt, totals, unitLabel, unitsOf } from '../lib/units';
import { dt, fCDF, ld, sum, tm, toCDF, today } from '../lib/format';
import { printHTML, receiptHTML } from '../lib/print';
import { Dual2, Empty, Head, Kpi, Modal, Note, Tile, useAction, useToast } from '../components/ui';
import { outboxAll } from '../offline/store';
import type { Invoice } from '../lib/types';

export function ShopHome() {
  const { profile } = useAuth(), nav = useNavigate();
  const sid = profile!.shop_id!;
  const shops = useShops(), rep = useReport(today(), today(), sid), stock = useStock(sid), products = useProducts(), dels = useDeliveries(sid);
  const shop = shops.data?.find((s) => s.id === sid), r = rep.data;
  const byId = new Map((products.data ?? []).map((p) => [p.id, p]));
  const low = (stock.data ?? []).filter((x) => x.qty <= 5 && byId.has(x.product_id)).sort((a, b) => a.qty - b.qty);
  const lastDel = dels.data?.find((d) => d.status === 'received');
  const toReceive = (dels.data ?? []).filter((d) => d.status === 'pending').length, toReview = (useOrders('pending').data ?? []).length;
  return (
    <>
      <Head t={`Good ${new Date().getHours() < 12 ? 'morning' : 'afternoon'}, ${profile!.name.split(' ')[0]}`} s={`${shop?.name ?? ''}, ${new Date().toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })}`} />
      <div className="kpis">
        <Kpi i="chart" l="Sales today" tone="ok"><Dual2 b={fCDF(r?.total ?? 0)} s={`${r?.n ?? 0} invoices`} /></Kpi>
        <Kpi i="cash" l="Cash taken"><Dual2 b={fCDF(r?.total ?? 0)} s="cash only" /></Kpi>
        <Kpi i="edit" l="Invoices edited today" tone={r?.edited ? 'warn' : ''}><Dual2 b={r?.edited ?? 0} s="by the shop admin" /></Kpi>
        <Kpi i="alert" l="Items running low" tone={low.length ? 'bad' : ''}><Dual2 b={low.length} s="5 or fewer left" /></Kpi>
      </div>
      <div className="tiles"><Tile i="cart" l={<>Open till{toReview ? <em>{toReview} to review</em> : null}</>} onClick={() => nav('/till')} /><Tile i="receipt" l="Invoices" onClick={() => nav('/invoices')} /><Tile i="truck" l={<>Deliveries{toReceive ? <em>{toReceive} to receive</em> : null}</>} onClick={() => nav('/received')} /><Tile i="chart" l="Sales report" onClick={() => nav('/reports')} /></div>
      <div className="card p0"><div style={{ padding: '16px 16px 0' }}><h3><Icon n="alert" /> Running low or sold on order</h3></div>
        {low.length ? <><div className="tw"><table className="t"><tbody>{low.slice(0, 30).map((x) => <tr key={x.product_id}><td><b>{byId.get(x.product_id)!.name}</b></td><td className="r"><span className={`chip ${x.qty > 0 ? 'warn' : 'bad'}`}>{x.qty > 0 ? x.qty + ' left' : x.qty < 0 ? Math.abs(x.qty) + ' sold on order' : 'None left'}</span></td></tr>)}</tbody></table></div>
          <Note i="truck" style={{ margin: '12px 16px' }}>The central store sees this list and sends stock directly.{lastDel ? <> Last delivery received: <b>{lastDel.no}</b> on {dt(lastDel.received_at ?? lastDel.created_at)}.</> : null}</Note></> : <Empty i="check" t="Stock levels look good" />}</div>
    </>
  );
}

export function ShopStock() {
  const { profile } = useAuth();
  const sid = profile!.shop_id!;
  const products = useProducts(), stock = useStock(sid), settings = useSettings();
  const rate = settings.data?.rate ?? 0, at = new Map((stock.data ?? []).map((r) => [r.product_id, r]));
  return (
    <>
      <Head t="Shop stock" s="Prices come from the Admin and are locked. Items can still be sold when stock reaches zero; the shortage shows here in red." />
      <div className="card p0"><div className="tw">{(products.data ?? []).length ? <table className="t"><thead><tr><th>Item</th><th>Category</th><th>Sold as</th><th className="r">In shop</th><th>Prices</th></tr></thead><tbody>
        {(products.data ?? []).map((p) => { const s = at.get(p.id), q = s?.qty ?? 0; return <tr key={p.id}><td><b>{p.name}</b><div className="code">{p.sku}{p.is_bundle ? `, set of ${p.pieces_per_set}${s?.open_pieces ? `, ${s.open_pieces} pieces already sold from an open set` : ''}` : ''}</div></td><td>{p.category}</td>
          <td>{unitsOf(p).map((u, k) => <span key={k}><span className="uchip">{unitLabel(u)}</span> </span>)}</td>
          <td className="r"><span className={`chip ${q < 0 ? 'bad' : q <= 5 ? 'warn' : 'ok'}`}>{q < 0 ? Math.abs(q) + ' on order' : q}</span>{q > 0 && ctnTxt(p, q) ? <div className="code">{ctnTxt(p, q)}</div> : null}</td>
          <td>{unitsOf(p).map((u, k) => <div key={k} style={{ whiteSpace: 'nowrap' }}><Icon n="lock" /> <b>{fCDF(toCDF(u.usd, rate))}</b> <span className="code">per {unitLabel(u)}</span></div>)}</td></tr>; })}
      </tbody></table> : <Empty i="box" t={products.isLoading ? 'Loading' : 'No items yet'} />}</div></div>
    </>
  );
}

export function Invoices() {
  const { profile } = useAuth();
  const sid = profile!.shop_id!;
  const [f, setF] = useState<'today' | 'week' | 'all'>('today'), [s, setS] = useState(''), [view, setView] = useState<Invoice | null>(null), [edit, setEdit] = useState<Invoice | null>(null);
  const since = f === 'all' ? null : new Date(f === 'today' ? new Date(today() + 'T00:00:00').getTime() : Date.now() - 7 * 864e5).toISOString();
  const inv = useInvoices(sid, since), shops = useShops(), settings = useSettings(), refresh = useRefresh(), toast = useToast();
  const [waiting, setWaiting] = useState<Invoice[]>([]);
  useEffect(() => { const upd = () => void outboxAll().then((l) => setWaiting(l.flatMap((e) => (e.shop_id === sid && e.kind !== 'order' ? [e.invoice] : [])))); upd(); addEventListener('sim-outbox', upd); return () => removeEventListener('sim-outbox', upd); }, [sid]);
  const shop = shops.data?.find((x) => x.id === sid);
  const q = s.trim().toLowerCase();
  const list = useMemo(() => {
    const server = inv.data ?? [], ids = new Set(server.map((i) => i.id));
    return [...waiting.filter((w) => !ids.has(w.id) && (f === 'all' || ld(w.t) >= ld(since!))), ...server].filter((i) => !q || i.no.toLowerCase().includes(q) || i.cashier_name.toLowerCase().includes(q));
  }, [inv.data, waiting, q, f, since]);
  const pending = list.filter((i) => !i.synced).length, edited = list.filter((i) => i.edits?.length).length;
  const dup = async (i: Invoice) => {
    if (!shop || !settings.data) return;
    try { if (i.synced) await rpc('record_reprint', { p_id: i.id }); printHTML(receiptHTML(i, settings.data.company, shop, { copy: 'client', dup: true })); await refresh('invoices', 'audit'); }
    catch (e) { toast((e as Error).message, 'bad'); }
  };
  return (
    <>
      <Head t="Invoices" s="Find any sale, edit it if something was wrong, or print a duplicate." />
      <div className="toolbar"><div className="seg">{([['today', 'Today'], ['week', '7 days'], ['all', 'All']] as const).map(([k, l]) => <button key={k} className={f === k ? 'on' : ''} onClick={() => setF(k)}>{l}</button>)}</div>
        <div className="search"><Icon n="search" /><input placeholder={`Invoice number or customer, e.g. ${shop?.code ?? 'GOM'}-T1-000005`} value={s} onChange={(e) => setS(e.target.value)} /></div></div>
      <div className="kpis">
        <Kpi i="receipt" l="Total"><Dual2 b={fCDF(sum(list, (i) => i.total))} s={`${list.length} invoices`} /></Kpi>
        <Kpi i="cash" l="Cash taken" tone="ok"><Dual2 b={fCDF(sum(list, (i) => i.total))} s="cash only" /></Kpi>
        <Kpi i="edit" l="Edited" tone={edited ? 'warn' : ''}><Dual2 b={edited} s="you can edit and reprint" /></Kpi>
        <Kpi i={pending ? 'clock' : 'cloud'} l="Sent to server" tone={pending ? 'warn' : 'ok'}><Dual2 b={pending ? pending + ' waiting' : 'All sent'} s={pending ? 'Will send when online' : 'Up to date'} /></Kpi>
      </div>
      <div className="card p0">{list.length ? <div className="tw"><table className="t"><thead><tr><th>Invoice</th><th>Time</th><th>Customer</th><th>Cashier</th><th className="r">Items</th><th className="r">Discount</th><th className="r">Total</th><th>Printing</th><th>Server</th><th /></tr></thead><tbody>
        {list.slice(0, 300).map((i) => <tr key={i.id}><td><b>{i.no}</b>{i.edits?.length ? <> <span className="chip warn">Edited</span></> : null}</td><td style={{ whiteSpace: 'nowrap' }}>{f === 'today' ? tm(i.t) : dt(i.t)}</td><td>{i.customer || '-'}</td><td>{i.cashier_name}{i.prepared_by_name ? <div className="code">prepared by {i.prepared_by_name}</div> : null}</td><td className="r">{sum(i.items, (x) => x.qty)}</td>
          <td className="r">{i.disc ? fCDF(i.disc) : '-'}</td><td className="r"><b>{fCDF(i.total)}</b></td>
          <td>{i.printed > 2 ? <span className="chip warn">{i.printed - 2} duplicate{i.printed - 2 > 1 ? 's' : ''}</span> : <span className="chip"><Icon n="lock" /> 2 copies</span>}</td>
          <td>{i.synced ? <span className="chip ok"><Icon n="cloud" /> Sent</span> : <span className="chip warn"><Icon n="clock" /> Waiting</span>}</td>
          <td><div className="act"><button title="View invoice" onClick={() => setView(i)}><Icon n="eye" /></button>{i.synced ? <button title="Edit invoice" onClick={() => setEdit(i)}><Icon n="edit" /></button> : null}<button title="Print duplicate" onClick={() => void dup(i)}><Icon n="printer" /></button></div></td></tr>)}
      </tbody></table></div> : <Empty i="receipt" t={inv.isLoading ? 'Loading' : 'No invoices for this period'} />}</div>
      {view && shop && settings.data ? <Modal title={'Invoice ' + view.no} icon="receipt" onClose={() => setView(null)} foot={<><button className="btn" onClick={() => setView(null)}>Close</button>{view.synced ? <button className="btn ghost" onClick={() => { setEdit(view); setView(null); }}><Icon n="edit" /> Edit invoice</button> : null}<button className="btn primary" onClick={() => void dup(view)}><Icon n="printer" /> Print duplicate</button></>}>
        <div className="rwrap" dangerouslySetInnerHTML={{ __html: receiptHTML(view, settings.data.company, shop, { copy: 'client', dup: true }) }} />
        {view.edits?.length ? <Note i="edit" warn>Edited {view.edits.length} time{view.edits.length > 1 ? 's' : ''}. Last change by {view.edits.at(-1)!.by_name} on {dt(view.edits.at(-1)!.at)}: {view.edits.at(-1)!.reason}</Note> : null}
        {!view.synced ? <Note i="clock" warn>Saved on this device. It will be sent to the server when the internet is available; it can be edited after that.</Note> : null}
      </Modal> : null}
      {edit ? <EditInvoice inv={edit} onClose={() => setEdit(null)} /> : null}
    </>
  );
}

function EditInvoice({ inv, onClose }: { inv: Invoice; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction();
  const [qty, setQty] = useState(inv.items.map((i) => String(i.qty))), [dp, setDp] = useState(String(inv.disc_pct || 0)), [reason, setReason] = useState('');
  const lines = inv.items.map((it, k) => ({ ...it, qty: Math.max(0, parseInt(qty[k]) || 0) })).filter((l) => l.qty > 0);
  const T = totals(lines, Math.min(30, Math.max(0, parseInt(dp) || 0)), inv.vat_rate), d = T.total - inv.total;
  const save = () => a.run(async () => {
    if (!lines.length) throw new Error('Keep at least one line on the invoice');
    if (reason.trim().length < 4) throw new Error('Write a short reason for the change');
    await rpc('edit_invoice', { p_id: inv.id, p_lines: inv.items.map((it, k) => ({ line_no: it.line_no, qty: Math.max(0, parseInt(qty[k]) || 0) })), p_disc: parseInt(dp) || 0, p_reason: reason });
    await refresh('invoices', 'stock', 'report', 'audit'); toast('Invoice updated. Print a duplicate if the customer needs it.'); onClose();
  });
  return (
    <Modal title={'Edit invoice ' + inv.no} icon="edit" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Save changes</button></>}>
      <Note i="shield">Change quantities or remove a line, and adjust the discount on this invoice. Item prices stay as they were sold. Stock is corrected automatically and the change is recorded in the activity log.</Note>
      <div className="tw"><table className="t"><thead><tr><th>Item</th><th>Unit</th><th className="r">Price</th><th style={{ width: 120 }}>Qty</th></tr></thead><tbody>
        {inv.items.map((it, k) => <tr key={k}><td><b>{it.name}</b></td><td><span className="uchip">{it.piece ? '1 piece' : it.unit}</span></td><td className="r">{fCDF(it.price)}</td><td><input className="input" data-eq={k} type="number" min="0" value={qty[k]} style={{ minHeight: 42 }} onChange={(e) => setQty(qty.map((x, j) => (j === k ? e.target.value : x)))} /></td></tr>)}
      </tbody></table></div>
      <div className="field"><label>Discount on this invoice (%)</label><input id="edp" className="input" type="number" min="0" max="30" value={dp} onChange={(e) => setDp(e.target.value)} /></div>
      <div className="field"><label>Reason for the change</label><input id="ereason" className="input" maxLength={80} placeholder="e.g. Customer returned one lipstick" value={reason} onChange={(e) => setReason(e.target.value)} /></div>
      <div className={`note ${d > 0 ? 'warn' : ''}`}><Icon n="receipt" /><div>New total <b>{fCDF(T.total)}</b>, was {fCDF(inv.total)}. {lines.length} line{lines.length === 1 ? '' : 's'}. {d < 0 ? <>Give back to the customer: <b>{fCDF(-d)}</b></> : d > 0 ? <>Collect from the customer: <b>{fCDF(d)}</b></> : 'No money changes hands.'}</div></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}
