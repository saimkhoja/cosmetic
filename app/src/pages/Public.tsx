// Screens shown before the app: not configured, first-run setup, sign in, password change, idle lock.
import { useState, type FormEvent } from 'react';
import { Icon } from '../lib/icons';
import { useAuth } from '../auth/AuthProvider';
import { emailFor, invoke, rpc, supabase } from '../lib/supabase';
import { rememberPassword } from '../offline/pwcache';
import { useAction } from '../components/ui';
import { QuickSalesLogo } from '../components/Brand';

const pwProblem = (p: string) => (p.length < 10 ? 'Password needs at least 10 characters' : !/[A-Za-z]/.test(p) || !/\d/.test(p) ? 'Password needs letters and numbers' : null);

// The sign-in panel: the QuickSales logo, the headline and six feature cards. Icons are white with a green accent.
const W = { fill: 'none', stroke: '#fff', strokeWidth: 3.2, strokeLinecap: 'round', strokeLinejoin: 'round' } as const;
const G = { ...W, stroke: '#2DD67F' } as const;
// labels break where \n is, as on the approved design
const FEATURES: [string, JSX.Element][] = [
  ['Keep Selling\nOffline', <><path {...W} d="M5 18a27 27 0 0 1 38 0M11 25a18 18 0 0 1 26 0M17 32a9 9 0 0 1 14 0" /><circle cx="24" cy="38" r="2.6" fill="#fff" /><circle cx="36" cy="36" r="8" fill="#2DD67F" /><path {...W} strokeWidth={2.8} d="M32.5 36l2.5 2.5 4.6-5" /></>],
  ['Flexible\nSelling', <><path {...W} d="M24 4l14 7v14l-14 7-14-7V11z" /><path {...W} d="M10 11l14 7 14-7M24 18v14" /><path {...G} d="M17 7.5l14 7" /><path {...W} d="M10 30v7l14 7 14-7v-7" /></>],
  ['Control Stock\n& Deliveries', <><path {...W} d="M14 10h19v22H14zM33 17h7l5 7v8H33" /><circle cx="20" cy="36" r="4" {...W} /><circle cx="39" cy="36" r="4" {...W} /><path {...G} d="M3 15h7M1 21h9M4 27h6" /></>],
  ['Built-in\nAccounting', <><rect x="6" y="26" width="7" height="16" rx="2" {...W} /><rect x="20" y="17" width="7" height="25" rx="2" {...W} /><rect x="34" y="7" width="7" height="35" rx="2" {...W} /><path {...G} d="M6 26v16" /></>],
  ['Secure &\nRole-Based Access', <><path {...W} d="M24 4l16 6v11c0 11-7 19-16 23C15 40 8 32 8 21V10z" /><path {...G} strokeWidth={3.6} d="M16.5 23.5l5.5 5.5 10-11" /></>],
  ['Barcode, Receipts\n& Price Tickets', <><path {...W} d="M4 13V6h7M37 6h7v7M44 35v7h-7M11 42H4v-7" /><path {...W} strokeWidth={2.6} d="M12 14v20M16 14v20M21 14v20M26 14v20M31 14v20M36 14v20" /><path {...W} strokeWidth={1.4} d="M18.5 14v20M23.5 14v20M33.5 14v20" /></>],
];

function Hero() {
  return (
    <section className="hero">
      <QuickSalesLogo dark />
      <h1>A complete POS for your <span className="biz">business<svg viewBox="0 0 220 18" preserveAspectRatio="none" aria-hidden="true"><path d="M4 13C60 5 150 3 216 9" fill="none" stroke="#2DD67F" strokeWidth="5" strokeLinecap="round" /></svg></span></h1>
      <div className="feats">{FEATURES.map(([t, i]) => <div key={t} className="feat"><svg viewBox="0 0 48 48" aria-hidden="true">{i}</svg><b>{t.split('\n').map((l, n) => <span key={n}>{n ? <br /> : null}{l}</span>)}</b></div>)}</div>
    </section>
  );
}

export function Unconfigured() {
  return <div className="lockwrap"><div className="card"><h3><Icon n="alert" /> QuickSales is not connected to a database</h3><p>Set <b>VITE_SUPABASE_URL</b> and <b>VITE_SUPABASE_ANON_KEY</b> when building the app. See deploy/DEPLOY.md.</p></div></div>;
}

