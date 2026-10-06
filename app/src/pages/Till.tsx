import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { rpc, rows, supabase } from '../lib/supabase';
import { cartPriced, takeLocal, totals, unitLabel, unitNote, unitsOf, type CartLine } from '../lib/units';
import { CATICON, CATS } from '../lib/items';
import { fCDF, tm, toCDF, today } from '../lib/format';
import { printHTML, receiptHTML, saleCopies } from '../lib/print';
import { Empty, Modal, Note, useAction, useToast } from '../components/ui';
import { useDeliveries, useOrders } from '../data/queries';
import { getDevice, getSnapshot, nextInvoiceNo, outboxAll, outboxPut, setDevice, setSnapshot, type Device, type OutboxEntry, type Snapshot } from '../offline/store';
import { isNetworkError, startSync, syncOutbox } from '../offline/sync';
import type { Invoice, Product, SaleOrder, Settings, Shop, StockRow } from '../lib/types';

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
  // sales still waiting in the outbox are not in the server stock yet (orders take no stock)
  for (const e of await outboxAll()) if (e.shop_id === shopId && e.kind !== 'order') for (const it of e.payload.items) {
    const p = byId.get(it.product_id); if (!p) continue;
    stock[p.id] = takeLocal(stock[p.id] ?? { qty: 0, open_pieces: 0 }, it.qty, it.mult, it.piece, p.pieces_per_set);
  }
  const snap: Snapshot = { shop: rows<Shop>(sh)[0], settings: rows<Settings>(st)[0], products, stock, at: Date.now() };
  await setSnapshot(snap);
  return snap;
}

// one registration at a time per shop, so a double start never makes two tills
const inflight = new Map<string, Promise<Device>>();
function registerOnce(shopId: string, known: string | null): Promise<Device> {
  if (!inflight.has(shopId)) inflight.set(shopId, (async () => {
    try {
      const r = await rpc<{ id: string; code: string; last_seq: number; shop_code: string }>('register_device', { p_device: known });
      const d = { id: r.id, code: r.code, last_seq: r.last_seq, shop_code: r.shop_code, shop_id: shopId };
      await setDevice(d); return d;
    } finally { inflight.delete(shopId); }
  })());
  return inflight.get(shopId)!;
}

