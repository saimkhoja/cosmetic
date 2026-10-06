import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { rpc, rows, supabase } from '../lib/supabase';
import { cartPriced, takeLocal, totals, unitLabel, unitNote, unitsOf, type CartLine } from '../lib/units';
import { CATICON, CATS } from '../lib/items';
import { fCDF, toCDF } from '../lib/format';
import { printHTML, receiptHTML, saleCopies } from '../lib/print';
import { Empty, Modal, Note, useToast } from '../components/ui';
import { getDevice, getSnapshot, nextInvoiceNo, outboxAll, outboxPut, setDevice, setSnapshot, type Device, type OutboxEntry, type Snapshot } from '../offline/store';
import { isNetworkError, startSync, syncOutbox } from '../offline/sync';
import type { Invoice, Product, Settings, Shop, StockRow } from '../lib/types';

/** Loads the shop's catalogue from the server and keeps it on the device for offline selling. */
export async function refreshSnapshot(shopId: string): Promise<Snapshot> {
  const [st, sh, pr] = await Promise.all([
    supabase.from('settings').select('rate,vat,tz,company'), supabase.from('shops').select('*').eq('id', shopId),
    (async () => { const out: Product[] = []; for (let a = 0; ; a += 1000) { const page = rows<Product>(await supabase.from('products').select('*').eq('active', true).order('name').range(a, a + 999)); out.push(...page); if (page.length < 1000) return out; } })(),
  ]);
  const stock: Record<string, { qty: number; open_pieces: number }> = {};
  for (let a = 0; ; a += 1000) {
    const page = rows<StockRow>(await supabase.from('shop_stock').select('*').eq('shop_id', shopId).range(a, a + 999));
    page.forEach((r) => { stock[r.product_id] = { qty: r.qty, open_pieces: r.open_pieces }; });
    if (page.length < 1000) break;
  }
  const products = pr, byId = new Map(products.map((p) => [p.id, p]));
  // sales still waiting in the outbox are not in the server stock yet
  for (const e of await outboxAll()) if (e.shop_id === shopId) for (const it of e.payload.items) {
    const p = byId.get(it.product_id); if (!p) continue;
    stock[p.id] = takeLocal(stock[p.id] ?? { qty: 0, open_pieces: 0 }, it.qty, it.mult, it.piece, p.pieces_per_set);
  }
  const snap: Snapshot = { shop: rows<Shop>(sh)[0], settings: rows<Settings>(st)[0], products, stock, at: Date.now() };
  await setSnapshot(snap);
  return snap;
}

