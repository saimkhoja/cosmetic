import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { useNavigate } from 'react-router-dom';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { rpc, rows, supabase } from '../lib/supabase';
import { cartPriced, cashNotes, hotSet, hotSort, payment, takeLocal, totals, unitLabel, unitNote, unitsOf, usdNotes, type CartLine, type PayIn } from '../lib/units';
import { catIcon, custName, findByCode } from '../lib/items';
import { dt, fCDF, fNum, fUSD, ld, tm, toCDF, today } from '../lib/format';
import { orderRef, orderSlipCopies, printHTML, receiptHTML, saleCopies } from '../lib/print';
import { Empty, Modal, Note, useAction, useToast } from '../components/ui';
import { TicketsModal } from '../components/Tickets';
import { useDeliveries, useOrders } from '../data/queries';
import { getDevice, getParked, getSnapshot, nextInvoiceNo, outboxAll, outboxPut, setDevice, setParked, setSnapshot, type Device, type OutboxEntry, type Parked, type Snapshot } from '../offline/store';
import { isNetworkError, startSync, syncOutbox } from '../offline/sync';
import type { Category, Invoice, Product, Rank, SaleOrder, Settings, Shop, StockRow } from '../lib/types';

const SHORT: Record<string, string> = { 'half dzn': '½ dz', dzn: 'dz', carton: 'ctn' };
/** A line of the sale: one item in one unit. */
const keyOf = (l: { pid: string; ui: number }) => l.pid + ':' + l.ui;

