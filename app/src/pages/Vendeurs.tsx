// Vendeurs: resellers who take goods on credit from a shop. The Shop Admin keeps them (credit period, credit limit),
// takes their payments, gives promo items from the stock and keeps or settles the monthly promo report.
// The goods on credit themselves are sold at the till ("On credit"). Everything here needs the connection.
import { useEffect, useMemo, useState } from 'react';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { usePromoReport, useProducts, useRefresh, useSettings, useShops, useStock, useVendeurs } from '../data/queries';
import { rpc } from '../lib/supabase';
import { getDevice } from '../offline/store';
import { pcValue } from '../lib/units';
import { bookRate, dt, fCDF, fUSD, ld, sum, toCDF, today } from '../lib/format';
import { printHTML, promoReportHTML, vendeurPaymentHTML, vendeurStatementHTML } from '../lib/print';
import { Dual2, Empty, Head, Kpi, Modal, Note, num, useAction, useToast } from '../components/ui';
import { creditWarnings, ddmm, vendeurPayment } from '../lib/vendeurs';
import type { Product, PromoData, PromoReport, Vendeur, VendeurPaid, VendeurState, VendeurStatement } from '../lib/types';

const monthOf = (d: string) => d.slice(0, 7) + '-01';
const monthName = (m: string) => new Date(m + 'T00:00:00').toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
const prevMonth = (m: string) => { const d = new Date(m + 'T00:00:00'); d.setMonth(d.getMonth() - 1); return ld(d).slice(0, 7) + '-01'; };

/** Where a vendeur stands: overdue (with how much and since when), over the limit, or fine. */
export function VendeurChips({ v }: { v: VendeurState }) {
  return (<>
    {v.overdue ? <span className="chip bad"><Icon n="alert" /> Overdue {v.days_overdue} day{v.days_overdue === 1 ? '' : 's'}: {fUSD(v.overdue_amount)}</span> : null}
    {v.over_limit ? <span className="chip warn"><Icon n="alert" /> Over the limit by {fUSD(-v.available)}</span> : null}
    {!v.overdue && !v.over_limit ? (v.balance > 0 ? <span className="chip">Next due {v.oldest_due ? ddmm(v.oldest_due) : '-'}</span> : <span className="chip ok"><Icon n="check" /> Nothing owed</span>) : null}
  </>);
}

