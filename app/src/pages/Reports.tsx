import { useState } from 'react';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useReport, useSettings, useShops } from '../data/queries';
import { dt, fCDF, fUSD, ld, shortCDF, today } from '../lib/format';
import { printHTML, reportHTML, shiftSlipHTML } from '../lib/print';
import { Bars, Dual2, Empty, Head, HList, Kpi, Modal } from '../components/ui';

export default function Reports() {
  const { profile } = useAuth();
  const isAdmin = profile!.role === 'admin';
  const [from, setFrom] = useState(ld(Date.now() - 6 * 864e5)), [to, setTo] = useState(today()), [shop, setShop] = useState('all');
  const [doc, setDoc] = useState<{ title: string; html: string; slip: boolean } | null>(null);
  const settings = useSettings(), shops = useShops();
  const sid = isAdmin ? (shop === 'all' ? null : shop) : profile!.shop_id;
  const rep = useReport(from <= to ? from : to, from <= to ? to : from, sid);
  const r = rep.data, single = from === to;
  const shopName = (id: string) => shops.data?.find((s) => s.id === id)?.name ?? '';
  const setRange = (k: string) => { const n = Date.now(), D = 864e5; setTo(today()); setFrom(k === 'today' ? today() : k === '7' ? ld(n - 6 * D) : k === '30' ? ld(n - 29 * D) : today().slice(0, 8) + '01'); };
  const print = () => {
    if (!r) return;
    if (single) {
      // day end report: one slip per shop (all shops plus a total for the Admin)
      const slips = r.slips.map((s) => shiftSlipHTML(s, profile!.username, from, settings.data?.rate ?? 0));
      if (r.slips.length > 1) slips.push(shiftSlipHTML({ shop_name: 'All shops', n: r.n, value_fc: r.total, value_usd: r.total_usd, collected: r.slips.reduce((a, s) => a + s.collected, 0), returned: r.slips.reduce((a, s) => a + s.returned, 0) }, profile!.username, from, settings.data?.rate ?? 0));
      const html = slips.join('<div class="pagebreak"></div>');
      setDoc({ title: 'Day end report', html, slip: true }); setTimeout(() => printHTML(html), 400);
    } else {
      const html = reportHTML(r, settings.data?.company ?? {}, sid ? shopName(sid) : 'All shops', profile!.name, shopName, !sid, settings.data?.vat ?? 0);
      setDoc({ title: 'Sales report', html, slip: false }); setTimeout(() => printHTML(html), 400);
    }
  };
  return (
    <>
      <Head t="Sales report" s="Pick the dates, then print. A single day, such as Today, prints the day end report for the shop." a={<button className="btn primary" disabled={!r} onClick={print}><Icon n="printer" /> {single ? 'Print day end report' : 'Print or save as PDF'}</button>} />
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
          {isAdmin ? <Kpi i="chart" l="Gross profit, excl. VAT"><Dual2 b={fUSD(r.profit_usd ?? 0)} s={fCDF((r.profit_usd ?? 0) * (settings.data?.rate ?? 0))} /></Kpi> : <Kpi i="cash" l="Cash taken"><Dual2 b={fCDF(r.total)} s="all sales are cash" /></Kpi>}
        </div>
        <div className="cols">
          <div className="card"><h3><Icon n="chart" /> Sales by day (FC)</h3>{r.by_day.length ? <Bars arr={r.by_day.slice(-14).map((d) => ({ label: d.day.slice(8) + '/' + d.day.slice(5, 7), val: d.v, txt: shortCDF(d.v) }))} /> : <Empty i="chart" t="No sales in these dates" />}</div>
          <div className="card"><h3><Icon n="box" /> Best sellers</h3><HList arr={r.top.slice(0, 8).map((x) => ({ name: x.name, val: x.val, txt: fCDF(x.val) }))} /></div>
          <div className="card"><h3><Icon n="users" /> By cashier</h3><HList arr={r.by_cashier.map((x) => ({ name: x.name, val: x.v, txt: fCDF(x.v) }))} /></div>
        </div>
        <div className="card p0"><div style={{ padding: '16px 16px 0' }}><h3><Icon n="receipt" /> Invoices in this period</h3></div>{r.invoices.length ? <div className="tw"><table className="t"><thead><tr><th>Invoice</th><th>Date</th>{!sid ? <th>Shop</th> : null}<th>Customer</th><th>Cashier</th><th className="r">Items</th><th className="r">Discount</th><th className="r">Total</th></tr></thead><tbody>
          {r.invoices.slice(0, 150).map((i) => <tr key={i.id}><td><b>{i.no}</b>{i.edited ? <> <span className="chip warn">Edited</span></> : null}</td><td>{dt(i.t)}</td>{!sid ? <td>{shopName(i.shop_id)}</td> : null}<td>{i.customer || '-'}</td><td>{i.cashier_name}</td><td className="r">{i.items}</td><td className="r">{i.disc ? fCDF(i.disc) : '-'}</td><td className="r"><b>{fCDF(i.total)}</b></td></tr>)}
        </tbody></table></div> : <Empty i="receipt" t="No invoices in these dates" />}</div>
      </>}
      {doc ? <Modal title={doc.title} icon="doc" wide={!doc.slip} onClose={() => setDoc(null)} foot={<><button className="btn" onClick={() => setDoc(null)}>Close</button><button className="btn primary" onClick={() => printHTML(doc.html)}><Icon n="printer" /> Print</button></>}>
        <div className={doc.slip ? 'rwrap' : ''} id="slips" style={doc.slip ? { display: 'grid', gap: 14 } : undefined} dangerouslySetInnerHTML={{ __html: doc.html }} /></Modal> : null}
    </>
  );
}
