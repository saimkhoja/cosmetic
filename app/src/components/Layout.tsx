import { useEffect, useRef, useState, type ReactNode } from 'react';
import { NavLink, useLocation, useSearchParams } from 'react-router-dom';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useShops } from '../data/queries';
import { outboxAll } from '../offline/store';
import { syncOutbox } from '../offline/sync';
import type { Role } from '../lib/types';
import { getTheme, nextTheme, setTheme, THEME_ICON, THEME_LABEL, type ThemePref } from '../lib/theme';
import { CartMark } from './Brand';
import { canSearch, GlobalSearch } from './GlobalSearch';
import { clearFind, showFind } from '../lib/search';

export const R: Record<Role, string> = { admin: 'Admin', whop: 'Warehouse Operator', shopadmin: 'Shop Admin', till: 'Till Operator' };
const ROLEICON: Record<Role, string> = { admin: 'shield', whop: 'warehouse', shopadmin: 'store', till: 'cart' };
export const NAV: Record<Role, [string, string, string][]> = {
  admin: [['/', 'Dashboard', 'home'], ['/inventory', 'Inventory', 'box'], ['/goods-in', 'Goods in', 'download'], ['/requests', 'Requests', 'receipt'], ['/deliveries', 'Deliveries', 'truck'], ['/returns', 'Returns', 'exchange'], ['/shop-stock', 'Shop stock', 'store'], ['/accounts', 'Accounts', 'wallet'], ['/upkeep', 'Upkeep', 'cash'], ['/reports', 'Reports', 'chart'], ['/users', 'Users', 'users'], ['/settings', 'Settings', 'settings'], ['/activity', 'Activity', 'shield']],
  whop: [['/inventory', 'Inventory', 'box'], ['/goods-in', 'Goods in', 'download'], ['/requests', 'Requests', 'receipt'], ['/deliveries', 'Deliveries', 'truck'], ['/returns', 'Returns', 'exchange'], ['/shop-stock', 'Shop stock', 'store'], ['/books', 'Statements', 'doc']],
  shopadmin: [['/', 'Home', 'home'], ['/till', 'Till', 'cart'], ['/invoices', 'Invoices', 'receipt'], ['/stock', 'Stock', 'box'], ['/requests', 'Order stock', 'plus'], ['/received', 'Deliveries', 'truck'], ['/returns', 'Returns', 'exchange'], ['/books', 'Statements', 'doc'], ['/reports', 'Reports', 'chart']],
  till: [['/till', 'Till', 'cart']],
};

export function useWaiting() {
  const [n, setN] = useState(0);
  useEffect(() => {
    const upd = () => { void outboxAll().then((l) => setN(l.length)); };
    upd(); addEventListener('sim-outbox', upd);
    return () => removeEventListener('sim-outbox', upd);
  }, []);
  return n;
}

/** Arriving from the global search (?find=word&at=record): wait for the tab to draw the record, then scroll to it and
 *  highlight the word. The highlight goes when the user leaves the tab or searches again. */
function useFind(main: React.RefObject<HTMLElement>) {
  const [params] = useSearchParams(), find = params.get('find') ?? '', at = params.get('at') ?? '';
  useEffect(() => {
    if (!find || !main.current) return;
    let tries = 0;
    const id = setInterval(() => {
      tries += 1;
      if (!main.current || showFind(main.current, find, at || find, tries >= 30) || tries >= 30) clearInterval(id);
    }, 200);
    return () => { clearInterval(id); clearFind(); };
  }, [find, at, main]);
  return find ? `${find}\u0000${at}` : '';
}

export default function Layout({ children }: { children: ReactNode }) {
  const { profile, offline, signOut } = useAuth();
  const shops = useShops();
  const loc = useLocation();
  const waiting = useWaiting();
  const [busy, setBusy] = useState(false), [theme, setThemeState] = useState<ThemePref>(getTheme);
  const main = useRef<HTMLElement>(null), findKey = useFind(main);
  if (!profile) return null;
  const switchTheme = () => { const t = nextTheme(theme); setTheme(t); setThemeState(t); };
  const shop = profile.shop_id ? shops.data?.find((s) => s.id === profile.shop_id) : null;
  if (shop) localStorage.setItem('sim.shopname', shop.name);
  const shopName = shop?.name ?? (profile.shop_id ? localStorage.getItem('sim.shopname') : null);
  const pos = loc.pathname === '/till';
  const pill = offline || !navigator.onLine
    ? <button className="pill off"><Icon n="wifioff" /><span>Offline{waiting ? `, ${waiting} saved on device` : ''}</span></button>
    : <button className={`pill ${busy ? 'spin' : ''}`} title="Send waiting sales now" onClick={async () => { setBusy(true); await syncOutbox(); setBusy(false); }}><Icon n={busy ? 'refresh' : 'wifi'} /><span>{waiting ? `${waiting} waiting to send` : 'Online, all synced'}</span></button>;
  const doSignOut = async () => {
    if (waiting && !confirm(`${waiting} sale${waiting > 1 ? 's or orders are' : ' or order is'} not sent yet. They stay on this device and are sent when the next person signs in here online. Sign out?`)) return;
    await signOut();
  };
  return (
    <>
      <header className={pos ? 'top tilltop' : 'top'}>
        <div className="brand"><div className="logo"><CartMark size={30} /></div><div style={{ minWidth: 0 }}><div className="bt"><span>Quick</span><span className="bt2">Sales</span></div><div className="bs">{shopName ?? 'Central store'}</div></div></div>
        {pos ? <div id="topslot" className="topslot" /> : <div className="sp" />}
        {canSearch(profile.role) && !pos ? <GlobalSearch /> : null}
        {pill}
        <div className="who" title={`${profile.name}, ${R[profile.role]}`}><span className="av"><Icon n={ROLEICON[profile.role]} /></span><div><b>{profile.name}</b><small>{R[profile.role]}</small></div></div>
        <button className="iconbtn" id="themebtn" onClick={switchTheme} title={`Screen: ${THEME_LABEL[theme]}. Click to change`} aria-label={`Screen colours: ${THEME_LABEL[theme]}. Click to change`}><Icon n={THEME_ICON[theme]} /></button>
        <button className="iconbtn" onClick={doSignOut} title="Sign out" aria-label="Sign out"><Icon n="logout" /></button>
      </header>
      {offline || !navigator.onLine ? <div className="offline-bar">No internet. {profile.role === 'till' || profile.role === 'shopadmin' ? 'The till keeps working; sales and orders are sent when the connection returns.' : 'Changes need the connection.'}</div> : null}
      <div className="layout">
        <nav className="nav">{NAV[profile.role].map(([to, l, i]) => <NavLink key={to} to={to} end className={({ isActive }) => (isActive ? 'on' : '')}><Icon n={i} /><span>{l}</span></NavLink>)}</nav>
        {/* a new search result opens the tab afresh, so it reads the record's filters from the link */}
        <main ref={main} key={findKey} className={pos ? 'posmain' : ''}>{children}</main>
      </div>
    </>
  );
}