/** Promo items picked from the shop's stock: search, then type how many pcs (or sets). Valued at the shop price. */
export function PromoPicker({ products, stockOf, rate, lines, setLines }: { products: Product[]; stockOf: (id: string) => number; rate: number; lines: Record<string, string>; setLines: (l: Record<string, string>) => void }) {
  const [q, setQ] = useState('');
  const ql = q.trim().toLowerCase();
  const picked = products.filter((p) => (parseInt(lines[p.id]) || 0) > 0);
  const shown = ql ? products.filter((p) => !lines[p.id] && (p.name + ' ' + p.sku + ' ' + p.category).toLowerCase().includes(ql) && stockOf(p.id) > 0).slice(0, 8) : [];
  const value = sum(picked, (p) => (parseInt(lines[p.id]) || 0) * toCDF(pcValue(p), rate));
  return (
    <div className="promopick">
      <div className="search"><Icon n="search" /><input id="promoq" placeholder="Add a promo item: type its name" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search promo items" /></div>
      {shown.length ? <div className="tw"><table className="t" style={{ fontSize: 13.5 }}><tbody>{shown.map((p) => <tr key={p.id}><td><b>{p.name}</b><div className="code">{stockOf(p.id)} {p.stock_unit} in the shop · {fCDF(toCDF(pcValue(p), rate))} per {p.is_bundle ? 'set' : 'pc'}</div></td>
        <td className="r"><button className="btn sm" onClick={() => { setLines({ ...lines, [p.id]: '1' }); setQ(''); }}><Icon n="plus" /> Add</button></td></tr>)}</tbody></table></div> : ql ? <div className="hint">No item in the shop's stock matches</div> : null}
      {Object.keys(lines).length ? <div className="tw" style={{ marginTop: 8 }}><table className="t" style={{ fontSize: 13.5 }}><thead><tr><th>Promo item</th><th className="r">Qty</th><th className="r">Value</th><th /></tr></thead><tbody>
        {products.filter((p) => p.id in lines).map((p) => { const n = parseInt(lines[p.id]) || 0, over = n > stockOf(p.id); return <tr key={p.id}><td><b>{p.name}</b><div className={`code ${over ? 'bad' : ''}`}>{stockOf(p.id)} {p.stock_unit} in the shop{over ? ', not enough' : ''}</div></td>
          <td className="r" style={{ width: 110 }}><input className="input" type="number" min="1" step="1" value={lines[p.id]} aria-label={`Promo quantity of ${p.name}`} onChange={(e) => setLines({ ...lines, [p.id]: e.target.value })} style={{ width: 90, textAlign: 'right' }} /><div className="code">{p.stock_unit}</div></td>
          <td className="r nw">{fCDF(n * toCDF(pcValue(p), rate))}</td>
          <td style={{ width: 1 }}><button className="iconbtn" title="Remove" aria-label={`Remove ${p.name}`} onClick={() => { const x = { ...lines }; delete x[p.id]; setLines(x); }}><Icon n="x" /></button></td></tr>; })}
        <tr><td colSpan={2}><b>Promo value, not invoiced</b></td><td className="r nw"><b>{fCDF(value)}</b></td><td /></tr></tbody></table></div> : null}
    </div>
  );
}
export const promoLines = (lines: Record<string, string>) => Object.entries(lines).map(([product_id, q]) => ({ product_id, qty: parseInt(q) || 0 })).filter((l) => l.qty > 0);

/** Deleting a vendeur: one created by mistake (nothing recorded) goes completely; one with goods, payments or promos is
 *  kept and made inactive, once it owes nothing. True when it was deleted or made inactive. */
async function deleteVendeur(v: Vendeur, toast: (m: string, t?: 'ok' | 'bad' | 'warn') => void, refresh: (...k: string[]) => Promise<unknown>) {
  const used = Math.abs(v.balance - Number(v.opening_value_usd ?? 0)) > 0.004 || !!v.last_payment || v.promo_open_n > 0 || v.open.some((o) => o.invoice_id);
  if (!confirm(used
    ? `${v.name} has goods, payments or promo items recorded, so it cannot be deleted: it is made inactive instead and keeps its history${v.balance > 0 ? ` (it still owes ${fUSD(v.balance)}: take the payment first)` : ''}. Go on?`
    : `Delete vendeur ${v.name}? Nothing was recorded for this vendeur, so it is removed completely${Number(v.opening_value_usd) ? `, with the ${fUSD(Number(v.opening_value_usd))} it was entered as owing` : ''}.`)) return false;
  try {
    const r = await rpc<string>('delete_vendeur', { p_id: v.id });
    await refresh('vendeurs', 'audit');
    toast(r === 'deleted' ? `Vendeur ${v.name} deleted` : `${v.name} made inactive; its history is kept`, r === 'deleted' ? 'ok' : 'warn');
    return true;
  } catch (e) { toast((e as Error).message, 'bad'); return false; }
}

export default function Vendeurs() {
  const { profile } = useAuth();
  const vend = useVendeurs(), shops = useShops(), refresh = useRefresh(), toast = useToast();
  const removeVendeur = (v: Vendeur) => deleteVendeur(v, toast, refresh);
  const [q, setQ] = useState(''), [showOff, setShowOff] = useState(false);
  const [edit, setEdit] = useState<Vendeur | 'new' | null>(null), [pay, setPay] = useState<Vendeur | null>(null), [promo, setPromo] = useState<Vendeur | null>(null);
  const [stmt, setStmt] = useState<Vendeur | null>(null), [report, setReport] = useState<string | null>(null);
  const thisMonth = monthOf(today());
  const rep = usePromoReport(thisMonth);
  const all = vend.data ?? [], ql = q.trim().toLowerCase();
  const list = all.filter((v) => (showOff || v.active) && (!ql || (v.name + ' ' + v.phone + ' ' + v.address).toLowerCase().includes(ql)));
  const owed = sum(all, (v) => v.balance), overdue = all.filter((v) => v.overdue), promoOpen = sum(all, (v) => v.promo_open);
  // the month-end reminder: open promo items from a month that is over
  const last = prevMonth(thisMonth), oldest = rep.data?.oldest_open, due = !!oldest && oldest < thisMonth;
  const keptLast = rep.data?.reports.find((r) => r.month === monthOf(oldest ?? last) && r.status === 'kept');
  const shopName = shops.data?.find((s) => s.id === profile!.shop_id)?.name ?? '';
  return (
    <>
      <Head t="Vendeurs" s="Resellers who take goods on credit. Give the goods at the till with On credit; take payments, give promo items and see statements here."
        a={<><button className="btn ghost" id="promorep" onClick={() => setReport(due ? monthOf(oldest!) : thisMonth)}><Icon n="gift" /> Promo report</button>
          <button className="btn primary" id="addvend" onClick={() => setEdit('new')}><Icon n="plus" /> Add vendeur</button></>} />
      {due ? <Note i="calendar" warn style={{ marginBottom: 12 }}><b>The promo report of {monthName(monthOf(oldest!))} is ready.</b> {keptLast ? 'It was kept, not settled: its promo items are still counted.' : 'Keep it, or settle it to start the promo count again at zero.'}{' '}
        <button className="linkbtn" onClick={() => setReport(monthOf(oldest!))}>Open the report</button></Note> : null}
      <div className="kpis">
        <Kpi i="wallet" l="Owed by vendeurs" tone={owed > 0 ? 'warn' : 'ok'}><Dual2 b={fUSD(owed)} s={`${all.filter((v) => v.balance > 0).length} of ${all.filter((v) => v.active).length} vendeurs`} /></Kpi>
        <Kpi i="alert" l="Payments overdue" tone={overdue.length ? 'bad' : ''}><Dual2 b={fUSD(sum(overdue, (v) => v.overdue_amount))} s={`${overdue.length} vendeur${overdue.length === 1 ? '' : 's'}`} /></Kpi>
        <Kpi i="gift" l="Promo items open"><Dual2 b={fCDF(promoOpen)} s="at the shop price, not invoiced" /></Kpi>
      </div>
      <div className="toolbar"><div className="search"><Icon n="search" /><input placeholder="Search vendeurs by name or phone" value={q} onChange={(e) => setQ(e.target.value)} /></div>
        <span className="chip">{list.length} vendeurs</span>
        {all.some((v) => !v.active) ? <label className="switch" style={{ margin: 0 }}><input type="checkbox" checked={showOff} onChange={(e) => setShowOff(e.target.checked)} /><span>Show inactive</span></label> : null}</div>
      <div className="card p0"><div className="tw">
        {vend.isLoading ? <Empty i="refresh" t="Loading vendeurs" /> : vend.error ? <Empty i="wifioff" t={(vend.error as Error).message} /> : !list.length ? <Empty i="users" t={all.length ? 'No vendeur matches' : 'No vendeurs yet. Add one to give goods on credit.'} /> :
          <table className="t" id="vendlist"><thead><tr><th>Vendeur</th><th className="r">Owed</th><th className="r">Credit left</th><th>Payment</th><th className="r">Promo open</th><th /></tr></thead><tbody>
            {list.map((v) => <tr key={v.id} data-find={v.name}>
              <td style={{ minWidth: 190 }}><b>{v.name}</b>{v.active ? null : <> <span className="chip">Inactive</span></>}<div className="code">{v.phone ? v.phone + ' · ' : ''}credit {v.credit_days} days, limit {fUSD(v.credit_limit_usd)}</div></td>
              <td className="r nw"><b>{fUSD(v.balance)}</b>{v.last_payment ? <div className="code">paid {fUSD(v.last_payment.amount)}, {dt(v.last_payment.at)}</div> : null}</td>
              <td className={`r nw ${v.available < 0 ? 'bad' : ''}`}>{fUSD(v.available)}</td>
              <td><div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}><VendeurChips v={v} /></div></td>
              <td className="r nw">{v.promo_open ? <>{fCDF(v.promo_open)}<div className="code">{v.promo_open_n} given</div></> : '-'}</td>
              <td><div className="act">
                <button title="Take a payment" aria-label={`Take a payment from ${v.name}`} disabled={v.balance <= 0} onClick={() => setPay(v)}><Icon n="cash" /></button>
                <button title="Give promo items" aria-label={`Give promo items to ${v.name}`} disabled={!v.active} onClick={() => setPromo(v)}><Icon n="gift" /></button>
                <button title="Statement" aria-label={`Statement of ${v.name}`} onClick={() => setStmt(v)}><Icon n="doc" /></button>
                <button title="Edit" aria-label={`Edit ${v.name}`} onClick={() => setEdit(v)}><Icon n="edit" /></button>
                <button title="Delete vendeur" aria-label={`Delete ${v.name}`} onClick={() => void removeVendeur(v)}><Icon n="trash" /></button></div></td>
            </tr>)}
          </tbody></table>}
      </div></div>
      <Note i="cart" style={{ marginTop: 12 }}>To give goods on credit, open the <b>Till</b>, add the items and press <b>On credit</b>. Goods can still be given when a vendeur is overdue or over the limit: the till warns first.</Note>
      {edit ? <VendeurForm v={edit === 'new' ? null : edit} onClose={() => setEdit(null)} /> : null}
      {pay ? <PayModal v={pay} onClose={() => setPay(null)} /> : null}
      {promo ? <PromoModal v={promo} onClose={() => setPromo(null)} /> : null}
      {stmt ? <StatementModal v={stmt} onClose={() => setStmt(null)} /> : null}
      {report ? <PromoReportModal month={report} shopName={shopName} onClose={() => { setReport(null); void refresh('vendeurs'); }} /> : null}
    </>
  );
}

