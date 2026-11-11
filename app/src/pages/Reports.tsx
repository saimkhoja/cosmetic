import { useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useCategories, useRefresh, useReport, useSettings, useShifts, useShops, useTills } from '../data/queries';
import { bookRate, dt, fCDF, fUSD, ld, shortCDF, tm, today } from '../lib/format';
import { printHTML, reportHTML, shiftSlipHTML, type CategorySales, type Slip } from '../lib/print';
import { Bars, Dual2, Empty, Head, HList, Kpi, Modal, Note, useAction } from '../components/ui';
import { rpc } from '../lib/supabase';
import { CategoryChart, unitsText } from '../components/CategoryChart';

export default function Reports() {
  const { profile } = useAuth();
  const isAdmin = profile!.role === 'admin';
  // opened from the global search on an invoice: that day and that shop
  const [params] = useSearchParams(), day = /^\d{4}-\d{2}-\d{2}$/.test(params.get('day') ?? '') ? params.get('day')! : null;
  const [from, setFrom] = useState(day ?? ld(Date.now() - 6 * 864e5)), [to, setTo] = useState(day ?? today()), [shop, setShop] = useState(params.get('shop') ?? 'all');
  const [doc, setDoc] = useState<{ title: string; html: string; slip: boolean } | null>(null), [cat, setCat] = useState<CategorySales | null>(null);
  const settings = useSettings(), shops = useShops(), cats = useCategories();
  const sid = isAdmin ? (shop === 'all' ? null : shop) : profile!.shop_id;
  const rep = useReport(from <= to ? from : to, from <= to ? to : from, sid);
  const r = rep.data, single = from === to;
  const shopName = (id: string) => shops.data?.find((s) => s.id === id)?.name ?? '';
  const setRange = (k: string) => { const n = Date.now(), D = 864e5; setTo(today()); setFrom(k === 'today' ? today() : k === '7' ? ld(n - 6 * D) : k === '30' ? ld(n - 29 * D) : today().slice(0, 8) + '01'); };
  // the Shop Admin prints the shift end report with the passcode the Admin gave, for every till (combined) or one till.
  // Today: the shift since the last one printed for that choice, then a new shift starts. A past day: the whole day.
  // A shift already printed can be printed again as it was.
  const [ask, setAsk] = useState(false), [code, setCode] = useState(''), [till, setTill] = useState(''), [again, setAgain] = useState(''), pa = useAction(), refresh = useRefresh();
  const tills = useTills(isAdmin ? null : profile!.shop_id, ask), shifts = useShifts(ask && !isAdmin);
  const isToday = from === today(), tillCode = (id: string | null) => tills.data?.find((t) => t.id === id)?.code ?? null;
  const done = (shifts.data ?? []).filter((x) => (x.device_id ?? '') === till && x.day === from);
  const last = (shifts.data ?? []).find((x) => (x.device_id ?? '') === till);
  const printSlip = () => pa.run(async () => {
    if (!code.trim()) throw new Error('Enter the passcode');
    const action = again ? 'reprint' : isToday ? 'close' : 'day';
    const res = await rpc<{ ok: boolean; error?: string; slip?: Slip; shift_no?: number; from?: string; to?: string; till?: string | null }>('shift_end_report',
      { p_code: code, p_action: action, p_device: till || null, p_day: action === 'day' ? from : null, p_shift: again || null });
    setCode('');
    if (!res.ok || !res.slip) throw new Error(res.error ?? 'Wrong passcode');
    const shift = res.shift_no ? `${res.shift_no}, ${dt(res.from!).split(',')[0] === dt(res.to!).split(',')[0] ? tm(res.from!) : dt(res.from!)} to ${tm(res.to!)}${again ? ' (copy)' : ''}` : 'Whole day';
    const html = shiftSlipHTML(res.slip, profile!.username, again ? ld(res.to!) : from, settings.data?.rate ?? 0, { till: res.till ?? null, shift });
    setAsk(false); setAgain(''); if (action === 'close') void refresh('shifts');
    setDoc({ title: res.shift_no ? `Shift end report, shift ${res.shift_no}` : 'Day end report', html, slip: true }); setTimeout(() => printHTML(html), 400);
  });
  const print = () => {
    if (!r) return;
    if (single && !isAdmin) { pa.setErr(''); setCode(''); setAgain(''); setAsk(true); return; }
    if (single) {
      // day end report: one slip per shop (all shops plus a total for the Admin)
      const slips = r.slips.map((s) => shiftSlipHTML(s, profile!.username, from, settings.data?.rate ?? 0));
      if (r.slips.length > 1) slips.push(shiftSlipHTML({ shop_name: 'All shops', n: r.n, value_fc: r.total, value_usd: r.total_usd, collected: r.slips.reduce((a, s) => a + s.collected, 0), returned: r.slips.reduce((a, s) => a + s.returned, 0), collected_usd: r.slips.reduce((a, s) => a + Number(s.collected_usd ?? 0), 0), collected_cdf: r.slips.reduce((a, s) => a + Number(s.collected_cdf ?? s.collected), 0) }, profile!.username, from, settings.data?.rate ?? 0));
      const html = slips.join('<div class="pagebreak"></div>');
      setDoc({ title: 'Day end report', html, slip: true }); setTimeout(() => printHTML(html), 400);
    } else {
      const html = reportHTML(r, settings.data?.company ?? {}, sid ? shopName(sid) : 'All shops', profile!.name, shopName, !sid, settings.data?.vat ?? 0);
      setDoc({ title: 'Sales report', html, slip: false }); setTimeout(() => printHTML(html), 400);
    }
  };
  return (
    <>
      <Head t="Sales report" s={isAdmin ? 'Pick the dates, then print. A single day, such as Today, prints the day end report for the shop.' : 'Pick the dates, then print. A single day, such as Today, prints the shift end report for the shop, with the passcode the Admin gave you.'} a={<button className="btn primary" disabled={!r} onClick={print}><Icon n="printer" /> {single ? 'Print day end report' : 'Print or save as PDF'}</button>} />
      <div className="card"><div className="rangebar">
        <div className="field"><label>From</label><input type="date" className="input" value={from} max={today()} onChange={(e) => setFrom(e.target.value)} /></div>
        <div className="field"><label>To</label><input type="date" className="input" value={to} max={today()} onChange={(e) => setTo(e.target.value)} /></div>
        {isAdmin ? <div className="field"><label>Shop</label><select className="input" value={shop} onChange={(e) => setShop(e.target.value)}><option value="all">All shops</option>{(shops.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></div> : null}
        <div className="seg">{[['today', 'Today'], ['7', '7 days'], ['30', '30 days'], ['month', 'This month']].map(([k, l]) => <button key={k} onClick={() => setRange(k)}>{l}</button>)}</div>
      </div></div>
      {!r ? <div className="card"><Empty i={rep.error ? 'alert' : 'refresh'} t={rep.error ? (rep.error as Error).message : 'Loading the report'} /></div> : <>
        <div className="kpis">
          <Kpi i="receipt" l="Sales, VAT included" tone="ok"><Dual2 b={fCDF(r.total)} s={`${r.n} invoices${isAdmin ? ', ' + fUSD(r.total_usd) : ''}`} /></Kpi>
          <Kpi i="cart" l="Items sold"><Dual2 b={r.items} s={`${r.n ? fCDF(r.total / r.n) : fCDF(0)} average sale`} /></Kpi>
          <Kpi i="tag" l="Discounts given" tone="warn"><Dual2 b={fCDF(r.disc)} s={`VAT in the period ${fCDF(r.vat)}`} /></Kpi>
          {isAdmin ? <Kpi i="chart" l="Gross profit, after VAT on the margin"><Dual2 b={fUSD(r.profit_usd ?? 0)} s={fCDF((r.profit_usd ?? 0) * bookRate(settings.data))} /></Kpi> : <Kpi i="cash" l="Cash taken"><Dual2 b={fCDF(r.total)} s="all sales are cash" /></Kpi>}
        </div>
        <div className="card"><h3><Icon n="chart" /> Sales by category</h3>
          {r.by_category ? <CategoryChart cats={r.by_category} names={(cats.data ?? []).map((c) => c.name)} onOpen={setCat} />
            : <Empty i="alert" t="Sales by category need the latest database update (migration 21 in the deploy guide)" />}</div>
        <div className="cols">
          <div className="card"><h3><Icon n="chart" /> Sales by day (CDF)</h3>{r.by_day.length ? <Bars arr={r.by_day.slice(-14).map((d) => ({ label: d.day.slice(8) + '/' + d.day.slice(5, 7), val: d.v, txt: shortCDF(d.v) }))} /> : <Empty i="chart" t="No sales in these dates" />}</div>
          <div className="card"><h3><Icon n="box" /> Best sellers</h3><HList arr={r.top.slice(0, 8).map((x) => ({ name: x.name, val: x.val, txt: fCDF(x.val) }))} /></div>
          <div className="card"><h3><Icon n="users" /> By cashier</h3><HList arr={r.by_cashier.map((x) => ({ name: x.name, val: x.v, txt: fCDF(x.v) }))} /></div>
        </div>
        <div className="card p0"><div style={{ padding: '16px 16px 0' }}><h3><Icon n="receipt" /> Invoices in this period</h3></div>{r.invoices.length ? <div className="tw"><table className="t"><thead><tr><th>Invoice</th><th>Date</th>{!sid ? <th>Shop</th> : null}<th>Customer</th><th>Cashier</th><th className="r">Items</th><th className="r">Discount</th><th className="r">Total</th></tr></thead><tbody>
          {r.invoices.slice(0, 150).map((i) => <tr key={i.id}><td><b>{i.no}</b>{i.edited ? <> <span className="chip warn">Edited</span></> : null}</td><td>{dt(i.t)}</td>{!sid ? <td>{shopName(i.shop_id)}</td> : null}<td>{i.customer || '-'}</td><td>{i.cashier_name}</td><td className="r">{i.items}</td><td className="r">{i.disc ? fCDF(i.disc) : '-'}</td><td className="r"><b>{fCDF(i.total)}</b></td></tr>)}
        </tbody></table></div> : <Empty i="receipt" t="No invoices in these dates" />}</div>
      </>}
      {cat && r ? <Modal title={`${cat.category}: items sold`} icon="box" wide onClose={() => setCat(null)} foot={<button className="btn" onClick={() => setCat(null)}>Close</button>}>
        <p><b>{fCDF(cat.val)}</b>, {r.total ? Math.round((cat.val * 1000) / r.total) / 10 : 0}% of the sales from {r.from} to {r.to}{sid ? `, ${shopName(sid)}` : ''}. {cat.items.length} item{cat.items.length === 1 ? '' : 's'}, {cat.pcs} pcs. Amounts are after the invoice discounts, VAT included.</p>
        <div className="tw"><table className="t" id="catitems"><thead><tr><th>#</th><th>Item</th><th>Sold</th><th className="r">Pcs</th><th className="r">Amount</th><th className="r">Share</th></tr></thead><tbody>
          {cat.items.map((it, k) => <tr key={it.product_id}><td>{k + 1}</td><td><b>{it.name}</b></td><td>{unitsText(it.units)}</td>
            <td className="r">{it.pcs}{it.pieces ? <div className="code">+ {it.pieces} piece{it.pieces > 1 ? 's' : ''}</div> : null}</td>
            <td className="r nw"><b>{fCDF(it.val)}</b></td><td className="r">{cat.val ? Math.round((it.val * 1000) / cat.val) / 10 : 0}%</td></tr>)}
        </tbody></table></div>
      </Modal> : null}
      {ask ? <Modal title={isToday ? 'Shift end report' : 'Day end report'} icon="lock" onClose={() => setAsk(false)} foot={<><button className="btn" onClick={() => setAsk(false)}>Cancel</button><button className="btn primary" id="slipbtn" disabled={pa.busy} onClick={() => void printSlip()}><Icon n="printer" /> {again ? 'Print again' : isToday ? 'Print and start a new shift' : 'Print day end report'}</button></>}>
        <div className="field"><label htmlFor="sliptill">Till</label><select id="sliptill" className="input" value={till} onChange={(e) => { setTill(e.target.value); setAgain(''); }}>
          <option value="">All tills (combined)</option>{(tills.data ?? []).map((t) => <option key={t.id} value={t.id}>Till {t.code}</option>)}</select></div>
        {isToday ? <>
          <div className="field"><label htmlFor="slipshift">Report</label><select id="slipshift" className="input" value={again} onChange={(e) => setAgain(e.target.value)}>
            <option value="">New: shift {done.length + 1}, sales since {last ? (last.day === from ? tm(last.to_at) : dt(last.to_at)) : 'the start of the day'}</option>
            {done.map((x) => <option key={x.id} value={x.id}>Print again: shift {x.shift_no}, {tm(x.from_at)} to {tm(x.to_at)} ({x.closed_by_name.split(' ')[0]})</option>)}</select></div>
          {!again ? <Note i="clock">{till ? `Till ${tillCode(till)} only. ` : 'Every till together. '}After printing, a new shift starts for {till ? 'this till' : 'all tills combined'}: the next report has only the sales made after it. Sales today and the sales report keep the whole day.</Note> : null}
        </> : <Note i="clock">The whole day, {till ? `Till ${tillCode(till)} only` : 'every till together'}. No shift is closed.</Note>}
        <div className="field"><label htmlFor="slipcode">Passcode</label><input id="slipcode" className="input" type="password" inputMode="numeric" autoComplete="off" maxLength={12} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} onKeyDown={(e) => { if (e.key === 'Enter') void printSlip(); }} autoFocus /></div>
        <div className="lerr">{pa.err}</div>
        <Note i="shield">It needs the connection.</Note>
      </Modal> : null}
      {doc ? <Modal title={doc.title} icon="doc" wide={!doc.slip} onClose={() => setDoc(null)} foot={<><button className="btn" onClick={() => setDoc(null)}>Close</button><button className="btn primary" onClick={() => printHTML(doc.html)}><Icon n="printer" /> Print</button></>}>
        <div className={doc.slip ? 'rwrap' : ''} id="slips" style={doc.slip ? { display: 'grid', gap: 14 } : undefined} dangerouslySetInnerHTML={{ __html: doc.html }} /></Modal> : null}
    </>
  );
}
