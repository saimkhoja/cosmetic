// getquicksales.com (and www): what QuickSales is, a signup form, and the approval page you open from the email
// sent for each signup (/approve?s=…&t=…). Loaded by main.tsx only on an address that is not a client's; it never
// loads the app or its database connection. See control/README.md for what happens after a signup.
import { useEffect, useRef, useState, type FormEvent } from 'react';
import { QuickSalesLogo } from '../components/Brand';
import { FEATURES } from '../components/Features';
import { ControlError, requestAction, sendSignup, subdomainAvailable, type Availability, type Request_ } from './control';
import { formProblem, subdomainProblem, suggestSubdomain, type SignupFields } from './form';
import { saveLang, startLang, TEXT, type Lang, type Text } from './i18n';
import './landing.css';

const DOMAIN = (import.meta.env.VITE_TENANT_DOMAIN as string | undefined) || 'getquicksales.com';
const WHATSAPP = ((import.meta.env.VITE_CONTACT_WHATSAPP as string | undefined) ?? '').replace(/\D/g, '');
const CONTACT_EMAIL = (import.meta.env.VITE_CONTACT_EMAIL as string | undefined) ?? '';
const waLink = (text: string) => `https://wa.me/${WHATSAPP}?text=${encodeURIComponent(text)}`;

export function Landing() {
  const [lang, setLang] = useState<Lang>(startLang);
  const t = TEXT[lang];
  useEffect(() => { document.documentElement.lang = lang; saveLang(lang); }, [lang]);
  const approving = location.pathname.replace(/\/+$/, '') === '/approve';
  useEffect(() => { document.title = approving ? 'Approve · QuickSales' : 'QuickSales'; }, [approving]);
  return (
    <div className="qsl">
      <header className="lp-nav">
        <a href="/" className="lp-brand" aria-label="QuickSales"><QuickSalesLogo /></a>
        <span className="lp-sp" />
        <div className="lp-lang" role="group" aria-label="Language">
          {(['fr', 'en'] as const).map((l) => <button key={l} aria-pressed={lang === l} className={lang === l ? 'on' : ''} onClick={() => setLang(l)}>{l.toUpperCase()}</button>)}
        </div>
        {!approving && <a className="btn sm lp-hide-s" href="#signin">{t.nav_signin}</a>}
        {!approving && <a className="btn sm primary" href="#signup">{t.nav_signup}</a>}
      </header>
      {approving ? <Approve /> : <Home t={t} lang={lang} />}
      <footer className="lp-foot">© {new Date().getFullYear()} {t.footer}</footer>
    </div>
  );
}

function Home({ t, lang }: { t: Text; lang: Lang }) {
  return (
    <main>
      <section className="lp-hero">
        <div className="lp-hero-text">
          <h1>{t.hero_title_1} <span className="biz">{t.hero_title_2}<svg viewBox="0 0 220 18" preserveAspectRatio="none" aria-hidden="true"><path d="M4 13C60 5 150 3 216 9" fill="none" stroke="#2DD67F" strokeWidth="5" strokeLinecap="round" /></svg></span></h1>
          <p className="lp-lead">{t.hero_lead}</p>
          <div className="lp-ctas">
            <a className="btn primary lp-big" href="#signup">{t.hero_cta}</a>
            {WHATSAPP && <a className="btn lp-big lp-wa" href={waLink(lang === 'fr' ? 'Bonjour, je voudrais des informations sur QuickSales.' : 'Hello, I would like information about QuickSales.')} target="_blank" rel="noopener">{t.hero_whatsapp}</a>}
          </div>
        </div>
        <div className="feats lp-feats">
          {FEATURES.map(([, icon], i) => <div key={i} className="feat"><svg viewBox="0 0 48 48" aria-hidden="true">{icon}</svg><b>{t.features[i].split('\n').map((l, n) => <span key={n}>{n ? <br /> : null}{l}</span>)}</b></div>)}
        </div>
      </section>

      <section className="lp-sec">
        <h2>{t.why_title}</h2>
        <div className="lp-why">{t.why.map(([h, p]) => <div key={h} className="lp-card"><h3>{h}</h3><p>{p}</p></div>)}</div>
      </section>

      <section className="lp-sec">
        <h2>{t.how_title}</h2>
        <ol className="lp-how">{t.how.map(([h, p], i) => <li key={h} className="lp-card"><span className="lp-step">{i + 1}</span><h3>{h}</h3><p>{p}</p></li>)}</ol>
      </section>

      <section className="lp-sec lp-split">
        <Signup t={t} lang={lang} />
        <aside className="lp-side">
          <SignIn t={t} />
          {(WHATSAPP || CONTACT_EMAIL) && (
            <div className="lp-card">
              <h3>{t.contact_title}</h3><p>{t.contact_text}</p>
              <div className="lp-contact">
                {WHATSAPP && <a className="btn lp-wa full" href={waLink('QuickSales')} target="_blank" rel="noopener">WhatsApp +{WHATSAPP}</a>}
                {CONTACT_EMAIL && <a className="btn full" href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>}
              </div>
            </div>
          )}
        </aside>
      </section>
    </main>
  );
}

