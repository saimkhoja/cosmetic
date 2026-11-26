// The Shop Admin is told when the Admin puts stock straight into the shop (no central store): a notice floats in at
// the top right; opening it lists what came in with the selling prices, and "Got it" marks it seen.
import { useMemo, useState } from 'react';
import { Icon } from '../lib/icons';
import { useArrivals, useProducts, useRefresh, useSettings } from '../data/queries';
import { rpc } from '../lib/supabase';
import { dt, fCDF, fNum, sum, toCDF } from '../lib/format';
import { ctnTxt, pcValue, unitLabel, unitsOf } from '../lib/units';
import type { Product, StockArrival } from '../lib/types';
import { Empty, Modal, useAction, useToast } from './ui';

/** "just now", "5 min ago", "2 h ago", or the date. */
export function ago(t: string, now = Date.now()) {
  const m = Math.round((now - new Date(t).getTime()) / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m} min ago`;
  if (m < 24 * 60) return `${Math.round(m / 60)} h ago`;
  return dt(t);
}
/** Items and units of some arrivals together. */
export const arrivalTotals = (list: Pick<StockArrival, 'stock_arrival_items'>[]) => {
  const items = new Set(list.flatMap((a) => a.stock_arrival_items.map((i) => i.product_id)));
  return { items: items.size, units: sum(list.flatMap((a) => a.stock_arrival_items), (i) => i.qty) };
};

/** The floating notice at the top right, for the Shop Admin on every page; shows while something that arrived is not seen yet
 *  (so the first thing a Shop Admin sees on signing in is stock added while they were away). */
export function ArrivalNotice() {
  const arr = useArrivals();
  const [later, setLater] = useState<string>(''), [open, setOpen] = useState<StockArrival[] | null>(null);
  const unseen = (arr.data ?? []).filter((a) => !a.seen_at);
  const key = unseen.map((a) => a.id).join(',');
  if (open) return <ArrivalsModal list={open} fresh onClose={() => setOpen(null)} />;
  if (!unseen.length || later === key) return null;
  const t = arrivalTotals(unseen), one = unseen.length === 1 ? unseen[0] : null;
  return (
    <div className="arrival" role="status" aria-live="polite" key={key}>
      <button className="arrival-body" onClick={() => setOpen(unseen)} aria-label="New stock arrived. Open to see the items">
        <span className="arrival-ic" aria-hidden="true"><Icon n="box" /><i className="spark s1" /><i className="spark s2" /><i className="spark s3" /></span>
        <span className="arrival-txt">
          <b>{one ? 'New stock arrived' : `${unseen.length} new stock arrivals`}</b>
          <span>{t.items} item{t.items === 1 ? '' : 's'}, {fNum(t.units)} units{one ? `, added by ${one.by_name} ${ago(one.at)}` : ''}</span>
          <span className="arrival-go">See what came in <Icon n="eye" /></span>
        </span>
      </button>
      <button className="arrival-x" onClick={() => setLater(key)} title="Later" aria-label="Hide for now"><Icon n="x" /></button>
    </div>
  );
}

/** What came in: each arrival with its items, quantities and selling prices. `fresh`: unseen ones, with "Got it". */
export function ArrivalsModal({ list, fresh, onClose }: { list: StockArrival[]; fresh?: boolean; onClose: () => void }) {
  const products = useProducts(), settings = useSettings(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const byId = useMemo(() => new Map((products.data ?? []).map((p) => [p.id, p])), [products.data]);
  const rate = settings.data?.rate ?? 0, t = arrivalTotals(list);
  const value = (rows: StockArrival['stock_arrival_items']) => sum(rows, (i) => { const p = byId.get(i.product_id); return p ? toCDF(pcValue(p), rate) * i.qty : 0; });
  const gotIt = () => a.run(async () => {
    if (fresh && list.length) await rpc('stock_arrivals_seen', { p_ids: list.map((x) => x.id) });
    await refresh('arrivals', 'stock', 'products');
    if (fresh && list.length) toast(`Stock checked in: ${t.items} item${t.items === 1 ? '' : 's'}, ${fNum(t.units)} units`);
    onClose();
  });
  return (
    <Modal title={fresh ? 'New stock in your shop' : 'Stock received'} icon="box" xl onClose={onClose}
      foot={fresh ? <><span className="sp" style={{ color: 'var(--muted)' }}>{t.items} items, {fNum(t.units)} units, {fCDF(value(list.flatMap((x) => x.stock_arrival_items)))} at selling price</span>
        <button className="btn primary" id="arrok" disabled={a.busy} onClick={() => void gotIt()}><Icon n="check" /> Got it</button></> : <button className="btn" onClick={onClose}>Close</button>}>
      {list.length ? list.map((x) => (
        <div key={x.id} className="arrival-sec">
          <div className="arrival-head">
            <span className="chip ok"><Icon n={x.kind === 'goods_in' ? 'truck' : 'download'} /> {x.kind === 'goods_in' ? 'From a supplier' : 'Added by the Admin'}</span>
            <b>{dt(x.at)}</b><span style={{ color: 'var(--muted)' }}>by {x.by_name}{x.what && x.what !== 'by hand' ? `, ${x.what}` : ''}</span>
            {x.seen_at ? <span className="code" style={{ marginLeft: 'auto' }}>Seen by {x.seen_by_name}</span> : !fresh ? <span className="chip warn" style={{ marginLeft: 'auto' }}>New</span> : null}
          </div>
          {x.note ? <div className="note" style={{ margin: '0 0 8px' }}><Icon n="doc" /><div>{x.note}</div></div> : null}
          <ArrivalTable rows={x.stock_arrival_items} byId={byId} rate={rate} />
        </div>
      )) : <Empty i="box" t="Nothing received yet" />}
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

function ArrivalTable({ rows, byId, rate }: { rows: StockArrival['stock_arrival_items']; byId: Map<string, Product>; rate: number }) {
  const list = rows.map((i) => ({ i, p: byId.get(i.product_id) })).sort((x, y) => (x.p?.name ?? '').localeCompare(y.p?.name ?? ''));
  return (
    <div className="tw"><table className="t arrival-t"><thead><tr><th>Item</th><th className="r">Received</th><th>Selling price</th><th className="r">Value</th></tr></thead><tbody>
      {list.map(({ i, p }) => { const units = p ? unitsOf(p).filter((u) => u.usd > 0) : [], c = p ? ctnTxt(p, i.qty) : ''; return (
        <tr key={i.product_id}>
          <td><b>{p?.name ?? 'Item'}</b><div className="code">{p?.sku}{p?.category ? ` · ${p.category}` : ''}</div></td>
          <td className="r nw"><b className="arrival-q">+{fNum(i.qty)}</b> {p?.stock_unit}{c ? <div className="code">{c}</div> : null}</td>
          <td>{units.length ? units.map((u, k) => <div key={k} className="nw"><span className="uchip">{unitLabel(u)}</span> {k === 0 ? <b>{fCDF(toCDF(u.usd, rate))}</b> : fCDF(toCDF(u.usd, rate))}</div>) : <span className="code">No price yet</span>}</td>
          <td className="r nw">{p ? fCDF(toCDF(pcValue(p), rate) * i.qty) : '-'}</td>
        </tr>); })}
    </tbody></table></div>
  );
}
