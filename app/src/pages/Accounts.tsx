// Book keeping, like Tally: suppliers and their bills, vouchers (payment, receipt, contra, journal,
// debit and credit notes), ledgers in groups, statements, day book, trial balance, profit and loss,
// balance sheet and money owed to suppliers. Every entry is in USD or FC; reports are in USD.
import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useGrns, useLedgers, useProducts, useRefresh, useSettings, useSuppliers } from '../data/queries';
import { rows, rpc, supabase } from '../lib/supabase';
import { dt, esc, fCDF, fUSD, ld, sum, today } from '../lib/format';
import { balTxt, bookHTML, printHTML, statementHTML } from '../lib/print';
import { Dual2, Empty, Head, Kpi, Modal, Note, useAction, useToast } from '../components/ui';
import type { AccountGroup, Cur, DayBookEntry, Grn, Ledger, Payable, Statement, Supplier } from '../lib/types';

const VTYPES: Record<string, string> = {
  payment: 'Payment', receipt: 'Receipt', contra: 'Contra', journal: 'Journal', debit_note: 'Debit note', credit_note: 'Credit note',
  sales: 'Sales', purchase: 'Purchase bill', goods_in: 'Goods in', transfer: 'Delivery to shop', return: 'Return', adjustment: 'Stock adjustment', opening: 'Opening',
};
const usd2 = (n: number) => Math.round(n * 100) / 100;
const useGroups = () => useQuery({ queryKey: ['groups'], queryFn: async () => rows<AccountGroup>(await supabase.from('account_groups').select('*').order('sort')) });
const usePayables = (enabled = true) => useQuery({ queryKey: ['books', 'payables'], enabled, queryFn: () => rpc<Payable[]>('payables', { p_as_of: today() }) });
const monthStart = () => today().slice(0, 8) + '01';
function useDoc() {
  const { profile } = useAuth(), settings = useSettings();
  return (title: string, sub: string, body: string) => printHTML(bookHTML(settings.data?.company ?? {}, title, sub, body, profile!.name));
}