const EMPTY: SignupFields = { business: '', name: '', phone: '', email: '', subdomain: '', shops: '1', note: '' };

function Signup({ t, lang }: { t: Text; lang: Lang }) {
  const [f, setF] = useState(EMPTY);
  const [subTouched, setSubTouched] = useState(false);
  const [avail, setAvail] = useState<Availability | 'checking' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<{ sub: string; email: string } | null>(null);
  const trap = useRef<HTMLInputElement>(null);

  const set = (k: keyof SignupFields) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) => {
    const v = e.target.value;
    setF((p) => ({ ...p, [k]: v, ...(k === 'business' && !subTouched ? { subdomain: suggestSubdomain(v) } : {}) }));
    setErr(null);
  };
  const setSub = (v: string) => { setSubTouched(true); setF((p) => ({ ...p, subdomain: v.toLowerCase().replace(/[^a-z0-9-]/g, '').slice(0, 40) })); setErr(null); };

  // is the address free? asked a moment after typing stops
  useEffect(() => {
    const s = f.subdomain;
    if (!s) { setAvail(null); return; }
    const local = subdomainProblem(s);
    if (local) { setAvail(local === 'subdomain_reserved' ? 'reserved' : 'invalid'); return; }
    setAvail('checking');
    let live = true;
    const timer = setTimeout(() => { subdomainAvailable(s).then((a) => live && setAvail(a), () => live && setAvail(null)); }, 400);
    return () => { live = false; clearTimeout(timer); };
  }, [f.subdomain]);

  const go = async (e: FormEvent) => {
    e.preventDefault();
    const p = formProblem(f) ?? (avail === 'taken' ? 'subdomain_taken' : null);
    if (p) { setErr(t.err[p]); return; }
    setBusy(true); setErr(null);
    try {
      const r = await sendSignup({ ...f, shops: Number(f.shops), lang, website: trap.current?.value ?? '' });
      setDone({ sub: `${r.subdomain}.${DOMAIN}`, email: f.email.trim() });
    } catch (x) {
      const code = x instanceof ControlError ? x.code : 'server';
      setErr(t.err[code] ?? t.err.server);
      if (code === 'subdomain_taken') setAvail('taken');
    } finally { setBusy(false); }
  };

  if (done) return (
    <div className="lp-card lp-form lp-done" id="signup" role="status">
      <div className="lp-tick" aria-hidden="true">✓</div>
      <h2>{t.done_title}</h2><p>{t.done_text(done.sub, done.email)}</p>
    </div>
  );
  const availText = avail === 'checking' ? t.avail_checking : avail === 'ok' ? t.avail_ok : avail === 'taken' ? t.avail_taken : avail === 'reserved' ? t.avail_reserved : avail === 'invalid' ? t.avail_invalid : '';
  return (
    <form className="lp-card lp-form" id="signup" onSubmit={go} noValidate>
      <h2>{t.form_title}</h2><p className="lp-muted">{t.form_lead}</p>
      <div className="lp-grid">
        <Field id="su-business" label={t.f_business}><input id="su-business" className="input" value={f.business} onChange={set('business')} autoComplete="organization" maxLength={80} required /></Field>
        <Field id="su-name" label={t.f_name}><input id="su-name" className="input" value={f.name} onChange={set('name')} autoComplete="name" maxLength={60} required /></Field>
        <Field id="su-phone" label={t.f_phone}><input id="su-phone" className="input" type="tel" value={f.phone} onChange={set('phone')} autoComplete="tel" placeholder="+243 81 234 5678" maxLength={30} required /></Field>
        <Field id="su-email" label={t.f_email}><input id="su-email" className="input" type="email" value={f.email} onChange={set('email')} autoComplete="email" maxLength={120} required /></Field>
      </div>
      <Field id="su-sub" label={t.f_subdomain}>
        <div className="lp-sub">
          <input id="su-sub" className="input" placeholder={t.sub_ph} value={f.subdomain} onChange={(e) => setSub(e.target.value)} autoCapitalize="off" spellCheck={false} aria-describedby="su-avail" required />
          <span className="lp-domain">.{DOMAIN}</span>
        </div>
        <span id="su-avail" className={`lp-avail ${avail ?? ''}`} aria-live="polite">{availText}</span>
      </Field>
      <div className="lp-grid">
        <Field id="su-shops" label={t.f_shops}><input id="su-shops" className="input" type="number" inputMode="numeric" min={1} max={50} value={f.shops} onChange={set('shops')} /></Field>
      </div>
      <Field id="su-note" label={t.f_note}><textarea id="su-note" className="input lp-ta" value={f.note} onChange={set('note')} placeholder={t.f_note_ph} maxLength={500} rows={3} /></Field>
      {/* only robots fill this in */}
      <input ref={trap} name="website" tabIndex={-1} autoComplete="off" className="lp-trap" aria-hidden="true" />
      {err && <div className="lp-err" role="alert">{err}</div>}
      <button className="btn primary xl" disabled={busy}>{busy ? t.f_sending : t.f_submit}</button>
    </form>
  );
}

