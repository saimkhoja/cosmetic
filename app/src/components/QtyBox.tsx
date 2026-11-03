// The quantity of a sale line, typed in its box or changed with the − and + beside it.
import { useRef, useState } from 'react';
import { useToast } from './ui';

/** What is typed counts when Enter is pressed or the box is left; Escape puts the quantity back. An empty box or 0
 *  keeps the quantity (✕ removes the line), and a barcode scanned into the box by mistake is not taken as one. */
export function QtyBox({ qty, label, onSet, onDone }: { qty: number; label: string; onSet: (n: number) => void; onDone?: () => void }) {
  const [v, setV] = useState<string | null>(null), toast = useToast();
  const typed = useRef<string | null>(null);   // what is typed, read when the box is left (state is a render late)
  const edit = (x: string | null) => { typed.current = x; setV(x); };
  const done = () => {
    const t = typed.current; edit(null);
    if (t === null) return;
    const n = parseInt(t, 10);
    if (t.length > 5) toast('That looks like a barcode, not a quantity. Scan in the search box.', 'warn');
    else if (n > 0 && n !== qty) onSet(n);
  };
  return <input className="qin" inputMode="numeric" pattern="[0-9]*" autoComplete="off" aria-label={label} value={v ?? String(qty)}
    onFocus={(e) => e.target.select()} onChange={(e) => edit(e.target.value.replace(/\D/g, ''))} onBlur={done}
    onKeyDown={(e) => {
      if (e.key !== 'Enter' && e.key !== 'Escape') return;
      e.preventDefault();
      if (e.key === 'Escape') edit(null);
      (e.target as HTMLInputElement).blur(); onDone?.();
    }} />;
}
