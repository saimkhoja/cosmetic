// Start: find out which client this address belongs to, then load the app for that client's database.
// Nothing here may import lib/supabase.ts (directly or through the app): see lib/tenant.ts.
import React from 'react';
import ReactDOM from 'react-dom/client';
import { registerSW } from 'virtual:pwa-register';
import './styles.css';
import { applyTheme, getTheme } from './lib/theme';
import { loadTenant } from './lib/tenant';
import { TenantProblem } from './pages/TenantProblem';

applyTheme(getTheme());
registerSW({ immediate: true });
const root = ReactDOM.createRoot(document.getElementById('root')!);

void loadTenant().then(async (r) => {
  if (r.kind === 'direct' || r.kind === 'tenant') {
    if (r.kind === 'tenant') document.title = `${r.tenant.name} · QuickSales`;
    const { start } = await import('./boot');
    start(root);
  } else if (r.kind === 'no-subdomain') {
    // getquicksales.com itself (and www): the landing page and signup, without the app
    const { Landing } = await import('./landing/Landing');
    root.render(<React.StrictMode><Landing /></React.StrictMode>);
  } else {
    root.render(<React.StrictMode><TenantProblem r={r} /></React.StrictMode>);
  }
});