function Field({ id, label, children }: { id: string; label: string; children: React.ReactNode }) {
  return <div className="field"><label htmlFor={id}>{label}</label>{children}</div>;
}

function SignIn({ t }: { t: Text }) {
  const [s, setS] = useState('');
  const go = (e: FormEvent) => { e.preventDefault(); const v = s.trim().toLowerCase().replace(/\..*$/, ''); if (!subdomainProblem(v)) location.href = `https://${v}.${DOMAIN}`; };
  return (
    <form className="lp-card" id="signin" onSubmit={go}>
      <h3>{t.signin_title}</h3><p>{t.signin_text}</p>
      <div className="lp-sub"><input className="input" aria-label={t.signin_title} placeholder={t.sub_ph} value={s} onChange={(e) => setS(e.target.value)} autoCapitalize="off" spellCheck={false} /><span className="lp-domain">.{DOMAIN}</span></div>
      <button className="btn full lp-mt" disabled={!!subdomainProblem(s.trim().toLowerCase())}>{t.signin_go}</button>
    </form>
  );
}

// ---- the approval page (for you; in English) ----
function Approve() {
  const q = new URLSearchParams(location.search);
  const s = q.get('s') ?? '', tok = q.get('t') ?? '';
  const [r, setR] = useState<Request_ | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState<'' | 'approve' | 'reject'>('');
  const [sure, setSure] = useState(false);

  const load = () => requestAction(s, tok, 'info').then(setR, (e) => setErr(msg(e)));
  useEffect(() => { void load(); }, []);   // eslint-disable-line react-hooks/exhaustive-deps
  // while it is being set up, look again every 15 s
  useEffect(() => { if (r?.status !== 'provisioning') return; const i = setInterval(load, 15000); return () => clearInterval(i); }, [r?.status]);   // eslint-disable-line react-hooks/exhaustive-deps

  const act = async (a: 'approve' | 'reject') => {
    setBusy(a); setErr(null);
    try { const after = await requestAction(s, tok, a); setR(a === 'reject' ? { ...r!, status: 'rejected' } : after); }
    catch (e) { setErr(msg(e)); void load(); }
    finally { setBusy(''); setSure(false); }
  };

  if (!r) return <main className="lp-sec lp-narrow"><div className="lp-card">{err ? <div className="lp-err" role="alert">{err}</div> : <p>Loading…</p>}</div></main>;
  const link = `https://${r.subdomain}.${DOMAIN}`;
  const row = (k: string, v: React.ReactNode) => <tr><th>{k}</th><td>{v}</td></tr>;
  return (
    <main className="lp-sec lp-narrow">
      <div className="lp-card lp-approve">
        <div className={`lp-status ${r.status}`}>{STATUS[r.status]}</div>
        <h2>{r.business}</h2>
        <table className="lp-table"><tbody>
          {row('Address', <b>{r.subdomain}.{DOMAIN}</b>)}
          {row('Name', r.name)}
          {row('Phone', <a href={`tel:${r.phone.replace(/[^+\d]/g, '')}`}>{r.phone}</a>)}
          {row('Email', <a href={`mailto:${r.email}`}>{r.email}</a>)}
          {row('Shops', r.shops)}
          {row('Language', r.lang === 'en' ? 'English' : 'French')}
          {row('Asked', new Date(r.created_at).toLocaleString())}
          {r.note && row('Message', r.note)}
        </tbody></table>
        {r.status === 'failed' && r.error && <div className="lp-err">Setup stopped: {r.error}</div>}
        {err && <div className="lp-err" role="alert">{err}</div>}
        {r.status === 'pending' && <>
          <p className="lp-muted">Approving creates their own Supabase project (about $10/month) and emails them the link when it is ready, in about 5 minutes.</p>
          <div className="lp-actions">
            <button className="btn go" disabled={!!busy} onClick={() => act('approve')}>{busy === 'approve' ? 'Starting…' : 'Approve'}</button>
            {!sure ? <button className="btn" disabled={!!busy} onClick={() => setSure(true)}>Reject…</button>
              : <button className="btn danger" disabled={!!busy} onClick={() => act('reject')}>{busy === 'reject' ? 'Rejecting…' : 'Yes, delete this request'}</button>}
          </div>
        </>}
        {r.status === 'failed' && <div className="lp-actions"><button className="btn go" disabled={!!busy} onClick={() => act('approve')}>{busy === 'approve' ? 'Starting…' : 'Try again'}</button></div>}
        {r.status === 'provisioning' && <p className="lp-muted">Being set up. This page updates by itself; you also get an email when it is done or if it stops.</p>}
        {(r.status === 'active' || r.status === 'suspended') && <p>Live at <a href={link}>{link}</a>. They have been emailed the link.</p>}
        {r.status === 'rejected' && <p className="lp-muted">Rejected and deleted. The name is free again.</p>}
      </div>
    </main>
  );
}
const STATUS: Record<Request_['status'], string> = { pending: 'Waiting for your approval', provisioning: 'Being set up…', active: 'Live', suspended: 'Switched off', failed: 'Setup failed', rejected: 'Rejected' };
const APPROVE_ERR: Record<string, string> = {
  bad_link: 'This link is not valid (or the request was made again since). Use the link from the latest email.',
  not_found: 'This request no longer exists (rejected).',
  already_provisioning: 'Already being set up.', already_active: 'Already live.', already_suspended: 'Already a client.',
  network: 'No connection. Try again.', server: 'Something went wrong. Try again.',
};
function msg(e: unknown) {
  if (e instanceof ControlError) return e.code === 'workflow' ? `GitHub did not start the setup: ${e.message}` : APPROVE_ERR[e.code] ?? `${e.code}: ${e.message}`;
  return 'Something went wrong. Try again.';
}
