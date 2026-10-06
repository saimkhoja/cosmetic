import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import { Icon } from '../lib/icons';
import { fCDF, fUSD } from '../lib/format';

export const Head = ({ t, s, a }: { t: string; s?: ReactNode; a?: ReactNode }) => (
  <div className="head"><div><h1>{t}</h1>{s ? <p>{s}</p> : null}</div>{a ? <div className="toolbar" style={{ margin: 0 }}>{a}</div> : null}</div>
);
export const Kpi = ({ i, l, children, tone = '' }: { i: string; l: string; children: ReactNode; tone?: string }) => (
  <div className={`kpi ${tone}`}><div className="ki"><Icon n={i} /></div><div><label>{l}</label>{children}</div></div>
);
export const Dual2 = ({ b, s }: { b: ReactNode; s: ReactNode }) => <span className="dual"><b>{b}</b><small>{s}</small></span>;
export const Dual = ({ usd, rate }: { usd: number; rate: number }) => <Dual2 b={fUSD(usd)} s={fCDF(usd * rate)} />;
export const Empty = ({ i, t, tall }: { i: string; t: string; tall?: boolean }) => <div className={`empty ${tall ? 'tall' : ''}`}><Icon n={i} /><p>{t}</p></div>;
export const Note = ({ i = 'lock', warn, children, style }: { i?: string; warn?: boolean; children: ReactNode; style?: React.CSSProperties }) => (
  <div className={`note ${warn ? 'warn' : ''}`} style={style}><Icon n={i} /><div>{children}</div></div>
);
export const Tile = ({ i, l, onClick }: { i: string; l: ReactNode; onClick: () => void }) => (
  <button className="tile" onClick={onClick}><span className="ti"><Icon n={i} /></span><span>{l}</span></button>
);
export function Bars({ arr }: { arr: { label: string; val: number; txt: string }[] }) {
  const max = Math.max(1, ...arr.map((a) => a.val));
  return <div className="bars">{arr.map((a, k) => <div className="bar" key={k}><b>{a.txt}</b><i style={{ height: Math.max(2, (a.val / max) * 140) }} /><span>{a.label}</span></div>)}</div>;
}
export function HList({ arr }: { arr: { name: string; val: number; txt: string }[] }) {
  const max = Math.max(1, ...arr.map((a) => a.val));
  return arr.length ? <>{arr.map((a, k) => <div className="hl" key={k}><span>{a.name}</span><div className="trk"><i style={{ width: `${(a.val / max) * 100}%` }} /></div><b>{a.txt}</b></div>)}</> : <Empty i="chart" t="No sales yet" />;
}
export function Modal({ title, icon, children, foot, wide, onClose }: { title: string; icon: string; children: ReactNode; foot?: ReactNode; wide?: boolean; onClose: () => void }) {
  useEffect(() => { const k = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); }; addEventListener('keydown', k); return () => removeEventListener('keydown', k); }, [onClose]);
  return (
    <div className="modal-wrap" onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className={`modal ${wide ? 'wide' : ''}`} role="dialog" aria-modal="true">
        <header><Icon n={icon} /><span>{title}</span><button className="iconbtn dark" style={{ marginLeft: 'auto' }} onClick={onClose} aria-label="Close"><Icon n="x" /></button></header>
        <div className="body">{children}</div>{foot ? <footer>{foot}</footer> : null}
      </div>
    </div>
  );
}

type Tone = 'ok' | 'bad' | 'warn';
const ToastCtx = createContext<(m: string, t?: Tone) => void>(() => {});
export const useToast = () => useContext(ToastCtx);
export function Toasts({ children }: { children: ReactNode }) {
  const [list, setList] = useState<{ id: number; m: string; t: Tone; go?: boolean }[]>([]);
  const push = useCallback((m: string, t: Tone = 'ok') => {
    const id = Date.now() + Math.random();
    setList((l) => [...l, { id, m, t }]);
    setTimeout(() => setList((l) => l.map((x) => (x.id === id ? { ...x, go: true } : x))), 2800);
    setTimeout(() => setList((l) => l.filter((x) => x.id !== id)), 3200);
  }, []);
  return <ToastCtx.Provider value={push}>{children}<div id="toasts" aria-live="polite">{list.map((x) => <div key={x.id} className={`toast ${x.t} ${x.go ? 'go' : ''}`}><Icon n={x.t === 'ok' ? 'check' : 'alert'} /><span>{x.m}</span></div>)}</div></ToastCtx.Provider>;
}
/** Runs an async action, shows its error under the form, and blocks double clicks. */
export function useAction() {
  const [busy, setBusy] = useState(false), [err, setErr] = useState('');
  const run = useCallback(async (f: () => Promise<unknown>) => {
    setBusy(true); setErr('');
    try { await f(); return true; } catch (e) { setErr((e as Error).message); return false; } finally { setBusy(false); }
  }, []);
  return { busy, err, setErr, run };
}
export const num = (v: string) => (v.trim() === '' ? NaN : Number(v.replace(',', '.')));
