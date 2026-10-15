import { useMemo, useState } from 'react';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useCategories, useCosts, useProducts, useRanks, useRefresh, useSettings } from '../data/queries';
import { rpc } from '../lib/supabase';
import { ctnTxt, hotSet, hotSort, pcValue, unitLabel, unitsOf } from '../lib/units';
import { itemProblem, MONTHS, type ItemInput } from '../lib/items';
import { ReceiveGoodsModal } from './Stores';
import { fCDF, fUSD, toCDF } from '../lib/format';
import { Dual, Empty, Head, Modal, Note, num, useAction, useToast } from '../components/ui';
import { IMPCOLS, impParse, readCSV, readXlsx, saveBlob, templateXlsx, type ImportRow } from '../lib/xlsx';
import type { Category, Cost, Product } from '../lib/types';

export const QtyCell = ({ p, q, cls = '' }: { p: Product; q: number; cls?: string }) => (
  <><span className={`chip ${cls}`}>{q} {p.stock_unit}</span>{ctnTxt(p, q) ? <div className="code">{ctnTxt(p, q)}</div> : null}</>
);

export default function Inventory() {
  const { profile } = useAuth();
  const isAdmin = profile!.role === 'admin';
  const products = useProducts(), costs = useCosts(isAdmin), settings = useSettings(), ranks = useRanks(null), refresh = useRefresh(), toast = useToast();
  const [q, setQ] = useState(''), [edit, setEdit] = useState<Product | 'new' | null>(null), [recv, setRecv] = useState<Product | 'any' | null>(null), [imp, setImp] = useState(false);
  const [cats, setCats] = useState(false), [archived, setArchived] = useState(false), [count, setCount] = useState<Product | null>(null);
  const rate = settings.data?.rate ?? 1;
  const costOf = useMemo(() => new Map((costs.data ?? []).map((c) => [c.product_id, c])), [costs.data]);
  const live = (products.data ?? []).filter((p) => p.active), gone = (products.data ?? []).filter((p) => !p.active);
  const hot = hotSet(ranks.data);
  const list = hotSort(archived ? gone : live, ranks.data).filter((p) => !q || (p.name + ' ' + p.sku + ' ' + p.category).toLowerCase().includes(q.toLowerCase()));
  const del = async (p: Product) => {
    if (!confirm(`Delete ${p.name}? An item that was ever received, sent or sold is archived instead, so its history stays.`)) return;
    try { const r = await rpc<string>('delete_product', { p_id: p.id }); await refresh('products', 'costs', 'stock', 'audit'); toast(r === 'deleted' ? `${p.name} deleted` : `${p.name} archived. Find it under Archived items.`, 'warn'); }
    catch (e) { toast((e as Error).message, 'bad'); }
  };
  const restore = async (p: Product) => {
    try { await rpc('restore_product', { p_id: p.id }); await refresh('products', 'audit'); toast(`${p.name} is back in the catalogue`); } catch (e) { toast((e as Error).message, 'bad'); }
  };
  return (
    <>
      <Head t="Inventory" s={isAdmin ? 'Selling prices, sets and piece prices are set here only. Shops see them in Francs and cannot change them.' : 'Item names, units and quantities. Prices are set by the Admin.'}
        a={<>{isAdmin ? <><button className="btn ghost" onClick={() => setCats(true)}><Icon n="grid" /> Categories</button><button className="btn ghost" onClick={() => setImp(true)}><Icon n="download" /> Import from Excel</button></> : null}
          <button className={`btn ${isAdmin ? 'ghost' : 'primary'}`} onClick={() => setRecv('any')}><Icon n="truck" /> Receive from supplier</button>
          {isAdmin ? <button className="btn primary" onClick={() => setEdit('new')}><Icon n="plus" /> Add new item</button> : null}</>} />
      <div className="toolbar"><div className="search"><Icon n="search" /><input placeholder="Search by name, code or category" value={q} onChange={(e) => setQ(e.target.value)} /></div><span className="chip">{live.length} items</span>
        {isAdmin && gone.length ? <div className="seg"><button className={archived ? '' : 'on'} onClick={() => setArchived(false)}>Active</button><button className={archived ? 'on' : ''} onClick={() => setArchived(true)}>Archived ({gone.length})</button></div> : null}
        {isAdmin ? null : <span className="chip warn"><Icon n="lock" /> Cost prices hidden for your role</span>}<span className="hint">Best sellers of the last 30 days come first; seasonal items out of season come last.</span></div>
      <div className="card p0"><div className="tw">
        {products.isLoading ? <Empty i="refresh" t="Loading items" /> : !list.length ? <Empty i="search" t={products.data?.length ? 'No items match your search' : 'No items yet. Add one or import from Excel.'} /> :
          <table className="t"><thead><tr><th>Item</th><th>Category</th><th className="r">In store</th>{isAdmin ? <th>Cost</th> : null}<th>Selling prices</th>{isAdmin ? <th className="r">Margin</th> : null}<th /></tr></thead><tbody>
            {list.map((p) => { const c = costOf.get(p.id); return (
              <tr key={p.id}>
                <td><b>{p.name}</b>{hot.has(p.id) ? <> <span className="chip hot">Hot</span></> : null}<div className="code">{p.sku}{p.is_bundle ? ` · mixed set of ${p.pieces_per_set}` : p.per_carton > 1 ? ` · ${p.per_carton} pcs per carton` : ''}</div></td><td>{p.category}</td>
                <td className="r"><QtyCell p={p} q={p.wh_qty} cls={p.wh_qty <= p.reorder ? 'bad' : 'ok'} /></td>
                {isAdmin ? <td>{c ? (p.is_bundle ? <><Dual usd={c.cost_usd} rate={rate} /><div className="code">per set</div></> : <><Dual usd={c.carton_cost_usd} rate={rate} /><div className="code">per carton, {fUSD(c.cost_usd)} per pc</div></>) : '-'}</td> : null}
                <td>{unitsOf(p).map((u, k) => <div key={k} style={{ whiteSpace: 'nowrap' }}><span className="uchip">{unitLabel(u)}</span> <b>{fCDF(toCDF(u.usd, rate))}</b>{isAdmin ? <span className="code"> {fUSD(u.usd)}</span> : null}</div>)}</td>
                {isAdmin ? <td className="r"><b>{c && pcValue(p) > 0 ? Math.round(((pcValue(p) - c.cost_usd) / pcValue(p)) * 100) : 0}%</b><div className="code">per {p.is_bundle ? 'set' : 'pc'}</div></td> : null}
                <td><div className="act">{!p.active ? <button title="Restore this item" onClick={() => void restore(p)}><Icon n="refresh" /></button>
                  : isAdmin ? <><button title="Edit item and prices" onClick={() => setEdit(p)}><Icon n="edit" /></button><button title="Stock count: correct the store quantity" onClick={() => setCount(p)}><Icon n="layers" /></button><button title="Delete item" onClick={() => void del(p)}><Icon n="trash" /></button></>
                  : <button title="Receive from supplier" onClick={() => setRecv(p)}><Icon n="plus" /></button>}</div></td>
              </tr>); })}
          </tbody></table>}
      </div></div>
      {edit ? <ItemModal p={edit === 'new' ? null : edit} cost={edit === 'new' ? undefined : costOf.get(edit.id)} rate={rate} onClose={() => setEdit(null)} onCats={() => setCats(true)} /> : null}
      {recv ? <ReceiveGoodsModal pid={recv === 'any' ? undefined : recv.id} onClose={() => setRecv(null)} /> : null}
      {cats ? <CategoriesModal products={live} onClose={() => setCats(false)} /> : null}
      {count ? <CountModal p={count} onClose={() => setCount(null)} /> : null}
      {imp ? <ImportModal products={products.data ?? []} rate={rate} onClose={() => setImp(false)} /> : null}
    </>
  );
}