export default function Till() {
  const { profile } = useAuth();
  const toast = useToast();
  const shopId = profile!.shop_id!;
  const [snap, setSnap] = useState<Snapshot | null>(null), [dev, setDev] = useState<Device | null>(null), [problem, setProblem] = useState('');
  const [cart, setCart] = useState<CartLine[]>([]), [dp, setDp] = useState(0), [cat, setCat] = useState('All'), [q, setQ] = useState('');
  const [pick, setPick] = useState<{ pid: string; idx: number } | null>(null), [check, setCheck] = useState(false), [disc, setDisc] = useState(false);
  const [last, setLast] = useState<Invoice | null>(null), [view, setView] = useState<Invoice | null>(null), [failed, setFailed] = useState<OutboxEntry[]>([]), [flash, setFlash] = useState(false);
  const busy = useRef(false), scan = useRef<HTMLInputElement>(null);

  const loadFailed = useCallback(() => { void outboxAll().then((l) => setFailed(l.filter((e) => e.error && e.shop_id === shopId))); }, [shopId]);
  const load = useCallback(async () => {
    const local = await getSnapshot(shopId);
    if (local) setSnap(local);
    try {
      const fresh = await refreshSnapshot(shopId); setSnap(fresh);
      const known = await getDevice(shopId);
      const r = await rpc<{ id: string; code: string; last_seq: number; shop_code: string }>('register_device', { p_device: known?.id ?? null });
      const d = { id: r.id, code: r.code, last_seq: r.last_seq, shop_code: r.shop_code, shop_id: shopId };
      await setDevice(d); setDev(d); setProblem('');
    } catch (e) {
      const d = await getDevice(shopId); if (d) setDev(d);
      if (!isNetworkError(e)) setProblem((e as Error).message);
      else if (!local) setProblem('This till has not been connected yet. Connect to the internet once to load the items and register the till.');
      else if (!d) setProblem('Connect to the internet once to register this till.');
    }
  }, [shopId]);
  useEffect(() => {
    void load(); startSync(); loadFailed();
    const t = setInterval(() => { if (navigator.onLine) void refreshSnapshot(shopId).then(setSnap).catch(() => {}); }, 120000);
    const on = () => void load();
    addEventListener('online', on); addEventListener('sim-outbox', loadFailed);
    return () => { clearInterval(t); removeEventListener('online', on); removeEventListener('sim-outbox', loadFailed); };
  }, [load, loadFailed, shopId]);

  const byId = useMemo(() => new Map((snap?.products ?? []).map((p) => [p.id, p])), [snap]);
  const rate = snap?.settings.rate ?? 0, vat = snap?.settings.vat ?? 0;
  const priced = useMemo(() => cartPriced(cart.filter((l) => byId.has(l.pid)), byId, rate), [cart, byId, rate]);
  const T = totals(priced, dp, vat);
  const cartBase = (pid: string) => priced.filter((l) => l.pid === pid).reduce((s, l) => s + (l.u.piece ? 0 : l.u.mult * l.qty), 0);
  const left = (p: Product) => (snap?.stock[p.id]?.qty ?? 0) - cartBase(p.id);
  const cats = ['All', ...new Set([...CATS, ...(snap?.products ?? []).map((p) => p.category)])];
  const ql = q.trim().toLowerCase();
  const list = (snap?.products ?? []).filter((p) => (cat === 'All' || p.category === cat) && (!ql || p.name.toLowerCase().includes(ql) || p.category.toLowerCase().includes(ql)));

  const add = (pid: string, ui?: number) => {
    const p = byId.get(pid); if (!p) return;
    const us = unitsOf(p);
    if (ui === undefined && us.length > 1) { setPick({ pid, idx: -1 }); return; }
    const i = ui ?? 0;
    setCart((c) => { const l = c.find((x) => x.pid === pid && x.ui === i); return l ? c.map((x) => (x === l ? { ...x, qty: x.qty + 1 } : x)) : [{ pid, ui: i, qty: 1 }, ...c]; });
    setFlash(true); setTimeout(() => setFlash(false), 600);
    if (!us[i].piece && left(p) - us[i].mult < 0) toast(`${p.name}: selling on order, the shop is ${Math.abs(left(p) - us[i].mult)} short`, 'warn');
  };
  const chg = (i: number, d: number) => setCart((c) => { const l = c[i]; if (!l) return c; const n = d === -999 || l.qty + d <= 0 ? c.filter((_, k) => k !== i) : c.map((x, k) => (k === i ? { ...x, qty: x.qty + d } : x)); if (!n.length) setDp(0); return n; });
  const setUnit = (idx: number, ui: number) => setCart((c) => { const l = c[idx]; if (!l) return c; const same = c.findIndex((x, k) => k !== idx && x.pid === l.pid && x.ui === ui); if (same >= 0) return c.map((x, k) => (k === same ? { ...x, qty: x.qty + l.qty } : x)).filter((_, k) => k !== idx); return c.map((x, k) => (k === idx ? { ...x, ui } : x)); });

  // Take cash: exact total in FC, saved on the device first, printed at once, then sent to the server
  const pay = async () => {
    if (busy.current || !priced.length || !snap) return;
    if (!dev) { toast('Connect to the internet once to register this till', 'bad'); return; }
    busy.current = true;
    try {
      const no = await nextInvoiceNo(dev), id = crypto.randomUUID(), t = new Date().toISOString();
      const items = priced.map((l) => ({ product_id: l.pid, name: l.p.name, unit: l.u.piece ? 'piece' : l.u.u, mult: l.u.piece ? 0 : l.u.mult, piece: !!l.u.piece, qty: l.qty, price: l.price, line: l.price * l.qty }));
      const inv: Invoice = { id, no, shop_id: shopId, cashier_id: profile!.id, cashier_name: profile!.name, t, rate, vat_rate: vat, gross: T.gross, disc_pct: dp, disc: T.disc, total: T.total, vat: T.vat, ht: T.ht, tendered: T.total, change: 0, printed: 2, items, edits: [], synced: false };
      await outboxPut({ id, t, shop_id: shopId, tries: 0, invoice: inv, payload: { id, no, device_id: dev.id, cashier_id: profile!.id, t, rate, vat_rate: vat, disc_pct: dp, tendered: T.total, items: items.map(({ product_id, mult, piece, qty, price }) => ({ product_id, mult, piece, qty, price })) } });
      const stock = { ...snap.stock };
      for (const l of priced) stock[l.pid] = takeLocal(stock[l.pid] ?? { qty: 0, open_pieces: 0 }, l.qty, l.u.piece ? 0 : l.u.mult, !!l.u.piece, l.p.pieces_per_set);
      const next = { ...snap, stock }; setSnap(next); void setSnapshot(next);
      printHTML(saleCopies(inv, snap.settings.company, snap.shop));
      setCart([]); setDp(0); setLast(inv);
      toast(`Sale ${no} done, ${fCDF(T.total)}. Printing.`);
      void syncOutbox();
      scan.current?.focus();
    } finally { busy.current = false; }
  };

  if (!snap) return <div className="card"><Empty i={problem ? 'wifioff' : 'refresh'} t={problem || 'Loading the till'} tall /></div>;
  const st = (p: Product) => snap.stock[p.id] ?? { qty: 0, open_pieces: 0 };
  return (
    <>
      {problem ? <Note i="alert" warn>{problem}</Note> : null}
      {failed.length ? <Note i="alert" warn><span>{failed.length} sale{failed.length > 1 ? 's' : ''} could not be saved on the server: {failed[0].invoice.no}, {failed[0].error}. {profile!.role === 'shopadmin' ? 'Check the items and prices, then try again.' : 'Tell the shop admin.'} <button className="btn sm" style={{ marginLeft: 8 }} onClick={() => void syncOutbox().then(loadFailed)}>Try again</button></span></Note> : null}
      <div className="pos"><section className="pos-left">
        <div className="scan"><Icon n="search" /><input id="scan" ref={scan} autoComplete="off" spellCheck={false} placeholder="Type part of the item name, e.g. lotion" aria-label="Search items" value={q} onChange={(e) => setQ(e.target.value)} />
          <button className="btn primary sm" onClick={() => setCheck(true)} title="Check a price, including the piece price of a set"><Icon n="tag" /><span>Price check</span></button></div>
        <div className="cats">{cats.map((c) => <button key={c} className={cat === c ? 'on' : ''} onClick={() => setCat(c)}><Icon n={CATICON[c] ?? 'box'} /><span>{c}</span></button>)}</div>
        <div className="pgrid">{list.length ? list.map((p) => { const us = unitsOf(p), lf = left(p); return (
          <button key={p.id} className="ptile" onClick={() => add(p.id)}><span className="ico"><Icon n={p.is_bundle ? 'gift' : CATICON[p.category] ?? 'box'} /></span>
            {p.is_bundle ? <span className="chip">set + piece</span> : us.length > 1 ? <span className="chip">{us.map((x) => x.u).join(' / ')}</span> : null}
            <span className="nm">{p.name}</span><span className="pr">{fCDF(toCDF(p.price_usd, rate))}<small> / {p.stock_unit}</small></span>
            <span className={`st ${lf <= 0 ? 'neg' : ''}`}>{lf > 0 ? lf + ' in shop' : lf === 0 ? 'None left, sells on order' : Math.abs(lf) + ' on order'}</span></button>); })
          : <Empty i="search" t={snap.products.length ? 'No items found. Try another word or another category.' : 'No items yet. The Admin adds them in Inventory.'} />}</div>
      </section>
      <section className="cart" id="cart">
        <div className="cart-h"><b><Icon n="cart" /> Current sale</b><span className="chip">{T.count} {T.count === 1 ? 'item' : 'items'}</span>{cart.length ? <button className="iconbtn dark" onClick={() => { setCart([]); setDp(0); }} title="Clear sale" aria-label="Clear sale"><Icon n="trash" /></button> : null}</div>
        <div className="lines">{priced.length ? priced.map((l, i) => { const short = !l.u.piece && st(l.p).qty - cartBase(l.pid) < 0; return (
          <div key={l.pid + ':' + l.ui} className={`line ${flash && i === 0 ? 'flash' : ''}`}><div><div className="ln">{l.p.name}</div><div className="lp"><Icon n="lock" /> {fCDF(l.price)} <button className="uchip" onClick={() => setPick({ pid: l.pid, idx: i })} title="Change unit">{unitLabel(l.u)} <Icon n="edit" /></button>{short ? <> <span className="chip warn">on order</span></> : null}</div></div><div className="lt">{fCDF(l.price * l.qty)}</div>
            <div className="qty"><button onClick={() => chg(i, -1)} aria-label="One less"><Icon n="minus" /></button><b>{l.qty}</b><button onClick={() => chg(i, 1)} aria-label="One more"><Icon n="plus" /></button></div><button className="rm" onClick={() => chg(i, -999)} aria-label="Remove item"><Icon n="x" /></button></div>); })
          : <Empty i="cart" t="Tap an item to start a sale" tall />}</div>
        <div className="totals"><div className="row"><span>Subtotal</span><span>{fCDF(T.gross)}</span></div>
          {T.disc ? <div className="row"><span>Invoice discount {dp}%</span><span>- {fCDF(T.disc)}</span></div> : null}
          <div className="row muted"><span>Includes VAT {vat}%</span><span>{fCDF(T.vat)}</span></div>
          <div className="grand"><span>To pay</span><b>{fCDF(T.total)}</b></div>
          {cart.length ? (profile!.role === 'shopadmin' ? <button className="btn ghost full disc-btn" onClick={() => setDisc(true)}><Icon n="tag" /> {dp ? `Invoice discount ${dp}%, change` : 'Discount on this invoice'}</button> : <Note style={{ margin: '0 0 10px' }}>Only the shop admin can give a discount.</Note>) : null}
          <div className="paybtns one"><button className="paybtn cash" onClick={() => void pay()} disabled={!cart.length}><Icon n="cash" /> Take cash and print</button></div>
          {last ? <div className="row muted" style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 10, fontSize: 13.5 }}><span className="chip ok"><Icon n="check" /> Last sale</span><span style={{ flex: 1 }}><b>{last.no}</b>, <span style={{ whiteSpace: 'nowrap' }}>{fCDF(last.total)}</span></span>{profile!.role === 'shopadmin' ? <button className="btn sm" onClick={() => setView(last)}><Icon n="eye" /> View</button> : null}</div> : null}
        </div>
      </section></div>

      {pick ? (() => { const p = byId.get(pick.pid)!, s = st(p); return (
        <Modal title={pick.idx >= 0 ? 'Change the unit' : 'How is it sold?'} icon={p.is_bundle ? 'gift' : 'layers'} onClose={() => setPick(null)} foot={<button className="btn" onClick={() => setPick(null)}>Cancel</button>}>
          <p><b>{p.name}</b><br /><span className="code">{s.qty >= 0 ? s.qty : Math.abs(s.qty) + ' on order'} {p.stock_unit} in the shop{p.is_bundle ? `, ${s.open_pieces} pieces sold from an open set` : ''}</span></p>
          <div className="ugrid">{unitsOf(p).map((u, i) => <button key={i} className="ubtn" onClick={() => { setPick(null); if (pick.idx >= 0) setUnit(pick.idx, i); else add(pick.pid, i); }}><b>{unitLabel(u)}</b><span>{unitNote(p, u)}</span><em>{fCDF(toCDF(u.usd, rate))}</em></button>)}</div>
          {p.is_bundle ? <Note i="tag">The piece price is the last price set by the Admin. It cannot be changed at the shop.</Note> : null}
        </Modal>); })() : null}
      {check ? <PriceCheck products={snap.products} stock={snap.stock} rate={rate} onClose={() => setCheck(false)} /> : null}
      {disc ? <DiscModal v={dp} onApply={(v) => { setDp(v); setDisc(false); }} onClose={() => setDisc(false)} /> : null}
      {view ? <Modal title={'Invoice ' + view.no} icon="receipt" onClose={() => setView(null)} foot={<button className="btn" onClick={() => setView(null)}>Close</button>}><div className="rwrap" dangerouslySetInnerHTML={{ __html: receiptHTML(view, snap.settings.company, snap.shop, { copy: 'client' }) }} /></Modal> : null}
    </>
  );
}

