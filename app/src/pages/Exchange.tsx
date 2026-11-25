// Money exchange at the shop counter: the Shop Admin buys dollars (takes USD, gives CDF) or sells them (takes CDF,
// gives USD) out of the shop's cash, at the buying and selling rates the Admin sets in Settings. The Admin sees every
// shop's exchanges and can cancel one. Everything here needs the connection.
import { useState } from 'react';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useExchanges, useRefresh, useSettings, useShops, type MoneyExchange } from '../data/queries';
import { rpc } from '../lib/supabase';
import { bookRate, dt, fCDF, fNum, fUSD, today } from '../lib/format';
import { exchangeCalc, type FxDir } from '../lib/exchange';
import { exchangeReceiptHTML, printHTML } from '../lib/print';
import { getDevice } from '../offline/store';
import { Dual2, Empty, Head, Kpi, Note, useAction, useToast } from '../components/ui';

const gainTxt = (g: number) => (g >= 0 ? '+' : '-') + fUSD(Math.abs(g));

export default function Exchange() {
  const { profile } = useAuth(), isAdmin = profile!.role === 'admin';
  const settings = useSettings(), shops = useShops(), refresh = useRefresh(), toast = useToast();
  const [day, setDay] = useState(today()), [shop, setShop] = useState('');
  const ex = useExchanges(day, day, isAdmin ? shop || null : null), d = ex.data;
  const s = settings.data, book = bookRate(s), buyRate = Number(s?.fx_buy_rate || book), sellRate = Number(s?.fx_sell_rate || book);
  const cancel = (x: MoneyExchange) => {
    const r = prompt(`Cancel exchange ${x.no}? Write the reason:`); if (!r) return;
    void rpc('cancel_exchange', { p_id: x.id, p_reason: r }).then(async () => { await refresh('exchanges', 'audit', 'report'); toast(`Exchange ${x.no} cancelled`, 'warn'); }, (e: Error) => toast(e.message, 'bad'));
  };
  return (
    <>
      <Head t="Money exchange" s={<>Dollars bought and sold over the counter, out of the shop's cash. The shop buys at <b>{fCDF(buyRate)}</b> and sells at <b>{fCDF(sellRate)}</b> for 1 USD{isAdmin ? ' (Settings)' : ''}.</>} />
      <div className="kpis">
        <Kpi i="download" l="Dollars bought" tone="ok"><Dual2 b={fUSD(d?.bought_usd ?? 0)} s={`${fCDF(d?.cdf_out ?? 0)} given out`} /></Kpi>
        <Kpi i="upload" l="Dollars sold"><Dual2 b={fUSD(d?.sold_usd ?? 0)} s={`${fCDF(d?.cdf_in ?? 0)} taken in`} /></Kpi>
        <Kpi i="cash" l="In the drawer"><Dual2 b={`${(d?.bought_usd ?? 0) - (d?.sold_usd ?? 0) >= 0 ? '+' : '-'}${fUSD(Math.abs((d?.bought_usd ?? 0) - (d?.sold_usd ?? 0)))}`} s={`${(d?.cdf_in ?? 0) - (d?.cdf_out ?? 0) >= 0 ? '+' : '-'}${fCDF(Math.abs((d?.cdf_in ?? 0) - (d?.cdf_out ?? 0)))}`} /></Kpi>
        <Kpi i="chart" l="Margin" tone={(d?.gain_usd ?? 0) < 0 ? 'bad' : 'ok'}><Dual2 b={gainTxt(d?.gain_usd ?? 0)} s={`${d?.n ?? 0} exchange${d?.n === 1 ? '' : 's'}, at the internal rate`} /></Kpi>
      </div>
      {isAdmin ? null : <ChangeMoney buyRate={buyRate} sellRate={sellRate} book={book} />}
      <div className="card p0">
        <div className="toolbar" style={{ padding: '12px 14px', margin: 0 }}>
          <div className="field" style={{ margin: 0 }}><label htmlFor="fxday">Day</label><input id="fxday" type="date" className="input" value={day} max={today()} onChange={(e) => setDay(e.target.value || today())} /></div>
          {isAdmin ? <div className="field" style={{ margin: 0 }}><label htmlFor="fxshop">Shop</label><select id="fxshop" className="input" value={shop} onChange={(e) => setShop(e.target.value)}><option value="">All shops</option>{(shops.data ?? []).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></div> : null}
        </div>
        <div className="tw">{d?.list.length ? <table className="t" id="fxlist"><thead><tr><th>No.</th><th>Exchange</th><th className="r">Dollars</th><th className="r">Rate</th><th className="r">Francs</th><th className="r">Margin</th><th>Customer</th><th /></tr></thead><tbody>
          {d.list.map((x) => { const off = x.status === 'cancelled'; return <tr key={x.id} style={off ? { opacity: 0.55 } : undefined}>
            <td className="nw">{x.no}<div className="code">{dt(x.at)}, {x.by_name}{isAdmin && !shop ? `, ${x.shop_name}` : ''}</div></td>
            <td>{x.dir === 'buy' ? <span className="chip ok">Bought USD</span> : <span className="chip">Sold USD</span>}{off ? <div className="code bad">Cancelled: {x.cancel_reason}</div> : null}</td>
            <td className="r nw">{off ? <s>{fUSD(x.usd)}</s> : <b>{x.dir === 'buy' ? '+' : '-'}{fUSD(x.usd)}</b>}</td>
            <td className="r nw">{fNum(x.rate)}</td>
            <td className="r nw">{off ? <s>{fCDF(x.cdf)}</s> : <>{x.dir === 'buy' ? '-' : '+'}{fCDF(x.cdf)}</>}</td>
            <td className={`r nw ${x.gain_usd < 0 ? 'bad' : ''}`}>{off ? '' : gainTxt(x.gain_usd)}</td>
            <td>{x.customer}{x.note ? <div className="code">{x.note}</div> : null}</td>
            <td style={{ width: 1 }}>{off ? null : <button className="btn sm" onClick={() => cancel(x)} aria-label={`Cancel exchange ${x.no}`}><Icon n="x" /> Cancel</button>}</td></tr>; })}
        </tbody></table> : <Empty i="dollar" t={ex.isLoading ? 'Loading' : 'No money exchanged on this day'} />}</div>
      </div>
      <Note>Each exchange moves the money between the shop's two cash drawers in the books (Cash and Cash USD), at the internal rate of {fCDF(book)}. The difference is the shop's margin, booked to Exchange gain on dollars: a gain, or a loss when the rate given is worse for the shop than the internal rate. The shift end report shows the dollars and Francs exchanged, so the drawer adds up.</Note>
    </>
  );
}

/** The Shop Admin's form: which way, how many dollars, the rate (Settings, or typed), and what to give or take. */
function ChangeMoney({ buyRate, sellRate, book }: { buyRate: number; sellRate: number; book: number }) {
  const { profile } = useAuth(), settings = useSettings(), shops = useShops(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const [dir, setDir] = useState<FxDir>('buy'), [usd, setUsd] = useState(''), [typed, setTyped] = useState<string | null>(null);
  const [customer, setCustomer] = useState(''), [note, setNote] = useState(''), [print, setPrint] = useState(false);
  const setRate = dir === 'buy' ? buyRate : sellRate, rate = typed ?? String(setRate), X = exchangeCalc(dir, usd, rate, book);
  const go = () => a.run(async () => {
    if (!(X.usd > 0)) throw new Error('Enter the dollars');
    if (X.err) throw new Error(X.err);
    const sid = profile!.shop_id!, dev = await getDevice(sid);
    const r = await rpc<MoneyExchange>('exchange_money', { p: { dir, usd: X.usd, rate: typed === null ? null : X.rate, customer, note, device_id: dev?.id ?? null } });
    const shop = shops.data?.find((x) => x.id === sid);
    if (print && shop) printHTML(exchangeReceiptHTML(r, settings.data?.company ?? {}, shop));
    await refresh('exchanges', 'audit', 'report');
    toast(`Exchange ${r.no}: ${dir === 'buy' ? `took ${fUSD(r.usd)}, gave ${fCDF(r.cdf)}` : `took ${fCDF(r.cdf)}, gave ${fUSD(r.usd)}`}`);
    setUsd(''); setCustomer(''); setNote(''); setTyped(null);
  });
  const enter = (e: React.KeyboardEvent) => { if (e.key === 'Enter') { e.preventDefault(); void go(); } };
  return (
    <div className="card" id="fxform"><h3><Icon n="dollar" /> Change money</h3>
      <div className="cnotes">
        <button type="button" className={dir === 'buy' ? 'on' : ''} onClick={() => { setDir('buy'); setTyped(null); }}>Customer gives dollars<br /><small>shop buys at {fNum(buyRate)}</small></button>
        <button type="button" className={dir === 'sell' ? 'on' : ''} onClick={() => { setDir('sell'); setTyped(null); }}>Customer wants dollars<br /><small>shop sells at {fNum(sellRate)}</small></button>
      </div>
      <div className="frow">
        <div className="field"><label htmlFor="fxusd">{dir === 'buy' ? 'Dollars received' : 'Dollars to give'}</label><input id="fxusd" className="input" type="number" min="0" step="1" inputMode="decimal" value={usd} onChange={(e) => setUsd(e.target.value)} onKeyDown={enter} placeholder="0" autoFocus /></div>
        <div className="field"><label htmlFor="fxrate">Rate: 1 USD in CDF{typed !== null && Number(typed) !== setRate ? <span className="chip warn" style={{ marginLeft: 6 }}>typed by hand</span> : null}</label>
          <input id="fxrate" className="input" type="number" min="1" step="1" inputMode="decimal" value={rate} onChange={(e) => setTyped(e.target.value)} onKeyDown={enter} />
          <span className="hint">{typed !== null && Number(typed) !== setRate ? <><button type="button" className="linkbtn" onClick={() => setTyped(null)}>Use the {dir === 'buy' ? 'buying' : 'selling'} rate ({fNum(setRate)})</button></> : `The ${dir === 'buy' ? 'buying' : 'selling'} rate from Settings. Type another for this exchange only.`}</span></div>
      </div>
      <div id="fxsum" className={`paychange ${!(X.usd > 0) ? '' : X.err ? 'bad' : 'ok'}`}>
        <span>{X.err && X.usd > 0 ? 'Check the exchange' : dir === 'buy' ? 'Give the customer' : 'Take from the customer'}</span>
        <b>{X.usd > 0 && !X.err ? fCDF(X.cdf) : '-'}</b></div>
      {X.usd > 0 && X.err ? <Note warn i="alert">{X.err}</Note> : null}
      {X.usd > 0 && !X.err ? <div className="paynote" style={{ color: 'var(--muted)' }}>{fUSD(X.usd)} × {fNum(X.rate)} = {fCDF(X.exact)}{X.rounded ? `, rounded ${dir === 'buy' ? 'down' : 'up'} by ${fNum(X.rounded)} FC` : ''} · margin {gainTxt(X.gain)}</div> : null}
      <div className="frow">
        <div className="field"><label htmlFor="fxcust">Customer</label><input id="fxcust" className="input" maxLength={60} value={customer} onChange={(e) => setCustomer(e.target.value)} placeholder="Optional" /></div>
        <div className="field"><label htmlFor="fxnote">Note</label><input id="fxnote" className="input" maxLength={120} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Optional" /></div>
      </div>
      <label className="switch"><input type="checkbox" checked={print} onChange={(e) => setPrint(e.target.checked)} /><span>Print a receipt for the customer</span></label>
      <div className="lerr">{a.err}</div>
      <button className="btn primary full" id="fxsave" disabled={a.busy || !(X.usd > 0) || !!X.err} onClick={() => void go()}><Icon n="check" /> {dir === 'buy' ? 'Record: dollars in, Francs out' : 'Record: Francs in, dollars out'}</button>
    </div>
  );
}
