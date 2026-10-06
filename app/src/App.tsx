import { Navigate, Route, Routes } from 'react-router-dom';
import { useEffect } from 'react';
import { useAuth } from './auth/AuthProvider';
import Layout, { NAV } from './components/Layout';
import { ChangePassword, Lock, Login, Setup, Unconfigured } from './pages/Public';
import Inventory from './pages/Inventory';
import Deliveries, { Received, ShopStockAll } from './pages/Deliveries';
import { Activity, AdminHome, SettingsPage, Upkeep, Users } from './pages/Admin';
import Reports from './pages/Reports';
import Till from './pages/Till';
import { Invoices, ShopHome, ShopStock } from './pages/Shop';
import { Empty } from './components/ui';
import { startSync } from './offline/sync';

export default function App() {
  const { status, profile, locked } = useAuth();
  useEffect(() => { if (profile && (profile.role === 'till' || profile.role === 'shopadmin')) startSync(); }, [profile]);
  if (status === 'loading') return <Empty i="refresh" t="Starting SIM" tall />;
  if (status === 'unconfigured') return <Unconfigured />;
  if (status === 'setup') return <Setup />;
  if (status !== 'ready' || !profile) return <Login />;
  if (locked) return <Lock />;
  if (profile.must_change_password) return <ChangePassword />;
  const allowed = new Set(NAV[profile.role].map((n) => n[0]));
  const page: Record<string, JSX.Element> = {
    '/': profile.role === 'admin' ? <AdminHome /> : <ShopHome />, '/inventory': <Inventory />, '/deliveries': <Deliveries />, '/shop-stock': <ShopStockAll />,
    '/upkeep': <Upkeep />, '/reports': <Reports />, '/users': <Users />, '/settings': <SettingsPage />, '/activity': <Activity />,
    '/till': <Till />, '/invoices': <Invoices />, '/stock': <ShopStock />, '/received': <Received />,
  };
  return (
    <Layout>
      <Routes>
        {[...allowed].map((p) => <Route key={p} path={p} element={page[p]} />)}
        <Route path="*" element={<Navigate to={NAV[profile.role][0][0]} replace />} />
      </Routes>
    </Layout>
  );
}
