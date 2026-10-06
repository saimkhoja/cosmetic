import { useMemo, useState } from 'react';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useCosts, useProducts, useRefresh, useSettings } from '../data/queries';
import { rpc } from '../lib/supabase';
import { ctnTxt, unitLabel, unitsOf } from '../lib/units';
import { CATS, itemProblem, type ItemInput } from '../lib/items';
import { fCDF, fUSD, toCDF } from '../lib/format';
import { Dual, Empty, Head, Modal, Note, num, useAction, useToast } from '../components/ui';
import { IMPCOLS, impParse, readCSV, readXlsx, saveBlob, templateXlsx, type ImportRow } from '../lib/xlsx';
import type { Cost, Product } from '../lib/types';

export const QtyCell = ({ p, q, cls = '' }: { p: Product; q: number; cls?: string }) => (
  <><span className={`chip ${cls}`}>{q} {p.stock_unit}</span>{ctnTxt(p, q) ? <div className="code">{ctnTxt(p, q)}</div> : null}</>
);

export default function Inventory() {
  const { profile } = useAuth();
  const isAdmin = profile!.role === 'admin';
  const products = useProducts(), costs = useCosts(isAdmin), settings = useSettings();
  const [q, setQ] = useState(''), [edit, setEdit] = useState<Product | 'new' | null>(null), [recv, setRecv] = useState<Product | null>(null), [imp, setImp] = useState(false);
  const rate = settings.data?.rate ?? 1;
  const costOf = useMemo(() => new Map((costs.data ?? []).map((c) => [c.product_id, c])), [costs.data]);
  const list = (products.data ?? []).filter((p) => !q || (p.name + ' ' + p.sku + ' ' + p.category).toLowerCase().includes(q.toLowerCase()));
  return (
    <>
      <Head t="Inventory" s={isAdmin ? 'Selling prices, sets and piece prices are set here only. Shops see them in Francs and cannot change them.' : 'Item names, units and quantities. Prices are set by the Admin.'}
        a={isAdmin ? <><button className="btn ghost" onClick={() => setImp(true)}><Icon n="download" /> Import from Excel</button><button className="btn primary" onClick={() => setEdit('new')}><Icon n="plus" /> Add new item</button></> : null} />
      <div className="toolbar"><div className="search"><Icon n="search" /><input placeholder="Search by name, code or category" value={q} onChange={(e) => setQ(e.target.value)} /></div><span className="chip">{products.data?.length ?? 0} items</span>{isAdmin ? null : <span className="chip warn"><Icon n="lock" /> Cost prices hidden for your role</span>}</div>
      <div className="card p0"><div className="tw">
        {products.isLoading ? <Empty i="refresh" t="Loading items" /> : !list.length ? <Empty i="search" t={products.data?.length ? 'No items match your search' : 'No items yet. Add one or import from Excel.'} /> :
          <table className="t"><thead><tr><th>Item</th><th>Category</th><th className="r">In store</th>{isAdmin ? <th>Cost</th> : null}<th>Selling prices</th>{isAdmin ? <th className="r">Margin</th> : null}<th /></tr></thead><tbody>
            {list.map((p) => { const c = costOf.get(p.id); return (
              <tr key={p.id}>
                <td><b>{p.name}</b><div className="code">{p.sku}{p.is_bundle ? ` · mixed set of ${p.pieces_per_set}` : p.per_carton > 1 ? ` · ${p.per_carton} pcs per carton` : ''}</div></td><td>{p.category}</td>
                <td className="r"><QtyCell p={p} q={p.wh_qty} cls={p.wh_qty <= p.reorder ? 'bad' : 'ok'} /></td>
                {isAdmin ? <td>{c ? (p.is_bundle ? <><Dual usd={c.cost_usd} rate={rate} /><div className="code">per set</div></> : <><Dual usd={c.carton_cost_usd} rate={rate} /><div className="code">per carton, {fUSD(c.cost_usd)} per pc</div></>) : '-'}</td> : null}
                <td>{unitsOf(p).map((u, k) => <div key={k} style={{ whiteSpace: 'nowrap' }}><span className="uchip">{unitLabel(u)}</span> <b>{fCDF(toCDF(u.usd, rate))}</b>{isAdmin ? <span className="code"> {fUSD(u.usd)}</span> : null}</div>)}</td>
                {isAdmin ? <td className="r"><b>{c && p.price_usd > 0 ? Math.round(((p.price_usd - c.cost_usd) / p.price_usd) * 100) : 0}%</b><div className="code">per {p.is_bundle ? 'set' : 'pc'}</div></td> : null}
                <td><div className="act">{isAdmin ? <button title="Edit item and prices" onClick={() => setEdit(p)}><Icon n="edit" /></button> : <button title="Receive stock" onClick={() => setRecv(p)}><Icon n="plus" /></button>}</div></td>
              </tr>); })}
          </tbody></table>}
      </div></div>
      {edit ? <ItemModal p={edit === 'new' ? null : edit} cost={edit === 'new' ? undefined : costOf.get(edit.id)} cats={[...new Set([...CATS, ...(products.data ?? []).map((p) => p.category)])]} rate={rate} onClose={() => setEdit(null)} /> : null}
      {recv ? <ReceiveModal p={recv} onClose={() => setRecv(null)} /> : null}
      {imp ? <ImportModal products={products.data ?? []} rate={rate} onClose={() => setImp(false)} /> : null}
    </>
  );
}

