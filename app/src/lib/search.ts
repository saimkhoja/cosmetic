// Global search: one box that looks for a word or part of a word in every record the signed-in user can see, and
// lists the tabs that hold it. Opening a result goes to that tab with ?find=<word>&at=<record>, and showFind (below)
// scrolls to the record there and highlights the word.

/** A record that can be found: a title and sub-line for the result list, the fields searched, and how to reach it. */
export interface Rec {
  id: string; title: string; sub?: string;
  fields: [label: string, value: string | null | undefined][];
  /** text shown on the tab inside this record's row or card (its number, code or name), used to find it there */
  anchor: string;
  /** extra URL parameters the tab needs to show it (an archived item, the ledgers tab, the day of an invoice) */
  params?: Record<string, string>;
}
/** One tab of the app and the records found on it. */
export interface Source { tab: string; route: string; icon: string; recs: Rec[] }
export interface Hit { rec: Rec; field: string; value: string; at: number }
export interface Group { tab: string; route: string; icon: string; hits: Hit[]; total: number }

export const MIN_QUERY = 2;
/** Results listed per tab; the tab shows how many there are in all. */
export const PER_TAB = 6;

const norm = (s: string) => s.toLocaleLowerCase();

/** Every record holding the text, anywhere in one of its fields (case does not matter), grouped by tab. */
export function search(q: string, sources: Source[]): Group[] {
  const t = norm(q.trim());
  if (t.length < MIN_QUERY) return [];
  const out: Group[] = [];
  for (const s of sources) {
    const hits: Hit[] = [];
    for (const rec of s.recs) {
      for (const [field, v] of rec.fields) {
        if (!v) continue;
        const at = norm(v).indexOf(t);
        if (at >= 0) { hits.push({ rec, field, value: v, at }); break; }
      }
    }
    // a match at the start of a field first (a code or a name typed from its beginning), then in list order
    hits.sort((a, b) => Number(a.at > 0) - Number(b.at > 0));
    if (hits.length) out.push({ tab: s.tab, route: s.route, icon: s.icon, hits: hits.slice(0, PER_TAB), total: hits.length });
  }
  return out;
}

/** The part of a long value around the match, so the matched word is always in view. */
export function snippet(value: string, at: number, len: number, room = 34) {
  const v = value.replace(/\s/g, ' ');
  if (v.length <= room * 2 + len) return { pre: v.slice(0, at), hit: v.slice(at, at + len), post: v.slice(at + len) };
  const a = Math.max(0, at - room), b = Math.min(v.length, at + len + room);
  return { pre: (a > 0 ? '…' : '') + v.slice(a, at), hit: v.slice(at, at + len), post: v.slice(at + len, b) + (b < v.length ? '…' : '') };
}

/** The link for a result: its tab, with the word, the record and what the tab needs to show it. */
export function hitLink(route: string, q: string, rec: Rec) {
  const p = new URLSearchParams({ ...rec.params, find: q.trim(), at: rec.anchor });
  return `${route}?${p}`;
}

/** Characters that would break a server text filter are left out of it (the box still searches the rest locally). */
export const serverTerm = (q: string) => q.trim().replace(/[%_,()*\\"]/g, ' ').trim();

// ---------- on the tab: scroll to the record and highlight the word ----------

const ROWS = 'tr, .card, .reqrow, li';

/** Every place the text appears (as one word or across a text node), as ranges, inside the element. */
function ranges(root: Node, text: string): Range[] {
  const t = norm(text), out: Range[] = [];
  if (!t) return out;
  const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let n = w.nextNode(); n; n = w.nextNode()) {
    const v = norm(n.nodeValue ?? '');
    for (let i = v.indexOf(t); i >= 0; i = v.indexOf(t, i + t.length)) { const r = document.createRange(); r.setStart(n, i); r.setEnd(n, i + t.length); out.push(r); }
  }
  return out;
}

/** The row or card that holds the record: the smallest one whose text has its anchor. */
export function findRow(root: HTMLElement, anchor: string): HTMLElement | null {
  const a = norm(anchor);
  let best: HTMLElement | null = null;
  root.querySelectorAll<HTMLElement>(ROWS).forEach((el) => {
    if (norm(el.textContent ?? '').includes(a) && (!best || (el.textContent ?? '').length < (best.textContent ?? '').length)) best = el;
  });
  return best;
}

type Reg = { set(k: string, v: unknown): void; delete(k: string): void };
const reg = (): Reg | null => (typeof CSS !== 'undefined' && 'highlights' in CSS ? (CSS as unknown as { highlights: Reg }).highlights : null);
const mk = (rs: Range[]) => new (window as unknown as { Highlight: new (...r: Range[]) => unknown }).Highlight(...rs);

export function clearFind() { const h = reg(); h?.delete('qs-find'); h?.delete('qs-find-now'); }

/** Scroll to the record on the tab and highlight the word: everywhere on the tab, and strongly in the record.
 *  Returns false while the tab has not drawn the record yet; with last, settles for the first place the word is. */
export function showFind(root: HTMLElement, q: string, anchor: string, last = false): boolean {
  const row = findRow(root, anchor), all = ranges(root, q);
  if (!row && (!last || !all.length)) return false;
  let now = row ? ranges(row, q) : all.slice(0, 1);
  if (row && !now.length) now = ranges(row, anchor);
  const h = reg();
  if (h) {
    h.set('qs-find', mk(all.filter((r) => !now.some((x) => x.startContainer === r.startContainer && x.startOffset === r.startOffset))));
    h.set('qs-find-now', mk(now));
  }
  const target = row ?? now[0]?.startContainer.parentElement ?? null;
  if (target) {
    target.scrollIntoView({ block: 'center', behavior: 'smooth' });
    target.animate?.([{ backgroundColor: 'var(--find-row)' }, { backgroundColor: 'var(--find-row)', offset: 0.7 }, { backgroundColor: 'transparent' }], { duration: 3200, easing: 'ease-out' });
  }
  return true;
}