export function Login() {
  const { signIn } = useAuth();
  const [u, setU] = useState(''), [p, setP] = useState('');
  const a = useAction();
  const go = (e: FormEvent) => { e.preventDefault(); if (!u.trim() || !p) { a.setErr('Enter your username and password'); return; } void a.run(() => signIn(u, p)); };
  return (
    <div className="login"><Hero />
      <section className="panel"><form className="lcard" onSubmit={go}><h2>Sign in</h2><p>Use the login given to you by the Admin.</p>
        <div className="field"><label htmlFor="lu">Username</label><div className="iwrap"><Icon n="user" /><input id="lu" className="input" autoComplete="username" autoCapitalize="off" spellCheck={false} value={u} onChange={(e) => setU(e.target.value)} autoFocus /></div></div>
        <div className="field"><label htmlFor="lp">Password</label><div className="iwrap"><Icon n="lock" /><input id="lp" type="password" className="input" autoComplete="current-password" value={p} onChange={(e) => setP(e.target.value)} /></div></div>
        <div className="lerr">{a.err}</div>
        <button id="lbtn" className="btn primary xl" disabled={a.busy}><Icon n="unlock" /> {a.busy ? 'Signing in…' : 'Sign in'}</button>
        <p className="demo-t">Forgot your password? Ask the Admin to reset it.</p>
      </form></section>
    </div>
  );
}

export function Setup() {
  const { reload } = useAuth();
  const [f, setF] = useState({ name: '', username: 'admin', password: '', password2: '', company: '', address: '', phone: '', rccm: '', idnat: '', nif: '', rate: '2850', vat: '16' });
  const [shops, setShops] = useState([{ code: '', name: '', address: '' }]);
  const a = useAction();
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value });
  const go = (e: FormEvent) => {
    e.preventDefault();
    void a.run(async () => {
      if (f.name.trim().length < 2) throw new Error('Enter your full name');
      const pw = pwProblem(f.password); if (pw) throw new Error(pw);
      if (f.password !== f.password2) throw new Error('The two passwords are not the same');
      if (!f.company.trim()) throw new Error('Enter the company name');
      const list = shops.filter((s) => s.name.trim() || s.code.trim());
      if (!list.length) throw new Error('Add at least one shop');
      await invoke('setup', { username: f.username.trim().toLowerCase(), name: f.name, password: f.password, rate: Number(f.rate), vat: Number(f.vat),
        company: { name: f.company, address: f.address, phone: f.phone, rccm: f.rccm, idnat: f.idnat, nif: f.nif, email: '', footer: 'Merci pour votre achat !' }, shops: list });
      const { data, error } = await supabase.auth.signInWithPassword({ email: emailFor(f.username), password: f.password });
      if (error) throw new Error(error.message);
      await rememberPassword(data.user.id, f.password);
      await reload();
    });
  };
  const fld = (k: keyof typeof f, l: string, type = 'text', extra: Record<string, unknown> = {}) => <div className="field"><label>{l}</label><input className="input" type={type} value={f[k]} onChange={set(k)} {...extra} /></div>;
  return (
    <div className="lockwrap"><form className="card" style={{ maxWidth: 760 }} onSubmit={go}>
      <h3><Icon n="shield" /> Set up QuickSales</h3>
      <p>This screen appears once, on a new installation. It creates the Admin login. The Admin then creates every other login.</p>
      <div className="frow">{fld('name', 'Your full name')}{fld('username', 'Admin username', 'text', { autoCapitalize: 'off' })}</div>
      <div className="frow">{fld('password', 'Password (10+ characters, letters and numbers)', 'password', { autoComplete: 'new-password' })}{fld('password2', 'Password again', 'password', { autoComplete: 'new-password' })}</div>
      <h3 style={{ marginTop: 8 }}><Icon n="receipt" /> Company details on invoices</h3>
      <div className="frow">{fld('company', 'Company name')}{fld('phone', 'Phone')}</div>
      <div className="frow">{fld('address', 'Head office address')}{fld('rccm', 'RCCM number')}</div>
      <div className="frow">{fld('idnat', 'ID NAT')}{fld('nif', 'NIF (tax number)')}</div>
      <div className="frow">{fld('rate', 'Sales rate: 1 USD in Congolese Francs', 'number')}{fld('vat', 'VAT (TVA) %', 'number')}</div>
      <h3 style={{ marginTop: 8 }}><Icon n="store" /> Shops</h3>
      {shops.map((s, i) => (
        <div className="frow three" key={i}>
          <div className="field"><label>Shop name</label><input className="input" value={s.name} onChange={(e) => setShops(shops.map((x, k) => (k === i ? { ...x, name: e.target.value } : x)))} /></div>
          <div className="field"><label>3-letter code</label><input className="input" maxLength={3} style={{ textTransform: 'uppercase' }} value={s.code} onChange={(e) => setShops(shops.map((x, k) => (k === i ? { ...x, code: e.target.value.toUpperCase() } : x)))} /></div>
          <div className="field"><label>Address</label><input className="input" value={s.address} onChange={(e) => setShops(shops.map((x, k) => (k === i ? { ...x, address: e.target.value } : x)))} /></div>
        </div>
      ))}
      <button type="button" className="btn ghost" onClick={() => setShops([...shops, { code: '', name: '', address: '' }])}><Icon n="plus" /> Add another shop</button>
      <div className="lerr" style={{ marginTop: 12 }}>{a.err}</div>
      <button className="btn primary xl" disabled={a.busy}><Icon n="check" /> {a.busy ? 'Setting up…' : 'Create Admin and finish setup'}</button>
    </form></div>
  );
}

