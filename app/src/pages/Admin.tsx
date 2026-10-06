import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useAudit, useCosts, useProducts, useRefresh, useReport, useSettings, useShops, useStock, useUpkeep, useUsers } from '../data/queries';
import { invoke, rpc } from '../lib/supabase';
import { dt, fCDF, fUSD, sum, today } from '../lib/format';
import { UPCATS } from '../lib/items';
import { Dual, Dual2, Empty, Head, HList, Kpi, Modal, Note, Tile, useAction, useToast } from '../components/ui';
import { R } from '../components/Layout';
import { QtyCell } from './Inventory';
import { DeliveryModal } from './Deliveries';
import type { Profile, Role } from '../lib/types';

export function AdminHome() {
  const nav = useNavigate();
  const products = useProducts(), costs = useCosts(true), settings = useSettings(), upkeep = useUpkeep(), stock = useStock(), shops = useShops();
  const rep = useReport(today(), today(), null);
  const [send, setSend] = useState<{ pid?: string; sid?: string } | null>(null);
  const rate = settings.data?.rate ?? 1, P = products.data ?? [];
  const cost = new Map((costs.data ?? []).map((c) => [c.product_id, c.cost_usd]));
  const m = today().slice(0, 7), upM = sum((upkeep.data ?? []).filter((u) => u.date.startsWith(m)), (u) => u.amount_usd);
  const low = P.filter((p) => p.wh_qty <= p.reorder);
  const byId = new Map(P.map((p) => [p.id, p]));
  const sl = (stock.data ?? []).filter((r) => r.qty <= 5 && byId.has(r.product_id)).sort((a, b) => a.qty - b.qty);
  return (
    <>
      <Head t="Admin dashboard" s={`Exchange rate today: 1 USD = ${fCDF(rate)}`} />
      <div className="kpis">
        <Kpi i="box" l="Store stock at cost"><Dual usd={sum(P, (p) => (cost.get(p.id) ?? 0) * p.wh_qty)} rate={rate} /></Kpi>
        <Kpi i="tag" l="Same stock at selling price"><Dual usd={sum(P, (p) => p.price_usd * p.wh_qty)} rate={rate} /></Kpi>
        <Kpi i="wallet" l="Upkeep this month" tone="warn"><Dual usd={upM} rate={rate} /></Kpi>
        <Kpi i="chart" l="All shops, sales today" tone="ok"><Dual2 b={fUSD(rep.data?.total_usd ?? 0)} s={`${fCDF(rep.data?.total ?? 0)} from ${rep.data?.n ?? 0} invoices`} /></Kpi>
      </div>
      <div className="tiles">
        <Tile i="plus" l="Add new item" onClick={() => nav('/inventory')} /><Tile i="truck" l="Send stock to shops" onClick={() => setSend({})} />
        <Tile i="store" l="Shop stock" onClick={() => nav('/shop-stock')} /><Tile i="chart" l="Sales report" onClick={() => nav('/reports')} /><Tile i="key" l="Create login" onClick={() => nav('/users')} />
      </div>
      <div className="cols">
        <div className="card p0"><div style={{ padding: '16px 16px 0' }}><h3><Icon n="alert" /> Low stock in the store</h3></div>{low.length ? <div className="tw"><table className="t"><thead><tr><th>Item</th><th className="r">In store</th><th className="r">Reorder at</th></tr></thead><tbody>{low.slice(0, 15).map((p) => <tr key={p.id}><td><b>{p.name}</b></td><td className="r"><QtyCell p={p} q={p.wh_qty} cls="bad" /></td><td className="r">{p.reorder}</td></tr>)}</tbody></table></div> : <Empty i="check" t="All items above reorder level" />}</div>
        <div className="card p0"><div style={{ padding: '16px 16px 0' }}><h3><Icon n="store" /> Running low in the shops</h3></div>{sl.length ? <div className="tw"><table className="t"><tbody>{sl.slice(0, 12).map((x) => <tr key={x.shop_id + x.product_id}><td><b>{byId.get(x.product_id)!.name}</b><div className="code">{shops.data?.find((s) => s.id === x.shop_id)?.name}</div></td><td className="r"><span className={`chip ${x.qty > 0 ? 'warn' : 'bad'}`}>{x.qty > 0 ? x.qty + ' left' : x.qty < 0 ? Math.abs(x.qty) + ' sold on order' : 'None left'}</span></td><td><div className="act"><button title="Send to this shop" onClick={() => setSend({ pid: x.product_id, sid: x.shop_id })}><Icon n="truck" /></button></div></td></tr>)}</tbody></table></div> : <Empty i="check" t="Shop stock levels look good" />}</div>
      </div>
      {send ? <DeliveryModal d={null} pid={send.pid} sid={send.sid} onClose={() => setSend(null)} /> : null}
    </>
  );
}

