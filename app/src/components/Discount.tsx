// The discount on an invoice, as a percentage or an amount in CDF: typing one fills in the other.
import { useState } from 'react';
import { fCDF } from '../lib/format';
import { MAX_DISC, pctOf, type Disc } from '../lib/units';

/** Why this discount can't be given, or '' when it can: at most 30% of the invoice, as a percentage or an amount. */
export function discProblem(d: Disc, gross: number) {
  const bad = typeof d === 'number' ? d < 0 || d > MAX_DISC : d.amount < 0 || d.amount * 100 > gross * MAX_DISC;
  return bad ? `Discount must be between 0% and ${MAX_DISC}%, at most ${fCDF(Math.floor((gross * MAX_DISC) / 100))}` : '';
}

/** Two linked boxes, % and CDF. The box typed last is the discount; the other is worked out from the invoice total. */
export function DiscFields({ gross, value, onChange, id = 'disc' }: { gross: number; value: Disc; onChange: (d: Disc) => void; id?: string }) {
  const amount = typeof value === 'number' ? Math.round((gross * value) / 1000) * 10 : value.amount;
  const pct = typeof value === 'number' ? value : pctOf(value.amount, gross);
  // the box being typed in shows what is typed ("2." or empty), the other one its worked-out value
  const [typing, setTyping] = useState<{ k: 'pct' | 'amount'; v: string } | null>(null);
  const num = (v: string) => { const n = Number(v.replace(',', '.')); return Number.isFinite(n) && n > 0 ? n : 0; };
  const problem = discProblem(value, gross);
  return (
    <>
      <div className="frow">
        <div className="field"><label htmlFor={id + '-pct'}>Discount (%)</label>
          <input id={id + '-pct'} className="input" type="number" min="0" max={MAX_DISC} step="0.01" inputMode="decimal" placeholder="0" autoComplete="off"
            value={typing?.k === 'pct' ? typing.v : pct ? String(pct) : ''} onBlur={() => setTyping(null)}
            onChange={(e) => { setTyping({ k: 'pct', v: e.target.value }); onChange(Math.round(num(e.target.value) * 100) / 100); }} /></div>
        <div className="field"><label htmlFor={id + '-amt'}>Or discount amount (CDF)</label>
          <input id={id + '-amt'} className="input" type="number" min="0" step="10" inputMode="numeric" placeholder="0" autoComplete="off"
            value={typing?.k === 'amount' ? typing.v : amount ? String(amount) : ''} onBlur={() => setTyping(null)}
            onChange={(e) => { setTyping({ k: 'amount', v: e.target.value }); const a = Math.round(num(e.target.value)); onChange(a ? { amount: a } : 0); }} /></div>
      </div>
      <span className={`hint ${problem ? 'bad' : ''}`} style={problem ? { color: 'var(--bad)', fontWeight: 700 } : undefined}>
        {problem || (amount ? `${fCDF(amount)} off ${fCDF(gross)}: ${pct}%. ` : '') + `Maximum ${MAX_DISC}%.`}</span>
    </>
  );
}
