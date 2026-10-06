import { useEffect, useState, type ReactNode } from 'react';
import { NavLink, useLocation } from 'react-router-dom';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { useShops } from '../data/queries';
import { outboxAll } from '../offline/store';
import { syncOutbox } from '../offline/sync';
import type { Role } from '../lib/types';

export const R: Record<Role, string> = { admin: 'Admin', whop: 'Warehouse Operator', shopadmin: 'Shop Admin', till: 'Till Operator' };
const ROLEICON: Record<Role, string> = { admin: 'shield', whop: 'warehouse', shopadmin: 'store', till: 'cart' };
export const NAV: Record<Role, [string, string, string][]> = {
  admin: [['/', 'Dashboard', 'home'], ['/inventory', 'Inventory', 'box'], ['/deliveries', 'Deliveries', 'truck'], ['/shop-stock', 'Shop stock', 'store'], ['/upkeep', 'Upkeep', 'wallet'], ['/reports', 'Reports', 'chart'], ['/users', 'Users', 'users'], ['/settings', 'Settings', 'settings'], ['/activity', 'Activity', 'shield']],
  whop: [['/inventory', 'Inventory', 'box'], ['/deliveries', 'Deliveries', 'truck'], ['/shop-stock', 'Shop stock', 'store']],
  shopadmin: [['/', 'Home', 'home'], ['/till', 'Till', 'cart'], ['/invoices', 'Invoices', 'receipt'], ['/stock', 'Stock', 'box'], ['/received', 'Deliveries', 'truck'], ['/reports', 'Reports', 'chart']],
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

export default function Layout({ children }: { children: ReactNode }) {
  const { profile, offline, signOut } = useAuth();
  const shops = useShops();
  const loc = useLocation();
  const waiting = useWaiting();
  const [busy, setBusy] = useState(false);
  if (!profile) return null;
  const shop = profile.shop_id ? shops.data?.find((s) => s.id === profile.shop_id) : null;
  const pos = loc.pathname === '/till';
  const pill = offline || !navigator.onLine
    ? <button className="pill off"><Icon n="wifioff" /><span>Offline{waiting ? `, ${waiting} sale${waiting > 1 ? 's' : ''} saved on device` : ''}</span></button>
    : <button className={`pill ${busy ? 'spin' : ''}`} title="Send waiting sales now" onClick={async () => { setBusy(true); await syncOutbox(); setBusy(false); }}><Icon n={busy ? 'refresh' : 'wifi'} /><span>{waiting ? `${waiting} sale${waiting > 1 ? 's' : ''} waiting to send` : 'Online, all synced'}</span></button>;
  const doSignOut = async () => {
    if (waiting && !confirm(`${waiting} sale${waiting > 1 ? 's are' : ' is'} not sent yet. They stay on this device and are sent when the next person signs in here online. Sign out?`)) return;
    await signOut();
  };
  return (
    <>
      <header className="top">
        <div className="brand"><div className="logo">SIM</div><div style={{ minWidth: 0 }}><div className="bt">Smart Invoice Management</div><div className="bs">{shop ? shop.name : 'Central store'}</div></div></div>
        <div className="sp" />
        {pill}
        <div className="who"><span className="av"><Icon n={ROLEICON[profile.role]} /></span><div><b>{profile.name}</b><small>{R[profile.role]}</small></div></div>
        <button className="iconbtn" onClick={doSignOut} title="Sign out" aria-label="Sign out"><Icon n="logout" /></button>
      </header>
      {offline || !navigator.onLine ? <div className="offline-bar">No internet. {profile.role === 'till' || profile.role === 'shopadmin' ? 'The till keeps selling; sales are sent when the connection returns.' : 'Changes need the connection.'}</div> : null}
      <div className="layout">
        <nav className="nav">{NAV[profile.role].map(([to, l, i]) => <NavLink key={to} to={to} end className={({ isActive }) => (isActive ? 'on' : '')}><Icon n={i} /><span>{l}</span></NavLink>)}</nav>
        <main className={pos ? 'posmain' : ''}>{children}</main>
      </div>
    </>
  );
}
