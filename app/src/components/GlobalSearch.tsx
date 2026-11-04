// The search box in the header, for the Admin and the Shop Admin: type any part of a word and see every tab that
// holds it (items, invoices, deliveries, requests, returns, suppliers, ledgers, users, the activity log...).
// Opening a result goes to that tab, scrolls to the record and highlights the word (lib/search.ts showFind).
import { useEffect, useMemo, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { supabase, rows } from '../lib/supabase';
import { dt, fCDF, ld } from '../lib/format';
import { barcodesOf } from '../lib/items';
import { hitLink, MIN_QUERY, search, serverTerm, snippet, type Rec, type Source } from '../lib/search';
import {
  useAudit, useDeliveries, useGrns, useLedgers, useProducts, useReturns, useShops, useStockRequests, useSupplierReturns, useSuppliers, useUpkeep, useUsers,
} from '../data/queries';
import { R } from './Layout';
import type { Product } from '../lib/types';

type InvHit = { id: string; no: string; shop_id: string; customer: string | null; cashier_name: string; t: string; total: number };

/** Who can use it: the Admin and the Shop Admin. */
export const canSearch = (role: string) => role === 'admin' || role === 'shopadmin';

function useSources(on: boolean, term: string): { sources: Source[]; loading: boolean } {
  const { profile } = useAuth(), admin = profile!.role === 'admin', sid = profile!.shop_id;
  const products = useProducts(), shops = useShops();
  const dels = useDeliveries(admin ? null : sid, on), reqs = useStockRequests(on), rets = useReturns(on);
  const grns = useGrns(on && admin), srets = useSupplierReturns(on && admin), sups = useSuppliers(on && admin), ledgers = useLedgers(on && admin);
  const upkeep = useUpkeep(on && admin), users = useUsers(on && admin), audit = useAudit(on && admin);
  // invoices are too many to load: they are searched on the server (only the shop's own for the Shop Admin)
  const t = serverTerm(term);
  const inv = useQuery({
    queryKey: ['gsearch', t], enabled: on && t.length >= MIN_QUERY, staleTime: 15000,
    queryFn: async () => rows<InvHit>(await supabase.from('invoices').select('id,no,shop_id,customer,cashier_name,t,total')
      .or(`no.ilike.%${t}%,customer.ilike.%${t}%,cashier_name.ilike.%${t}%`).order('t', { ascending: false }).limit(40)),
  });
  const sources = useMemo(() => {
    const byId = new Map((products.data ?? []).map((p) => [p.id, p])), shopName = (id: string) => shops.data?.find((s) => s.id === id)?.name ?? '';
    const supName = (id: string) => sups.data?.find((s) => s.id === id)?.name ?? '';
    const items = (l: { product_id: string }[]) => l.map((i): [string, string | undefined] => ['Item', byId.get(i.product_id)?.name]);
    const product = (p: Product, params?: Record<string, string>): Rec => ({
      id: p.id, title: p.name, sub: [p.sku, p.category, p.active ? '' : 'archived'].filter(Boolean).join(' · '), anchor: p.sku || p.name, params,
      fields: [['Name', p.name], ['Code', p.sku], ['Category', p.category], ...barcodesOf(p).map((b): [string, string] => ['Barcode', b])],
    });
    const S: Source[] = [];
    if (admin) S.push({ tab: 'Inventory', route: '/inventory', icon: 'box', recs: (products.data ?? []).map((p) => product(p, p.active ? undefined : { arch: '1' })) });
    else S.push({ tab: 'Stock', route: '/stock', icon: 'box', recs: (products.data ?? []).filter((p) => p.active).map((p) => product(p)) });
    S.push({ tab: admin ? 'Reports (invoices)' : 'Invoices', route: admin ? '/reports' : '/invoices', icon: 'receipt', recs: (inv.data ?? []).map((i): Rec => ({
      id: i.id, title: i.no, sub: [i.customer, admin ? shopName(i.shop_id) : '', dt(i.t), fCDF(i.total)].filter(Boolean).join(' · '), anchor: i.no,
      params: admin ? { day: ld(i.t), shop: i.shop_id } : { f: 'all', s: i.no },
      fields: [['Invoice', i.no], ['Customer', i.customer], ['Sales person', i.cashier_name]],
    })) });
    if (admin) {
      S.push({ tab: 'Goods in', route: '/goods-in', icon: 'download', recs: [
        ...(grns.data ?? []).map((g): Rec => ({ id: g.id, title: g.no, sub: [supName(g.supplier_id), dt(g.received_at)].join(' · '), anchor: g.no,
          fields: [['Receipt', g.no], ['Supplier', supName(g.supplier_id)], ['Supplier ref', g.ref], ['Note', g.note], ['Received by', g.received_by_name], ...items(g.grn_items)] })),
        ...(srets.data ?? []).map((r): Rec => ({ id: r.id, title: r.no, sub: [r.kind === 'short' ? 'Claim, not received' : 'Return to supplier', supName(r.supplier_id)].join(' · '), anchor: r.no,
          fields: [['Return', r.no], ['Supplier', supName(r.supplier_id)], ['Reason', r.reason], ['Note', r.note], ['By', r.created_by_name], ...items(r.supplier_return_items)] })),
      ] });
    }
    S.push({ tab: admin ? 'Requests' : 'Order stock', route: '/requests', icon: admin ? 'receipt' : 'plus', recs: (reqs.data ?? []).map((r) => ({
      id: r.id, title: r.no, sub: [shopName(r.shop_id), dt(r.created_at)].join(' · '), anchor: r.no,
      fields: [['Request', r.no], ['Shop', shopName(r.shop_id)], ['Note', r.note], ['Asked by', r.created_by_name], ['Reason', r.reason], ...(admin && r.status === 'pending' ? [] : items(r.stock_request_items))],
    })) });
    S.push({ tab: 'Deliveries', route: admin ? '/deliveries' : '/received', icon: 'truck', recs: (dels.data ?? []).map((d) => ({
      id: d.id, title: d.no, sub: [shopName(d.shop_id), dt(d.created_at)].join(' · '), anchor: d.no,
      fields: [['Delivery', d.no], ['Shop', shopName(d.shop_id)], ['Sent by', d.created_by_name], ['Received by', d.received_by_name], ['Note', d.received_note], ...items(d.delivery_items)],
    })) });
    S.push({ tab: 'Returns', route: '/returns', icon: 'exchange', recs: (rets.data ?? []).map((x) => ({
      id: x.id, title: x.no, sub: [shopName(x.shop_id), dt(x.created_at)].join(' · '), anchor: x.no,
      fields: [['Return', x.no], ['Shop', shopName(x.shop_id)], ['Reason', x.reason], ['Sent by', x.created_by_name], ['Note', x.received_note], ...items(x.return_items)],
    })) });
    if (admin) {
      S.push({ tab: 'Accounts', route: '/accounts', icon: 'wallet', recs: [
        ...(sups.data ?? []).map((s): Rec => ({ id: s.id, title: s.name, sub: ['Supplier', s.contact, s.phone].filter(Boolean).join(' · '), anchor: s.name, params: { tab: 'suppliers', ...(s.active ? {} : { inactive: '1' }) },
          fields: [['Supplier', s.name], ['Contact', s.contact], ['Phone', s.phone], ['Email', s.email], ['Address', s.address], ['Tax no.', s.tax_no]] })),
        ...(ledgers.data ?? []).map((l): Rec => ({ id: l.id, title: l.name, sub: ['Ledger', l.group_name].join(' · '), anchor: l.name, params: { tab: 'ledgers' },
          fields: [['Ledger', l.name], ['Code', l.code], ['Group', l.group_name]] })),
      ] });
      S.push({ tab: 'Upkeep', route: '/upkeep', icon: 'cash', recs: (upkeep.data ?? []).map((u) => ({ id: u.id, title: u.description || u.category, sub: [u.category, u.date].join(' · '), anchor: u.description || u.category,
        fields: [['Description', u.description], ['Type', u.category], ['Recorded by', u.by_name]] })) });
      S.push({ tab: 'Users', route: '/users', icon: 'users', recs: (users.data ?? []).map((u) => ({ id: u.id, title: u.name, sub: [u.username, R[u.role]].join(' · '), anchor: u.username,
        fields: [['Name', u.name], ['Username', u.username]] })) });
      S.push({ tab: 'Settings (shops)', route: '/settings', icon: 'settings', recs: (shops.data ?? []).map((s) => ({ id: s.id, title: s.name, sub: [s.code, s.address].join(' · '), anchor: s.name,
        fields: [['Shop', s.name], ['Code', s.code], ['Address', s.address]] })) });
      S.push({ tab: 'Activity', route: '/activity', icon: 'shield', recs: (audit.data ?? []).map((x) => ({ id: String(x.id), title: x.action, sub: [x.username, dt(x.at)].join(' · '), anchor: x.action,
        fields: [['What happened', x.action], ['User', x.username]] })) });
    }
    return S;
  }, [admin, products.data, shops.data, inv.data, grns.data, srets.data, sups.data, reqs.data, dels.data, rets.data, ledgers.data, upkeep.data, users.data, audit.data]);
  return { sources, loading: inv.isFetching || dels.isLoading || reqs.isLoading };
}

function Mark({ value, at, len }: { value: string; at: number; len: number }) {
  const s = snippet(value, at, len);
  return <>{s.pre}<mark>{s.hit}</mark>{s.post}</>;
}

function SearchDialog({ onClose }: { onClose: () => void }) {
  const [q, setQ] = useState(''), [term, setTerm] = useState(''), [k, setK] = useState(0);
  // the list follows the box at once; the server search for invoices waits until typing pauses
  const [slow, setSlow] = useState('');
  useEffect(() => { setTerm(q); const t = setTimeout(() => setSlow(q), 250); return () => clearTimeout(t); }, [q]);
  const { sources, loading } = useSources(true, slow);
  const groups = useMemo(() => search(term, sources), [term, sources]);
  const flat = groups.flatMap((g) => g.hits.map((h) => ({ g, h })));
  const nav = useNavigate(), list = useRef<HTMLDivElement>(null);
  useEffect(() => setK(0), [term]);
  useEffect(() => { list.current?.querySelector(`[data-k="${k}"]`)?.scrollIntoView({ block: 'nearest' }); }, [k]);
  const open = (i: number) => { const x = flat[i]; if (!x) return; nav(hitLink(x.g.route, term, x.h.rec)); onClose(); };
  const key = (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setK((v) => Math.min(flat.length - 1, v + 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setK((v) => Math.max(0, v - 1)); }
    else if (e.key === 'Enter') { e.preventDefault(); open(k); }
    else if (e.key === 'Escape') { e.preventDefault(); onClose(); }
  };
  const tabs = sources.map((s) => s.tab).join(', ');
  const len = term.trim().length;
  let n = -1;
  return (
    <div className="modal-wrap gs-wrap" onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="modal gs" role="dialog" aria-modal="true" aria-label="Search everything">
        <div className="gs-box"><Icon n="search" />
          <input autoFocus value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={key} placeholder="Search everything: an item, invoice, customer, delivery, supplier…"
            role="combobox" aria-expanded={flat.length > 0} aria-controls="gs-list" aria-activedescendant={flat.length ? `gs-${k}` : undefined} autoComplete="off" spellCheck={false} />
          {loading && len >= MIN_QUERY ? <span className="gs-busy"><Icon n="refresh" /></span> : null}
          <button className="iconbtn dark" onClick={onClose} aria-label="Close"><Icon n="x" /></button></div>
        <div className="gs-list" id="gs-list" role="listbox" ref={list}>
          {len < MIN_QUERY ? <div className="gs-empty"><b>Type at least {MIN_QUERY} letters or numbers.</b><span>Any part of a word works: “ivea” finds Nivea. Searches {tabs}.</span></div>
            : !groups.length ? <div className="gs-empty"><b>{loading ? 'Searching…' : `Nothing found for “${term.trim()}”`}</b><span>Searches {tabs}.</span></div>
            : <>
              <div className="gs-sum">Found on {groups.length} tab{groups.length > 1 ? 's' : ''}: {groups.map((g) => `${g.tab} (${g.total})`).join(', ')}</div>
              {groups.map((g) => <div key={g.tab} className="gs-group" role="group" aria-label={g.tab}>
                <div className="gs-tab"><Icon n={g.icon} /><b>{g.tab}</b><span>{g.total} found{g.total > g.hits.length ? `, first ${g.hits.length} shown` : ''}</span></div>
                {g.hits.map((h) => { n += 1; const i = n, inTitle = h.value === h.rec.title;
                  return <button key={h.rec.id} id={`gs-${i}`} data-k={i} role="option" aria-selected={i === k} className={`gs-hit ${i === k ? 'on' : ''}`} onMouseMove={() => setK(i)} onClick={() => open(i)}>
                    <span className="gs-t">{inTitle ? <Mark value={h.value} at={h.at} len={len} /> : h.rec.title}</span>
                    <span className="gs-s">{inTitle ? h.rec.sub : <><em>{h.field}:</em> <Mark value={h.value} at={h.at} len={len} /></>}</span>
                    <span className="gs-go" aria-hidden="true">›</span></button>; })}
                {g.total > g.hits.length ? <button className="gs-more" onClick={() => { nav(hitLink(g.route, term, { id: '', title: '', fields: [], anchor: term.trim() })); onClose(); }}>
                  Show all {g.total} on {g.tab}, with “{term.trim()}” highlighted ›</button> : null}
              </div>)}
            </>}
        </div>
        <div className="gs-foot"><span><kbd>↑</kbd><kbd>↓</kbd> move</span><span><kbd>Enter</kbd> open</span><span><kbd>Esc</kbd> close</span></div>
      </div>
    </div>
  );
}

/** The header button (and Ctrl+K or /) that opens the search. */
export function GlobalSearch() {
  const [open, setOpen] = useState(false), loc = useLocation();
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      const typing = e.target instanceof HTMLElement && (e.target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName));
      if ((e.key === 'k' && (e.ctrlKey || e.metaKey)) || (e.key === '/' && !typing)) { e.preventDefault(); setOpen(true); }
    };
    addEventListener('keydown', k); return () => removeEventListener('keydown', k);
  }, []);
  useEffect(() => setOpen(false), [loc.pathname, loc.search]);
  return (
    <>
      <button className="gsearch" onClick={() => setOpen(true)} title="Search everything (Ctrl+K)" aria-label="Search everything"><Icon n="search" /><span>Search everything</span><kbd>Ctrl K</kbd></button>
      {open ? <SearchDialog onClose={() => setOpen(false)} /> : null}
    </>
  );
}