function ItemModal({ p, cost, cats, rate, onClose }: { p: Product | null; cost?: Cost; cats: string[]; rate: number; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction();
  const v = (x: number | undefined) => (x === undefined || x === null || (!p && x === 0) ? '' : String(x));
  const [f, setF] = useState({
    name: p?.name ?? '', category: p?.category ?? CATS[0], is_bundle: p?.is_bundle ?? false,
    carton_cost: v(p && !p.is_bundle ? cost?.carton_cost_usd : undefined), per_carton: v(p?.per_carton || undefined), pc: p && !p.is_bundle ? String(p.price_usd) : '',
    dzn: p?.dozen_usd ? String(p.dozen_usd) : '', ctn: v(p?.carton_usd || undefined),
    set_cost: p?.is_bundle ? String(cost?.cost_usd ?? '') : '', set_price: p?.is_bundle ? String(p.price_usd) : '', pcs: String(p?.pieces_per_set || 12), piece: p?.piece_usd ? String(p.piece_usd) : '',
    qc: '0', ql: '0', reorder: String(p?.reorder ?? 20), supplier: '',
  });
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  const o: ItemInput = { name: f.name, category: f.category, is_bundle: f.is_bundle, carton_cost: num(f.carton_cost), per_carton: num(f.per_carton), pc: num(f.pc), dzn: num(f.dzn) || 0, ctn: num(f.ctn),
    set_cost: num(f.set_cost), set_price: num(f.set_price), pcs: num(f.pcs), piece: num(f.piece) };
  const problem = itemProblem(o), below = !!problem && /below/.test(problem);
  const row = (u: string, price: number, c: number) => (price > 0 ? <tr key={u}><td><b>{u}</b></td><td className="r"><b>{fCDF(toCDF(price, rate))}</b></td><td className="r">{fUSD(price)}</td><td className="r">{c >= 0 ? fUSD(c) : '-'}</td><td className="r">{c >= 0 ? <span className={`chip ${price < c ? 'bad' : 'ok'}`}>{Math.round(((price - c) / price) * 100)}%</span> : null}</td></tr> : null);
  const cpc = o.carton_cost >= 0 && o.per_carton > 1 ? o.carton_cost / o.per_carton : -1;
  const rows = o.is_bundle ? [row('1 set', o.set_price, o.set_cost), row('1 piece', o.piece, o.set_cost >= 0 && o.pcs > 1 ? o.set_cost / o.pcs : -1)]
    : [row('1 pc', o.pc, cpc), o.per_carton !== 12 ? row('1 dozen (12 pcs)', o.dzn, cpc >= 0 ? cpc * 12 : -1) : null, row(`1 carton${o.per_carton > 1 ? ` (${o.per_carton} pcs)` : ''}`, o.ctn, o.carton_cost >= 0 ? o.carton_cost : -1)];
  const save = () => a.run(async () => {
    if (problem) throw new Error(problem);
    await rpc('save_product', { p: { id: p?.id ?? null, name: f.name, category: f.category, is_bundle: f.is_bundle, carton_cost: o.carton_cost, per_carton: o.per_carton, pc: o.pc, dzn: o.dzn, ctn: o.ctn,
      set_cost: o.set_cost, set_price: o.set_price, pcs: o.pcs, piece: o.piece, qty_cartons: f.is_bundle ? 0 : Number(f.qc) || 0, qty_loose: Number(f.ql) || 0, reorder: Number(f.reorder) || 0, supplier: f.supplier } });
    await refresh('products', 'costs', 'stock', 'audit'); toast(p ? 'Item saved' : 'Item added'); onClose();
  });
  return (
    <Modal title={p ? 'Edit item and prices' : 'Add new item'} icon="box" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Save item</button></>}>
      <div className="frow"><div className="field"><label>Item name</label><input id="in" className="input" value={f.name} maxLength={60} onChange={set('name')} placeholder="e.g. Shea body lotion 400 ml" autoFocus /></div>
        <div className="field"><label>Category</label><input id="ic" className="input" list="catlist" value={f.category} maxLength={30} onChange={set('category')} /><datalist id="catlist">{cats.map((c) => <option key={c} value={c} />)}</datalist></div></div>
      <label className="switch"><input type="checkbox" id="ibundle" checked={f.is_bundle} onChange={set('is_bundle')} /><span>This is a mixed set sold together, for example assorted brushes or clips</span></label>
      {!f.is_bundle ? <>
        <div className="frow"><div className="field"><label>Cost of one carton (USD)</label><input id="icc" className="input" type="number" min="0" step="0.01" value={f.carton_cost} onChange={set('carton_cost')} /></div>
          <div className="field"><label>Pcs in one carton</label><input id="ipc" className="input" type="number" min="2" step="1" value={f.per_carton} onChange={set('per_carton')} /></div></div>
        <div className="frow three"><div className="field"><label>Selling price per pc (USD)</label><input id="isell" className="input" type="number" min="0" step="0.01" value={f.pc} onChange={set('pc')} /></div>
          <div className="field"><label>Per dozen (USD)</label><input id="idz" className="input" type="number" min="0" step="0.01" value={f.dzn} placeholder="Optional" onChange={set('dzn')} /></div>
          <div className="field"><label>Per carton (USD)</label><input id="ictn" className="input" type="number" min="0" step="0.01" value={f.ctn} onChange={set('ctn')} /></div></div>
        <span className="hint" style={{ display: 'block', margin: '-6px 0 12px' }}>Leave the dozen price empty if the item is not sold by the dozen. Stock is counted in pcs.</span>
      </> : <>
        <div className="frow"><div className="field"><label>Cost of one set (USD)</label><input id="iscost" className="input" type="number" min="0" step="0.01" value={f.set_cost} onChange={set('set_cost')} /></div>
          <div className="field"><label>Selling price for one set (USD)</label><input id="isset" className="input" type="number" min="0" step="0.01" value={f.set_price} onChange={set('set_price')} /></div></div>
        <div className="frow"><div className="field"><label>Pieces in one set</label><input id="ipcs" className="input" type="number" min="2" value={f.pcs} onChange={set('pcs')} /></div>
          <div className="field"><label>Last price for one piece (USD)</label><input id="ippu" className="input" type="number" min="0" step="0.01" value={f.piece} onChange={set('piece')} /></div></div>
        <Note i="gift">The shop can sell the whole set, or one piece at the last price you set here. Only you can change this price.</Note>
      </>}
      <div id="iprev" className={`note ${below ? 'warn' : ''}`}><Icon n={below ? 'alert' : 'lock'} /><div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ marginBottom: 6 }}>Shops sell at these prices, locked. 1 USD = {fCDF(rate)}.{below ? <b> {problem}.</b> : null}</div>
        {rows.some(Boolean) ? <div className="tw"><table className="t" style={{ fontSize: 13.5 }}><thead><tr><th>Unit</th><th className="r">Shop price</th><th className="r">USD</th><th className="r">Cost</th><th className="r">Margin</th></tr></thead><tbody>{rows}</tbody></table></div> : 'Enter prices to see the shop price in Francs.'}
      </div></div>
      <div className="frow">{!f.is_bundle ? <div className="field"><label>{p ? 'Cartons received now' : 'Opening stock, cartons'}</label><input id="iqc" className="input" type="number" min="0" step="1" value={f.qc} onChange={set('qc')} /></div> : null}
        <div className="field"><label>{f.is_bundle ? (p ? 'Sets received now' : 'Opening stock, sets') : p ? 'Loose pcs received now' : 'Opening stock, loose pcs'}</label><input id="iq" className="input" type="number" min="0" step="1" value={f.ql} onChange={set('ql')} /><span className="hint">{p ? `Currently ${p.wh_qty} ${p.stock_unit} in the store${ctnTxt(p, p.wh_qty) ? `, ${ctnTxt(p, p.wh_qty)}` : ''}` : ''}</span></div></div>
      <div className="frow"><div className="field"><label>Reorder when the store has less than ({f.is_bundle ? 'sets' : 'pcs'})</label><input id="ir" className="input" type="number" min="0" value={f.reorder} onChange={set('reorder')} /></div>
        <div className="field"><label>Supplier (optional)</label><input id="isup" className="input" maxLength={60} value={f.supplier} onChange={set('supplier')} /></div></div>
      <div id="ierr" className="lerr">{a.err}</div>
    </Modal>
  );
}