function ItemModal({ p, cost, rate, onClose, onCats }: { p: Product | null; cost?: Cost; rate: number; onClose: () => void; onCats: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction(), cats = useCategories();
  const v = (x: number | undefined) => (x === undefined || x === null || (!p && x === 0) ? '' : String(x));
  const [f, setF] = useState({
    name: p?.name ?? '', category: p?.category ?? '', is_bundle: p?.is_bundle ?? false,
    carton_cost: v(p && !p.is_bundle ? cost?.carton_cost_usd : undefined), per_carton: v(p?.per_carton || undefined), pc: p && !p.is_bundle && p.price_usd > 0 ? String(p.price_usd) : '',
    half: p?.half_dozen_usd ? String(p.half_dozen_usd) : '', dzn: p?.dozen_usd ? String(p.dozen_usd) : '', ctn: v(p?.carton_usd || undefined),
    set_cost: p?.is_bundle ? String(cost?.cost_usd ?? '') : '', set_price: p?.is_bundle ? String(p.price_usd) : '', pcs: String(p?.pieces_per_set || 12), piece: p?.piece_usd ? String(p.piece_usd) : '',
    qc: '0', ql: '0', reorder: String(p?.reorder ?? 20),
  });
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.type === 'checkbox' ? (e.target as HTMLInputElement).checked : e.target.value });
  const o: ItemInput = { name: f.name, category: f.category, is_bundle: f.is_bundle, carton_cost: num(f.carton_cost), per_carton: num(f.per_carton), pc: num(f.pc), half: num(f.half) || 0, dzn: num(f.dzn) || 0, ctn: num(f.ctn) || 0,
    set_cost: num(f.set_cost), set_price: num(f.set_price), pcs: num(f.pcs), piece: num(f.piece) };
  const problem = itemProblem(o), below = !!problem && /below/.test(problem);
  const row = (u: string, price: number, c: number) => (price > 0 ? <tr key={u}><td><b>{u}</b></td><td className="r"><b>{fCDF(toCDF(price, rate))}</b></td><td className="r">{fUSD(price)}</td><td className="r">{c >= 0 ? fUSD(c) : '-'}</td><td className="r">{c >= 0 ? <span className={`chip ${price < c ? 'bad' : 'ok'}`}>{Math.round(((price - c) / price) * 100)}%</span> : null}</td></tr> : null);
  const cpc = o.carton_cost >= 0 && o.per_carton > 1 ? o.carton_cost / o.per_carton : -1;
  const rows = o.is_bundle ? [row('1 set', o.set_price, o.set_cost), row('1 piece', o.piece, o.set_cost >= 0 && o.pcs > 1 ? o.set_cost / o.pcs : -1)]
    : [row('1 pc', o.pc, cpc), o.per_carton !== 6 ? row('half dozen (6 pcs)', o.half, cpc >= 0 ? cpc * 6 : -1) : null, o.per_carton !== 12 ? row('1 dozen (12 pcs)', o.dzn, cpc >= 0 ? cpc * 12 : -1) : null, row(`1 carton${o.per_carton > 1 ? ` (${o.per_carton} pcs)` : ''}`, o.ctn, o.carton_cost >= 0 ? o.carton_cost : -1)];
  const save = () => a.run(async () => {
    if (problem) throw new Error(problem);
    await rpc('save_product', { p: { id: p?.id ?? null, name: f.name, category: f.category, is_bundle: f.is_bundle, carton_cost: o.carton_cost, per_carton: o.per_carton, pc: o.pc, half: o.half, dzn: o.dzn, ctn: o.ctn,
      set_cost: o.set_cost, set_price: o.set_price, pcs: o.pcs, piece: o.piece, qty_cartons: f.is_bundle ? 0 : Number(f.qc) || 0, qty_loose: Number(f.ql) || 0, reorder: Number(f.reorder) || 0 } });
    await refresh('products', 'costs', 'stock', 'audit'); toast(p ? 'Item saved' : 'Item added'); onClose();
  });
  return (
    <Modal title={p ? 'Edit item and prices' : 'Add new item'} icon="box" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Save item</button></>}>
      <div className="frow"><div className="field"><label>Item name</label><input id="in" className="input" value={f.name} maxLength={60} onChange={set('name')} placeholder="e.g. Shea body lotion 400 ml" autoFocus /></div>
        <div className="field"><label>Category</label><select id="ic" className="input" value={f.category} onChange={set('category')}><option value="">Choose a category</option>{(cats.data ?? []).map((c) => <option key={c.id} value={c.name}>{c.name}{c.seasonal ? ' (seasonal)' : ''}</option>)}</select>
          <span className="hint">{cats.data && !cats.data.length ? 'No categories yet. ' : ''}<button type="button" className="linkbtn" onClick={() => { onClose(); onCats(); }}>Add or edit categories</button></span></div></div>
      <label className="switch"><input type="checkbox" id="ibundle" checked={f.is_bundle} onChange={set('is_bundle')} /><span>This is a mixed set sold together, for example assorted brushes or clips</span></label>
      {!f.is_bundle ? <>
        <div className="frow"><div className="field"><label>Cost of one carton (USD)</label><input id="icc" className="input" type="number" min="0" step="0.01" value={f.carton_cost} onChange={set('carton_cost')} /></div>
          <div className="field"><label>Pcs in one carton</label><input id="ipc" className="input" type="number" min="2" step="1" value={f.per_carton} onChange={set('per_carton')} /></div></div>
        <div className="frow"><div className="field"><label>Selling price per pc (USD)</label><input id="isell" className="input" type="number" min="0" step="0.01" value={f.pc} placeholder="Optional" onChange={set('pc')} /></div>
          <div className="field"><label>Per half dozen, 6 pcs (USD)</label><input id="ihz" className="input" type="number" min="0" step="0.01" value={f.half} placeholder="Optional" onChange={set('half')} /></div></div>
        <div className="frow"><div className="field"><label>Per dozen, 12 pcs (USD)</label><input id="idz" className="input" type="number" min="0" step="0.01" value={f.dzn} placeholder="Optional" onChange={set('dzn')} /></div>
          <div className="field"><label>Per carton (USD)</label><input id="ictn" className="input" type="number" min="0" step="0.01" value={f.ctn} placeholder="Optional" onChange={set('ctn')} /></div></div>
        <span className="hint" style={{ display: 'block', margin: '-6px 0 12px' }}>Every price is optional, but enter at least one. Leave a price empty when the item is not sold that way: the till only offers the units that have a price. Stock is counted in pcs.</span>
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
      {p ? <Note i="box">Currently {p.wh_qty} {p.stock_unit} in the store{ctnTxt(p, p.wh_qty) ? `, ${ctnTxt(p, p.wh_qty)}` : ''}. New stock comes in through <b>Receive from supplier</b>; a counting error is corrected with the stock count button.</Note>
        : <div className="frow">{!f.is_bundle ? <div className="field"><label>Opening stock, cartons</label><input id="iqc" className="input" type="number" min="0" step="1" value={f.qc} onChange={set('qc')} /></div> : null}
          <div className="field"><label>{f.is_bundle ? 'Opening stock, sets' : 'Opening stock, loose pcs'}</label><input id="iq" className="input" type="number" min="0" step="1" value={f.ql} onChange={set('ql')} /><span className="hint">Stock already in the store, booked at cost as opening stock.</span></div></div>}
      <div className="field"><label>Reorder when the store has less than ({f.is_bundle ? 'sets' : 'pcs'})</label><input id="ir" className="input" type="number" min="0" value={f.reorder} onChange={set('reorder')} /></div>
      <div id="ierr" className="lerr">{a.err}</div>
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
    const res = await rpc<{ imported: number; new_categories: number }>('import_products', { p_rows: ok.map((r) => ({ row: r.n, name: r.o.name, category: r.o.category, carton_cost: r.o.carton_cost, per_carton: r.o.per_carton, pc: r.o.pc, half: r.o.half, dzn: r.o.dzn, ctn: r.o.ctn, open_cartons: r.o.open_cartons, open_pcs: r.o.open_pcs, reorder: r.o.reorder, sku: r.sku })), p_file: file });
    await refresh('products', 'costs', 'stock', 'audit', 'categories'); toast(`${res.imported} item${res.imported === 1 ? '' : 's'} imported${res.new_categories ? `, ${res.new_categories} new categor${res.new_categories === 1 ? 'y' : 'ies'} made` : ''}`); onClose();
  });
  return (
    <Modal title="Import items from Excel" icon="download" wide onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" id="impBtn" disabled={!ok.length || a.busy} onClick={() => void go()}><Icon n="check" /> Import {ok.length} item{ok.length === 1 ? '' : 's'}</button></>}>
      <Note i="doc">One row per new item. Prices are in USD, like the item form. Stock is counted in pcs. Leave any price (per pc, half dozen, dozen or carton) empty when an item is not sold that way; each item needs at least one. A category that does not exist yet is created. Items whose name or code already exists are skipped, so nothing is overwritten.</Note>
      <div className="tw" style={{ marginBottom: 12 }}><table className="t nw" style={{ fontSize: 13 }}><thead><tr>{IMPCOLS.map((c) => <th key={c}>{c}</th>)}</tr></thead><tbody><tr><td>Aloe vera gel 300 ml</td><td>Skin care</td><td>60</td><td>24</td><td>4</td><td>23</td><td>45</td><td>90</td><td>5</td><td>0</td><td>24</td><td /></tr></tbody></table></div>
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'center', marginBottom: 14 }}>
        <button className="btn ghost" onClick={() => saveBlob(templateXlsx(), 'SIM-items-template.xlsx')}><Icon n="download" /> Download Excel template</button>
        <label className="btn primary" style={{ cursor: 'pointer' }}><Icon n="plus" /> Choose Excel file<input type="file" accept=".xlsx,.csv,.txt" style={{ display: 'none' }} onChange={(e) => void pick(e.target.files?.[0])} /></label>
        <span className="hint">{file || '.xlsx or .csv'}</span>
      </div>
      {reading ? <Empty i="refresh" t={`Reading ${file}`} /> : null}
      {rowsIn.length ? <>
        <div className="toolbar"><span className="chip ok"><Icon n="check" /> {ok.length} ready</span>{bad.length ? <span className="chip bad"><Icon n="alert" /> {bad.length} with errors</span> : null}{skip.length ? <span className="chip warn">{skip.length} skipped, already in the catalogue</span> : null}</div>
        <div className="tw" style={{ maxHeight: '44vh', overflow: 'auto', border: '1px solid var(--line)', borderRadius: 12 }}><table className="t" style={{ fontSize: 13.5 }}><thead><tr><th>Row</th><th>Item</th><th>Carton</th><th className="r">Per pc</th><th className="r">Half dozen</th><th className="r">Per dozen</th><th className="r">Per carton</th><th className="r">Opening</th><th>Status</th></tr></thead><tbody>
          {rowsIn.slice(0, 500).map((r) => <tr key={r.n}><td className="code">{r.n}</td><td><b>{r.o.name || '(no name)'}</b><div className="code">{r.o.category}{r.sku ? ' · ' + r.sku : ''}</div></td>
            <td className="nw">{isNaN(r.o.carton_cost) ? '-' : fUSD(r.o.carton_cost)}<div className="code">{isNaN(r.o.per_carton) ? '-' : r.o.per_carton} pcs</div></td>
            <td className="r nw">{fp(r.o.pc)}</td><td className="r nw">{r.o.per_carton === 6 ? <span className="code">= carton</span> : fp(r.o.half)}</td><td className="r nw">{r.o.per_carton === 12 ? <span className="code">= carton</span> : fp(r.o.dzn)}</td><td className="r nw">{fp(r.o.ctn)}</td><td className="r nw">{r.status === 'ok' ? r.qty + ' pcs' : ''}</td>
            <td>{r.status === 'ok' ? <span className="chip ok">Ready</span> : <span className={`chip ${r.status === 'skip' ? 'warn' : 'bad'}`}>{r.msg}</span>}</td></tr>)}
        </tbody></table></div>
        {bad.length ? <Note i="alert" warn style={{ marginTop: 12 }}>Rows with errors are not imported. Fix them in Excel and import the file again; items already imported are skipped.</Note> : null}
      </> : null}
      <div id="imperr" className="lerr">{a.err}</div>
    </Modal>
  );
}

