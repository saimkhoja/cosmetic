// Shown instead of the app when the address does not lead to a client's database (see lib/tenant.ts).
// Kept free of lib/supabase.ts and the auth code, which need a database to load.
import { Icon } from '../lib/icons';
import type { Resolved } from '../lib/tenant';

type Problem = Exclude<Resolved, { kind: 'direct' } | { kind: 'tenant' }>;

export function TenantProblem({ r }: { r: Problem }) {
  const host = location.host;
  const [title, body] = ((): [string, JSX.Element] => {
    switch (r.kind) {
      case 'no-subdomain':
        return ['Open your shop\'s own address', <p>Each business has its own QuickSales address, such as <b>yourshop.getquicksales.com</b>. Use the link you were given when you signed up.</p>];
      case 'unknown':
        return ['No shop at this address', <p>There is no QuickSales business at <b>{host}</b>. Check the spelling of the address, or use the link you were given when you signed up.</p>];
      case 'suspended':
        return [`${r.name} is switched off`, <p>QuickSales for <b>{r.name}</b> is not active at the moment. Contact QuickSales support to switch it back on.</p>];
      case 'unreachable':
        return ['No connection', <p>The first time QuickSales opens on this device it needs the internet to find <b>{host}</b>. Connect and try again; after that it also opens offline.</p>];
      case 'unconfigured':
        return ['QuickSales is not connected to a database', <p>Set <b>VITE_CONTROL_URL</b> and <b>VITE_CONTROL_ANON_KEY</b> (one site for every client) or <b>VITE_SUPABASE_URL</b> and <b>VITE_SUPABASE_ANON_KEY</b> (one client) when building the app. See deploy/DEPLOY.md.</p>];
    }
  })();
  return (
    <div className="lockwrap"><div className="card" id="tenant-problem" data-kind={r.kind}>
      <h3><Icon n="alert" /> {title}</h3>{body}
      {r.kind === 'unreachable' && <button className="btn primary" onClick={() => location.reload()}>Try again</button>}
    </div></div>
  );
}