function ReceiveModal({ p, onClose }: { p: Product; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction();
  const ctn = !p.is_bundle && p.per_carton > 1;
  const [c, setC] = useState(''), [l, setL] = useState(''), [s, setS] = useState('');
  const save = () => a.run(async () => {
    await rpc('receive_stock', { p_product: p.id, p_cartons: Number(c) || 0, p_loose: Number(l) || 0, p_supplier: s });
    await refresh('products', 'audit'); toast('Stock received'); onClose();
  });
  return (
    <Modal title="Receive stock" icon="box" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Add to store stock</button></>}>
      <p><b>{p.name}</b><br /><span className="code">{p.sku}, currently {p.wh_qty} {p.stock_unit} in the store{ctnTxt(p, p.wh_qty) ? ` (${ctnTxt(p, p.wh_qty)})` : ''}{ctn ? `, ${p.per_carton} pcs per carton` : ''}</span></p>
      <div className="frow">{ctn ? <div className="field"><label>Cartons received</label><input className="input" type="number" min="0" step="1" value={c} onChange={(e) => setC(e.target.value)} autoFocus /></div> : null}
        <div className="field"><label>{ctn ? 'Loose pcs received' : `Quantity received (${p.stock_unit})`}</label><input className="input" type="number" min="0" step="1" value={l} onChange={(e) => setL(e.target.value)} autoFocus={!ctn} /></div></div>
      <div className="field"><label>Supplier or delivery note</label><input className="input" maxLength={60} value={s} onChange={(e) => setS(e.target.value)} /></div>
      <Note>Prices are not part of this screen. Only the Admin sets cost and selling prices.</Note><div className="lerr">{a.err}</div>
    </Modal>
  );
}

