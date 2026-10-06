import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { configured, emailFor, rpc, supabase } from '../lib/supabase';
import type { Profile } from '../lib/types';
import { checkPasswordOffline, rememberPassword } from '../offline/pwcache';
import { isNetworkError } from '../offline/sync';

type Status = 'loading' | 'unconfigured' | 'setup' | 'signedout' | 'ready';
interface Auth {
  status: Status; profile: Profile | null; offline: boolean; locked: boolean;
  signIn: (username: string, password: string) => Promise<void>;
  signOut: () => Promise<void>; unlock: (password: string) => Promise<void>; reload: () => Promise<void>;
}
const Ctx = createContext<Auth>(null as never);
export const useAuth = () => useContext(Ctx);
const IDLE_MS = 15 * 60 * 1000, CACHE = 'sim.profile';

function friendly(m: string) {
  if (/invalid login credentials/i.test(m)) return 'Username or password is wrong';
  if (/banned/i.test(m)) return 'This account is disabled. Contact the Admin.';
  if (/rate limit|too many/i.test(m)) return 'Too many attempts. Wait a few minutes and try again.';
  if (isNetworkError(m)) return 'No connection to the server. Signing in needs the internet the first time.';
  return m;
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<Status>('loading');
  const [profile, setProfile] = useState<Profile | null>(null);
  const [offline, setOffline] = useState(false);
  const [locked, setLocked] = useState(false);
  const last = useRef(Date.now());

  const loadProfile = useCallback(async (uid: string) => {
    const { data, error } = await supabase.from('profiles').select('*').eq('id', uid).maybeSingle();
    if (error) throw new Error(error.message);
    if (!data || !data.active) { await supabase.auth.signOut(); localStorage.removeItem(CACHE); return null; }
    localStorage.setItem(CACHE, JSON.stringify(data));
    return data as Profile;
  }, []);

  const reload = useCallback(async () => {
    if (!configured) { setStatus('unconfigured'); return; }
    try {
      if (await rpc<boolean>('setup_needed')) { setStatus('setup'); return; }
    } catch { /* offline: carry on with the saved session */ }
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) { setProfile(null); setStatus('signedout'); return; }
    try {
      const p = await loadProfile(session.user.id);
      setOffline(false); setProfile(p); setStatus(p ? 'ready' : 'signedout');
    } catch (e) {
      const cached = JSON.parse(localStorage.getItem(CACHE) || 'null') as Profile | null;
      if (isNetworkError(e) && cached && cached.id === session.user.id) { setOffline(true); setProfile(cached); setStatus('ready'); }
      else { setProfile(null); setStatus('signedout'); }
    }
  }, [loadProfile]);

  useEffect(() => {
    void reload();
    const { data: sub } = supabase.auth.onAuthStateChange((ev) => { if (ev === 'SIGNED_OUT') { setProfile(null); setStatus((s) => (s === 'setup' ? s : 'signedout')); } });
    const on = () => { setOffline(false); void reload(); }, off = () => setOffline(true);
    addEventListener('online', on); addEventListener('offline', off);
    return () => { sub.subscription.unsubscribe(); removeEventListener('online', on); removeEventListener('offline', off); };
  }, [reload]);

  // 15 minutes without activity locks the screen
  useEffect(() => {
    const act = () => { last.current = Date.now(); };
    ['click', 'keydown', 'touchstart'].forEach((e) => addEventListener(e, act, { passive: true }));
    const t = setInterval(() => { if (profile && Date.now() - last.current > IDLE_MS) setLocked(true); }, 20000);
    return () => { clearInterval(t); ['click', 'keydown', 'touchstart'].forEach((e) => removeEventListener(e, act)); };
  }, [profile]);

  const signIn = async (username: string, password: string) => {
    const { data, error } = await supabase.auth.signInWithPassword({ email: emailFor(username), password });
    if (error || !data.user) throw new Error(friendly(error?.message ?? 'Sign-in failed'));
    const p = await loadProfile(data.user.id);
    if (!p) throw new Error('This login has no SIM account or is disabled. Contact the Admin.');
    await rememberPassword(p.id, password);
    last.current = Date.now(); setLocked(false); setOffline(false); setProfile(p); setStatus('ready');
  };
  const signOut = async () => {
    await supabase.auth.signOut({ scope: 'local' });
    localStorage.removeItem(CACHE); setProfile(null); setLocked(false); setStatus('signedout');
  };
  const unlock = async (password: string) => {
    if (!profile) return;
    if (navigator.onLine) {
      const { error } = await supabase.auth.signInWithPassword({ email: emailFor(profile.username), password });
      if (error && !isNetworkError(error.message)) throw new Error(friendly(error.message));
      if (error && !(await checkPasswordOffline(profile.id, password))) throw new Error('Password is wrong');
    } else if (!(await checkPasswordOffline(profile.id, password))) throw new Error('Password is wrong');
    last.current = Date.now(); setLocked(false);
  };

  return <Ctx.Provider value={{ status, profile, offline, locked, signIn, signOut, unlock, reload }}>{children}</Ctx.Provider>;
}