function PriceCheck({ products, stock, rate, onClose }: { products: Product[]; stock: Snapshot['stock']; rate: number; onClose: () => void }) {
  const [q, setQ] = useState('');
  const list = products.filter((p) => !q.trim() || p.name.toLowerCase().includes(q.trim().toLowerCase())).slice(0, 40);
  return (
    <Modal title="Price check" icon="tag" wide onClose={onClose} foot={<button className="btn" onClick={onClose}>Close</button>}>
      <div className="field"><label>Search</label><input className="input" placeholder="Item name" value={q} onChange={(e) => setQ(e.target.value)} autoFocus /></div>
      {list.length ? <div className="tw"><table className="t"><thead><tr><th>Item</th><th>Unit</th><th className="r">Price</th><th className="r">In shop</th></tr></thead><tbody>
        {list.flatMap((p) => unitsOf(p).map((u, i) => { const s = stock[p.id]?.qty ?? 0; return <tr key={p.id + i}><td>{i === 0 ? <><b>{p.name}</b>{p.is_bundle ? <div className="code">mixed set</div> : null}</> : null}</td><td><span className="uchip">{unitLabel(u)}</span>{u.piece ? <span className="code"> last price</span> : null}</td><td className="r"><b>{fCDF(toCDF(u.usd, rate))}</b></td><td className="r">{i === 0 ? (s < 0 ? Math.abs(s) + ' on order' : s) : ''}</td></tr>; }))}
      </tbody></table></div> : <Empty i="search" t="No item matches" />}
    </Modal>
  );
}
function DiscModal({ v, onApply, onClose }: { v: number; onApply: (v: number) => void; onClose: () => void }) {
  const [x, setX] = useState(String(v)), [err, setErr] = useState('');
  const apply = (n: number) => { if (n < 0 || n > 30 || n % 1) { setErr('Discount must be between 0% and 30%'); return; } onApply(n); };
  return (
    <Modal title="Discount on this invoice" icon="tag" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" onClick={() => apply(parseInt(x) || 0)}><Icon n="check" /> Apply</button></>}>
      <p>The discount applies to this invoice only, not to any item price. Maximum 30%.</p>
      <div className="quick">{[0, 5, 10, 15, 20].map((n) => <button key={n} className={v === n ? 'on' : ''} onClick={() => apply(n)}>{n ? n + '%' : 'None'}</button>)}</div>
      <div className="field"><label>Or type %</label><input type="number" min="0" max="30" className="input" value={x} onChange={(e) => setX(e.target.value)} /></div><div className="lerr">{err}</div>
    </Modal>
  );
}