function ImportModal({ products, rate, onClose }: { products: Product[]; rate: number; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction();
  const [rowsIn, setRows] = useState<ImportRow[]>([]), [file, setFile] = useState(''), [reading, setReading] = useState(false);
  const ok = rowsIn.filter((r) => r.status === 'ok'), bad = rowsIn.filter((r) => r.status === 'bad'), skip = rowsIn.filter((r) => r.status === 'skip');
  const fp = (v: number) => (v > 0 ? fCDF(toCDF(v, rate)) : '-');
  const pick = async (f?: File) => {
    if (!f) return; setFile(f.name); a.setErr(''); setRows([]); setReading(true);
    try {
      const ext = f.name.toLowerCase().split('.').pop();
      if (ext === 'xls') throw new Error('Old .xls files are not supported. In Excel choose File, Save As, Excel Workbook (.xlsx).');
      const sheet = ext === 'xlsx' ? await readXlsx(await f.arrayBuffer()) : ext === 'csv' || ext === 'txt' ? readCSV(await f.text()) : null;
      if (!sheet) throw new Error('Choose an .xlsx or .csv file');
      setRows(impParse(sheet, products.map((p) => p.name), products.map((p) => p.sku)));
    } catch (e) { a.setErr((e as Error).message); } finally { setReading(false); }
  };
  const go = () => a.run(async () => {
    const res = await rpc<{ imported: number }>('import_products', { p_rows: ok.map((r) => ({ row: r.n, name: r.o.name, category: r.o.category, carton_cost: r.o.carton_cost, per_carton: r.o.per_carton, pc: r.o.pc, dzn: r.o.dzn, ctn: r.o.ctn, open_cartons: r.o.open_cartons, open_pcs: r.o.open_pcs, reorder: r.o.reorder, sku: r.sku })), p_file: file });
    await refresh('products', 'costs', 'stock', 'audit'); toast(`${res.imported} item${res.imported === 1 ? '' : 's'} imported`); onClose();
  });
  return (
    <Modal title="Import items from Excel" icon="download" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" id="impBtn" disabled={!ok.length || a.busy} onClick={() => void go()}><Icon n="check" /> Import {ok.length} item{ok.length === 1 ? '' : 's'}</button></>}>
      <Note i="doc">One row per new item. Prices are in USD, like the item form. Stock is counted in pcs. Leave <b>Price per dozen</b> empty when an item is not sold by the dozen. Items whose name or code already exists are skipped, so nothing is overwritten.</Note>
      <div className="tw" style={{ marginBottom: 12 }}><table className="t nw" style={{ fontSize: 13 }}><thead><tr>{IMPCOLS.map((c) => <th key={c}>{c}</th>)}</tr></thead><tbody><tr><td>Aloe vera gel 300 ml</td><td>Skin care</td><td>60</td><td>24</td><td>4</td><td>45</td><td>90</td><td>5</td><td>0</td><td>24</td><td /></tr></tbody></table></div>
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'center', marginBottom: 14 }}>
        <button className="btn ghost" onClick={() => saveBlob(templateXlsx(), 'SIM-items-template.xlsx')}><Icon n="download" /> Download Excel template</button>
        <label className="btn primary" style={{ cursor: 'pointer' }}><Icon n="plus" /> Choose Excel file<input type="file" accept=".xlsx,.csv,.txt" style={{ display: 'none' }} onChange={(e) => void pick(e.target.files?.[0])} /></label>
        <span className="hint">{file || '.xlsx or .csv'}</span>
      </div>
      {reading ? <Empty i="refresh" t={`Reading ${file}`} /> : null}
      {rowsIn.length ? <>
        <div className="toolbar"><span className="chip ok"><Icon n="check" /> {ok.length} ready</span>{bad.length ? <span className="chip bad"><Icon n="alert" /> {bad.length} with errors</span> : null}{skip.length ? <span className="chip warn">{skip.length} skipped, already in the catalogue</span> : null}</div>
        <div className="tw" style={{ maxHeight: '44vh', overflow: 'auto', border: '1px solid var(--line)', borderRadius: 12 }}><table className="t" style={{ fontSize: 13.5 }}><thead><tr><th>Row</th><th>Item</th><th>Carton</th><th className="r">Per pc</th><th className="r">Per dozen</th><th className="r">Per carton</th><th className="r">Opening</th><th>Status</th></tr></thead><tbody>
          {rowsIn.slice(0, 500).map((r) => <tr key={r.n}><td className="code">{r.n}</td><td><b>{r.o.name || '(no name)'}</b><div className="code">{r.o.category}{r.sku ? ' · ' + r.sku : ''}</div></td>
            <td className="nw">{isNaN(r.o.carton_cost) ? '-' : fUSD(r.o.carton_cost)}<div className="code">{isNaN(r.o.per_carton) ? '-' : r.o.per_carton} pcs</div></td>
            <td className="r nw">{fp(r.o.pc)}</td><td className="r nw">{r.o.per_carton === 12 ? <span className="code">= carton</span> : fp(r.o.dzn)}</td><td className="r nw">{fp(r.o.ctn)}</td><td className="r nw">{r.status === 'ok' ? r.qty + ' pcs' : ''}</td>
            <td>{r.status === 'ok' ? <span className="chip ok">Ready</span> : <span className={`chip ${r.status === 'skip' ? 'warn' : 'bad'}`}>{r.msg}</span>}</td></tr>)}
        </tbody></table></div>
        {bad.length ? <Note i="alert" warn style={{ marginTop: 12 }}>Rows with errors are not imported. Fix them in Excel and import the file again; items already imported are skipped.</Note> : null}
      </> : null}
      <div id="imperr" className="lerr">{a.err}</div>
    </Modal>
  );
}