export default function Accounts() {
  const [tab, setTab] = useState('suppliers');
  const tabs: [string, string][] = [['suppliers', 'Suppliers'], ['bills', 'Bills & payables'], ['vouchers', 'Vouchers & day book'], ['statement', 'Statements'], ['ledgers', 'Ledgers'], ['tb', 'Trial balance'], ['pl', 'Profit & loss'], ['bs', 'Balance sheet']];
  const ledgers = useLedgers();
  return (
    <>
      <Head t="Accounts" s="Suppliers, bills, payments and the books. Sales, deliveries, goods in, returns and stock counts are booked by SIM on their own; enter the rest as vouchers. Each entry is in USD or Francs; reports are in USD." />
      <div className="tabs">{tabs.map(([k, l]) => <button key={k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>{l}</button>)}</div>
      {tab === 'suppliers' ? <Suppliers /> : tab === 'bills' ? <Bills /> : tab === 'vouchers' ? <Vouchers /> : tab === 'statement' ? <StatementView ledgers={ledgers.data ?? []} loading={ledgers.isLoading} />
        : tab === 'ledgers' ? <Ledgers ledgers={ledgers.data ?? []} /> : tab === 'tb' ? <TrialBalance /> : tab === 'pl' ? <ProfitLoss /> : <BalanceSheet />}
    </>
  );
}

// ---------- suppliers ----------
function Suppliers() {
  const suppliers = useSuppliers(), pay = usePayables(), products = useProducts();
  const [open, setOpen] = useState<Supplier | 'new' | null>(null), [q, setQ] = useState('');
  const owed = new Map((pay.data ?? []).map((p) => [p.id, p]));
  const list = (suppliers.data ?? []).filter((s) => !q || (s.name + ' ' + s.phone + ' ' + s.contact).toLowerCase().includes(q.toLowerCase()));
  return (
    <>
      <div className="toolbar"><div className="search"><Icon n="search" /><input placeholder="Supplier name, contact or phone" value={q} onChange={(e) => setQ(e.target.value)} /></div><span className="sp" /><button className="btn primary" onClick={() => setOpen('new')}><Icon n="plus" /> Add supplier</button></div>
      <div className="card p0"><div className="tw">{list.length ? <table className="t"><thead><tr><th>Supplier</th><th>Contact</th><th>Credit terms</th><th className="r">Items</th><th className="r">We owe</th><th className="r">Overdue</th><th /></tr></thead><tbody>
        {list.map((s) => { const o = owed.get(s.id), over = sum((o?.bills ?? []).filter((b) => b.days_overdue > 0), (b) => b.outstanding); return <tr key={s.id}>
          <td><b>{s.name}</b>{s.active ? null : <> <span className="chip bad">Inactive</span></>}<div className="code">{s.tax_no ? 'NIF ' + s.tax_no : ''}</div></td><td>{s.contact}<div className="code">{s.phone}{s.email ? ' · ' + s.email : ''}</div></td>
          <td>{s.credit_days} days{s.credit_limit > 0 ? <div className="code">limit {fUSD(s.credit_limit)}</div> : null}</td><td className="r">{s.supplier_items?.length ?? 0}</td>
          <td className="r"><b>{o ? balTxt(-o.balance) : '-'}</b></td><td className="r">{over > 0 ? <span className="chip bad">{fUSD(over)}</span> : '-'}</td>
          <td><div className="act"><button title="Edit supplier" onClick={() => setOpen(s)}><Icon n="edit" /></button></div></td></tr>; })}
      </tbody></table> : <Empty i="users" t={suppliers.isLoading ? 'Loading' : 'No suppliers yet. Add the first one.'} />}</div></div>
      {open ? <SupplierModal s={open === 'new' ? null : open} products={(products.data ?? []).filter((p) => p.active)} onClose={() => setOpen(null)} /> : null}
    </>
  );
}

function SupplierModal({ s, products, onClose }: { s: Supplier | null; products: { id: string; name: string; sku: string; category: string }[]; onClose: () => void }) {
  const ledgers = useLedgers(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const acc = ledgers.data?.find((l) => l.id === s?.account_id);
  const [f, setF] = useState({ name: s?.name ?? '', contact: s?.contact ?? '', phone: s?.phone ?? '', email: s?.email ?? '', address: s?.address ?? '', tax_no: s?.tax_no ?? '',
    credit_days: String(s?.credit_days ?? 30), credit_limit: s?.credit_limit ? String(s.credit_limit) : '', currency: s?.currency ?? 'USD', notes: s?.notes ?? '', active: s?.active ?? true,
    oa: acc?.opening_amount ? String(acc.opening_amount) : '', oside: acc?.opening_side ?? 'Cr', ocur: acc?.opening_currency ?? 'USD' });
  const [items, setItems] = useState<string[]>((s?.supplier_items ?? []).map((i) => i.product_id)), [q, setQ] = useState('');
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => setF({ ...f, [k]: e.target.value });
  const ql = q.trim().toLowerCase(), shown = products.filter((p) => items.includes(p.id) || (ql && (p.name + ' ' + p.sku + ' ' + p.category).toLowerCase().includes(ql))).slice(0, 80);
  const save = () => a.run(async () => {
    await rpc('save_supplier', { p: { id: s?.id ?? null, name: f.name, contact: f.contact, phone: f.phone, email: f.email, address: f.address, tax_no: f.tax_no, credit_days: Number(f.credit_days) || 0,
      credit_limit: Number(f.credit_limit) || 0, currency: f.currency, notes: f.notes, active: f.active, opening_amount: Number(f.oa) || 0, opening_side: f.oside, opening_currency: f.ocur, items } });
    await refresh('suppliers', 'audit'); toast(s ? 'Supplier saved' : 'Supplier added, with its own ledger'); onClose();
  });
  return (
    <Modal title={s ? 'Edit supplier' : 'Add supplier'} icon="users" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Save supplier</button></>}>
      <div className="frow"><div className="field"><label>Supplier name</label><input id="sname" className="input" maxLength={60} value={f.name} onChange={set('name')} autoFocus /></div><div className="field"><label>Contact person</label><input className="input" maxLength={60} value={f.contact} onChange={set('contact')} /></div></div>
      <div className="frow"><div className="field"><label>Phone</label><input className="input" maxLength={40} value={f.phone} onChange={set('phone')} /></div><div className="field"><label>Email</label><input className="input" maxLength={80} value={f.email} onChange={set('email')} /></div></div>
      <div className="frow"><div className="field"><label>Address</label><input className="input" maxLength={120} value={f.address} onChange={set('address')} /></div><div className="field"><label>Tax number (NIF)</label><input className="input" maxLength={40} value={f.tax_no} onChange={set('tax_no')} /></div></div>
      <div className="frow three"><div className="field"><label>Credit days</label><input id="sdays" className="input" type="number" min="0" max="365" value={f.credit_days} onChange={set('credit_days')} /><span className="hint">Bills fall due this many days after the bill date.</span></div>
        <div className="field"><label>Credit limit (USD)</label><input className="input" type="number" min="0" value={f.credit_limit} placeholder="Optional" onChange={set('credit_limit')} /></div>
        <div className="field"><label>Usually bills in</label><select className="input" value={f.currency} onChange={set('currency')}><option value="USD">USD</option><option value="FC">Francs (FC)</option></select></div></div>
      <div className="frow three"><div className="field"><label>Opening balance</label><input id="soa" className="input" type="number" min="0" step="0.01" value={f.oa} placeholder="0" onChange={set('oa')} /></div>
        <div className="field"><label>Side</label><select className="input" value={f.oside} onChange={set('oside')}><option value="Cr">Cr, we owe them</option><option value="Dr">Dr, they owe us (advance)</option></select></div>
        <div className="field"><label>In</label><select className="input" value={f.ocur} onChange={set('ocur')}><option value="USD">USD</option><option value="FC">FC</option></select></div></div>
      <div className="field"><label>Items this supplier supplies</label><div className="search" style={{ maxWidth: 'none' }}><Icon n="search" /><input placeholder="Find items to add" value={q} onChange={(e) => setQ(e.target.value)} /></div>
        <div className="mchips" style={{ marginTop: 8 }}>{shown.map((p) => { const on = items.includes(p.id); return <label key={p.id} className="chip" style={on ? { background: 'var(--btn)', color: '#fff' } : undefined}><input type="checkbox" hidden checked={on} onChange={() => setItems(on ? items.filter((x) => x !== p.id) : [...items, p.id])} />{on ? '✓ ' : '+ '}{p.name}</label>; })}</div>
        <span className="hint">{items.length} item{items.length === 1 ? '' : 's'}. When the warehouse receives from this supplier, these items are listed first.</span></div>
      <div className="field"><label>Notes</label><input className="input" maxLength={200} value={f.notes} onChange={set('notes')} /></div>
      {s ? <label className="switch"><input type="checkbox" checked={f.active} onChange={(e) => setF({ ...f, active: e.target.checked })} /><span>Active (the warehouse can receive from this supplier)</span></label> : null}
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

// ---------- bills ----------
export function BillModal({ grn, onClose }: { grn?: Grn; onClose: () => void }) {
  const suppliers = useSuppliers(), ledgers = useLedgers(), settings = useSettings(), products = useProducts(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const sup0 = grn ? suppliers.data?.find((s) => s.id === grn.supplier_id) : undefined;
  const [f, setF] = useState({ supplier: grn?.supplier_id ?? '', account: '', bill_no: '', bill_date: today(), due: '', amount: '', vat: '', currency: (sup0?.currency ?? 'USD') as Cur, rate: '', narration: '' });
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  const sup = suppliers.data?.find((s) => s.id === f.supplier), rate = Number(f.rate) || settings.data?.rate || 1;
  const std = grn ? sum(grn.grn_items, (i) => i.qty * Number(i.std_cost_usd ?? 0)) : 0;
  const amt = Number(f.amount) || 0, amtUsd = f.currency === 'FC' ? amt / rate : amt;
  const due = f.due || (sup && f.bill_date ? ld(new Date(f.bill_date + 'T12:00:00').getTime() + sup.credit_days * 864e5) : '');
  const byId = new Map((products.data ?? []).map((p) => [p.id, p]));
  const save = () => a.run(async () => {
    await rpc('enter_bill', { p: { grn_id: grn?.id ?? null, supplier_id: f.supplier, account_id: grn ? null : f.account || null, bill_no: f.bill_no, bill_date: f.bill_date, due_date: f.due || null,
      amount: amt, vat: Number(f.vat) || 0, currency: f.currency, rate, narration: f.narration } });
    await refresh('grns', 'suppliers', 'audit'); toast(`Bill ${f.bill_no} entered, due ${due}`); onClose();
  });
  const charge = (ledgers.data ?? []).filter((l) => l.active && ['direxp', 'indexp', 'fixed', 'stock', 'advances'].includes(l.group_code) && !l.shop_id);
  return (
    <Modal title={grn ? `Enter the bill for ${grn.no}` : 'Enter a supplier bill'} icon="receipt" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Save bill</button></>}>
      {grn ? <Note i="truck">{sup0?.name}: {grn.grn_items.map((i) => `${i.qty} ${byId.get(i.product_id)?.name ?? ''}`).join(', ')}. At item cost these goods are <b>{fUSD(std)}</b>; a different bill amount goes to Purchase price difference.</Note>
        : <div className="frow"><div className="field"><label>Supplier</label><select className="input" value={f.supplier} onChange={(e) => { const s = suppliers.data?.find((x) => x.id === e.target.value); setF({ ...f, supplier: e.target.value, currency: s?.currency ?? f.currency }); }}><option value="">Choose</option>{(suppliers.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></div>
          <div className="field"><label>For (charged to)</label><select className="input" value={f.account} onChange={set('account')}><option value="">Choose a ledger</option>{charge.map((l) => <option key={l.id} value={l.id}>{l.name} ({l.group_name})</option>)}</select><span className="hint">Goods for the store come in through Goods in; use this for transport, services, equipment.</span></div></div>}
      <div className="frow three"><div className="field"><label>Supplier's bill no.</label><input id="bno" className="input" maxLength={40} value={f.bill_no} onChange={set('bill_no')} autoFocus /></div>
        <div className="field"><label>Bill date</label><input type="date" className="input" value={f.bill_date} onChange={set('bill_date')} /></div>
        <div className="field"><label>Due date</label><input type="date" className="input" value={f.due || due} onChange={set('due')} /><span className="hint">{sup ? `${sup.credit_days} days credit` : ''}</span></div></div>
      <div className="frow three"><div className="field"><label>Amount before VAT</label><input id="bamt" className="input" type="number" min="0" step="0.01" value={f.amount} onChange={set('amount')} /></div>
        <div className="field"><label>VAT on the bill</label><input className="input" type="number" min="0" step="0.01" value={f.vat} placeholder="0" onChange={set('vat')} /></div>
        <div className="field"><label>Currency</label><div style={{ display: 'flex', gap: 6 }}><select className="input" value={f.currency} onChange={set('currency')}><option value="USD">USD</option><option value="FC">FC</option></select>{f.currency === 'FC' ? <input className="input" type="number" min="1" value={f.rate} placeholder={String(settings.data?.rate ?? '')} onChange={set('rate')} aria-label="Rate" /> : null}</div></div></div>
      {grn && amt > 0 ? <Note i={Math.abs(amtUsd - std) > 0.005 ? 'alert' : 'check'} warn={Math.abs(amtUsd - std) > 0.005}>Bill {fUSD(amtUsd)} vs item cost {fUSD(std)}: difference {fUSD(amtUsd - std)}.</Note> : null}
      <div className="field"><label>Narration (optional)</label><input className="input" maxLength={120} value={f.narration} onChange={set('narration')} /></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}

function Bills() {
  const grns = useGrns(), pay = usePayables(), suppliers = useSuppliers(), doc = useDoc();
  const [bill, setBill] = useState<Grn | 'direct' | null>(null), [payTo, setPayTo] = useState<Payable | null>(null);
  const waiting = (grns.data ?? []).filter((g) => g.status === 'awaiting_bill');
  const ages = (p: Payable) => { const b = [0, 0, 0, 0, 0]; p.bills.forEach((x) => { const d = x.days_overdue; b[d <= 0 ? 0 : d <= 30 ? 1 : d <= 60 ? 2 : d <= 90 ? 3 : 4] += x.outstanding; }); return b; };
  const P = (pay.data ?? []).filter((p) => Math.abs(p.balance) > 0.005 || p.bills.length);
  const tot = [0, 1, 2, 3, 4].map((k) => sum(P, (p) => ages(p)[k]));
  const print = () => doc('Money owed to suppliers', `as of ${today()}`, `<table class="t"><thead><tr><th>Supplier</th><th class="r">Balance</th><th class="r">Not due</th><th class="r">1-30</th><th class="r">31-60</th><th class="r">61-90</th><th class="r">Over 90</th></tr></thead><tbody>${P.map((p) => { const a = ages(p); return `<tr><td>${esc(p.name)}</td><td class="r">${balTxt(-p.balance)}</td>${a.map((x) => `<td class="r">${x ? fUSD(x) : ''}</td>`).join('')}</tr>`; }).join('')}<tr><td><b>Total</b></td><td class="r"><b>${fUSD(-sum(P, (p) => -p.balance))}</b></td>${tot.map((x) => `<td class="r"><b>${fUSD(x)}</b></td>`).join('')}</tr></tbody></table><p>Days overdue counted from each bill's due date. Balances include opening balances and amounts not matched to a bill.</p>`);
  return (
    <>
      <div className="toolbar"><span className="sp" /><button className="btn ghost" onClick={print}><Icon n="printer" /> Print</button><button className="btn primary" onClick={() => setBill('direct')}><Icon n="plus" /> Other bill</button></div>
      <div className="card p0"><div style={{ padding: '16px 16px 0' }}><h3><Icon n="truck" /> Goods received, bill not entered ({waiting.length})</h3></div>
        {waiting.length ? <div className="tw"><table className="t"><tbody>{waiting.map((g) => <tr key={g.id}><td><b>{g.no}</b><div className="code">{dt(g.received_at)}, {g.received_by_name}</div></td><td>{suppliers.data?.find((s) => s.id === g.supplier_id)?.name}{g.ref ? <div className="code">{g.ref}</div> : null}</td><td className="r">{fUSD(sum(g.grn_items, (i) => i.qty * Number(i.std_cost_usd ?? 0)))}<div className="code">at item cost</div></td><td><button className="btn primary sm" onClick={() => setBill(g)}><Icon n="receipt" /> Enter bill</button></td></tr>)}</tbody></table></div> : <Empty i="check" t="Every goods receipt has its bill" />}</div>
      <div className="kpis">{['Not yet due', '1 to 30 days late', '31 to 60 days late', '61 to 90 days late', 'Over 90 days late'].map((l, k) => <Kpi key={l} i={k ? 'alert' : 'clock'} l={l} tone={k === 0 ? '' : k === 1 ? 'warn' : 'bad'}><Dual2 b={fUSD(tot[k])} s="still to pay" /></Kpi>)}</div>
      <div className="card p0"><div style={{ padding: '16px 16px 0' }}><h3><Icon n="wallet" /> Money owed to suppliers, bill by bill</h3></div>
        {P.length ? <div className="tw"><table className="t"><thead><tr><th>Supplier / bill</th><th>Bill date</th><th>Due</th><th className="r">Bill</th><th className="r">Still to pay</th><th /></tr></thead><tbody>
          {P.map((p) => [<tr key={p.id} style={{ background: 'var(--bg)' }}><td colSpan={4}><b>{p.name}</b> <span className="code">{p.credit_days} days credit{p.phone ? ', ' + p.phone : ''}</span></td><td className="r"><b>{balTxt(-p.balance)}</b></td><td><button className="btn sm" onClick={() => setPayTo(p)}><Icon n="cash" /> Pay</button></td></tr>,
            ...p.bills.map((b) => <tr key={b.id}><td>&nbsp;&nbsp;{b.bill_ref} <span className="code">{b.no}</span></td><td>{b.date}</td><td>{b.due_date}{b.days_overdue > 0 ? <> <span className="chip bad">{b.days_overdue} days late</span></> : null}</td><td className="r">{fUSD(b.amount)}{b.currency === 'FC' ? <div className="code">{fCDF(b.original)}</div> : null}</td><td className="r"><b>{fUSD(b.outstanding)}</b></td><td /></tr>)])}
        </tbody></table></div> : <Empty i="check" t={pay.isLoading ? 'Loading' : 'Nothing owed to suppliers'} />}</div>
      {bill ? <BillModal grn={bill === 'direct' ? undefined : bill} onClose={() => setBill(null)} /> : null}
      {payTo ? <VoucherModal type="payment" party={payTo} onClose={() => setPayTo(null)} /> : null}
    </>
  );
}

// ---------- vouchers ----------
type VLine = { account: string; side: 'Dr' | 'Cr'; amount: string; currency: Cur; rate: string; memo: string };
function VoucherModal({ type: t0, party, onClose }: { type: string; party?: Payable; onClose: () => void }) {
  const ledgers = useLedgers(), settings = useSettings(), pay = usePayables(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const L = (ledgers.data ?? []).filter((l) => l.active), rate0 = String(settings.data?.rate ?? '');
  const cash = L.find((l) => l.code === 'CASH_HO');
  const supAcc = party ? (ledgers.data ?? []).find((l) => l.supplier_id === party.id) : undefined;
  const blank = (side: 'Dr' | 'Cr', account = ''): VLine => ({ account, side, amount: '', currency: (L.find((l) => l.id === account)?.currency ?? 'USD'), rate: rate0, memo: '' });
  const [t, setT] = useState(t0), [date, setDate] = useState(today()), [narr, setNarr] = useState(party ? `Payment to ${party.name}` : ''), [ref, setRef] = useState('');
  const [lines, setLines] = useState<VLine[]>(() => t0 === 'payment' ? [blank('Dr', supAcc?.id), blank('Cr', cash?.id)] : t0 === 'receipt' ? [blank('Dr', cash?.id), blank('Cr')] : [blank('Dr'), blank('Cr')]);
  const [alloc, setAlloc] = useState<Record<string, string>>({});
  const base = (l: VLine) => { const n = Number(l.amount) || 0; return l.currency === 'FC' ? n / (Number(l.rate) || Number(rate0) || 1) : n; };
  const dr = sum(lines.filter((l) => l.side === 'Dr'), base), cr = sum(lines.filter((l) => l.side === 'Cr'), base), diff = usd2(dr - cr);
  const upd = (i: number, patch: Partial<VLine>) => setLines(lines.map((l, k) => { if (k !== i) return l; const n = { ...l, ...patch }; if (patch.account) n.currency = L.find((x) => x.id === patch.account)?.currency ?? n.currency; return n; }));
  // bills of the supplier being paid (or debited), to settle bill by bill
  const supLines = lines.filter((l) => l.side === 'Dr' && L.find((x) => x.id === l.account)?.supplier_id);
  const sid = supLines.length ? L.find((x) => x.id === supLines[0].account)?.supplier_id : null;
  const bills = (t === 'payment' || t === 'debit_note') && sid ? pay.data?.find((p) => p.id === sid)?.bills ?? [] : [];
  const supPaid = sum(supLines, base), allocated = sum(Object.values(alloc), (v) => Number(v) || 0);
  const autoAlloc = () => { let left = supPaid; const o: Record<string, string> = {}; [...bills].sort((x, y) => x.due_date.localeCompare(y.due_date)).forEach((b) => { const v = Math.min(left, b.outstanding); if (v > 0.005) { o[b.id] = String(usd2(v)); left -= v; } }); setAlloc(o); };
  const save = () => a.run(async () => {
    if (Math.abs(diff) > 0.01) throw new Error(`Debit and credit are not equal: difference ${fUSD(diff)}`);
    if (allocated > supPaid + 0.01) throw new Error('More is matched to bills than is paid');
    const r = await rpc<{ no: string }>('post_voucher', { p: { type: t, date, narration: narr, ref,
      lines: lines.filter((l) => l.account && Number(l.amount) > 0).map((l) => ({ account: l.account, side: l.side, amount: Number(l.amount), currency: l.currency, rate: Number(l.rate) || Number(rate0), memo: l.memo })),
      allocations: Object.entries(alloc).filter(([, v]) => Number(v) > 0).map(([bill_id, v]) => ({ bill_id, amount: Number(v) })) } });
    await refresh('books', 'ledgers', 'audit'); toast(`${VTYPES[t]} ${r.no} saved`); onClose();
  });
  const hint: Record<string, string> = { payment: 'Money paid out: Dr who or what is paid, Cr the cash or bank it comes from.', receipt: 'Money received: Dr the cash or bank, Cr who paid or the income.', contra: 'Moving money between cash and bank: Dr where it goes, Cr where it comes from.', journal: 'Any other entry, for example a correction or a provision.', debit_note: 'A supplier owes us back (goods returned to them, overcharge): Dr the supplier, Cr purchase price difference or an expense.', credit_note: 'We owe someone more (discount given, a charge accepted): Dr the expense, Cr the party.' };
  return (
    <Modal title={`New ${VTYPES[t].toLowerCase()} voucher`} icon="receipt" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Save voucher</button></>}>
      <div className="frow three"><div className="field"><label>Type</label><select id="vtype" className="input" value={t} onChange={(e) => setT(e.target.value)}>{['payment', 'receipt', 'contra', 'journal', 'debit_note', 'credit_note'].map((k) => <option key={k} value={k}>{VTYPES[k]}</option>)}</select></div>
        <div className="field"><label>Date</label><input type="date" className="input" value={date} max={today()} onChange={(e) => setDate(e.target.value)} /></div>
        <div className="field"><label>Reference (optional)</label><input className="input" maxLength={60} value={ref} onChange={(e) => setRef(e.target.value)} placeholder="cheque, receipt no." /></div></div>
      <Note i="doc">{hint[t]}</Note>
      <div className="tw"><table className="t vlines"><thead><tr><th style={{ width: 70 }}>Dr/Cr</th><th>Ledger</th><th style={{ width: 130 }}>Amount</th><th style={{ width: 90 }}>In</th><th style={{ width: 100 }}>Rate</th><th className="r">USD</th><th /></tr></thead><tbody>
        {lines.map((l, i) => <tr key={i}><td><select className="input" value={l.side} onChange={(e) => upd(i, { side: e.target.value as 'Dr' | 'Cr' })} aria-label="Side"><option>Dr</option><option>Cr</option></select></td>
          <td><select className="input vacc" value={l.account} onChange={(e) => upd(i, { account: e.target.value })} aria-label="Ledger"><option value="">Choose a ledger</option>{groupOptions(L)}</select></td>
          <td><input className="input vamt" type="number" min="0" step="0.01" value={l.amount} onChange={(e) => upd(i, { amount: e.target.value })} aria-label="Amount" /></td>
          <td><select className="input" value={l.currency} onChange={(e) => upd(i, { currency: e.target.value as Cur })} aria-label="Currency"><option>USD</option><option>FC</option></select></td>
          <td>{l.currency === 'FC' ? <input className="input" type="number" min="1" value={l.rate} onChange={(e) => upd(i, { rate: e.target.value })} aria-label="Rate" /> : <span className="code">-</span>}</td>
          <td className={`r ${l.side === 'Dr' ? 'dr' : 'cr'}`}>{fUSD(base(l))}</td>
          <td>{lines.length > 2 ? <button className="rbtn bad" title="Remove line" onClick={() => setLines(lines.filter((_, k) => k !== i))}><Icon n="x" /></button> : null}</td></tr>)}
        <tr><td colSpan={2}><button className="btn sm" onClick={() => setLines([...lines, blank(diff > 0 ? 'Cr' : 'Dr')])}><Icon n="plus" /> Add line</button></td><td colSpan={3} className="r"><b>Dr {fUSD(dr)} · Cr {fUSD(cr)}</b></td><td className="r">{Math.abs(diff) > 0.01 ? <span className="chip bad">off by {fUSD(Math.abs(diff))}</span> : <span className="chip ok">balanced</span>}</td><td /></tr>
      </tbody></table></div>
      {bills.length ? <div className="card" style={{ background: 'var(--bg)', marginTop: 12 }}><h3><Icon n="receipt" /> Settle bills</h3>
        <table className="t"><thead><tr><th>Bill</th><th>Due</th><th className="r">Still to pay</th><th style={{ width: 140 }}>Settle now (USD)</th></tr></thead><tbody>
          {bills.map((b) => <tr key={b.id}><td>{b.bill_ref} <span className="code">{b.no}</span></td><td>{b.due_date}{b.days_overdue > 0 ? <span className="code"> ({b.days_overdue} days late)</span> : null}</td><td className="r">{fUSD(b.outstanding)}</td><td><input className="input" type="number" min="0" step="0.01" value={alloc[b.id] ?? ''} onChange={(e) => setAlloc({ ...alloc, [b.id]: e.target.value })} aria-label={`Settle ${b.bill_ref}`} /></td></tr>)}
        </tbody></table>
        <div className="rrow"><b>{fUSD(allocated)} of {fUSD(supPaid)} matched to bills{supPaid - allocated > 0.005 ? `; ${fUSD(supPaid - allocated)} stays on account` : ''}</b><button className="btn sm" onClick={autoAlloc}>Oldest bills first</button></div></div> : null}
      <div className="field" style={{ marginTop: 12 }}><label>Narration</label><input id="vnarr" className="input" maxLength={200} value={narr} onChange={(e) => setNarr(e.target.value)} placeholder="What is this entry for?" /></div>
      <div className="lerr">{a.err}</div>
    </Modal>
  );
}
function groupOptions(L: Ledger[]) {
  const by = new Map<string, Ledger[]>(); L.forEach((l) => by.set(l.group_name, [...(by.get(l.group_name) ?? []), l]));
  return [...by.entries()].map(([g, ls]) => <optgroup key={g} label={g}>{ls.map((l) => <option key={l.id} value={l.id}>{l.name}{l.currency === 'FC' ? ' (FC)' : ''}</option>)}</optgroup>);
}

function Vouchers() {
  const [from, setFrom] = useState(today()), [to, setTo] = useState(today()), [type, setType] = useState(''), [make, setMake] = useState<string | null>(null), [cancel, setCancel] = useState<DayBookEntry | null>(null);
  const book = useQuery({ queryKey: ['books', 'daybook', from, to, type], queryFn: () => rpc<DayBookEntry[]>('day_book', { p_from: from <= to ? from : to, p_to: from <= to ? to : from, p_type: type || null }) });
  const doc = useDoc(), list = book.data ?? [];
  const print = () => doc('Day book', `${from} to ${to}${type ? ', ' + VTYPES[type] : ''}`, `<table class="t"><thead><tr><th>Date</th><th>Voucher</th><th>Particulars</th><th class="r">Debit USD</th><th class="r">Credit USD</th></tr></thead><tbody>${list.map((v) => `<tr><td>${v.date}</td><td>${esc(v.no)}<br><small>${VTYPES[v.type]}${v.status === 'cancelled' ? ', CANCELLED' : ''}</small></td><td>${esc(v.narration)}${v.lines.map((l) => `<br><small>${l.side} ${esc(l.account)}${l.currency === 'FC' ? ' ' + fCDF(l.amount) : ''}</small>`).join('')}</td><td class="r">${fUSD(sum(v.lines.filter((l) => l.side === 'Dr'), (l) => l.base))}</td><td class="r">${fUSD(sum(v.lines.filter((l) => l.side === 'Cr'), (l) => l.base))}</td></tr>`).join('') || '<tr><td colspan="5">No vouchers</td></tr>'}</tbody></table>`);
  return (
    <>
      <div className="toolbar">{['payment', 'receipt', 'contra', 'journal'].map((k) => <button key={k} className="btn primary sm" onClick={() => setMake(k)}><Icon n="plus" /> {VTYPES[k]}</button>)}<button className="btn ghost sm" onClick={() => setMake('debit_note')}>Debit note</button><button className="btn ghost sm" onClick={() => setMake('credit_note')}>Credit note</button></div>
      <div className="card"><div className="rangebar">
        <div className="field"><label>From</label><input type="date" className="input" value={from} onChange={(e) => setFrom(e.target.value)} /></div>
        <div className="field"><label>To</label><input type="date" className="input" value={to} onChange={(e) => setTo(e.target.value)} /></div>
        <div className="field"><label>Type</label><select className="input" value={type} onChange={(e) => setType(e.target.value)}><option value="">All vouchers</option>{Object.entries(VTYPES).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
        <button className="btn ghost" onClick={print}><Icon n="printer" /> Print day book</button></div></div>
      <div className="card p0"><div className="tw">{list.length ? <table className="t"><thead><tr><th>Date</th><th>Voucher</th><th>Particulars</th><th className="r">Amount</th><th /></tr></thead><tbody>
        {list.map((v) => <tr key={v.id} style={v.status === 'cancelled' ? { opacity: 0.55 } : undefined}><td className="nw">{v.date}</td><td className="nw"><b>{v.no}</b><div className="code">{VTYPES[v.type]}</div>{v.status === 'cancelled' ? <span className="chip bad" title={v.cancel_reason ?? ''}>Cancelled</span> : null}</td>
          <td>{v.narration}{v.lines.map((l, k) => <div key={k} className="code"><span className={l.side === 'Dr' ? 'dr' : 'cr'}>{l.side}</span> {l.account}{l.currency === 'FC' ? ` · ${fCDF(l.amount)} @ ${l.rate}` : ''} · {fUSD(l.base)}{l.memo ? ` · ${l.memo}` : ''}</div>)}<div className="code">by {v.created_by_name}</div></td>
          <td className="r nw"><b>{fUSD(sum(v.lines.filter((l) => l.side === 'Dr'), (l) => l.base))}</b></td>
          <td>{v.status === 'posted' && ['payment', 'receipt', 'contra', 'journal', 'debit_note', 'credit_note', 'purchase'].includes(v.type) ? <div className="act"><button title="Cancel this voucher" onClick={() => setCancel(v)}><Icon n="x" /></button></div> : null}</td></tr>)}
      </tbody></table> : <Empty i="receipt" t={book.isLoading ? 'Loading' : 'No vouchers in these dates'} />}</div></div>
      {make ? <VoucherModal type={make} onClose={() => setMake(null)} /> : null}
      {cancel ? <CancelVoucher v={cancel} onClose={() => setCancel(null)} /> : null}
    </>
  );
}
function CancelVoucher({ v, onClose }: { v: DayBookEntry; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction();
  const [r, setR] = useState('');
  const go = () => a.run(async () => { await rpc('cancel_voucher', { p_id: v.id, p_reason: r }); await refresh('books', 'grns', 'audit'); toast(`${v.no} cancelled`, 'warn'); onClose(); });
  return (
    <Modal title={`Cancel voucher ${v.no}`} icon="x" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Back</button><button className="btn danger" disabled={a.busy} onClick={() => void go()}><Icon n="x" /> Cancel voucher</button></>}>
      <p>The voucher stays in the day book marked cancelled and no longer counts in any balance.{v.type === 'purchase' ? ' A bill for goods received goes back to waiting for its bill.' : ''}</p>
      <div className="field"><label>Reason</label><input className="input" maxLength={80} value={r} onChange={(e) => setR(e.target.value)} autoFocus /></div><div className="lerr">{a.err}</div>
    </Modal>
  );
}

// ---------- statements ----------
export function StatementView({ ledgers, loading }: { ledgers: Ledger[]; loading: boolean }) {
  const { profile } = useAuth(), settings = useSettings();
  const [acc, setAcc] = useState(''), [from, setFrom] = useState(monthStart()), [to, setTo] = useState(today()), [withOpening, setWithOpening] = useState(true);
  const id = acc || ledgers[0]?.id || '';
  const st = useQuery({ queryKey: ['books', 'statement', id, from, to, withOpening], enabled: !!id, queryFn: () => rpc<Statement>('account_statement', { p_account: id, p_from: from, p_to: to, p_opening: withOpening }) });
  const s = st.data;
  let run = s?.brought_forward ?? 0;
  return (
    <>
      <div className="card"><div className="rangebar">
        <div className="field" style={{ minWidth: 260 }}><label>Ledger</label><select id="stacc" className="input" value={id} onChange={(e) => setAcc(e.target.value)}>{groupOptions(ledgers)}</select></div>
        <div className="field"><label>From</label><input type="date" className="input" value={from} onChange={(e) => setFrom(e.target.value)} /></div>
        <div className="field"><label>To</label><input type="date" className="input" value={to} onChange={(e) => setTo(e.target.value)} /></div>
        <label className="switch" style={{ alignSelf: 'center' }}><input id="stopen" type="checkbox" checked={withOpening} onChange={(e) => setWithOpening(e.target.checked)} /><span>Include opening balance</span></label>
        <button className="btn ghost" disabled={!s} onClick={() => s && printHTML(statementHTML(s, settings.data?.company ?? {}, profile!.name))}><Icon n="printer" /> Print or PDF</button></div></div>
      {!ledgers.length ? <div className="card"><Empty i="wallet" t={loading ? 'Loading' : 'No ledgers to show'} /></div> : !s ? <div className="card"><Empty i={st.error ? 'alert' : 'refresh'} t={st.error ? (st.error as Error).message : 'Loading the statement'} /></div> : <>
        <div className="kpis"><Kpi i="clock" l={withOpening ? 'Opening balance' : 'Opening balance (not included)'}><Dual2 b={balTxt(s.brought_forward)} s={`on ${s.from}`} /></Kpi><Kpi i="plus" l="Debits in the period"><Dual2 b={fUSD(s.total_dr)} s={`${s.lines.filter((l) => l.side === 'Dr').length} entries`} /></Kpi>
          <Kpi i="minus" l="Credits in the period"><Dual2 b={fUSD(s.total_cr)} s={`${s.lines.filter((l) => l.side === 'Cr').length} entries`} /></Kpi><Kpi i="wallet" l="Closing balance" tone="ok"><Dual2 b={balTxt(s.closing)} s={`on ${s.to}`} /></Kpi></div>
        <div className="card p0"><div className="tw"><table className="t" id="sttable"><thead><tr><th>Date</th><th>Voucher</th><th>Particulars</th><th className="r">FC</th><th className="r">Debit</th><th className="r">Credit</th><th className="r">Balance</th></tr></thead><tbody>
          {withOpening ? <tr style={{ background: 'var(--bg)' }}><td>{s.from}</td><td /><td><b>Opening balance</b></td><td /><td className="r">{s.brought_forward > 0 ? fUSD(s.brought_forward) : ''}</td><td className="r">{s.brought_forward < 0 ? fUSD(-s.brought_forward) : ''}</td><td className="r"><b>{balTxt(s.brought_forward)}</b></td></tr> : null}
          {s.lines.map((l) => { run += l.side === 'Dr' ? l.base : -l.base; return <tr key={l.id}><td className="nw">{l.date}</td><td className="nw">{l.no}<div className="code">{VTYPES[l.type]}</div></td><td>{l.narration}{l.memo ? <div className="code">{l.memo}</div> : null}{l.bill_ref ? <div className="code">Bill {l.bill_ref}{l.due_date ? `, due ${l.due_date}` : ''}</div> : null}</td>
            <td className="r nw">{l.currency === 'FC' ? <>{fCDF(l.amount)}<div className="code">@ {l.rate}</div></> : null}</td><td className="r">{l.side === 'Dr' ? fUSD(l.base) : ''}</td><td className="r">{l.side === 'Cr' ? fUSD(l.base) : ''}</td><td className="r nw">{balTxt(run)}</td></tr>; })}
          {!s.lines.length ? <tr><td colSpan={7}><Empty i="doc" t="No entries in these dates" /></td></tr> : null}
          <tr style={{ background: 'var(--bg)' }}><td colSpan={4}><b>Totals and closing balance</b></td><td className="r"><b>{fUSD(s.total_dr)}</b></td><td className="r"><b>{fUSD(s.total_cr)}</b></td><td className="r"><b id="stclose">{balTxt(s.closing)}</b></td></tr>
        </tbody></table></div></div></>}
    </>
  );
}

// ---------- ledgers ----------
function Ledgers({ ledgers }: { ledgers: Ledger[] }) {
  const [open, setOpen] = useState<Ledger | 'new' | null>(null), [q, setQ] = useState('');
  const list = ledgers.filter((l) => !q || (l.name + ' ' + l.group_name).toLowerCase().includes(q.toLowerCase()));
  const by = new Map<string, Ledger[]>(); list.forEach((l) => by.set(l.group_name, [...(by.get(l.group_name) ?? []), l]));
  return (
    <>
      <div className="toolbar"><div className="search"><Icon n="search" /><input placeholder="Ledger or group" value={q} onChange={(e) => setQ(e.target.value)} /></div><span className="sp" /><button className="btn primary" onClick={() => setOpen('new')}><Icon n="plus" /> New ledger</button></div>
      <Note i="lock">Ledgers marked SIM are used by the automatic entries and cannot be deleted. Each supplier's ledger is made with the supplier. A shop gets its cash, sales and stock ledgers when it is added.</Note>
      <div className="card p0"><div className="tw"><table className="t"><thead><tr><th>Ledger</th><th>Currency</th><th className="r">Opening</th><th className="r">Balance now</th><th /></tr></thead><tbody>
        {[...by.entries()].map(([g, ls]) => [<tr key={g} style={{ background: 'var(--bg)' }}><td colSpan={5}><b>{g}</b></td></tr>,
          ...ls.map((l) => <tr key={l.id}><td>&nbsp;&nbsp;{l.name}{l.system ? <> <span className="chip">SIM</span></> : null}{l.active ? null : <> <span className="chip bad">Inactive</span></>}</td><td>{l.currency}</td>
            <td className="r">{l.opening_amount ? `${l.opening_currency === 'FC' ? fCDF(l.opening_amount) : fUSD(l.opening_amount)} ${l.opening_side}` : '-'}</td><td className="r"><b>{balTxt(l.balance)}</b></td>
            <td><div className="act">{l.supplier_id ? null : <button title="Edit ledger" onClick={() => setOpen(l)}><Icon n="edit" /></button>}</div></td></tr>)])}
      </tbody></table></div></div>
      {open ? <LedgerModal l={open === 'new' ? null : open} onClose={() => setOpen(null)} /> : null}
    </>
  );
}
function LedgerModal({ l, onClose }: { l: Ledger | null; onClose: () => void }) {
  const groups = useGroups(), refresh = useRefresh(), toast = useToast(), a = useAction(), b = useAction();
  const [f, setF] = useState({ name: l?.name ?? '', group: l?.group_code ?? 'indexp', currency: l?.currency ?? 'USD', oa: l?.opening_amount ? String(l.opening_amount) : '', oside: l?.opening_side ?? 'Dr', ocur: l?.opening_currency ?? 'USD', orate: l?.opening_rate ? String(l.opening_rate) : '', active: l?.active ?? true });
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  const save = () => a.run(async () => {
    await rpc('save_account', { p: { id: l?.id ?? null, name: f.name, group_code: f.group, currency: f.currency, opening_amount: Number(f.oa) || 0, opening_side: f.oside, opening_currency: f.ocur, opening_rate: Number(f.orate) || null, active: f.active } });
    await refresh('ledgers', 'audit'); toast('Ledger saved'); onClose();
  });
  const del = () => b.run(async () => { if (!l || !confirm(`Delete the ledger ${l.name}?`)) return; await rpc('delete_account', { p_id: l.id }); await refresh('ledgers', 'audit'); toast('Ledger deleted', 'warn'); onClose(); });
  return (
    <Modal title={l ? 'Edit ledger' : 'New ledger'} icon="wallet" onClose={onClose} foot={<>{l && !l.system ? <button className="btn danger" disabled={b.busy} onClick={() => void del()}><Icon n="trash" /> Delete</button> : null}<span className="sp" /><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Save</button></>}>
      <div className="field"><label>Name</label><input id="lname" className="input" maxLength={60} value={f.name} onChange={set('name')} autoFocus placeholder="e.g. Rawbank USD account, Owner's capital, Generator" /></div>
      <div className="frow"><div className="field"><label>Group</label><select id="lgroup" className="input" value={f.group} disabled={!!l?.system} onChange={set('group')}>{(groups.data ?? []).filter((g) => g.code !== 'creditors').map((g) => <option key={g.code} value={g.code}>{g.name}</option>)}</select></div>
        <div className="field"><label>Kept in</label><select className="input" value={f.currency} onChange={set('currency')}><option value="USD">USD</option><option value="FC">Francs (FC)</option></select></div></div>
      <div className="frow three"><div className="field"><label>Opening balance</label><input id="loa" className="input" type="number" min="0" step="0.01" value={f.oa} placeholder="0" onChange={set('oa')} /></div>
        <div className="field"><label>Side</label><select className="input" value={f.oside} onChange={set('oside')}><option value="Dr">Dr</option><option value="Cr">Cr</option></select></div>
        <div className="field"><label>In</label><select className="input" value={f.ocur} onChange={set('ocur')}><option value="USD">USD</option><option value="FC">FC</option></select></div></div>
      {f.ocur === 'FC' ? <div className="field"><label>Rate for the opening balance</label><input className="input" type="number" min="1" value={f.orate} onChange={set('orate')} placeholder="today's rate" /></div> : null}
      <Note i="doc">Opening balances are what each account held when the books started: cash in hand, bank, capital, loans. They show in statements and reports only when you choose to include them.</Note>
      {l && !l.system ? <label className="switch"><input type="checkbox" checked={f.active} onChange={(e) => setF({ ...f, active: e.target.checked })} /><span>Active</span></label> : null}
      <div className="lerr">{a.err || b.err}</div>
    </Modal>
  );
}

// ---------- reports ----------
type TB = { as_of: string; with_opening: boolean; rows: { id: string; name: string; group_name: string; nature: string; balance: number }[]; total_dr: number; total_cr: number; opening_difference: number };
function TrialBalance() {
  const [asOf, setAsOf] = useState(today()), [withOpening, setWithOpening] = useState(true), doc = useDoc();
  const tb = useQuery({ queryKey: ['books', 'tb', asOf, withOpening], queryFn: () => rpc<TB>('trial_balance', { p_as_of: asOf, p_opening: withOpening }) });
  const t = tb.data;
  const body = (t: TB) => `<table class="t"><thead><tr><th>Ledger</th><th>Group</th><th class="r">Debit USD</th><th class="r">Credit USD</th></tr></thead><tbody>${t.rows.map((r) => `<tr><td>${esc(r.name)}</td><td>${esc(r.group_name)}</td><td class="r">${r.balance > 0 ? fUSD(r.balance) : ''}</td><td class="r">${r.balance < 0 ? fUSD(-r.balance) : ''}</td></tr>`).join('')}
    ${Math.abs(t.opening_difference) > 0.005 ? `<tr><td colspan="2">Difference in opening balances</td><td class="r">${t.opening_difference < 0 ? fUSD(-t.opening_difference) : ''}</td><td class="r">${t.opening_difference > 0 ? fUSD(t.opening_difference) : ''}</td></tr>` : ''}
    <tr><td colspan="2"><b>Total</b></td><td class="r"><b>${fUSD(t.total_dr + Math.max(0, -t.opening_difference))}</b></td><td class="r"><b>${fUSD(t.total_cr + Math.max(0, t.opening_difference))}</b></td></tr></tbody></table>`;
  return (
    <>
      <div className="card"><div className="rangebar"><div className="field"><label>As of</label><input type="date" className="input" value={asOf} onChange={(e) => setAsOf(e.target.value)} /></div>
        <label className="switch" style={{ alignSelf: 'center' }}><input type="checkbox" checked={withOpening} onChange={(e) => setWithOpening(e.target.checked)} /><span>Include opening balances</span></label>
        <button className="btn ghost" disabled={!t} onClick={() => t && doc('Trial balance', `as of ${asOf}${withOpening ? '' : ', without opening balances'}`, body(t))}><Icon n="printer" /> Print</button></div></div>
      {t ? <>{Math.abs(t.opening_difference) > 0.005 ? <Note i="alert" warn>The opening balances entered do not balance: difference {balTxt(t.opening_difference)}. Check the opening balances of the ledgers (capital usually takes the difference).</Note> : null}
        <div className="card p0" id="tb"><div dangerouslySetInnerHTML={{ __html: body(t) }} /></div></> : <div className="card"><Empty i="refresh" t="Loading" /></div>}
    </>
  );
}
type PL = { rows: { name: string; group_name: string; group_code: string; nature: string; amount: number }[]; income: number; expense: number; gross_income: number; direct_expense: number };
function ProfitLoss() {
  const [from, setFrom] = useState(monthStart()), [to, setTo] = useState(today()), doc = useDoc();
  const pl = useQuery({ queryKey: ['books', 'pl', from, to], queryFn: () => rpc<PL>('profit_loss', { p_from: from, p_to: to }) });
  const p = pl.data;
  const sec = (rows: PL['rows'], title: string) => `<h3 style="margin:14px 0 6px">${title}</h3><table class="t"><tbody>${rows.map((r) => `<tr><td>${esc(r.name)}<br><small>${esc(r.group_name)}</small></td><td class="r">${fUSD(r.amount)}</td></tr>`).join('') || '<tr><td colspan="2">None</td></tr>'}<tr><td><b>Total</b></td><td class="r"><b>${fUSD(sum(rows, (r) => r.amount))}</b></td></tr></tbody></table>`;
  const body = (p: PL) => { const gross = p.gross_income - p.direct_expense, net = p.income - p.expense;
    return `${sec(p.rows.filter((r) => r.nature === 'income' && r.group_code !== 'indinc'), 'Sales and direct income')}${sec(p.rows.filter((r) => r.group_code === 'direxp'), 'Cost of goods sold and direct expenses')}
    <p style="color:#000;font-size:16px"><b>Gross profit: ${fUSD(gross)}</b></p>${sec(p.rows.filter((r) => r.group_code === 'indinc'), 'Other income')}${sec(p.rows.filter((r) => r.group_code === 'indexp'), 'Running expenses')}
    <p style="color:#000;font-size:18px"><b>Net ${net >= 0 ? 'profit' : 'loss'}: ${fUSD(Math.abs(net))}</b></p><p>Sales are booked without VAT. Amounts in USD at each entry's rate.</p>`; };
  return (
    <>
      <div className="card"><div className="rangebar"><div className="field"><label>From</label><input type="date" className="input" value={from} onChange={(e) => setFrom(e.target.value)} /></div><div className="field"><label>To</label><input type="date" className="input" value={to} onChange={(e) => setTo(e.target.value)} /></div>
        <button className="btn ghost" disabled={!p} onClick={() => p && doc('Profit and loss', `${from} to ${to}`, body(p))}><Icon n="printer" /> Print</button></div></div>
      {p ? <><div className="kpis"><Kpi i="chart" l="Income" tone="ok"><Dual2 b={fUSD(p.income)} s="sales without VAT, other income" /></Kpi><Kpi i="wallet" l="Costs and expenses" tone="warn"><Dual2 b={fUSD(p.expense)} s="cost of goods sold, running costs" /></Kpi>
        <Kpi i="tag" l="Gross profit"><Dual2 b={fUSD(p.gross_income - p.direct_expense)} s="sales minus cost of goods" /></Kpi><Kpi i="check" l={p.income - p.expense >= 0 ? 'Net profit' : 'Net loss'} tone={p.income - p.expense >= 0 ? 'ok' : 'bad'}><Dual2 b={fUSD(Math.abs(p.income - p.expense))} s={`${from} to ${to}`} /></Kpi></div>
        <div className="card" dangerouslySetInnerHTML={{ __html: body(p) }} /></> : <div className="card"><Empty i="refresh" t="Loading" /></div>}
    </>
  );
}
type BS = { rows: { name: string; group_name: string; nature: string; balance: number }[]; profit: number; assets: number; liabilities: number };
function BalanceSheet() {
  const [asOf, setAsOf] = useState(today()), doc = useDoc();
  const bs = useQuery({ queryKey: ['books', 'bs', asOf], queryFn: () => rpc<BS>('balance_sheet', { p_as_of: asOf }) });
  const b = bs.data;
  const body = useMemo(() => (b: BS) => {
    const side = (rows: BS['rows'], neg: boolean) => rows.map((r) => `<tr><td>${esc(r.name)}<br><small>${esc(r.group_name)}</small></td><td class="r">${fUSD(neg ? -r.balance : r.balance)}</td></tr>`).join('');
    const diff = b.assets - b.liabilities - b.profit;
    return `<div style="display:grid;grid-template-columns:1fr 1fr;gap:16px"><div><h3>Capital and liabilities</h3><table class="t"><tbody>${side(b.rows.filter((r) => r.nature !== 'asset'), true)}<tr><td>Profit and loss to date</td><td class="r">${fUSD(b.profit)}</td></tr>${Math.abs(diff) > 0.005 ? `<tr><td>Difference in opening balances</td><td class="r">${fUSD(diff)}</td></tr>` : ''}<tr><td><b>Total</b></td><td class="r"><b>${fUSD(b.assets)}</b></td></tr></tbody></table></div>
      <div><h3>Assets</h3><table class="t"><tbody>${side(b.rows.filter((r) => r.nature === 'asset'), false)}<tr><td><b>Total</b></td><td class="r"><b>${fUSD(b.assets)}</b></td></tr></tbody></table></div></div>`;
  }, []);
  return (
    <>
      <div className="card"><div className="rangebar"><div className="field"><label>As of</label><input type="date" className="input" value={asOf} onChange={(e) => setAsOf(e.target.value)} /></div>
        <button className="btn ghost" disabled={!b} onClick={() => b && doc('Balance sheet', `as of ${asOf}`, body(b))}><Icon n="printer" /> Print</button></div></div>
      {b ? <div className="card" dangerouslySetInnerHTML={{ __html: body(b) }} /> : <div className="card"><Empty i="refresh" t="Loading" /></div>}
    </>
  );
}