/** Loads the shop's catalogue from the server and keeps it on the device for offline selling. */
export async function refreshSnapshot(shopId: string): Promise<Snapshot> {
  const [st, sh, pr, cats, ranks] = await Promise.all([
    supabase.from('settings').select('*'), supabase.from('shops').select('*').eq('id', shopId),
    (async () => { const out: Product[] = []; for (let a = 0; ; a += 1000) { const page = rows<Product>(await supabase.from('products').select('*').eq('active', true).order('name').range(a, a + 999)); out.push(...page); if (page.length < 1000) return out; } })(),
    supabase.from('categories').select('id,name,seasonal,season_months').order('name'),
    rpc<Rank[]>('item_ranks', { p_shop: shopId }).catch(() => [] as Rank[]),
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
  const snap: Snapshot = { shop: rows<Shop>(sh)[0], settings: rows<Settings>(st)[0], products, stock, at: Date.now(), categories: rows<Category>(cats), ranks };
  await setSnapshot(snap);
  return snap;
}

/** The shop admin always sells; a till operator only when the Admin turned on "Till operators sell directly". */
const canSell = (isAdmin: boolean, s: Snapshot | null | undefined) => isAdmin || !!s?.settings.features?.till_sells;

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
  const [customer, setCustomer] = useState(''), [custDraft, setCustDraft] = useState(''), [editing, setEditing] = useState<SaleOrder | null>(null), [tickets, setTickets] = useState(false);
  const [pick, setPick] = useState<{ pid: string; k: string | null } | null>(null), [check, setCheck] = useState(false), [disc, setDisc] = useState(false), [reject, setReject] = useState<SaleOrder | null>(null);
  const [last, setLast] = useState<Invoice | null>(null), [view, setView] = useState<Invoice | null>(null), [outbox, setOutbox] = useState<OutboxEntry[]>([]), [flash, setFlash] = useState(false);
  const [cashFor, setCashFor] = useState<{ total: number; info: string; go: (pay: PayIn) => Promise<boolean>; cancel: () => void } | null>(null);
  // the highlighted line (n changes on every scan, so the same line flashes and scrolls into view again)
  const [sel, setSel] = useState<{ k: string; n: number } | null>(null), [parked, setParkedList] = useState<Parked[]>([]), [showParked, setShowParked] = useState(false);
  const [slot, setSlot] = useState<HTMLElement | null>(null);
  const busy = useRef(false), scan = useRef<HTMLInputElement>(null), custIn = useRef<HTMLInputElement>(null);
  useLayoutEffect(() => setSlot(document.getElementById('topslot')), []);
  useEffect(() => { void getParked(shopId).then(setParkedList); }, [shopId]);
  // only the sale list scrolls to the highlighted line, never the page
  useEffect(() => {
    const el = sel && document.getElementById('ln-' + sel.k), box = el?.parentElement; if (!el || !box) return;
    const r = el.getBoundingClientRect(), b = box.getBoundingClientRect();
    if (r.top < b.top) box.scrollTop -= b.top - r.top + 4; else if (r.bottom > b.bottom) box.scrollTop += r.bottom - b.bottom + 4;
  }, [sel]);
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
      else if (!known && canSell(isAdmin, local)) setProblem('Connect to the internet once to register this till.');
      return;
    }
    try {
      const fresh = await refreshSnapshot(shopId); setSnap(fresh);
      if (canSell(isAdmin, fresh)) { const d = await registerOnce(shopId, known?.id ?? null); setDev(d); }
      setProblem('');
    } catch (e) {
      if (!isNetworkError(e)) setProblem((e as Error).message);
      else if (!local) setProblem('This till has not been connected yet. Connect to the internet once to load the items and register the till.');
      else if (!known && canSell(isAdmin, local)) setProblem('Connect to the internet once to register this till.');
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
  // switches from Settings: walk-in sales without a name, and barcode scanning
  const optCust = !!snap?.settings.features?.customer_optional, codes = !!snap?.settings.features?.barcode, ready = !!customer || optCust, sells = canSell(isAdmin, snap), cashIn = !!snap?.settings.features?.cash_change, usdPay = !!snap?.settings.features?.usd_pay, cashStep = cashIn || usdPay;
  useEffect(() => { if (!customer) setTimeout(() => (optCust ? scan : custIn).current?.focus(), 50); }, [customer, optCust]);

  const byId = useMemo(() => new Map((snap?.products ?? []).map((p) => [p.id, p])), [snap]);
  const rate = snap?.settings.rate ?? 0, vat = snap?.settings.vat ?? 0;
  const priced = useMemo(() => cartPriced(cart.filter((l) => byId.has(l.pid)), byId, rate), [cart, byId, rate]);
  const T = totals(priced, dp, vat);
  const cartBase = (pid: string) => priced.filter((l) => l.pid === pid).reduce((s, l) => s + (l.u.piece ? 0 : l.u.mult * l.qty), 0);
  const left = (p: Product) => (snap?.stock[p.id]?.qty ?? 0) - cartBase(p.id);
  const used = new Set((snap?.products ?? []).map((p) => p.category));
  const cats = ['All', ...(snap?.categories?.length ? snap.categories.map((c) => c.name).filter((c) => used.has(c)) : [...used].sort())];
  const ql = q.trim().toLowerCase(), hot = hotSet(snap?.ranks);
  const list = hotSort(snap?.products ?? [], snap?.ranks).filter((p) => (cat === 'All' || p.category === cat) && (!ql || p.name.toLowerCase().includes(ql) || p.category.toLowerCase().includes(ql)));
  const failed = outbox.filter((e) => e.error);
  // orders already approved on this till but not yet sent are hidden from the review list
  const approvedHere = new Set(outbox.flatMap((e) => (e.kind !== 'order' && e.payload.order_id ? [e.payload.order_id] : [])));
  const toReview = (orders.data ?? []).filter((o) => o.status === 'pending' && !approvedHere.has(o.id));
  const toReceive = (dels.data ?? []).filter((d) => d.status === 'pending').length;
  const orderTotal = (o: SaleOrder) => o.items.reduce((s, it) => { const p = byId.get(it.product_id); if (!p) return s; const u = unitsOf(p).find((x) => (it.piece ? !!x.piece : !x.piece && x.mult === it.mult)); return s + (u ? toCDF(u.usd, rate) * it.qty : 0); }, 0);

  const startCustomer = () => { const c = custDraft.trim().replace(/\s+/g, ' ').slice(0, 60); if (!c) { if (optCust) scan.current?.focus(); else toast('Type the customer name, then press Enter', 'warn'); return; } setCustomer(c); setCustDraft(''); setTimeout(() => scan.current?.focus(), 50); };
  const resetSale = () => { setCart([]); setDp(0); setCustomer(''); setSel(null); };
  const hi = (k: string) => { setSel((s) => ({ k, n: (s?.n ?? 0) + 1 })); setFlash(true); setTimeout(() => setFlash(false), 600); };
  const add = (pid: string, ui?: number) => {
    if (!ready) { toast('Type the customer name first', 'warn'); custIn.current?.focus(); return; }
    const p = byId.get(pid); if (!p) return;
    const us = unitsOf(p);
    if (!us.length) { toast(`${p.name} has no price yet`, 'warn'); return; }
    if (ui === undefined && us.length > 1) { setPick({ pid, k: null }); return; }
    const i = ui ?? 0;
    // a new line goes at the bottom, as on the receipt; scanning it again adds 1 to its line
    setCart((c) => { const l = c.find((x) => x.pid === pid && x.ui === i); return l ? c.map((x) => (x === l ? { ...x, qty: x.qty + 1 } : x)) : [...c, { pid, ui: i, qty: 1 }]; });
    hi(keyOf({ pid, ui: i }));
    if (!us[i].piece && left(p) - us[i].mult < 0) toast(`${p.name}: selling on order, the shop is ${Math.abs(left(p) - us[i].mult)} short`, 'warn');
  };
  // a USB scanner types the barcode and presses Enter: the item goes into the sale as 1 pc (or 1 set)
  const scanned = () => {
    const code = q.trim(); if (!codes || !code) return;
    const p = findByCode(snap?.products ?? [], code);
    if (p) { add(p.id, 0); setQ(''); }
    else if (/^\d{6,}$/.test(code)) { toast(`No item has the barcode ${code}`, 'warn'); setQ(''); }
  };
  // removing the highlighted line moves the highlight to the line above it
  const remove = (k: string) => {
    const ks = priced.map(keyOf), at = ks.indexOf(k), nk = ks[at - 1] ?? ks[at + 1];
    setCart((c) => { const n = c.filter((x) => keyOf(x) !== k); if (!n.length) setDp(0); return n; });
    if (!sel || sel.k === k) setSel(nk ? { k: nk, n: (sel?.n ?? 0) + 1 } : null);
  };
  const step = (k: string, d: number) => {
    const l = cart.find((x) => keyOf(x) === k); if (!l) return;
    if (l.qty + d <= 0) { remove(k); return; }
    setCart((c) => c.map((x) => (keyOf(x) === k ? { ...x, qty: x.qty + d } : x))); hi(k);
  };
  const setUnit = (k: string, ui: number) => {
    const l = cart.find((x) => keyOf(x) === k); if (!l || l.ui === ui) return;
    const nk = keyOf({ pid: l.pid, ui });
    setCart((c) => { const same = c.find((x) => keyOf(x) === nk); return same ? c.flatMap((x) => (keyOf(x) === k ? [] : x === same ? [{ ...x, qty: x.qty + l.qty }] : [x])) : c.map((x) => (keyOf(x) === k ? { ...x, ui } : x)); });
    hi(nk);
  };
  // the arrow keys in the search box walk through the sale, to check it line by line
  const move = (d: number) => {
    const ks = priced.map(keyOf); if (!ks.length) return;
    const at = sel ? ks.indexOf(sel.k) : -1, i = at < 0 ? (d > 0 ? 0 : ks.length - 1) : Math.min(ks.length - 1, Math.max(0, at + d));
    setSel({ k: ks[i], n: (sel?.n ?? 0) + 1 });
  };

  // an order's lines as cart lines, at today's prices; lines whose unit no longer exists are reported
  const orderLines = (o: SaleOrder) => {
    const lines: CartLine[] = [], missing: string[] = [];
    for (const it of o.items) {
      const p = byId.get(it.product_id); if (!p) { missing.push('an item no longer sold'); continue; }
      const ui = unitsOf(p).findIndex((u) => (it.piece ? !!u.piece : !u.piece && u.mult === it.mult));
      if (ui < 0) missing.push(p.name); else lines.push({ pid: p.id, ui, qty: it.qty });
    }
    return { lines, missing };
  };

  // till operator: the order goes to the shop admin and an order slip prints for the customer;
  // nothing is sold and no stock moves until the shop admin approves it
  const sendOrder = async () => {
    if (busy.current || !priced.length || !ready || !snap) return;
    busy.current = true;
    try {
      const id = crypto.randomUUID(), t = new Date().toISOString();
      await outboxPut({ kind: 'order', id, t, shop_id: shopId, tries: 0, total: T.total, created_by: profile!.id,
        payload: { id, customer, t, items: priced.map((l) => ({ product_id: l.pid, mult: l.u.piece ? 0 : l.u.mult, piece: !!l.u.piece, qty: l.qty })) } });
      printHTML(orderSlipCopies({ ref: orderRef(id), customer, t, by: profile!.name, total: T.total, lines: priced.map((l) => ({ name: l.p.name, unit: unitLabel(l.u), qty: l.qty, price: l.price })) }, snap.settings.company, snap.shop));
      toast(`Order ${orderRef(id)} for ${custName(customer)} sent to the shop admin. Printing the order slip, customer and shop copies.`);
      resetSale(); void syncOutbox();
    } finally { busy.current = false; }
  };

  // shop admin: a sale is saved on the device, printed, then sent to the server (works offline too).
  // Approving an order is the same: the invoice prints here and the stock goes down.
  // with the cash step on, pay is what the customer handed over (Francs and maybe dollars); otherwise the exact total in Francs
  const sell = async (lines: CartLine[], disc: number, cust: string, order: SaleOrder | null, pay?: PayIn) => {
    if (busy.current || !snap || (!cust && !optCust)) return false;
    if (!dev) { toast('Connect to the internet once to register this till', 'bad'); return false; }
    const pr = cartPriced(lines.filter((l) => byId.has(l.pid)), byId, rate);
    if (!pr.length) return false;
    busy.current = true;
    try {
      const S = totals(pr, disc, vat), tend = pay?.tendered ?? S.total, usd = pay && pay.paid_usd > 0 ? pay : null;
      if (tend < S.total) { toast(`Cash received is less than the total, ${fCDF(S.total)}`, 'warn'); return false; }
      const no = await nextInvoiceNo(dev), id = crypto.randomUUID(), t = new Date().toISOString();
      const items = pr.map((l) => ({ product_id: l.pid, name: l.p.name, unit: l.u.piece ? 'piece' : l.u.u, mult: l.u.piece ? 0 : l.u.mult, piece: !!l.u.piece, qty: l.qty, price: l.price, line: l.price * l.qty }));
      const inv: Invoice = { id, no, shop_id: shopId, cashier_id: profile!.id, cashier_name: profile!.name, t, rate, vat_rate: vat, gross: S.gross, disc_pct: disc, disc: S.disc, total: S.total, vat: S.vat, ht: S.ht, tendered: tend, change: tend - S.total, paid_usd: usd?.paid_usd ?? 0, paid_cdf: usd ? usd.paid_cdf : tend, change_usd: usd?.change_usd ?? 0, change_cdf: tend - S.total - Math.round((usd?.change_usd ?? 0) * rate), printed: 2, items, edits: [], synced: false,
        customer: cust, order_id: order?.id ?? null, prepared_by_name: order?.created_by_name ?? null };
      await outboxPut({ id, t, shop_id: shopId, tries: 0, invoice: inv, payload: { id, no, device_id: dev.id, cashier_id: profile!.id, t, rate, vat_rate: vat, disc_pct: disc, tendered: tend, ...(usd ? { paid_usd: usd.paid_usd, paid_cdf: usd.paid_cdf, change_usd: usd.change_usd } : {}), customer: cust, order_id: order?.id ?? null, items: items.map(({ product_id, mult, piece, qty, price }) => ({ product_id, mult, piece, qty, price })) } });
      const stock = { ...snap.stock };
      for (const l of pr) stock[l.pid] = takeLocal(stock[l.pid] ?? { qty: 0, open_pieces: 0 }, l.qty, l.u.piece ? 0 : l.u.mult, !!l.u.piece, l.p.pieces_per_set);
      const next = { ...snap, stock }; setSnap(next); void setSnapshot(next);
      printHTML(saleCopies(inv, snap.settings.company, snap.shop, cashStep));
      setLast(inv);
      toast(order ? `Order ${orderRef(order.id)} for ${custName(cust)} approved as ${no}, ${fCDF(S.total)}.${inv.change > 0 ? ` Change ${changeText(inv)}.` : ''} Printing the invoice.` : `Sale ${no} for ${custName(cust)} done, ${fCDF(S.total)}.${inv.change > 0 ? ` Change ${changeText(inv)}.` : ''} Printing.`);
      void syncOutbox();
      return true;
    } finally { busy.current = false; }
  };
  // with the cash step on, the payment window asks what the customer hands over; otherwise the sale prints at once
  const pay = () => {
    if (!priced.length || !ready) return;
    if (!cashStep) { void sell(cart, dp, customer, null).then((ok) => { if (ok) resetSale(); }); return; }
    setCashFor({ total: T.total, info: `${custName(customer)} · ${T.count} ${T.count === 1 ? 'item' : 'items'}`, go: async (t) => { const ok = await sell(cart, dp, customer, null, t); if (ok) resetSale(); return ok; }, cancel: () => {} });
  };
  // approving an order: with the switch on, the cash received is asked first
  const sellOrder = async (lines: CartLine[], d: number, o: SaleOrder) => {
    if (!cashStep) return sell(lines, d, o.customer, o);
    const total = totals(cartPriced(lines.filter((l) => byId.has(l.pid)), byId, rate), d, vat).total;
    return new Promise<boolean>((done) => setCashFor({ total, info: `Order ${orderRef(o.id)} for ${custName(o.customer)}`, go: async (t) => { const ok = await sell(lines, d, o.customer, o, t); if (ok) done(true); return ok; }, cancel: () => done(false) }));
  };
  // a parked sale waits on this till (it survives a restart) while the next customer is served
  const saveParked = (l: Parked[]) => { setParkedList(l); void setParked(shopId, l); };
  const withCurrent = (l: Parked[]) => [...l, { id: crypto.randomUUID(), t: new Date().toISOString(), customer, lines: cart, dp, total: T.total, count: T.count, by: profile!.name }];
  const park = () => {
    if (!priced.length) return;
    if (parked.length >= 20) { toast('20 sales are parked already. Finish or delete one first.', 'warn'); return; }
    saveParked(withCurrent(parked)); toast(`Sale for ${custName(customer)} parked. Open Parked to finish it.`); resetSale();
    setTimeout(() => (optCust ? scan : custIn).current?.focus(), 50);
  };
  const resume = (x: Parked) => {
    const rest = parked.filter((y) => y.id !== x.id), swap = priced.length > 0;
    saveParked(swap ? withCurrent(rest) : rest);
    const lines = x.lines.filter((l) => byId.has(l.pid));
    setCart(lines); setDp(x.dp); setCustomer(x.customer); setShowParked(false);
    setSel(lines.length ? { k: keyOf(lines[lines.length - 1]), n: (sel?.n ?? 0) + 1 } : null);
    toast(`Sale for ${custName(x.customer)} back on the till${swap ? `; the sale for ${custName(customer)} is parked` : ''}`);
    setTimeout(() => scan.current?.focus(), 50);
  };
  const unpark = (x: Parked) => { if (confirm(`Delete the parked sale for ${custName(x.customer)}, ${fCDF(x.total)}? Nothing was sold.`)) saveParked(parked.filter((y) => y.id !== x.id)); };
  const approve = async (o: SaleOrder) => {
    const { lines, missing } = orderLines(o);
    if (missing.length) { toast(`Open the order with Edit: ${missing.join(', ')} can no longer be sold this way`, 'warn'); setEditing(o); return; }
    await sellOrder(lines, 0, o);
  };

  if (!snap) return <div className="card"><Empty i={problem ? 'wifioff' : 'refresh'} t={problem || 'Loading the till'} tall /></div>;
  const st = (p: Product) => snap.stock[p.id] ?? { qty: 0, open_pieces: 0 };
  const myUnsent = outbox.filter((e) => e.kind === 'order');
  const myOrders = sells ? [] : (orders.data ?? []).slice(0, 8);

  // the search box, Price check and Tickets sit in the top bar
  const top = slot ? createPortal(<>
    <div className={`hscan ${ready ? '' : 'off'}`}><Icon n="search" /><input id="scan" ref={scan} autoComplete="off" spellCheck={false} placeholder={codes ? 'Scan a barcode or type part of the item name' : 'Type part of the item name, e.g. lotion'} aria-label="Search items" value={q} onChange={(e) => setQ(e.target.value)}
      onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); scanned(); } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); move(e.key === 'ArrowDown' ? 1 : -1); } }} />
      {q ? <button className="hclear" onClick={() => { setQ(''); scan.current?.focus(); }} aria-label="Clear the search"><Icon n="x" /></button> : null}</div>
    <button className="hbtn" onClick={() => setCheck(true)} title="Check a price, including the piece price of a set" aria-label="Price check"><Icon n="tag" /><span>Price check</span></button>
    <button className="hbtn" onClick={() => setTickets(true)} title="Print price tickets for the shelves" aria-label="Tickets"><Icon n="printer" /><span>Tickets</span></button>
  </>, slot) : null;

  const pos = (
    <div className="pos"><section className="pos-left">
      {customer ? (
        <div className="custbar on"><Icon n="user" /><span className="cn">Customer: <b id="custname">{customer}</b></span>
          <button className="btn sm" onClick={() => { setCustDraft(customer); setCustomer(''); }}><Icon n="edit" /> Change</button></div>
      ) : (
        <form className="custbar" onSubmit={(e) => { e.preventDefault(); startCustomer(); }}><Icon n="user" />
          <input id="cust" ref={custIn} autoComplete="off" placeholder={optCust ? 'Customer name (optional)' : 'New sale: type the customer name and press Enter'} aria-label="Customer name" value={custDraft} maxLength={60} onChange={(e) => setCustDraft(e.target.value)} />
          <button className="btn primary sm"><Icon n="check" /> Start</button></form>
      )}
      <div className="cats">{cats.map((c) => <button key={c} className={cat === c ? 'on' : ''} onClick={() => setCat(c)}><Icon n={c === 'All' ? 'grid' : catIcon(c)} /><span>{c}</span></button>)}</div>
      <div className="pgrid">{list.length ? list.map((p) => { const us = unitsOf(p), lf = left(p); return (
        <button key={p.id} className="ptile" onClick={() => add(p.id)}><span className="ptop"><span className="ico"><Icon n={p.is_bundle ? 'gift' : catIcon(p.category)} /></span>
          <span className="tchips">{hot.has(p.id) ? <span className="chip hot">Hot</span> : null}{p.is_bundle ? <span className="chip">set + piece</span> : us.length > 1 ? <span className="chip">{us.map((x) => SHORT[x.u] ?? x.u).join(' · ')}</span> : null}</span></span>
          <span className="nm">{p.name}</span><span className="pr">{us.length ? <>{fCDF(toCDF(us[0].usd, rate))}<small> / {us[0].u === 'pcs' ? p.stock_unit : unitLabel(us[0])}</small></> : <small>no price</small>}</span>
          <span className={`st ${lf <= 0 ? 'neg' : ''}`}>{lf > 0 ? lf + ' in shop' : lf === 0 ? 'None left, sells on order' : Math.abs(lf) + ' on order'}</span></button>); })
        : <Empty i="search" t={snap.products.length ? 'No items found. Try another word or another category.' : 'No items yet. The Admin adds them in Inventory.'} />}</div>
    </section>
    <section className="cart" id="cart">
      <div className="cart-h"><b><Icon n="cart" /> {sells ? 'Current sale' : 'New order'}</b><span className="chip">{T.count} {T.count === 1 ? 'item' : 'items'}</span>
        {parked.length ? <button id="parked" className="btn sm ghost" onClick={() => setShowParked(true)} title="Sales put aside on this till"><Icon n="pause" /><span className="lbl">Parked</span><em className="badge">{parked.length}</em></button> : null}
        {sells && last ? <button className="btn sm" onClick={() => setView(last)} title={`Last sale ${last.no}, ${fCDF(last.total)}`} aria-label="Last sale"><Icon n="receipt" /><span className="lbl">Last sale</span></button> : null}
        {cart.length || customer ? <button className="iconbtn dark" onClick={resetSale} title="Clear" aria-label="Clear sale"><Icon n="trash" /></button> : null}</div>
      {priced.length ? <div className="lhead" aria-hidden="true"><span>#</span><span>Item</span><span className="c">Qty</span><span className="r">Price</span><span className="r">Amount</span><span /></div> : null}
      <div className="lines">{priced.length ? priced.map((l, i) => { const k = keyOf(l), on = sel?.k === k, short = !l.u.piece && st(l.p).qty - cartBase(l.pid) < 0, many = unitsOf(l.p).length > 1; return (
        <div key={k} id={'ln-' + k} className={`line ${on ? 'on' : ''} ${on && flash ? 'flash' : ''}`} onClick={() => { if (!on) setSel({ k, n: (sel?.n ?? 0) + 1 }); }}>
          <span className="no">{i + 1}</span>
          <div className="li"><div className="ln">{l.p.name}</div>{many || short || l.u.u !== 'pcs' ? <div className="lp">{many ? <button className="uchip" onClick={() => setPick({ pid: l.pid, k })} title="Change unit">{unitLabel(l.u)} <Icon n="edit" /></button> : l.u.u !== 'pcs' ? <span className="uchip">{unitLabel(l.u)}</span> : null}{short ? <span className="chip warn">on order</span> : null}</div> : null}</div>
          <div className="qty"><button onClick={() => step(k, -1)} aria-label="One less"><Icon n="minus" /></button><b>{l.qty}</b><button onClick={() => step(k, 1)} aria-label="One more"><Icon n="plus" /></button></div>
          <span className="lpr"><small>× </small>{fNum(l.price)}</span>
          <b className="lt">{fNum(l.price * l.qty)}</b>
          <button className="rm" onClick={(e) => { e.stopPropagation(); remove(k); }} title="Remove from the sale" aria-label="Remove item"><Icon n="x" /></button></div>); })
        : <Empty i={ready ? 'cart' : 'user'} t={ready ? (codes ? 'Scan or tap an item to add it' : 'Tap an item to add it') : 'Start with the customer name'} tall />}</div>
      <div className="totals">
        <div className="tsum"><div className="sumrows"><div className="row"><span>Subtotal</span><span>{fCDF(T.gross)}</span></div>
          {T.disc ? <div className="row"><span>Discount {dp}%</span><span>- {fCDF(T.disc)}</span></div> : null}
          <div className="row muted"><span>Incl. VAT {vat}%</span><span>{fCDF(T.vat)}</span></div></div>
          <div className="grand"><span>{sells ? 'To pay' : 'Order total'}</span><b>{fCDF(T.total)}</b></div></div>
        <div className={`cact ${isAdmin ? 'three' : ''}`}>
          {isAdmin ? <button className={`btn ${dp ? 'primary' : ''}`} onClick={() => setDisc(true)} disabled={!cart.length} title="Discount on this invoice" aria-label="Discount on this invoice"><Icon n="tag" /><span>{dp ? `${dp}%` : 'Discount'}</span></button> : null}
          <button id="park" className="btn" onClick={park} disabled={!priced.length} title="Put this sale aside and serve the next customer"><Icon n="pause" /><span>Park sale</span></button>
          {sells
            ? <button id="paybtn" className="paybtn cash" onClick={pay} disabled={!priced.length || !ready}><Icon n="cash" /> {cashStep ? 'Take payment' : 'Take cash and print'}</button>
            : <button className="paybtn" onClick={() => void sendOrder()} disabled={!priced.length || !ready}><Icon n="check" /> Send to shop admin for approval</button>}</div>
        {!sells && (myUnsent.length || myOrders.length) ? <div className="myorders"><div className="code" style={{ margin: '10px 0 4px', fontWeight: 800 }}>My orders today</div>
          {myUnsent.map((e) => <div key={e.id} className="morow"><span>{e.kind === 'order' ? custName(e.payload.customer) : ''}</span><span className="chip warn">{e.error ? 'Not accepted: ' + e.error : 'Not sent yet'}</span></div>)}
          {myOrders.filter((o) => !myUnsent.some((e) => e.id === o.id)).map((o) => <div key={o.id} className="morow"><span>{custName(o.customer)} <span className="code">{orderRef(o.id)}, {tm(o.created_at)}</span></span>
            {o.status === 'pending' ? <span className="chip">Waiting for approval</span> : o.status === 'approved' ? <span className="chip ok">Approved</span> : <span className="chip bad" title={o.reason ?? ''}>Rejected{o.reason ? ': ' + o.reason : ''}</span>}</div>)}
        </div> : null}
      </div>
    </section></div>
  );

  // with "Till operators sell directly" on, no orders come in: the review panel shows only when something waits
  const review = isAdmin && (!snap.settings.features?.till_sells || toReview.length > 0 || toReceive > 0);

  return (
    <>
      {top}
      {problem ? <Note i="alert" warn>{problem}</Note> : null}
      {failed.length ? <Note i="alert" warn><span>{failed.length} {failed.length > 1 ? 'entries' : 'entry'} could not be saved on the server: {failed[0].error}. {isAdmin ? 'Check the items and prices, then try again.' : 'Tell the shop admin.'} <button className="btn sm" style={{ marginLeft: 8 }} onClick={() => void syncOutbox().then(loadOutbox)}>Try again</button></span></Note> : null}
      {review ? (
        <div className="tillwrap">{pos}
          <aside className="review" aria-label="Orders for review">
            <div className="cart-h"><b><Icon n="receipt" /> For review</b><span className={`chip ${toReview.length ? 'warn' : ''}`}>{toReview.length}</span></div>
            <div className="rl">
              {!navigator.onLine ? <Note i="wifioff" warn>Orders from the till operators arrive when the internet is back.</Note> : null}
              {toReview.length ? toReview.map((o) => (
                <div key={o.id} className={`rcard ${editing?.id === o.id ? 'on' : ''}`}>
                  <div className="rrow"><b title={custName(o.customer)}>{custName(o.customer)}</b><span className="amt">{fCDF(orderTotal(o))}</span></div>
                  <div className="rrow"><span className="code" style={{ flex: 1 }}>{orderRef(o.id)} · {o.items.reduce((s, i) => s + i.qty, 0)} items · {o.created_by_name.split(' ')[0]}, {tm(o.created_at)}</span>
                    <button className="rbtn ok" title="Approve this order" aria-label={`Approve order for ${custName(o.customer)}`} onClick={() => void approve(o)}><Icon n="check" /></button>
                    <button className="rbtn bad" title="Reject this order" aria-label={`Reject order for ${custName(o.customer)}`} onClick={() => setReject(o)}><Icon n="x" /></button>
                    <button className="rbtn ed" title="Check and change before approving" aria-label={`Edit order for ${custName(o.customer)}`} onClick={() => setEditing(o)}><Icon n="edit" /></button></div>
                </div>)) : <Empty i="check" t={orders.isLoading ? 'Loading' : 'No orders waiting'} />}
              {toReceive ? <button className="rcard" style={{ width: '100%', textAlign: 'left', cursor: 'pointer', background: 'var(--warn-l)' }} onClick={() => nav('/received')}><b><Icon n="truck" /> {toReceive} deliver{toReceive > 1 ? 'ies' : 'y'} to receive</b><div className="code">From the central store. Open to check and approve.</div></button> : null}
            </div>
          </aside>
        </div>
      ) : pos}

      {pick ? (() => { const p = byId.get(pick.pid)!, s = st(p); return (
        <Modal title={pick.k ? 'Change the unit' : 'How is it sold?'} icon={p.is_bundle ? 'gift' : 'layers'} onClose={() => setPick(null)} foot={<button className="btn" onClick={() => setPick(null)}>Cancel</button>}>
          <p><b>{p.name}</b><br /><span className="code">{s.qty >= 0 ? s.qty : Math.abs(s.qty) + ' on order'} {p.stock_unit} in the shop{p.is_bundle ? `, ${s.open_pieces} pieces sold from an open set` : ''}</span></p>
          <div className="ugrid">{unitsOf(p).map((u, i) => <button key={i} className="ubtn" onClick={() => { setPick(null); if (pick.k) setUnit(pick.k, i); else add(pick.pid, i); }}><b>{unitLabel(u)}</b><span>{unitNote(p, u)}</span><em>{fCDF(toCDF(u.usd, rate))}</em></button>)}</div>
          {p.is_bundle ? <Note i="tag">The piece price is the last price set by the Admin. It cannot be changed at the shop.</Note> : null}
        </Modal>); })() : null}
      {check ? <PriceCheck products={snap.products} stock={snap.stock} rate={rate} onClose={() => setCheck(false)} /> : null}
      {disc ? <DiscModal v={dp} onApply={(v) => { setDp(v); setDisc(false); }} onClose={() => setDisc(false)} /> : null}
      {reject ? <RejectModal o={reject} onClose={() => setReject(null)} onDone={() => { if (editing?.id === reject.id) setEditing(null); setReject(null); void orders.refetch(); }} /> : null}
      {editing ? <OrderEditor o={editing} init={orderLines(editing)} byId={byId} snap={snap} onClose={() => setEditing(null)} onReject={() => { setReject(editing); }} onApprove={async (lines, d) => { if (await sellOrder(lines, d, editing)) setEditing(null); }} /> : null}
      {cashFor ? <CashModal total={cashFor.total} info={cashFor.info} rate={rate} usdPay={usdPay} onClose={() => { cashFor.cancel(); setCashFor(null); }} onPay={async (p) => { if (await cashFor.go(p)) setCashFor(null); }} /> : null}
      {showParked ? <ParkedModal list={parked} onResume={resume} onDelete={unpark} onClose={() => setShowParked(false)} /> : null}
      {tickets ? <TicketsModal products={hotSort(snap.products, snap.ranks)} rate={rate} shopName={snap.shop.name} onClose={() => setTickets(false)} /> : null}
      {view ? <Modal title={'Invoice ' + view.no} icon="receipt" onClose={() => setView(null)} foot={<button className="btn" onClick={() => setView(null)}>Close</button>}><div className="rwrap" dangerouslySetInnerHTML={{ __html: receiptHTML(view, snap.settings.company, snap.shop, { copy: 'client', cash: cashStep }) }} /></Modal> : null}
    </>
  );
}

