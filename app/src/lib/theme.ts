// Light or dark screens. "auto" follows the device setting; the choice is kept on this device.
export type ThemePref = 'auto' | 'light' | 'dark';
const KEY = 'sim.theme';

export function getTheme(): ThemePref {
  try { const v = localStorage.getItem(KEY); return v === 'light' || v === 'dark' ? v : 'auto'; } catch { return 'auto'; }
}
export function applyTheme(t: ThemePref) {
  const el = document.documentElement;
  if (t === 'auto') delete el.dataset.theme; else el.dataset.theme = t;
  const dark = t === 'dark' || (t === 'auto' && matchMedia('(prefers-color-scheme: dark)').matches);
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', dark ? '#0B2468' : '#06328F');
}
export function setTheme(t: ThemePref) {
  try { if (t === 'auto') localStorage.removeItem(KEY); else localStorage.setItem(KEY, t); } catch { /* not saved */ }
  applyTheme(t);
}
export const nextTheme = (t: ThemePref): ThemePref => (t === 'auto' ? 'light' : t === 'light' ? 'dark' : 'auto');
export const THEME_LABEL: Record<ThemePref, string> = { auto: 'Auto (follows this device)', light: 'Light', dark: 'Dark' };
export const THEME_ICON: Record<ThemePref, string> = { auto: 'contrast', light: 'sun', dark: 'moon' };