function CategoriesModal({ products, onClose }: { products: Product[]; onClose: () => void }) {
  const cats = useCategories(), refresh = useRefresh(), toast = useToast(), a = useAction();
  const [f, setF] = useState<{ id: string | null; name: string; seasonal: boolean; months: number[] }>({ id: null, name: '', seasonal: false, months: [] });
  const used = (c: Category) => products.filter((p) => p.category === c.name).length;
  const save = () => a.run(async () => {
    await rpc('save_category', { p: { id: f.id, name: f.name, seasonal: f.seasonal, season_months: f.months } });
    await refresh('categories', 'products', 'ranks', 'audit'); toast(f.id ? 'Category saved' : 'Category added'); setF({ id: null, name: '', seasonal: false, months: [] });
  });
  const del = (c: Category) => a.run(async () => { if (!confirm(`Delete the category ${c.name}?`)) return; await rpc('delete_category', { p_id: c.id }); await refresh('categories', 'audit'); toast('Category deleted', 'warn'); });
  return (
    <Modal title="Categories" icon="grid" wide onClose={onClose} foot={<button className="btn" onClick={onClose}>Close</button>}>
      <Note i="grid">Make the categories you need; items are filed under them and the till shows them as tabs. A <b>seasonal</b> category (school, festive) only sells in some months: outside those months its items move to the end of the lists.</Note>
      <div className="card" style={{ background: 'var(--bg)' }}>
        <div className="frow"><div className="field"><label>{f.id ? 'Rename the category' : 'New category'}</label><input id="catname" className="input" maxLength={30} value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} placeholder="e.g. Skin care" /></div>
          <div className="field"><label>Sells</label><label className="switch"><input type="checkbox" checked={f.seasonal} onChange={(e) => setF({ ...f, seasonal: e.target.checked })} /><span>Only in some months (seasonal)</span></label></div></div>
        {f.seasonal ? <div className="field"><label>Months it sells</label><div className="mchips">{MONTHS.map((m, i) => { const on = f.months.includes(i + 1); return <label key={m} className="chip" style={on ? { background: 'var(--btn)', color: '#fff' } : undefined}><input type="checkbox" hidden checked={on} onChange={() => setF({ ...f, months: on ? f.months.filter((x) => x !== i + 1) : [...f.months, i + 1].sort((x, y) => x - y) })} />{m}</label>; })}</div></div> : null}
        <div style={{ display: 'flex', gap: 8 }}><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> {f.id ? 'Save category' : 'Add category'}</button>{f.id ? <button className="btn" onClick={() => setF({ id: null, name: '', seasonal: false, months: [] })}>Cancel</button> : null}</div>
        <div className="lerr">{a.err}</div>
      </div>
      {(cats.data ?? []).length ? <div className="tw"><table className="t"><thead><tr><th>Category</th><th>Sells</th><th className="r">Items</th><th /></tr></thead><tbody>
        {(cats.data ?? []).map((c) => <tr key={c.id}><td><b>{c.name}</b></td><td>{c.seasonal ? <span className="chip warn">{c.season_months.map((m) => MONTHS[m - 1]).join(', ')}</span> : <span className="chip">All year</span>}</td><td className="r">{used(c)}</td>
          <td><div className="act"><button title="Edit" onClick={() => setF({ id: c.id, name: c.name, seasonal: c.seasonal, months: c.season_months })}><Icon n="edit" /></button><button title="Delete" onClick={() => void del(c)}><Icon n="trash" /></button></div></td></tr>)}
      </tbody></table></div> : <Empty i="grid" t={cats.isLoading ? 'Loading' : 'No categories yet. Add the first one above.'} />}
    </Modal>
  );
}