export function ChangePassword() {
  const { profile, reload, signOut } = useAuth();
  const [p1, setP1] = useState(''), [p2, setP2] = useState('');
  const a = useAction();
  const go = (e: FormEvent) => {
    e.preventDefault();
    void a.run(async () => {
      const pw = pwProblem(p1); if (pw) throw new Error(pw);
      if (p1 !== p2) throw new Error('The two passwords are not the same');
      const { error } = await supabase.auth.updateUser({ password: p1 });
      if (error) throw new Error(/different from the old/i.test(error.message) ? 'Choose a password different from the one the Admin gave you' : error.message);
      await rpc('mark_password_changed');
      await rememberPassword(profile!.id, p1);
      await reload();
    });
  };
  return (
    <div className="lockwrap"><form className="card" onSubmit={go}>
      <h3><Icon n="key" /> Choose your own password</h3>
      <p>Welcome, {profile?.name.split(' ')[0]}. The Admin gave you a first password; choose your own before you start. Only you will know it.</p>
      <div className="field"><label>New password</label><input className="input" type="password" autoComplete="new-password" value={p1} onChange={(e) => setP1(e.target.value)} autoFocus /><span className="hint">At least 10 characters with letters and numbers</span></div>
      <div className="field"><label>New password again</label><input className="input" type="password" autoComplete="new-password" value={p2} onChange={(e) => setP2(e.target.value)} /></div>
      <div className="lerr">{a.err}</div>
      <button className="btn primary xl" disabled={a.busy}><Icon n="check" /> Save password</button>
      <button type="button" className="btn full" style={{ marginTop: 10 }} onClick={() => void signOut()}><Icon n="logout" /> Sign out</button>
    </form></div>
  );
}

export function Lock() {
  const { profile, unlock, signOut } = useAuth();
  const [p, setP] = useState('');
  const a = useAction();
  return (
    <div className="lockwrap"><form className="card" onSubmit={(e) => { e.preventDefault(); void a.run(async () => { await unlock(p); setP(''); }); }}>
      <h3><Icon n="lock" /> Screen locked</h3>
      <p>Locked after 15 minutes without activity. {profile?.name}, enter your password to continue.</p>
      <div className="field"><label>Password</label><input className="input" type="password" autoComplete="current-password" value={p} onChange={(e) => setP(e.target.value)} autoFocus /></div>
      <div className="lerr">{a.err}</div>
      <button className="btn primary xl" disabled={a.busy}><Icon n="unlock" /> Unlock</button>
      <button type="button" className="btn full" style={{ marginTop: 10 }} onClick={() => void signOut()}><Icon n="logout" /> Sign out instead</button>
    </form></div>
  );
}