function RejectModal({ o, onClose, onDone }: { o: SaleOrder; onClose: () => void; onDone: () => void }) {
  const [r, setR] = useState(''), a = useAction(), toast = useToast();
  const go = () => a.run(async () => { await rpc('reject_order', { p_id: o.id, p_reason: r }); toast(`Order for ${custName(o.customer)} rejected`, 'warn'); onDone(); });
  return (
    <Modal title={`Reject the order for ${custName(o.customer)}`} icon="x" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn danger" disabled={a.busy} onClick={() => void go()}><Icon n="x" /> Reject order</button></>}>
      <p>Sent by {o.created_by_name}. Nothing is sold and no stock moves. {o.created_by_name.split(' ')[0]} sees the reason on the till.</p>
      <div className="field"><label>Reason</label><input id="rreason" className="input" maxLength={80} value={r} onChange={(e) => setR(e.target.value)} placeholder="e.g. Customer left" autoFocus /></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

function PriceCheck({ products, stock, rate, onClose }: { products: Product[]; stock: Snapshot['stock']; rate: number; onClose: () => void }) {
  const [q, setQ] = useState('');
  const hit = findByCode(products, q), list = hit ? [hit] : products.filter((p) => !q.trim() || p.name.toLowerCase().includes(q.trim().toLowerCase())).slice(0, 40);
  return (
    <Modal title="Price check" icon="tag" wide onClose={onClose} foot={<button className="btn" onClick={onClose}>Close</button>}>
      <div className="field"><label>Search</label><input className="input" placeholder="Item name or barcode" value={q} onChange={(e) => setQ(e.target.value)} autoFocus /></div>
      {list.length ? <div className="tw"><table className="t"><thead><tr><th>Item</th><th>Unit</th><th className="r">Price</th><th className="r">In shop</th></tr></thead><tbody>
        {list.flatMap((p) => unitsOf(p).map((u, i) => { const s = stock[p.id]?.qty ?? 0; return <tr key={p.id + i}><td>{i === 0 ? <><b>{p.name}</b>{p.is_bundle ? <div className="code">mixed set</div> : null}</> : null}</td><td><span className="uchip">{unitLabel(u)}</span>{u.piece ? <span className="code"> last price</span> : null}</td><td className="r"><b>{fCDF(toCDF(u.usd, rate))}</b></td><td className="r">{i === 0 ? (s < 0 ? Math.abs(s) + ' on order' : s) : ''}</td></tr>; }))}
      </tbody></table></div> : <Empty i="search" t="No item matches" />}
    </Modal>
  );
}
/** The payment window: what the customer hands over (Francs, and dollars when allowed), and the change to give. */
function CashModal({ total, info, rate, usdPay, onClose, onPay }: { total: number; info: string; rate: number; usdPay: boolean; onClose: () => void; onPay: (pay: PayIn) => Promise<void> }) {
  const [v, setV] = useState(''), [u, setU] = useState(''), [back, setBack] = useState(false), [busy, setBusy] = useState(false);
  const P = payment(total, rate, usdPay ? u : 0, v, back), any = !!u || !!v;
  // a barcode scanned into the box by mistake is far more digits than any amount
  const odd = v.replace(/\D/g, '').length >= 10 || u.replace(/\D/g, '').length >= 10;
  const go = () => { if (P.short || odd || busy) return; setBusy(true); void onPay(P.pay).finally(() => setBusy(false)); };
  const enter = (e: React.KeyboardEvent) => { if (e.key === 'Enter') { e.preventDefault(); go(); } };
  const rest = P.change - Math.round(P.maxDollars * rate);
  return (
    <Modal title="Payment" icon="cash" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn go" disabled={P.short > 0 || odd || busy} onClick={go}><Icon n="cash" /> Take cash and print</button></>}>
      <div className="paytotal"><small>{info}</small><b>{fCDF(total)}</b>{usdPay ? <small>Due in USD <span id="usddue" className="due">{fUSD(P.due)}</span> · 1 USD = {fCDF(rate)}</small> : null}</div>
      <div className="cashin">
        {usdPay ? <div className="frow">
          <div className="field"><label htmlFor="cashusd">USD received</label><input id="cashusd" className="input" type="number" min="0" step="1" inputMode="decimal" autoComplete="off" value={u} autoFocus onChange={(e) => setU(e.target.value)} onKeyDown={enter} placeholder="0" /></div>
          <div className="field"><label htmlFor="cashin">CDF received</label><input id="cashin" className="input" type="number" min="0" step="10" inputMode="numeric" autoComplete="off" value={v} onChange={(e) => setV(e.target.value)} onKeyDown={enter} placeholder="0" /></div>
        </div> : <div className="field"><label htmlFor="cashin">Cash received (CDF)</label><input id="cashin" className="input" type="number" min="0" step="10" inputMode="numeric" autoComplete="off" value={v} autoFocus onChange={(e) => setV(e.target.value)} onKeyDown={enter} placeholder={String(total)} /></div>}
        <div className="cnotes">{usdPay ? <>
          {usdNotes(P.due).map((n) => <button key={'u' + n} type="button" className={P.usd === n && !v ? 'on' : ''} onClick={() => { setU(String(n)); setV(''); }}>${n}</button>)}
          <button type="button" className={!u && P.cdf === total ? 'on' : ''} onClick={() => { setU(''); setV(String(total)); }}>Exact CDF</button>
        </> : cashNotes(total).map((n) => <button key={n} type="button" className={!u && P.cdf === n ? 'on' : ''} onClick={() => setV(String(n))}>{n === total ? 'Exact' : fCDF(n)}</button>)}</div>
        <div id="cashchange" className={`paychange ${!any ? '' : odd || P.short ? 'bad' : 'ok'}`}>
          <span>{odd ? 'Check the amount' : any && P.short ? (usdPay ? 'Still to pay' : 'Not enough cash') : 'Change to give'}</span>
          <b>{!any || odd ? '-' : P.short ? (usdPay ? `${fCDF(P.short)} (≈ ${fUSD(Math.ceil((P.short / rate) * 100) / 100)})` : fCDF(P.short)) : P.changeUsd ? `$${P.changeUsd} + ${fCDF(P.changeCdf)}` : fCDF(P.change)}</b></div>
        {usdPay && P.maxDollars > 0 && !odd ? <button id="dollarsback" type="button" className={`btn sm full ${back ? 'primary' : 'ghost'}`} onClick={() => setBack(!back)}>
          {back ? `Giving $${P.maxDollars} + ${fCDF(rest)}: tap for all in CDF` : `Give dollars back: $${P.maxDollars} + ${fCDF(rest)}`}</button> : null}
      </div>
    </Modal>
  );
}
/** Sales put aside on this till: resume one (the sale on the till is parked in its place) or delete it. */
function ParkedModal({ list, onResume, onDelete, onClose }: { list: Parked[]; onResume: (x: Parked) => void; onDelete: (x: Parked) => void; onClose: () => void }) {
  return (
    <Modal title="Parked sales" icon="pause" wide onClose={onClose} foot={<button className="btn" onClick={onClose}>Close</button>}>
      <p>Resume a sale to finish it. If a sale is on the till, it is parked in its place. Prices are today's.</p>
      {list.length ? <div className="tw"><table className="t"><thead><tr><th>Customer</th><th>Parked</th><th className="r">Items</th><th className="r">Total</th><th /></tr></thead><tbody>
        {[...list].reverse().map((x) => <tr key={x.id}><td><b>{custName(x.customer)}</b></td><td className="nw">{ld(x.t) === today() ? tm(x.t) : dt(x.t)}<div className="code">{x.by}</div></td>
          <td className="r">{x.count}</td><td className="r nw"><b>{fCDF(x.total)}</b></td>
          <td><div className="pact"><button className="btn sm primary" onClick={() => onResume(x)} aria-label={`Resume the sale for ${custName(x.customer)}`}><Icon n="cart" /> Resume</button>
            <button className="rbtn bad" onClick={() => onDelete(x)} title="Delete this parked sale" aria-label={`Delete the parked sale for ${custName(x.customer)}`}><Icon n="trash" /></button></div></td></tr>)}
      </tbody></table></div> : <Empty i="pause" t="No parked sales" />}
    </Modal>
  );
}
/** The change as given: Francs, or whole dollars plus Francs. */
const changeText = (inv: Invoice) => (inv.change_usd ? `$${inv.change_usd} + ${fCDF(inv.change_cdf ?? 0)}` : fCDF(inv.change));
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

/** The shop admin checks and changes an order in its own window; the sale being made on the till stays as it is. */
function OrderEditor({ o, init, byId, snap, onClose, onReject, onApprove }: { o: SaleOrder; init: { lines: CartLine[]; missing: string[] }; byId: Map<string, Product>; snap: Snapshot; onClose: () => void; onReject: () => void; onApprove: (lines: CartLine[], dp: number) => Promise<void> }) {
  const [lines, setLines] = useState<CartLine[]>(init.lines), [dp, setDp] = useState(0), [q, setQ] = useState(''), [busy, setBusy] = useState(false);
  const rate = snap.settings.rate, priced = cartPriced(lines.filter((l) => byId.has(l.pid)), byId, rate), T = totals(priced, dp, snap.settings.vat);
  const ql = q.trim().toLowerCase(), found = ql ? snap.products.filter((p) => p.name.toLowerCase().includes(ql)).slice(0, 8) : [];
  const chg = (i: number, d: number) => setLines((c) => c.flatMap((l, k) => (k !== i ? [l] : l.qty + d <= 0 ? [] : [{ ...l, qty: l.qty + d }])));
  const unit = (i: number, ui: number) => setLines((c) => c.map((l, k) => (k === i ? { ...l, ui } : l)));
  const add = (p: Product) => { setLines((c) => { const l = c.find((x) => x.pid === p.id && x.ui === 0); return l ? c.map((x) => (x === l ? { ...x, qty: x.qty + 1 } : x)) : [...c, { pid: p.id, ui: 0, qty: 1 }]; }); setQ(''); };
  return (
    <Modal title={`Order ${orderRef(o.id)} for ${custName(o.customer)}`} icon="receipt" wide onClose={onClose} foot={<><button className="btn danger" onClick={onReject}><Icon n="x" /> Reject</button><span className="sp" /><button className="btn" onClick={onClose}>Close</button>
      <button className="btn primary" id="oapprove" disabled={!priced.length || busy} onClick={() => { setBusy(true); void onApprove(lines, dp).finally(() => setBusy(false)); }}><Icon n="check" /> Approve {fCDF(T.total)}</button></>}>
      <p>Order {orderRef(o.id)}, prepared by {o.created_by_name} at {tm(o.created_at)}. Change quantities or units, add or remove items, then approve: the invoice prints here and the stock goes down.</p>
      {init.missing.length ? <Note i="alert" warn>Not added: {init.missing.join(', ')}. The unit or item is no longer sold.</Note> : null}
      <div className="tw"><table className="t"><thead><tr><th>Item</th><th>Unit</th><th className="r">Price</th><th style={{ width: 150 }}>Qty</th><th className="r">Line</th></tr></thead><tbody>
        {priced.map((l, i) => <tr key={l.pid + ':' + l.ui}><td><b>{l.p.name}</b><div className="code">{snap.stock[l.pid]?.qty ?? 0} in shop</div></td>
          <td><select className="input" style={{ minHeight: 40 }} value={l.ui} onChange={(e) => unit(i, Number(e.target.value))} aria-label="Unit">{unitsOf(l.p).map((u, k) => <option key={k} value={k}>{unitLabel(u)}</option>)}</select></td>
          <td className="r">{fCDF(l.price)}</td><td><div className="qty"><button onClick={() => chg(i, -1)} aria-label="One less"><Icon n="minus" /></button><b>{l.qty}</b><button onClick={() => chg(i, 1)} aria-label="One more"><Icon n="plus" /></button></div></td><td className="r"><b>{fCDF(l.price * l.qty)}</b></td></tr>)}
      </tbody></table></div>
      <div className="search" style={{ maxWidth: 'none', margin: '12px 0 6px' }}><Icon n="search" /><input placeholder="Add an item" value={q} onChange={(e) => setQ(e.target.value)} /></div>
      {found.length ? <div className="mchips">{found.map((p) => <button key={p.id} className="chip" onClick={() => add(p)}>+ {p.name}</button>)}</div> : null}
      <div className="frow" style={{ marginTop: 12 }}><div className="field"><label>Discount on this invoice (%)</label><input className="input" type="number" min="0" max="30" value={dp || ''} placeholder="0" onChange={(e) => setDp(Math.min(30, Math.max(0, parseInt(e.target.value) || 0)))} /></div>
        <div className="field"><label>Total</label><div style={{ fontSize: 22, fontWeight: 900 }}>{fCDF(T.total)}</div><span className="hint">{T.disc ? `after ${fCDF(T.disc)} discount, ` : ''}VAT included {fCDF(T.vat)}</span></div></div>
    </Modal>
  );
}