function CountModal({ p, onClose }: { p: Product; onClose: () => void }) {
  const refresh = useRefresh(), toast = useToast(), a = useAction();
  const [n, setN] = useState(String(p.wh_qty)), [reason, setReason] = useState('');
  const d = (parseInt(n) || 0) - p.wh_qty;
  const save = () => a.run(async () => { await rpc('adjust_stock', { p: { product_id: p.id, counted: parseInt(n) || 0, reason } }); await refresh('products', 'audit'); toast(`Store stock of ${p.name} set to ${parseInt(n) || 0}`); onClose(); });
  return (
    <Modal title="Stock count" icon="layers" onClose={onClose} foot={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={a.busy} onClick={() => void save()}><Icon n="check" /> Save count</button></>}>
      <p><b>{p.name}</b><br /><span className="code">{p.sku}, SIM shows {p.wh_qty} {p.stock_unit} in the central store</span></p>
      <div className="frow"><div className="field"><label>Counted ({p.stock_unit})</label><input id="cnt" className="input" type="number" min="0" step="1" value={n} onChange={(e) => setN(e.target.value)} autoFocus /></div>
        <div className="field"><label>Difference</label><div className={`chip ${d < 0 ? 'bad' : d > 0 ? 'ok' : ''}`} style={{ alignSelf: 'flex-start', marginTop: 10 }}>{d > 0 ? '+' : ''}{d} {p.stock_unit}</div></div></div>
      <div className="field"><label>Reason</label><input id="cntr" className="input" maxLength={80} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Broken bottles, counting error" /></div>
      <Note i="wallet">The difference is booked at cost to Stock adjustments and losses.</Note><div className="lerr">{a.err}</div>
    </Modal>
  );
}
