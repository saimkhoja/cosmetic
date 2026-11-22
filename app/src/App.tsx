import { Navigate, Route, Routes } from 'react-router-dom';
import { useEffect } from 'react';
import { useAuth } from './auth/AuthProvider';
import Layout, { navFor } from './components/Layout';
import { ChangePassword, Lock, Login, Setup, Unconfigured } from './pages/Public';
import Inventory from './pages/Inventory';
import Deliveries, { Received, ShopStockAll } from './pages/Deliveries';
import { Activity, AdminHome, SettingsPage, Upkeep, Users } from './pages/Admin';
import Reports from './pages/Reports';
import Till from './pages/Till';
import { Invoices, ShopHome, ShopStock } from './pages/Shop';
import { Books, GoodsIn, Returns } from './pages/Stores';
import Accounts from './pages/Accounts';
import Requests from './pages/Requests';
import Vendeurs from './pages/Vendeurs';
import { Empty } from './components/ui';
import { startSync } from './offline/sync';
import { useSettings } from './data/queries';

export default function App() {
  const { status, profile, locked } = useAuth();
  const settings = useSettings(status === 'ready' && !!profile);
  useEffect(() => { if (profile && (profile.role === 'till' || profile.role === 'shopadmin')) startSync(); }, [profile]);
  if (status === 'loading') return <Empty i="refresh" t="Starting QuickSales" tall />;
  if (status === 'unconfigured') return <Unconfigured />;
  if (status === 'setup') return <Setup />;
  if (status !== 'ready' || !profile) return <Login />;
  if (locked) return <Lock />;
  if (profile.must_change_password) return <ChangePassword />;
  // the tabs of this role: without a central store the store-to-shop ones are left out, address and all
  // while the settings load, the Vendeurs address is kept, so opening or reloading /vendeurs does not jump to the first tab
  const nav = navFor(profile.role, settings.data ? settings.data.features : { vendeurs: true });
  const allowed = new Set(nav.map((n) => n[0]));
  const page: Record<string, JSX.Element> = {
    '/': profile.role === 'admin' ? <AdminHome /> : <ShopHome />, '/inventory': <Inventory />, '/deliveries': <Deliveries />, '/shop-stock': <ShopStockAll />,
    '/upkeep': <Upkeep />, '/reports': <Reports />, '/users': <Users />, '/settings': <SettingsPage />, '/activity': <Activity />,
    '/till': <Till />, '/invoices': <Invoices />, '/stock': <ShopStock />, '/received': <Received />,
    '/goods-in': <GoodsIn />, '/returns': <Returns />, '/books': <Books />, '/accounts': <Accounts />, '/requests': <Requests />, '/vendeurs': <Vendeurs />,
  };
  return (
    <Layout>
      <Routes>
        {[...allowed].map((p) => <Route key={p} path={p} element={page[p]} />)}
        <Route path="*" element={<Navigate to={nav[0][0]} replace />} />
      </Routes>
    </Layout>
  );
}
