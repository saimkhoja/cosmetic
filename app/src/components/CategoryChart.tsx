// Sales by category: a pie (donut) of the biggest categories beside the ranked list of every category.
// The list carries every name and amount, so the pie is never read by colour alone; each row opens the category's items.
import { useState } from 'react';
import { Icon } from '../lib/icons';
import { fCDF, shortCDF } from '../lib/format';
import type { CategorySales } from '../lib/print';
import { Empty } from './ui';

/** Categories that get their own slice; the rest share the "Other" slice (the palette has 7 checked colours). */
const SLICES = 7;
const pct = (v: number, t: number) => (t > 0 ? Math.round((v * 1000) / t) / 10 : 0);

/** One slice of the donut, from angle a0 to a1 (radians, 0 at the top, clockwise). */
function arc(a0: number, a1: number, r: number, r0: number) {
  const p = (a: number, rr: number) => `${(110 + rr * Math.sin(a)).toFixed(2)} ${(110 - rr * Math.cos(a)).toFixed(2)}`;
  const big = a1 - a0 > Math.PI ? 1 : 0;
  return `M${p(a0, r)}A${r} ${r} 0 ${big} 1 ${p(a1, r)}L${p(a1, r0)}A${r0} ${r0} 0 ${big} 0 ${p(a0, r0)}Z`;
}

export function CategoryChart({ cats, names, onOpen }: { cats: CategorySales[]; names: string[]; onOpen: (c: CategorySales) => void }) {
  // the slice lifted (hovered or focused, on the pie or in the list) and where its tooltip sits, if on the pie
  const [lift, setLift] = useState<number | null>(null), [at, setAt] = useState<{ x: number; y: number } | null>(null);
  const sold = cats.filter((c) => c.val > 0), total = sold.reduce((s, c) => s + c.val, 0);
  // categories made by the Admin with no sales in these dates still show in the list
  const unsold = names.filter((n) => !cats.some((c) => c.category === n)).sort((a, b) => a.localeCompare(b));
  if (!total) return <Empty i="chart" t="No sales in these dates" />;
  const own = sold.length > SLICES ? sold.slice(0, SLICES) : sold, rest = sold.slice(own.length);
  const slices = [...own.map((c, k) => ({ name: c.category, val: c.val, color: `var(--cat${k + 1})`, c: c as CategorySales | null })),
    ...(rest.length ? [{ name: `Other (${rest.length} categories)`, val: rest.reduce((s, c) => s + c.val, 0), color: 'var(--cat-other)', c: null }] : [])];
  let a = 0;
  const geo = slices.map((s) => { const a0 = a, a1 = a + (s.val / total) * 2 * Math.PI; a = a1; return { ...s, a0, a1, mid: (a0 + a1) / 2 }; });
  const sliceOf = (name: string) => { const k = geo.findIndex((g) => g.c?.category === name); return k < 0 ? geo.length - 1 : k; };
  const point = (k: number, e?: { clientX: number; clientY: number; currentTarget: Element }) => {
    const box = (e?.currentTarget.closest('.catpie') as HTMLElement | null)?.getBoundingClientRect();
    setLift(k); setAt(box && e ? { x: e.clientX - box.left, y: e.clientY - box.top } : { x: 110 + 84 * Math.sin(geo[k].mid), y: 110 - 84 * Math.cos(geo[k].mid) });
  };
  const off = () => { setLift(null); setAt(null); };
  const tip = lift !== null && at ? geo[lift] : null;
  return (
    <div className="catchart">
      <div className="catpie" onPointerLeave={off}>
        <svg viewBox="0 0 220 220" role="img" aria-label={`Sales by category, ${fCDF(total)}`}>
          {geo.map((g, k) => {
            const props = { fill: g.color, className: `slice ${lift === k ? 'on' : ''} ${g.c ? 'go' : ''}`, tabIndex: 0, role: g.c ? 'button' : undefined,
              'aria-label': `${g.name}: ${fCDF(g.val)}, ${pct(g.val, total)}%`, onPointerMove: (e: React.PointerEvent) => point(k, e), onFocus: () => point(k), onBlur: off,
              onClick: () => g.c && onOpen(g.c), onKeyDown: (e: React.KeyboardEvent) => { if ((e.key === 'Enter' || e.key === ' ') && g.c) { e.preventDefault(); onOpen(g.c); } } };
            // a single category is the whole ring; an arc cannot be drawn all the way round
            return geo.length === 1 ? <path key={k} d={`${arc(0, Math.PI, 106, 62)}${arc(Math.PI, 2 * Math.PI, 106, 62)}`} {...props} className={props.className + ' whole'} />
              : <path key={k} d={arc(g.a0, g.a1, 106, 62)} {...props} />;
          })}
          <text x="110" y="106" textAnchor="middle" className="ctot">{shortCDF(total)}</text>
          <text x="110" y="126" textAnchor="middle" className="csub">CDF sold</text>
        </svg>
        {tip && at ? <div className="ctip" style={{ left: at.x, top: at.y }}><b>{fCDF(tip.val)}</b><span><i style={{ background: tip.color }} />{tip.name}</span>
          <small>{pct(tip.val, total)}% of the sales{tip.c ? ' · click for the items' : ''}</small></div> : null}
      </div>
      <div className="catlist" role="list">
        {sold.map((c) => { const k = sliceOf(c.category);
          return <button key={c.category} role="listitem" className={`catrow ${lift === k ? 'on' : ''}`} onClick={() => onOpen(c)}
            onPointerEnter={() => setLift(k)} onPointerLeave={() => setLift(null)} onFocus={() => setLift(k)} onBlur={() => setLift(null)}
            aria-label={`${c.category}: ${fCDF(c.val)}, ${pct(c.val, total)}% of the sales. Open its items`}>
            <i style={{ background: geo[k].color }} /><span className="cn">{c.category}</span>
            <span className="cv">{fCDF(c.val)}</span><span className="cp">{pct(c.val, total)}%</span><Icon n="eye" /></button>; })}
        {unsold.map((n) => <div key={n} role="listitem" className="catrow off"><i /><span className="cn">{n}</span><span className="cv">No sales</span><span className="cp" /><span /></div>)}
      </div>
    </div>
  );
}

const UNIT_ORDER = ['pcs', 'set', 'piece', 'half dzn', 'dzn', 'quarter ctn', 'half ctn', 'carton'];
/** "2 dzn, 5 pcs": how many of each unit an item was sold in. */
export const unitsText = (units: Record<string, number>) =>
  Object.entries(units).sort((a, b) => UNIT_ORDER.indexOf(a[0]) - UNIT_ORDER.indexOf(b[0])).map(([u, q]) => `${q} ${u}`).join(', ');