export default function Till() {
  const { profile } = useAuth();
  const toast = useToast(), nav = useNavigate();
  const shopId = profile!.shop_id!, isAdmin = profile!.role === 'shopadmin';
  const [snap, setSnap] = useState<Snapshot | null>(null), [dev, setDev] = useState<Device | null>(null), [problem, setProblem] = useState('');
  const [cart, setCart] = useState<CartLine[]>([]), [dp, setDp] = useState(0), [cat, setCat] = useState('All'), [q, setQ] = useState('');
  const [customer, setCustomer] = useState(''), [custDraft, setCustDraft] = useState(''), [reviewing, setReviewing] = useState<SaleOrder | null>(null);
  const [pick, setPick] = useState<{ pid: string; idx: number } | null>(null), [check, setCheck] = useState(false), [disc, setDisc] = useState(false), [reject, setReject] = useState<SaleOrder | null>(null);
  const [last, setLast] = useState<Invoice | null>(null), [view, setView] = useState<Invoice | null>(null), [outbox, setOutbox] = useState<OutboxEntry[]>([]), [flash, setFlash] = useState(false);
  const busy = useRef(false), scan = useRef<HTMLInputElement>(null), custIn = useRef<HTMLInputElement>(null);
  const startOfDay = useMemo(() => new Date(today() + 'T00:00:00').toISOString(), []);
  const orders = useOrders(isAdmin ? 'pending' : 'all', isAdmin ? undefined : startOfDay);
  const dels = useDeliveries(shopId, isAdmin);

  const loadOutbox = useCallback(() => { void outboxAll().then((l) => setOutbox(l.filter((e) => e.shop_id === shopId))); }, [shopId]);
  const load = useCallback(async () => {
    // what is on the device comes first, so the till sells at once even when the network hangs
    const local = await getSnapshot(shopId), known = await getDevice(shopId);
    if (local) setSnap(local);
    if (known) setDev(known);
    if (!navigator.onLine) {
      if (!local) setProblem('This till has not been connected yet. Connect to the internet once to load the items and register the till.');
      else if (!known && isAdmin) setProblem('Connect to the internet once to register this till.');
      return;
    }
    try {
      const fresh = await refreshSnapshot(shopId); setSnap(fresh);
      if (isAdmin) { const d = await registerOnce(shopId, known?.id ?? null); setDev(d); }
      setProblem('');
    } catch (e) {
      if (!isNetworkError(e)) setProblem((e as Error).message);
      else if (!local) setProblem('This till has not been connected yet. Connect to the internet once to load the items and register the till.');
      else if (!known && isAdmin) setProblem('Connect to the internet once to register this till.');
    }
  }, [shopId, isAdmin]);
  useEffect(() => {
    void load(); startSync(); loadOutbox();
    const t = setInterval(() => { if (navigator.onLine) void refreshSnapshot(shopId).then(setSnap).catch(() => {}); }, 120000);
    const on = () => void load();
    const upd = () => { loadOutbox(); void orders.refetch(); };
    addEventListener('online', on); addEventListener('sim-outbox', upd);
    return () => { clearInterval(t); removeEventListener('online', on); removeEventListener('sim-outbox', upd); };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [load, loadOutbox, shopId]);
  useEffect(() => { if (!customer) setTimeout(() => custIn.current?.focus(), 50); }, [customer]);

  const byId = useMemo(() => new Map((snap?.products ?? []).map((p) => [p.id, p])), [snap]);
  const rate = snap?.settings.rate ?? 0, vat = snap?.settings.vat ?? 0;
  const priced = useMemo(() => cartPriced(cart.filter((l) => byId.has(l.pid)), byId, rate), [cart, byId, rate]);
  const T = totals(priced, dp, vat);
  const cartBase = (pid: string) => priced.filter((l) => l.pid === pid).reduce((s, l) => s + (l.u.piece ? 0 : l.u.mult * l.qty), 0);
  const left = (p: Product) => (snap?.stock[p.id]?.qty ?? 0) - cartBase(p.id);
  const cats = ['All', ...new Set([...CATS, ...(snap?.products ?? []).map((p) => p.category)])];
  const ql = q.trim().toLowerCase();
  const list = (snap?.products ?? []).filter((p) => (cat === 'All' || p.category === cat) && (!ql || p.name.toLowerCase().includes(ql) || p.category.toLowerCase().includes(ql)));
  const failed = outbox.filter((e) => e.error);
  // orders already approved on this till but not yet sent are hidden from the review list
  const approvedHere = new Set(outbox.flatMap((e) => (e.kind !== 'order' && e.payload.order_id ? [e.payload.order_id] : [])));
  const toReview = (orders.data ?? []).filter((o) => o.status === 'pending' && !approvedHere.has(o.id));
  const toReceive = (dels.data ?? []).filter((d) => d.status === 'pending').length;
  const orderTotal = (o: SaleOrder) => o.items.reduce((s, it) => { const p = byId.get(it.product_id); if (!p) return s; const u = unitsOf(p).find((x) => (it.piece ? !!x.piece : !x.piece && x.mult === it.mult)); return s + (u ? toCDF(u.usd, rate) * it.qty : 0); }, 0);

  const startCustomer = () => { const c = custDraft.trim().replace(/\s+/g, ' ').slice(0, 60); if (!c) { toast('Type the customer name, then press Enter', 'warn'); return; } setCustomer(c); setCustDraft(''); setTimeout(() => scan.current?.focus(), 50); };
  const resetSale = () => { setCart([]); setDp(0); setCustomer(''); setReviewing(null); };
  const add = (pid: string, ui?: number) => {
    if (!customer) { toast('Type the customer name first', 'warn'); custIn.current?.focus(); return; }
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

  // the shop admin opens an order from the till into his own sale to check, change and approve it
  const openOrder = (o: SaleOrder) => {
    if (cart.length && reviewing?.id !== o.id && !confirm('Replace the current sale with this order?')) return;
    const lines: CartLine[] = [], missing: string[] = [];
    for (const it of o.items) {
      const p = byId.get(it.product_id); if (!p) { missing.push('an item no longer sold'); continue; }
      const ui = unitsOf(p).findIndex((u) => (it.piece ? !!u.piece : !u.piece && u.mult === it.mult));
      if (ui < 0) missing.push(p.name); else lines.push({ pid: p.id, ui, qty: it.qty });
    }
    setCart(lines); setDp(0); setCustomer(o.customer); setReviewing(o);
    if (missing.length) toast(`Check the order: ${missing.join(', ')} could not be added`, 'warn');
  };

  // till operator: the order goes to the shop admin; nothing is sold or printed yet
  const sendOrder = async () => {
    if (busy.current || !priced.length || !customer) return;
    busy.current = true;
    try {
      const id = crypto.randomUUID(), t = new Date().toISOString();
      await outboxPut({ kind: 'order', id, t, shop_id: shopId, tries: 0, total: T.total, created_by: profile!.id,
        payload: { id, customer, t, items: priced.map((l) => ({ product_id: l.pid, mult: l.u.piece ? 0 : l.u.mult, piece: !!l.u.piece, qty: l.qty })) } });
      toast(`Order for ${customer} sent to the shop admin for approval`);
      resetSale(); void syncOutbox();
    } finally { busy.current = false; }
  };

  // shop admin: take cash, print, then send to the server (works offline too)
  const pay = async () => {
    if (busy.current || !priced.length || !snap || !customer) return;
    if (!dev) { toast('Connect to the internet once to register this till', 'bad'); return; }
    busy.current = true;
    try {
      const no = await nextInvoiceNo(dev), id = crypto.randomUUID(), t = new Date().toISOString();
      const items = priced.map((l) => ({ product_id: l.pid, name: l.p.name, unit: l.u.piece ? 'piece' : l.u.u, mult: l.u.piece ? 0 : l.u.mult, piece: !!l.u.piece, qty: l.qty, price: l.price, line: l.price * l.qty }));
      const inv: Invoice = { id, no, shop_id: shopId, cashier_id: profile!.id, cashier_name: profile!.name, t, rate, vat_rate: vat, gross: T.gross, disc_pct: dp, disc: T.disc, total: T.total, vat: T.vat, ht: T.ht, tendered: T.total, change: 0, printed: 2, items, edits: [], synced: false,
        customer, order_id: reviewing?.id ?? null, prepared_by_name: reviewing?.created_by_name ?? null };
      await outboxPut({ id, t, shop_id: shopId, tries: 0, invoice: inv, payload: { id, no, device_id: dev.id, cashier_id: profile!.id, t, rate, vat_rate: vat, disc_pct: dp, tendered: T.total, customer, order_id: reviewing?.id ?? null, items: items.map(({ product_id, mult, piece, qty, price }) => ({ product_id, mult, piece, qty, price })) } });
      const stock = { ...snap.stock };
      for (const l of priced) stock[l.pid] = takeLocal(stock[l.pid] ?? { qty: 0, open_pieces: 0 }, l.qty, l.u.piece ? 0 : l.u.mult, !!l.u.piece, l.p.pieces_per_set);
      const next = { ...snap, stock }; setSnap(next); void setSnapshot(next);
      printHTML(saleCopies(inv, snap.settings.company, snap.shop));
      setLast(inv); resetSale();
      toast(`Sale ${no} for ${inv.customer} done, ${fCDF(T.total)}. Printing.`);
      void syncOutbox();
    } finally { busy.current = false; }
  };

  if (!snap) return <div className="card"><Empty i={problem ? 'wifioff' : 'refresh'} t={problem || 'Loading the till'} tall /></div>;
  const st = (p: Product) => snap.stock[p.id] ?? { qty: 0, open_pieces: 0 };
  const myUnsent = outbox.filter((e) => e.kind === 'order');
  const myOrders = isAdmin ? [] : (orders.data ?? []).slice(0, 6);

  const pos = (
    <div className="pos"><section className="pos-left">
      {customer ? (
        <div className="custbar on"><Icon n="user" /><span style={{ flex: 1 }}>Customer: <b id="custname">{customer}</b>{reviewing ? <span className="code"> · order from {reviewing.created_by_name}, {tm(reviewing.created_at)}</span> : null}</span>
          {reviewing ? null : <button className="btn sm" onClick={() => { setCustDraft(customer); setCustomer(''); }}><Icon n="edit" /> Change</button>}</div>
      ) : (
        <form className="custbar" onSubmit={(e) => { e.preventDefault(); startCustomer(); }}><Icon n="user" />
          <input id="cust" ref={custIn} autoComplete="off" placeholder="New sale: type the customer name and press Enter" aria-label="Customer name" value={custDraft} maxLength={60} onChange={(e) => setCustDraft(e.target.value)} />
          <button className="btn primary sm"><Icon n="check" /> Start</button></form>
      )}
      <div className="scan" style={customer ? undefined : { opacity: 0.5 }}><Icon n="search" /><input id="scan" ref={scan} autoComplete="off" spellCheck={false} placeholder="Type part of the item name, e.g. lotion" aria-label="Search items" value={q} onChange={(e) => setQ(e.target.value)} />
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
      <div className="cart-h"><b><Icon n="cart" /> {reviewing ? 'Order to approve' : isAdmin ? 'Current sale' : 'New order'}</b><span className="chip">{T.count} {T.count === 1 ? 'item' : 'items'}</span>{cart.length || customer ? <button className="iconbtn dark" onClick={resetSale} title={reviewing ? 'Close this order without approving' : 'Clear'} aria-label="Clear sale"><Icon n="trash" /></button> : null}</div>
      <div className="lines">{priced.length ? priced.map((l, i) => { const short = !l.u.piece && st(l.p).qty - cartBase(l.pid) < 0; return (
        <div key={l.pid + ':' + l.ui} className={`line ${flash && i === 0 ? 'flash' : ''}`}><div><div className="ln">{l.p.name}</div><div className="lp"><Icon n="lock" /> {fCDF(l.price)} <button className="uchip" onClick={() => setPick({ pid: l.pid, idx: i })} title="Change unit">{unitLabel(l.u)} <Icon n="edit" /></button>{short ? <> <span className="chip warn">on order</span></> : null}</div></div><div className="lt">{fCDF(l.price * l.qty)}</div>
          <div className="qty"><button onClick={() => chg(i, -1)} aria-label="One less"><Icon n="minus" /></button><b>{l.qty}</b><button onClick={() => chg(i, 1)} aria-label="One more"><Icon n="plus" /></button></div><button className="rm" onClick={() => chg(i, -999)} aria-label="Remove item"><Icon n="x" /></button></div>); })
        : <Empty i={customer ? 'cart' : 'user'} t={customer ? 'Tap an item to add it' : 'Start with the customer name'} tall />}</div>
      <div className="totals"><div className="row"><span>Subtotal</span><span>{fCDF(T.gross)}</span></div>
        {T.disc ? <div className="row"><span>Invoice discount {dp}%</span><span>- {fCDF(T.disc)}</span></div> : null}
        <div className="row muted"><span>Includes VAT {vat}%</span><span>{fCDF(T.vat)}</span></div>
        <div className="grand"><span>{isAdmin ? 'To pay' : 'Order total'}</span><b>{fCDF(T.total)}</b></div>
        {cart.length ? (isAdmin ? <button className="btn ghost full disc-btn" onClick={() => setDisc(true)}><Icon n="tag" /> {dp ? `Invoice discount ${dp}%, change` : 'Discount on this invoice'}</button> : null) : null}
        <div className="paybtns one">{isAdmin
          ? <button className="paybtn cash" onClick={() => void pay()} disabled={!cart.length || !customer}><Icon n="cash" /> {reviewing ? 'Approve, take cash and print' : 'Take cash and print'}</button>
          : <button className="paybtn" onClick={() => void sendOrder()} disabled={!cart.length || !customer}><Icon n="check" /> Send to shop admin for approval</button>}</div>
        {isAdmin && last ? <div className="row muted" style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 10, fontSize: 13.5 }}><span className="chip ok"><Icon n="check" /> Last sale</span><span style={{ flex: 1 }}><b>{last.no}</b>, <span style={{ whiteSpace: 'nowrap' }}>{fCDF(last.total)}</span></span><button className="btn sm" onClick={() => setView(last)}><Icon n="eye" /> View</button></div> : null}
        {!isAdmin && (myUnsent.length || myOrders.length) ? <div className="myorders"><div className="code" style={{ margin: '10px 0 4px', fontWeight: 800 }}>My orders today</div>
          {myUnsent.map((e) => <div key={e.id} className="morow"><span>{e.kind === 'order' ? e.payload.customer : ''}</span><span className="chip warn">{e.error ? 'Not accepted: ' + e.error : 'Not sent yet'}</span></div>)}
          {myOrders.filter((o) => !myUnsent.some((e) => e.id === o.id)).map((o) => <div key={o.id} className="morow"><span>{o.customer} <span className="code">{tm(o.created_at)}</span></span>
            {o.status === 'pending' ? <span className="chip">Waiting for approval</span> : o.status === 'approved' ? <span className="chip ok">Approved</span> : <span className="chip bad" title={o.reason ?? ''}>Rejected{o.reason ? ': ' + o.reason : ''}</span>}</div>)}
        </div> : null}
      </div>
    </section></div>
  );

  return (
    <>
      {problem ? <Note i="alert" warn>{problem}</Note> : null}
      {failed.length ? <Note i="alert" warn><span>{failed.length} {failed.length > 1 ? 'entries' : 'entry'} could not be saved on the server: {failed[0].error}. {isAdmin ? 'Check the items and prices, then try again.' : 'Tell the shop admin.'} <button className="btn sm" style={{ marginLeft: 8 }} onClick={() => void syncOutbox().then(loadOutbox)}>Try again</button></span></Note> : null}
      {isAdmin ? (
        <div className="tillwrap">{pos}
          <aside className="review" aria-label="Orders for review">
            <div className="cart-h"><b><Icon n="receipt" /> For review</b><span className={`chip ${toReview.length ? 'warn' : ''}`}>{toReview.length}</span></div>
            <div className="rl">
              {!navigator.onLine ? <Note i="wifioff" warn>Orders from the till operators arrive when the internet is back.</Note> : null}
              {toReview.length ? toReview.map((o) => (
                <div key={o.id} className={`rcard ${reviewing?.id === o.id ? 'on' : ''}`}>
                  <b>{o.customer}</b><div className="code">from {o.created_by_name}, {tm(o.created_at)}</div>
                  <div style={{ margin: '4px 0 8px', fontWeight: 700 }}>{o.items.reduce((s, i) => s + i.qty, 0)} items · {fCDF(orderTotal(o))}</div>
                  <div style={{ display: 'flex', gap: 6 }}><button className="btn primary sm" style={{ flex: 1 }} onClick={() => openOrder(o)}><Icon n="eye" /> Open</button><button className="btn sm" onClick={() => setReject(o)} title="Reject this order"><Icon n="x" /></button></div>
                </div>)) : <Empty i="check" t={orders.isLoading ? 'Loading' : 'No orders waiting'} />}
              {toReceive ? <button className="rcard" style={{ width: '100%', textAlign: 'left', cursor: 'pointer', background: 'var(--warn-l)' }} onClick={() => nav('/received')}><b><Icon n="truck" /> {toReceive} deliver{toReceive > 1 ? 'ies' : 'y'} to receive</b><div className="code">From the central store. Open to check and approve.</div></button> : null}
            </div>
          </aside>
        </div>
      ) : pos}

      {pick ? (() => { const p = byId.get(pick.pid)!, s = st(p); return (
        <Modal title={pick.idx >= 0 ? 'Change the unit' : 'How is it sold?'} icon={p.is_bundle ? 'gift' : 'layers'} onClose={() => setPick(null)} foot={<button className="btn" onClick={() => setPick(null)}>Cancel</button>}>
          <p><b>{p.name}</b><br /><span className="code">{s.qty >= 0 ? s.qty : Math.abs(s.qty) + ' on order'} {p.stock_unit} in the shop{p.is_bundle ? `, ${s.open_pieces} pieces sold from an open set` : ''}</span></p>
          <div className="ugrid">{unitsOf(p).map((u, i) => <button key={i} className="ubtn" onClick={() => { setPick(null); if (pick.idx >= 0) setUnit(pick.idx, i); else add(pick.pid, i); }}><b>{unitLabel(u)}</b><span>{unitNote(p, u)}</span><em>{fCDF(toCDF(u.usd, rate))}</em></button>)}</div>
          {p.is_bundle ? <Note i="tag">The piece price is the last price set by the Admin. It cannot be changed at the shop.</Note> : null}
        </Modal>); })() : null}
      {check ? <PriceCheck products={snap.products} stock={snap.stock} rate={rate} onClose={() => setCheck(false)} /> : null}
      {disc ? <DiscModal v={dp} onApply={(v) => { setDp(v); setDisc(false); }} onClose={() => setDisc(false)} /> : null}
      {reject ? <RejectModal o={reject} onClose={() => setReject(null)} onDone={() => { if (reviewing?.id === reject.id) resetSale(); setReject(null); void orders.refetch(); }} /> : null}
      {view ? <Modal title={'Invoice ' + view.no} icon="receipt" onClose={() => setView(null)} foot={<button className="btn" onClick={() => setView(null)}>Close</button>}><div className="rwrap" dangerouslySetInnerHTML={{ __html: receiptHTML(view, snap.settings.company, snap.shop, { copy: 'client' }) }} /></Modal> : null}
    </>
  );
}

function RejectModal({ o, onClose, onDone }: { o: SaleOrder; onClose: () => void; onDone: () => void }) {
  const [r, setR] = useState(''), a = useAction(), toast = useToast();
  const go = () => a.run(async () => { await rpc('reject_order', { p_id: o.id, p_reason: r }); toast(`Order for ${o.customer} rejected`, 'warn'); onDone(); });
  return (
    <Modal title={`Reject the order for ${o.customer}`} icon="x" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn danger" disabled={a.busy} onClick={() => void go()}><Icon n="x" /> Reject order</button></>}>
      <p>Sent by {o.created_by_name}. Nothing is sold and no stock moves. {o.created_by_name.split(' ')[0]} sees the reason on the till.</p>
      <div className="field"><label>Reason</label><input id="rreason" className="input" maxLength={80} value={r} onChange={(e) => setR(e.target.value)} placeholder="e.g. Customer left" autoFocus /></div>
      <div className="lerr">{a.err}</div>
    </Modal>
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