function VendeurForm({ v, onClose }: { v: Vendeur | null; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction(), b = useAction(), book = bookRate(useSettings().data);
  // what is owed from before, in USD: dollars, and Francs at a taux (a vendeur saved before owed Francs only)
  const oc0 = v ? (v.opening_cdf ?? (v.opening_usd ? 0 : v.opening_balance)) : 0;
  const [f, setF] = useState({ name: v?.name ?? '', phone: v?.phone ?? '', address: v?.address ?? '', notes: v?.notes ?? '', credit_days: String(v?.credit_days ?? 30),
    credit_limit_usd: v?.credit_limit_usd ? String(v.credit_limit_usd) : '', opening_cdf: oc0 ? String(oc0) : '', opening_usd: v?.opening_usd ? String(v.opening_usd) : '', active: v?.active ?? true });
  const [typedRate, setRate] = useState<string | null>(oc0 && v?.opening_rate ? String(v.opening_rate) : null);
  const orate = Number(typedRate ?? book) || 0, ou = Math.round((num(f.opening_usd) || 0) * 100) / 100, oc = num(f.opening_cdf) || 0;
  const obUsd = Math.round((ou + (oc > 0 && orate > 0 ? oc / orate : 0)) * 100) / 100, rateOff = oc > 0 && (orate < book / 2 || orate > book * 2);
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  const save = () => a.run(async () => {
    if (!f.name.trim()) throw new Error('Enter the vendeur name');
    const lim = num(f.credit_limit_usd), days = num(f.credit_days);
    if (!(lim > 0)) throw new Error('Enter the credit limit in USD');
    if (!(days >= 0 && days <= 365) || days % 1) throw new Error('Credit period must be 0 to 365 days');
    if (oc < 0 || oc % 1 || ou < 0) throw new Error('Opening balance must be a whole amount of 0 or more');
    if (rateOff) throw new Error(`Check the rate: ${fCDF(orate)} is far from the internal rate (${fCDF(book)})`);
    await rpc('save_vendeur', { p: { id: v?.id ?? null, name: f.name, phone: f.phone, address: f.address, notes: f.notes, active: f.active, credit_limit_usd: lim, credit_days: days,
      opening_cdf: oc, opening_usd: ou, opening_rate: oc > 0 ? orate : null } });
    await refresh('vendeurs', 'audit'); toast(v ? 'Vendeur saved' : `Vendeur ${f.name.trim()} added`); onClose();
  });
  const del = () => b.run(async () => { if (v && await deleteVendeur(v, toast, refresh)) onClose(); });
  return (
    <Modal title={v ? `Edit vendeur ${v.name}` : 'Add vendeur'} icon="user" onClose={onClose} foot={<>{v ? <button className="btn danger" disabled={b.busy} onClick={() => void del()}><Icon n="trash" /> Delete vendeur</button> : null}<span className="sp" /><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" id="vsave" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Save vendeur</button></>}>
      <div className="field"><label htmlFor="vname">Name of the vendeur</label><input id="vname" className="input" maxLength={40} value={f.name} onChange={set('name')} autoFocus /></div>
      <div className="frow"><div className="field"><label htmlFor="vdays">Credit period (days)</label><input id="vdays" className="input" type="number" min="0" max="365" step="1" value={f.credit_days} onChange={set('credit_days')} /><span className="hint">Goods given are due after this many days</span></div>
        <div className="field"><label htmlFor="vlim">Credit limit (USD)</label><input id="vlim" className="input" type="number" min="1" step="0.01" value={f.credit_limit_usd} onChange={set('credit_limit_usd')} /><span className="hint">The most the vendeur should owe at once, in dollars. Payments bring the credit back.</span></div></div>
      <div className="frow"><div className="field"><label htmlFor="vphone">Phone</label><input id="vphone" className="input" maxLength={30} value={f.phone} onChange={set('phone')} /></div>
      </div>
      <div className="card" style={{ background: 'var(--bg)', padding: 12, marginBottom: 12 }} id="vopening"><b>Already owes</b> <span className="code">what the vendeur owed before QuickSales, if anything: in USD, CDF or both</span>
        <div className="frow" style={{ marginTop: 8 }}>
          <div className="field"><label htmlFor="vobusd">USD</label><input id="vobusd" className="input" type="number" min="0" step="0.01" value={f.opening_usd} placeholder="0" onChange={set('opening_usd')} /></div>
          <div className="field"><label htmlFor="vob">CDF</label><input id="vob" className="input" type="number" min="0" step="1" value={f.opening_cdf} placeholder="0" onChange={set('opening_cdf')} /></div>
          {oc > 0 ? <div className="field"><label htmlFor="vobrate">Taux: 1 USD in CDF{typedRate !== null && Number(typedRate) !== book ? <span className="chip warn" style={{ marginLeft: 6 }}>typed by hand</span> : null}</label>
            <input id="vobrate" className="input" type="number" min="1" step="1" value={typedRate ?? String(book)} onChange={(e) => setRate(e.target.value)} />
            <span className="hint">{typedRate !== null && Number(typedRate) !== book ? <button type="button" className="linkbtn" onClick={() => setRate(null)}>Use the internal rate ({fCDF(book)})</button> : 'The internal rate, as for payments in Francs'}</span></div> : null}
        </div>
        {obUsd > 0 ? <div className={rateOff ? 'lerr' : 'code'} style={{ marginTop: 2 }}>{rateOff ? `Check the rate: ${fCDF(orate)} is far from the internal rate (${fCDF(book)})` : <>Owes from before: <b>{fUSD(obUsd)}</b>{oc > 0 ? ` (${ou ? fUSD(ou) + ' + ' : ''}${fCDF(oc)} at ${orate})` : ''}</>}</div> : null}
      </div>
      <div className="field"><label htmlFor="vaddr">Address</label><input id="vaddr" className="input" maxLength={80} value={f.address} onChange={set('address')} /></div>
      <div className="field"><label htmlFor="vnotes">Notes</label><input id="vnotes" className="input" maxLength={200} value={f.notes} onChange={set('notes')} /></div>
      {v ? <label className="switch"><input type="checkbox" checked={f.active} onChange={set('active')} /><span>Active: goods can be given to this vendeur</span></label> : null}
      <div className="lerr">{a.err || b.err}</div>
    </Modal>
  );
}

/** A vendeur's payment off what they owe in USD: dollars count one for one, Francs at the taux (the internal rate unless
 *  the Shop Admin types the one agreed). Dollars worth more than is owed get the rest back in Francs. */
function PayModal({ v, onClose }: { v: Vendeur; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction(), settings = useSettings(), shops = useShops();
  const book = bookRate(settings.data);
  const [cdf, setCdf] = useState(''), [usd, setUsd] = useState(''), [typedRate, setRate] = useState<string | null>(null), [note, setNote] = useState(''), [print, setPrint] = useState(true);
  const rate = typedRate ?? String(book);
  const P = vendeurPayment(v.balance, usd, cdf, rate, book), any = P.value > 0;
  const go = () => a.run(async () => {
    if (!any) throw new Error('Enter the amount paid, in USD or CDF');
    if (P.err) throw new Error(P.err);
    // the till this is taken on, so that till's own shift end report counts it too
    const dev = await getDevice(v.shop_id);
    const r = await rpc<VendeurPaid>('vendeur_pay', { p: { vendeur_id: v.id, paid_cdf: P.cdf, paid_usd: P.usd, rate: P.rate, note, device_id: dev?.id ?? null } });
    const shop = shops.data?.find((s) => s.id === v.shop_id);
    if (print && shop) printHTML(vendeurPaymentHTML(r, settings.data?.company ?? {}, shop));
    await refresh('vendeurs', 'audit', 'report');
    toast(`Payment ${r.no} from ${v.name}: ${fUSD(r.amount)}${r.change_cdf ? `, give back ${fCDF(r.change_cdf)}` : ''}. ${r.state.balance > 0 ? `Still owes ${fUSD(r.state.balance)}.` : 'Nothing left to pay.'}`); onClose();
  });
  const enter = (e: React.KeyboardEvent) => { if (e.key === 'Enter') { e.preventDefault(); void go(); } };
  return (
    <Modal title={`Payment from ${v.name}`} icon="cash" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" id="vpay" disabled={a.busy || !any || !!P.err} onClick={() => void go()}><Icon n="check" /> Take payment</button></>}>
      <div className="kpis"><Kpi i="wallet" l="Owes" tone="warn"><Dual2 b={fUSD(v.balance)} s={`${P.rate > 0 ? `≈ ${fCDF(P.allCdf)} at ${P.rate} · ` : ''}limit ${fUSD(v.credit_limit_usd)}`} /></Kpi>{v.overdue ? <Kpi i="alert" l="Overdue" tone="bad"><Dual2 b={fUSD(v.overdue_amount)} s={`${v.days_overdue} days`} /></Kpi> : null}</div>
      {v.open.length ? <div className="tw" style={{ marginBottom: 12 }}><table className="t" style={{ fontSize: 13.5 }}><thead><tr><th>Goods</th><th>Due</th><th className="r">Still owed</th></tr></thead><tbody>
        {v.open.map((o) => <tr key={o.no}><td>{o.no}<div className="code">{ddmm(o.date)}, {fUSD(o.amount)}</div></td><td>{o.days_overdue ? <span className="chip bad">{ddmm(o.due)}, {o.days_overdue} days late</span> : ddmm(o.due)}</td><td className="r">{fUSD(o.owed)}</td></tr>)}</tbody></table></div> : null}
      <div className="frow">
        <div className="field"><label htmlFor="vusd">USD received</label><input id="vusd" className="input" type="number" min="0" step="1" inputMode="decimal" value={usd} onChange={(e) => setUsd(e.target.value)} onKeyDown={enter} placeholder="0" autoFocus /></div>
        <div className="field"><label htmlFor="vamt">CDF received</label><input id="vamt" className="input" type="number" min="0" step="50" inputMode="numeric" value={cdf} onChange={(e) => setCdf(e.target.value)} onKeyDown={enter} placeholder="0" /></div>
      </div>
      <div className="cnotes">
        {P.allUsd > 0 ? <button type="button" className={!cdf && P.usd === P.allUsd ? 'on' : ''} onClick={() => { setUsd(String(P.allUsd)); setCdf(''); }}>All in USD: ${P.allUsd}</button> : null}
        {P.allCdf > 0 ? <button type="button" className={!usd && P.cdf === P.allCdf ? 'on' : ''} onClick={() => { setCdf(String(P.allCdf)); setUsd(''); }}>All in CDF: {fCDF(P.allCdf)}</button> : null}
      </div>
      <div className="field"><label htmlFor="vrate">Taux for the Francs: 1 USD in CDF{P.typed ? <span className="chip warn" style={{ marginLeft: 6 }}>typed by hand</span> : null}</label>
        <input id="vrate" className="input" type="number" min="1" step="1" inputMode="decimal" value={rate} onChange={(e) => setRate(e.target.value)} onKeyDown={enter} />
        <span className="hint">{Number(rate) !== book
          ? <>The internal rate is {fCDF(book)}. <button type="button" className="linkbtn" onClick={() => setRate(null)}>Use the internal rate</button></>
          : 'The internal rate. Type the taux agreed with the vendeur if it is different. Dollars count one for one.'}</span></div>
      <div id="vpaysum" className={`paychange ${!any ? '' : P.err ? 'bad' : 'ok'}`}>
        <span>{!any ? 'Paid' : P.err ? 'Check the payment' : P.change ? 'Change to give' : 'Paid'}</span>
        <b>{!any ? '-' : P.err ? '' : P.change ? fCDF(P.change) : fUSD(P.amount)}</b></div>
      {any && P.err ? <Note warn i="alert">{P.err}</Note> : null}
      {any && !P.err ? <Note i="check">{P.cdf > 0 ? <>{fCDF(P.cdf)} at {P.rate} = <b>{fUSD(Math.round((P.cdf / P.rate) * 100) / 100)}</b>{P.usd > 0 ? <> + {fUSD(P.usd)}</> : null}. </> : null}{P.change ? <>{fUSD(P.amount)} off the debt. </> : null}
        {P.after > 0 ? <>After this payment {v.name} owes {fUSD(P.after)}; credit left {fUSD(v.available + P.amount)}.</> : <>{v.name} has nothing left to pay.</>} The oldest goods are paid first.</Note> : null}
      <div className="field"><label htmlFor="vnote">Note</label><input id="vnote" className="input" maxLength={120} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Optional" /></div>
      <label className="switch"><input type="checkbox" checked={print} onChange={(e) => setPrint(e.target.checked)} /><span>Print a receipt for the vendeur</span></label>
      <Note>Francs go into the shop's cash, dollars into its USD cash; both show on the shift end report.</Note>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

function PromoModal({ v, onClose }: { v: Vendeur; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction(), settings = useSettings(), products = useProducts(), stock = useStock(v.shop_id);
  const [lines, setLines] = useState<Record<string, string>>({}), [note, setNote] = useState('');
  const at = useMemo(() => new Map((stock.data ?? []).map((r) => [r.product_id, r.qty])), [stock.data]);
  const live = (products.data ?? []).filter((p) => p.active);
  const go = () => a.run(async () => {
    const l = promoLines(lines);
    if (!l.length) throw new Error('Add the promo items');
    const r = await rpc<{ no: string; value: number }>('give_promo', { p: { vendeur_id: v.id, lines: l, note } });
    await refresh('vendeurs', 'stock', 'audit'); toast(`Promo ${r.no} for ${v.name}: ${fCDF(r.value)} of items, not invoiced`); onClose();
  });
  return (
    <Modal title={`Promo items for ${v.name}`} icon="gift" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" id="vpromo" disabled={a.busy} onClick={() => void go()}><Icon n="check" /> Give promo items</button></>}>
      <Note i="gift">Promo items are given free: they leave the shop's stock but are not on an invoice and the vendeur does not owe them. They add up in the monthly promo report. To give them with goods on credit, use On credit at the till.</Note>
      <PromoPicker products={live} stockOf={(id) => at.get(id) ?? 0} rate={settings.data?.rate ?? 0} lines={lines} setLines={setLines} />
      <div className="field" style={{ marginTop: 10 }}><label htmlFor="pnote">Note</label><input id="pnote" className="input" maxLength={120} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Optional, for example the offer" /></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

function StatementModal({ v, onClose }: { v: Vendeur; onClose: () => void }) {
  const { profile } = useAuth(), refresh = useRefresh(), toast = useToast(), a = useAction(), settings = useSettings();
  const [from, setFrom] = useState(ld(Date.now() - 90 * 864e5)), [to, setTo] = useState(today()), [st, setSt] = useState<VendeurStatement | null>(null), [tick, setTick] = useState(0);
  useEffect(() => { void a.run(async () => setSt(await rpc<VendeurStatement>('vendeur_statement', { p_id: v.id, p_from: from, p_to: to }))); }, [v.id, from, to, tick]); // eslint-disable-line react-hooks/exhaustive-deps
  const cancelPay = (id: string, no: string) => { const r = prompt(`Cancel payment ${no}? Write the reason:`); if (!r) return; void a.run(async () => { await rpc('cancel_vendeur_payment', { p_id: id, p_reason: r }); await refresh('vendeurs', 'audit', 'report'); toast(`Payment ${no} cancelled`, 'warn'); setTick((x) => x + 1); }); };
  const cancelPromo = (id: string, no: string) => { const r = prompt(`Cancel promo ${no}? Its items go back into the stock. Write the reason:`); if (!r) return; void a.run(async () => { await rpc('cancel_promo', { p_id: id, p_reason: r }); await refresh('vendeurs', 'stock', 'audit'); toast(`Promo ${no} cancelled, items back in stock`, 'warn'); setTick((x) => x + 1); }); };
  let run = st?.brought_forward ?? 0;
  return (
    <Modal title={`Statement of ${v.name}`} icon="doc" xl onClose={onClose} foot={<><button className="btn" onClick={onClose}>Close</button><button className="btn primary" disabled={!st} onClick={() => st && printHTML(vendeurStatementHTML(st, settings.data?.company ?? {}, profile!.name))}><Icon n="printer" /> Print statement</button></>}>
      <div className="frow three"><div className="field"><label>From</label><input className="input" type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></div><div className="field"><label>To</label><input className="input" type="date" value={to} onChange={(e) => setTo(e.target.value)} /></div>
        <div className="field"><label>Owed today</label><div style={{ paddingTop: 8 }}><b>{fUSD(v.balance)}</b> <VendeurChips v={v} /></div></div></div>
      {!st ? <Empty i="refresh" t="Loading the statement" /> : <>
        <div className="tw"><table className="t" id="vstmt"><thead><tr><th>Date</th><th>No.</th><th>Particulars</th><th className="r">Goods USD</th><th className="r">Paid USD</th><th className="r">Balance USD</th></tr></thead><tbody>
          <tr><td>{ddmm(st.from)}</td><td /><td><b>Brought forward</b></td><td /><td /><td className="r">{fUSD(st.brought_forward)}</td></tr>
          {st.lines.map((l, i) => { run += l.dr - l.cr; return <tr key={i}><td className="nw">{ddmm(l.date)}</td><td className="nw">{l.no}</td><td>{l.what}{(l.items ?? []).map((it, k) => <div key={k} className="stitem"><span>{it.qty} {it.unit} {it.name}</span><span>{fUSD(it.amount)}</span></div>)}{l.due ? <div className="code">due {ddmm(l.due)}</div> : null}</td><td className="r nw">{l.dr ? fUSD(l.dr) : ''}</td><td className="r nw">{l.cr ? fUSD(l.cr) : ''}</td><td className="r nw">{fUSD(run)}</td></tr>; })}
          <tr><td colSpan={3}><b>Totals</b></td><td className="r nw"><b>{fUSD(st.total_dr)}</b></td><td className="r nw"><b>{fUSD(st.total_cr)}</b></td><td className="r nw"><b>{fUSD(st.closing)}</b></td></tr></tbody></table></div>
        {st.payments.length ? <><h3 style={{ marginTop: 16 }}><Icon n="cash" /> Payments</h3><div className="tw"><table className="t" style={{ fontSize: 13.5 }}><tbody>{st.payments.map((x) => <tr key={x.id}><td className="nw">{x.no}<div className="code">{dt(x.at)}, {x.by_name}</div></td><td><div>{[x.paid_usd ? fUSD(x.paid_usd) : '', x.paid_cdf ? `${fCDF(x.paid_cdf)} at ${x.usd_rate ?? ''}` : ''].filter(Boolean).join(' + ')}{x.change_cdf ? `, ${fCDF(x.change_cdf)} given back` : ''}</div>{x.note}{x.status === 'cancelled' ? <div className="code bad">Cancelled: {x.cancel_reason}</div> : null}</td>
          <td className="r nw">{x.status === 'cancelled' ? <s>{fUSD(x.amount)}</s> : fUSD(x.amount)}</td><td style={{ width: 1 }}>{x.status === 'ok' ? <button className="btn sm" disabled={a.busy} onClick={() => cancelPay(x.id, x.no)}><Icon n="x" /> Cancel</button> : null}</td></tr>)}</tbody></table></div></> : null}
        {st.promos.length ? <><h3 style={{ marginTop: 16 }}><Icon n="gift" /> Promo items given (not owed)</h3><div className="tw"><table className="t" style={{ fontSize: 13.5 }}><tbody>{st.promos.map((p) => <tr key={p.id}><td className="nw">{p.no}<div className="code">{ddmm(p.date)}{p.invoice ? `, with ${p.invoice}` : ''}</div></td>
          <td>{(p.items ?? []).map((i) => `${i.qty} ${i.unit} ${i.name}`).join(', ')}{p.note ? <div className="code">{p.note}</div> : null}</td><td className="r nw">{fCDF(p.value)}</td>
          <td style={{ width: 1 }}>{p.status === 'settled' ? <span className="chip ok">Settled</span> : <button className="btn sm" disabled={a.busy} onClick={() => cancelPromo(p.id, p.no)}><Icon n="x" /> Cancel</button>}</td></tr>)}</tbody></table></div></> : null}
      </>}
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

export function PromoReportModal({ month: m0, shopName, onClose }: { month: string; shopName: string; onClose: () => void }) {
  const { profile } = useAuth(), refresh = useRefresh(), toast = useToast(), a = useAction(), settings = useSettings();
  const [month, setMonth] = useState(m0), [view, setView] = useState<PromoReport['reports'][number] | null>(null);
  const rep = usePromoReport(month), d = rep.data;
  const kept = d?.reports.find((r) => r.month === month && r.status === 'kept');
  const close = (action: 'keep' | 'settle') => a.run(async () => {
    if (action === 'settle' && !confirm(`Settle the promo report of ${monthName(month)}? Its ${d?.pcs ?? 0} pieces given out are closed and the promo count starts again at zero. The settled report is kept to view and print.`)) return;
    await rpc('close_promo_report', { p_month: month, p_action: action });
    await refresh('vendeurs', 'audit'); void rep.refetch();
    toast(action === 'settle' ? `Promo report of ${monthName(month)} settled; the count starts again at zero` : `Promo report of ${monthName(month)} kept; its promos stay open`);
  });
  const printIt = (x: PromoData, status: 'open' | 'kept' | 'settled') => printHTML(promoReportHTML(x, settings.data?.company ?? {}, shopName, profile!.name, status));
  // a promo given with a cash sale by mistake: its items go back into the stock
  const cancelCash = (id: string, no: string) => { const r = prompt(`Cancel promo ${no}? Its items go back into the stock. Write the reason:`); if (!r) return;
    void a.run(async () => { await rpc('cancel_promo', { p_id: id, p_reason: r }); await refresh('vendeurs', 'stock', 'audit'); void rep.refetch(); toast(`Promo ${no} cancelled, items back in stock`, 'warn'); }); };
  const shown: PromoData | undefined = view?.data ?? d;
  return (
    <Modal title="Promo report" icon="gift" xl onClose={onClose} foot={view ? <><button className="btn" onClick={() => setView(null)}>Back</button><button className="btn primary" onClick={() => printIt(view.data, view.status)}><Icon n="printer" /> Print</button></>
      : <><button className="btn" onClick={onClose}>Close</button><span className="sp" /><button className="btn" disabled={!d?.items?.length} onClick={() => d && printIt(d, kept ? 'kept' : 'open')}><Icon n="printer" /> Print</button>
        <button className="btn" id="promokeep" disabled={a.busy || !d?.n} onClick={() => void close('keep')}><Icon n="doc" /> Keep report</button>
        <button className="btn primary" id="promosettle" disabled={a.busy || !d?.n} onClick={() => void close('settle')}><Icon n="check" /> Settle</button></>}>
      {view ? <Note i="doc">{view.status === 'settled' ? 'Settled' : 'Kept'} report of {monthName(view.month)}, {dt(view.at)} by {view.by_name}.</Note>
        : <div className="frow three"><div className="field"><label htmlFor="pmonth">Month</label><input id="pmonth" className="input" type="month" value={month.slice(0, 7)} max={today().slice(0, 7)} onChange={(e) => e.target.value && setMonth(e.target.value + '-01')} /></div>
          <div className="field"><label>Given out, open at the end of the month</label><div style={{ paddingTop: 8 }}><b>{d?.pcs ?? 0} pieces</b>{d?.carried_pcs ? <span className="code"> · {d.carried_pcs} from earlier months</span> : null}</div></div>
          <div className="field"><label>Status</label><div style={{ paddingTop: 8 }}>{kept ? <span className="chip warn">Kept {dt(kept.at)}, not settled</span> : d?.n ? <span className="chip">Not kept or settled</span> : <span className="chip ok">Nothing open</span>}</div></div></div>}
      {rep.isLoading && !view ? <Empty i="refresh" t="Loading the report" /> : !shown?.items?.length ? <Empty i="gift" t={`No promo items open up to the end of ${monthName(month)}`} /> :
        <div className="tw"><table className="t" id="promotable"><thead><tr><th>Item</th><th className="r">Pieces given out</th><th className="r">Cash sales</th><th className="r">Credit sales</th></tr></thead><tbody>
          {shown.items.map((i) => <tr key={i.name}><td><b>{i.name}</b>{i.carried ? <div className="code">{i.carried} from earlier months</div> : null}</td>
            <td className="r nw"><b>{i.qty}</b>{i.unit !== 'pcs' ? ` ${i.unit}` : ''}</td><td className="r nw">{i.cash_qty ?? '-'}</td><td className="r nw">{i.credit_qty ?? i.qty}</td></tr>)}
          <tr><td><b>Total</b></td><td className="r nw"><b>{shown.pcs}</b></td><td className="r nw"><b>{shown.cash_pcs ?? '-'}</b></td><td className="r nw"><b>{shown.credit_pcs ?? shown.pcs}</b></td></tr></tbody></table></div>}
      {!view && d?.cash_promos?.length ? <><h3 style={{ marginTop: 16 }}><Icon n="gift" /> Given with cash sales</h3><div className="tw"><table className="t" style={{ fontSize: 13.5 }}><tbody>{d.cash_promos.map((p) => <tr key={p.id}>
        <td className="nw">{p.no}<div className="code">{ddmm(p.date)}{p.invoice ? `, with ${p.invoice}` : ''}, {p.by_name}</div></td><td>{(p.items ?? []).map((i) => `${i.qty} ${i.unit} ${i.name}`).join(', ')}</td><td className="r nw">{fCDF(p.value)}</td>
        <td style={{ width: 1 }}><button className="btn sm" disabled={a.busy} onClick={() => cancelCash(p.id, p.no)}><Icon n="x" /> Cancel</button></td></tr>)}</tbody></table></div></> : null}
      {!view ? <Note i="gift" style={{ marginTop: 12 }}><b>Keep report</b> saves it as it is; its promos stay open and keep adding up into next month. <b>Settle</b> closes them: the promo count starts again at zero, and the settled report stays here to view and print.</Note> : null}
      {!view && d?.reports.length ? <><h3 style={{ marginTop: 16 }}><Icon n="doc" /> Reports kept and settled</h3><div className="tw"><table className="t" style={{ fontSize: 13.5 }}><tbody>{d.reports.map((r) => <tr key={r.id}><td><b>{monthName(r.month)}</b><div className="code">{dt(r.at)}, {r.by_name}</div></td>
        <td>{r.status === 'settled' ? <span className="chip ok">Settled</span> : <span className="chip warn">Kept</span>}</td><td className="r nw">{r.data?.pcs ?? '-'} pieces</td>
        <td style={{ width: 1 }}><button className="btn sm" onClick={() => setView(r)}><Icon n="eye" /> View</button></td></tr>)}</tbody></table></div></> : null}
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

/** At the till: give the goods in the sale on credit to a vendeur, with promo items if any. Warns (but allows) when the
 *  vendeur is overdue or the goods take them over the credit limit. */
export function CreditModal({ total, count, products, stockOf, rate, usdRate, onClose, onGive }: {
  total: number; count: number; products: Product[]; stockOf: (id: string) => number; rate: number; usdRate: number; onClose: () => void;
  onGive: (v: Vendeur, promo: { product_id: string; qty: number }[], note: string, day: string, ir: number) => Promise<boolean>;
}) {
  // the day of the sale (a credit sale given earlier can be entered on its day) and the internal rate it is owed at
  const [day, setDay] = useState(today()), [irTyped, setIr] = useState<string | null>(null);
  const ir = Number(irTyped ?? usdRate) || 0, irOff = ir < usdRate / 2 || ir > usdRate * 2, past = day < today();
  const vend = useVendeurs(navigator.onLine), a = useAction();
  const [q, setQ] = useState(''), [sel, setSel] = useState<string | null>(null), [promoOn, setPromoOn] = useState(false), [lines, setLines] = useState<Record<string, string>>({}), [note, setNote] = useState('');
  const live = (vend.data ?? []).filter((v) => v.active), ql = q.trim().toLowerCase();
  const list = live.filter((v) => !ql || (v.name + ' ' + v.phone).toLowerCase().includes(ql));
  const v = live.find((x) => x.id === sel) ?? null;
  // the goods are owed in USD at the internal rate (taux interne) of the sale
  const totalUsd = ir > 0 ? Math.round((total / ir) * 100) / 100 : 0;
  const warns = v ? creditWarnings(v, totalUsd) : [];
  const due = v ? ld(new Date(day + 'T12:00:00').getTime() + v.credit_days * 864e5) : '';
  const go = () => a.run(async () => {
    if (!v) throw new Error('Choose the vendeur');
    const promo = promoOn ? promoLines(lines) : [];
    const short = promo.find((l) => l.qty > stockOf(l.product_id));
    if (short) throw new Error(`Not enough ${products.find((p) => p.id === short.product_id)?.name ?? 'stock'} in the shop for the promo`);
    if (!day || day > today()) throw new Error('Choose the date of the sale: today or a day before');
    if (!(ir > 0) || irOff) throw new Error(`Check the internal rate: ${fCDF(ir)} is far from the internal rate (${fCDF(usdRate)})`);
    if (await onGive(v, promo, note, day, ir)) onClose();
  });
  return (
    <Modal title="Give the goods on credit" icon="users" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button>
      <button className={`btn ${warns.length ? 'danger' : 'primary'}`} id="creditgo" disabled={a.busy || !v} onClick={() => void go()}><Icon n="printer" /> {warns.length ? 'Give on credit anyway and print' : 'Give on credit and print'}</button></>}>
      <p style={{ marginTop: 0 }}><b>{fUSD(totalUsd)}</b>, {count} {count === 1 ? 'item' : 'items'}: the stock leaves the shop now, nothing is paid at the till, and the vendeur owes {fUSD(totalUsd)}.</p>
      <div className="frow" id="creddate">
        <div className="field"><label htmlFor="credday">Date of the sale</label><input id="credday" className="input" type="date" value={day} max={today()} onChange={(e) => setDay(e.target.value || today())} />
          <span className="hint">{past ? 'A credit sale given earlier, entered on its day: it is due after the credit days from that date.' : 'Today. Pick an earlier day to enter a credit sale given before.'}</span></div>
        <div className="field"><label htmlFor="credir">Internal rate (taux interne){irTyped !== null && Number(irTyped) !== usdRate ? <span className="chip warn" style={{ marginLeft: 6 }}>typed by hand</span> : null}</label>
          <input id="credir" className="input" type="number" min="1" step="1" value={irTyped ?? String(usdRate)} onChange={(e) => setIr(e.target.value)} />
          <span className={irOff ? 'lerr' : 'hint'}>{irOff ? `Check the rate: far from the internal rate (${fCDF(usdRate)})` : irTyped !== null && Number(irTyped) !== usdRate ? <button type="button" className="linkbtn" onClick={() => setIr(null)}>Use today's internal rate ({fCDF(usdRate)})</button> : past ? 'Type the internal rate of that day if it was different.' : "Today's internal rate, from Settings."}</span></div>
      </div>
      {!navigator.onLine ? <Note i="wifioff" warn>Goods on credit need the internet connection, to check what the vendeur owes.</Note>
        : vend.isLoading ? <Empty i="refresh" t="Loading vendeurs" /> : vend.error ? <Note i="alert" warn>{(vend.error as Error).message}</Note> : !live.length ? <Note i="users" warn>No vendeurs yet. Add them in the Vendeurs tab.</Note> : <>
        <div className="search" style={{ marginBottom: 8 }}><Icon n="search" /><input id="credq" placeholder="Find the vendeur" value={q} onChange={(e) => setQ(e.target.value)} autoFocus aria-label="Find the vendeur" /></div>
        <div className="tw" style={{ maxHeight: 220, overflow: 'auto', border: '1px solid var(--line)', borderRadius: 12 }}><table className="t" style={{ fontSize: 13.5 }}><tbody>
          {list.map((x) => <tr key={x.id} className={x.id === sel ? 'sel' : ''} style={{ cursor: 'pointer', background: x.id === sel ? 'var(--blue-l)' : undefined }} onClick={() => setSel(x.id)}>
            <td><label style={{ display: 'flex', gap: 8, alignItems: 'center', cursor: 'pointer' }}><input type="radio" name="vend" checked={x.id === sel} onChange={() => setSel(x.id)} aria-label={x.name} /><span><b>{x.name}</b><div className="code">owes {fUSD(x.balance)} of {fUSD(x.credit_limit_usd)}</div></span></label></td>
            <td className="r"><div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', justifyContent: 'flex-end' }}><VendeurChips v={x} /></div></td></tr>)}
          {!list.length ? <tr><td>No vendeur matches</td></tr> : null}</tbody></table></div>
        {v ? <div style={{ marginTop: 12 }}>
          {warns.length ? <Note i="alert" warn><b>Reminder.</b> {warns.join(' ')} The goods can still be given.</Note> : null}
          <div className="kpis" style={{ marginTop: 8 }}>
            <Kpi i="wallet" l="Owes after this" tone={v.balance + totalUsd > v.credit_limit_usd ? 'bad' : 'ok'}><Dual2 b={fUSD(v.balance + totalUsd)} s={`credit left ${fUSD(v.available - totalUsd)}`} /></Kpi>
            <Kpi i="calendar" l="These goods are due"><Dual2 b={ddmm(due)} s={`after ${v.credit_days} days`} /></Kpi></div>
          <label className="switch"><input type="checkbox" id="credpromo" checked={promoOn} onChange={(e) => setPromoOn(e.target.checked)} /><span>Add promo items: free, from the stock, not on the invoice</span></label>
          {promoOn ? <><PromoPicker products={products} stockOf={stockOf} rate={rate} lines={lines} setLines={setLines} />
            <div className="field" style={{ marginTop: 8 }}><label htmlFor="credpnote">Promo note</label><input id="credpnote" className="input" maxLength={120} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Optional" /></div></> : null}
        </div> : null}
      </>}
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}
