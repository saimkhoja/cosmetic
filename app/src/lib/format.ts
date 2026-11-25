// Money and date formatting, as on the approved demo.
/** Francs rounded UP to the next 50 (4 220 -> 4 250, 4 260 -> 4 300); whole 50s stay. Cents first, so float noise
 *  (0.1 x 3000 = 300.00000000000006) does not push a round amount up. Mirrors app.to_cdf. */
export const up50 = (cdf: number) => Math.ceil(Math.round((Number(cdf) || 0) * 100) / 100 / 50) * 50;
/** Shop price in Francs: USD x the sales rate, rounded up to the next 50 FC. */
export const toCDF = (usd: number, rate: number) => up50(Number(usd) * Number(rate));
/** Francs the rounding added to a price (USD x rate up to the next 50), to the whole Franc: 4 275 -> 4 300 is 25. */
export const roundedBy = (usd: number, rate: number) => Math.max(0, Math.round(toCDF(usd, rate) - Number(usd) * Number(rate)));
export const fNum = (n: number) => Math.round(Number(n) || 0).toLocaleString('en-US').replace(/,/g, ' ');
export const fCDF = (n: number) => fNum(n) + ' CDF';
export const fUSD = (n: number) => (n < 0 ? '-' : '') + '$' + Math.abs(Number(n) || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
export const ld = (t: string | number | Date) => { const d = new Date(t); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); };
export const today = () => ld(Date.now());
export const dt = (t: string | number) => new Date(t).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
export const tm = (t: string | number) => new Date(t).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
export const shortCDF = (n: number) => (n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1000 ? Math.round(n / 1000) + 'k' : String(Math.round(n)));
export const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
export const sum = <T,>(a: T[], f: (x: T) => number) => a.reduce((s, x) => s + f(x), 0);
/** The internal rate (suppliers, expenses, vouchers); an installation without it uses the sales rate. */
export const bookRate = (s?: { rate?: number; book_rate?: number } | null) => Number(s?.book_rate || s?.rate || 1);