export function Upkeep() {
  const upkeep = useUpkeep(), settings = useSettings(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const [f, setF] = useState({ d: today(), c: UPCATS[0], desc: '', amt: '' });
  const rate = settings.data?.rate ?? 1, m = today().slice(0, 7), list = upkeep.data ?? [], month = list.filter((u) => u.date.startsWith(m));
  const byCat = UPCATS.map((c) => ({ name: c, val: sum(month.filter((u) => u.category === c), (u) => u.amount_usd) })).filter((x) => x.val > 0).map((x) => ({ ...x, txt: fUSD(x.val) }));
  const save = () => a.run(async () => { await rpc('add_upkeep', { p_date: f.d, p_category: f.c, p_desc: f.desc, p_amount: Number(f.amt) }); await refresh('upkeep', 'audit'); setF({ ...f, desc: '', amt: '' }); toast('Expense saved'); });
  return (
    <>
      <Head t="Store upkeep" s="Running costs: rent, fuel, wages, transport. Amounts are entered in USD and shown in Francs too." />
      <div className="kpis"><Kpi i="wallet" l="Total this month" tone="warn"><Dual usd={sum(month, (u) => u.amount_usd)} rate={rate} /></Kpi><Kpi i="receipt" l="Expenses recorded this month"><Dual2 b={month.length} s="entries" /></Kpi></div>
      <div className="cols"><div className="card"><h3><Icon n="plus" /> Record an expense</h3>
        <div className="frow"><div className="field"><label>Date</label><input type="date" className="input" value={f.d} max={today()} onChange={(e) => setF({ ...f, d: e.target.value })} /></div><div className="field"><label>Type</label><select className="input" value={f.c} onChange={(e) => setF({ ...f, c: e.target.value })}>{UPCATS.map((c) => <option key={c}>{c}</option>)}</select></div></div>
        <div className="field"><label>Description</label><input className="input" maxLength={80} value={f.desc} placeholder="e.g. Generator diesel, 200 L" onChange={(e) => setF({ ...f, desc: e.target.value })} /></div>
        <div className="field"><label>Amount (USD)</label><input type="number" min="0" step="0.01" className="input" value={f.amt} onChange={(e) => setF({ ...f, amt: e.target.value })} /><span className="hint">{Number(f.amt) > 0 ? '= ' + fCDF(Number(f.amt) * rate) : ''}</span></div>
        <div className="lerr">{a.err}</div><button className="btn primary full" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Save expense</button></div>
        <div className="card"><h3><Icon n="chart" /> This month by type</h3><HList arr={byCat} /></div></div>
      <div className="card p0"><div className="tw">{list.length ? <table className="t"><thead><tr><th>Date</th><th>Type</th><th>Description</th><th>Amount</th><th>Recorded by</th></tr></thead><tbody>{list.map((u) => <tr key={u.id}><td>{u.date}</td><td><span className="chip">{u.category}</span></td><td>{u.description}</td><td><Dual usd={u.amount_usd} rate={rate} /></td><td>{u.by_name}</td></tr>)}</tbody></table> : <Empty i="wallet" t="No expenses recorded yet" />}</div></div>
    </>
  );
}

const genPw = () => { const a = 'abcdefghjkmnpqrstuvwxyz', d = '23456789', r = (s: string) => s[crypto.getRandomValues(new Uint8Array(1))[0] % s.length]; let s = 'Sim'; for (let i = 0; i < 4; i++) s += r(a); for (let i = 0; i < 4; i++) s += r(d); return s + '!'; };
export function Users() {
  const { profile } = useAuth();
  const users = useUsers(true), shops = useShops(), refresh = useRefresh(), toast = useToast();
  const [open, setOpen] = useState<Profile | 'new' | null>(null), [reset, setReset] = useState<Profile | null>(null), [shown, setShown] = useState<{ u: string; p: string; name: string } | null>(null);
  const toggle = async (u: Profile) => {
    try { await invoke('admin-users', { action: 'set_active', user_id: u.id, active: !u.active }); await refresh('users', 'audit'); toast(u.active ? 'Account disabled. They can no longer sign in.' : 'Account enabled', u.active ? 'warn' : 'ok'); }
    catch (e) { toast((e as Error).message, 'bad'); }
  };
  return (
    <>
      <Head t="Users and logins" s="Create logins for the store operator, shop admins and till operators, reset passwords or disable an account. Only the Admin can do this." a={<button className="btn primary" onClick={() => setOpen('new')}><Icon n="plus" /> Create login</button>} />
      <div className="card p0"><div className="tw"><table className="t"><thead><tr><th>Name</th><th>Username</th><th>Role</th><th>Workplace</th><th>Status</th><th /></tr></thead><tbody>
        {(users.data ?? []).map((u) => <tr key={u.id}><td><b>{u.name}</b></td><td>{u.username}</td><td><span className="chip">{R[u.role]}</span></td><td>{u.shop_id ? shops.data?.find((s) => s.id === u.shop_id)?.name : 'Central store'}</td>
          <td>{u.active ? (u.must_change_password ? <span className="chip warn">Must choose a password</span> : <span className="chip ok">Active</span>) : <span className="chip bad">Disabled</span>}</td>
          <td><div className="act"><button title="Edit name, role or shop" onClick={() => setOpen(u)}><Icon n="edit" /></button><button title="Reset password" onClick={() => setReset(u)}><Icon n="key" /></button>{u.id !== profile!.id ? <button title={u.active ? 'Disable account' : 'Enable account'} onClick={() => void toggle(u)}><Icon n={u.active ? 'lock' : 'unlock'} /></button> : null}</div></td></tr>)}
      </tbody></table></div></div>
      <Note i="shield"><span>What each role can do. <b>Admin</b>: everything, including cost prices, selling prices and piece prices. <b>Warehouse Operator</b>: sees item names, units and quantities, receives stock, sees every shop's stock, and sends and corrects deliveries to the shops, with no cost prices and no price changes. <b>Shop Admin</b>: reviews and approves the till operators' orders, takes the cash and prints, sells directly, discount on an invoice, edits a confirmed invoice, reprints, receives deliveries from the store and sees reports. <b>Till Operator</b>: types the customer name, picks the items and sends the order to the shop admin for approval; no cash, no invoice list and no reports.</span></Note>
      <Note><span>Passwords are stored only as secure hashes by Supabase Auth; nobody, not even the Admin, can read them. A new or reset login must choose its own password at first sign-in. The screen locks after 15 minutes without activity.</span></Note>
      {open ? <UserModal u={open === 'new' ? null : open} onClose={() => setOpen(null)} onCreated={(x) => setShown(x)} /> : null}
      {reset ? <ResetModal u={reset} onClose={() => setReset(null)} onDone={(p) => setShown({ u: reset.username, p, name: reset.name })} /> : null}
      {shown ? <Modal title="Give these details" icon="check" onClose={() => setShown(null)} foot={<button className="btn primary" onClick={() => setShown(null)}>Done</button>}><p>Give these details to <b>{shown.name}</b>. The password will not be shown again; they choose their own at first sign-in.</p><div className="card" style={{ fontSize: 18, margin: 0 }}><div>Username: <b>{shown.u}</b></div><div>Password: <b>{shown.p}</b></div></div></Modal> : null}
    </>
  );
}
function UserModal({ u, onClose, onCreated }: { u: Profile | null; onClose: () => void; onCreated: (x: { u: string; p: string; name: string }) => void }) {
  const shops = useShops(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const [f, setF] = useState({ name: u?.name ?? '', username: u?.username ?? '', password: u ? '' : genPw(), role: (u?.role ?? 'till') as Role, shop: u?.shop_id ?? '' });
  const needShop = f.role === 'shopadmin' || f.role === 'till';
  const save = () => a.run(async () => {
    const shop_id = needShop ? f.shop || shops.data?.[0]?.id : null;
    if (u) { await invoke('admin-users', { action: 'update', user_id: u.id, name: f.name, role: f.role, shop_id }); await refresh('users', 'audit'); toast('Login updated'); onClose(); return; }
    await invoke('admin-users', { action: 'create', name: f.name, username: f.username, password: f.password, role: f.role, shop_id });
    await refresh('users', 'audit'); onClose(); onCreated({ u: f.username.trim().toLowerCase(), p: f.password, name: f.name });
  });
  return (
    <Modal title={u ? 'Edit login ' + u.username : 'Create login'} icon="key" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> {u ? 'Save' : 'Create login'}</button></>}>
      <div className="field"><label>Full name</label><input id="un" className="input" maxLength={50} value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} autoFocus /></div>
      {u ? null : <div className="frow"><div className="field"><label>Username</label><input id="uu" className="input" autoCapitalize="off" spellCheck={false} maxLength={30} placeholder="e.g. till.gombe2" value={f.username} onChange={(e) => setF({ ...f, username: e.target.value })} /></div>
        <div className="field"><label>First password</label><div style={{ display: 'flex', gap: 8 }}><input id="up" className="input" maxLength={72} value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} /><button className="btn ghost" title="Make a password" onClick={() => setF({ ...f, password: genPw() })}><Icon n="refresh" /></button></div><span className="hint">10+ characters with letters and numbers. They change it at first sign-in.</span></div></div>}
      <div className="frow"><div className="field"><label>Role</label><select id="ur" className="input" value={f.role} onChange={(e) => setF({ ...f, role: e.target.value as Role })}><option value="till">Till Operator</option><option value="shopadmin">Shop Admin</option><option value="whop">Warehouse Operator</option><option value="admin">Admin</option></select></div>
        {needShop ? <div className="field"><label>Shop</label><select id="us" className="input" value={f.shop || shops.data?.[0]?.id} onChange={(e) => setF({ ...f, shop: e.target.value })}>{(shops.data ?? []).filter((s) => s.active).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></div> : null}</div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}
function ResetModal({ u, onClose, onDone }: { u: Profile; onClose: () => void; onDone: (p: string) => void }) {
  const refresh = useRefresh(), a = useAction();
  const [p, setP] = useState(genPw());
  const save = () => a.run(async () => { await invoke('admin-users', { action: 'reset_password', user_id: u.id, password: p }); await refresh('users', 'audit'); onClose(); onDone(p); });
  return (
    <Modal title="Reset password" icon="key" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Reset password</button></>}>
      <p>New first password for <b>{u.name}</b> ({u.username}). They choose their own at the next sign-in.</p>
      <div className="field"><label>New password</label><div style={{ display: 'flex', gap: 8 }}><input className="input" value={p} maxLength={72} onChange={(e) => setP(e.target.value)} /><button className="btn ghost" onClick={() => setP(genPw())}><Icon n="refresh" /></button></div></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

export function SettingsPage() {
  const settings = useSettings(), shops = useShops(), refresh = useRefresh(), toast = useToast(), a = useAction(), b = useAction();
  const s = settings.data;
  const [f, setF] = useState<Record<string, string> | null>(null);
  const v = f ?? (s ? { rate: String(s.rate), vat: String(s.vat), ...Object.fromEntries(['name', 'phone', 'address', 'email', 'rccm', 'idnat', 'nif', 'footer'].map((k) => [k, String((s.company as Record<string, string>)[k] ?? '')])) } : null);
  const [shop, setShop] = useState({ name: '', code: '', address: '' });
  if (!v) return <Empty i="refresh" t="Loading" tall />;
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...v, [k]: e.target.value });
  const fld = (k: string, l: string) => <div className="field"><label htmlFor={'s-' + k}>{l}</label><input id={'s-' + k} className="input" maxLength={80} value={v[k]} onChange={set(k)} /></div>;
  const save = () => a.run(async () => {
    await rpc('save_settings', { p: { rate: Number(v.rate), vat: Number(v.vat), company: { name: v.name, phone: v.phone, address: v.address, email: v.email, rccm: v.rccm, idnat: v.idnat, nif: v.nif, footer: v.footer } } });
    await refresh('settings', 'audit'); setF(null); toast('Settings saved');
  });
  const addShop = () => b.run(async () => { await rpc('save_shop', { p: shop }); await refresh('shops', 'stock', 'audit'); setShop({ name: '', code: '', address: '' }); toast('Shop added'); });
  return (
    <>
      <Head t="Settings" s="Company details appear on every customer invoice. The exchange rate sets every shop price in Francs." />
      <div className="cols"><div className="card"><h3><Icon n="exchange" /> Currency and tax</h3>
        <div className="frow"><div className="field"><label htmlFor="srate">1 USD in Congolese Francs</label><input id="srate" type="number" min="1" className="input" value={v.rate} onChange={set('rate')} /></div><div className="field"><label>VAT (TVA) %</label><input type="number" min="0" max="30" className="input" value={v.vat} onChange={set('vat')} /></div></div>
        <Note>Shop price = selling price in USD × rate, rounded to the nearest 10 FC. Changing the rate reprices every shop at once; past invoices keep the rate of their sale. Customer invoices show Francs only.</Note></div>
        <div className="card"><h3><Icon n="store" /> Shops</h3><table className="t"><tbody>{(shops.data ?? []).map((x) => <tr key={x.id}><td><b>{x.name}</b><div className="code">{x.code}, {x.address}</div></td></tr>)}</tbody></table>
          <div className="frow" style={{ marginTop: 12 }}><div className="field"><label>New shop name</label><input className="input" maxLength={40} value={shop.name} onChange={(e) => setShop({ ...shop, name: e.target.value })} /></div><div className="field"><label>Short code (3 letters)</label><input className="input" maxLength={3} style={{ textTransform: 'uppercase' }} value={shop.code} onChange={(e) => setShop({ ...shop, code: e.target.value.toUpperCase() })} /></div></div>
          <div className="field"><label>Address</label><input className="input" maxLength={80} value={shop.address} onChange={(e) => setShop({ ...shop, address: e.target.value })} /></div><div className="lerr">{b.err}</div><button className="btn ghost full" disabled={b.busy} onClick={() => void addShop()}><Icon n="plus" /> Add shop</button></div></div>
      <div className="card"><h3><Icon n="receipt" /> Company details on invoices</h3>
        <div className="frow">{fld('name', 'Company name')}{fld('phone', 'Phone')}</div><div className="frow">{fld('address', 'Head office address')}{fld('email', 'Email')}</div>
        <div className="frow">{fld('rccm', 'RCCM number')}{fld('idnat', 'ID NAT')}</div><div className="frow">{fld('nif', 'NIF (tax number)')}{fld('footer', 'Message at the bottom of invoices')}</div>
        <div className="lerr">{a.err}</div><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Save settings</button></div>
    </>
  );
}

export function Activity() {
  const audit = useAudit();
  const list = useMemo(() => audit.data ?? [], [audit.data]);
  return (
    <>
      <Head t="Activity log" s="Every sign-in step, price change, delivery, sale, invoice edit, reprint and login change." />
      <div className="card p0"><div className="tw">{list.length ? <table className="t"><thead><tr><th>When</th><th>User</th><th>What happened</th></tr></thead><tbody>{list.map((x) => <tr key={x.id}><td style={{ whiteSpace: 'nowrap' }}>{dt(x.at)}</td><td>{x.username}</td><td>{/Disabled|denied/.test(x.action) ? <span className="chip bad">{x.action}</span> : x.action}</td></tr>)}</tbody></table> : <Empty i="shield" t={audit.isLoading ? 'Loading' : 'Nothing recorded yet'} />}</div></div>
    </>
  );
}
