// A till or back office left open for days never reloads, so it would keep running an old version of the app (and miss
// new things, like the "new stock arrived" notice). The service worker installs a new version as soon as it finds one and
// reloads the page; this asks it to look, but only at safe moments: never while the till screen is open, since a reload
// there would lose the sale being rung up.
let reg: ServiceWorkerRegistration | undefined;
let last = 0;
/** main.tsx hands over the service worker registration once it is known. */
export const setRegistration = (r?: ServiceWorkerRegistration) => { reg = r; };
/** Whether it is safe to look for (and so maybe switch to) a new version now. */
export const safeToUpdate = (path: string) => !path.startsWith('/till');
/** Looks for a new version of the app (at most once a minute) unless the till is open. */
export function checkForUpdate(path = location.pathname) {
  if (!reg || !safeToUpdate(path) || Date.now() - last < 60_000 || (typeof navigator !== 'undefined' && !navigator.onLine)) return;
  last = Date.now();
  void reg.update().catch(() => undefined);
}
/** Every 20 minutes, and whenever the app comes back into view. */
export function watchForUpdates() {
  setInterval(() => checkForUpdate(), 20 * 60_000);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') checkForUpdate(); });
}
