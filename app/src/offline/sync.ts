// Sends queued sales to the server, oldest first. A network failure stops the round and it is
// tried again later; a sale the server refuses is kept with the reason so the shop admin sees it.
import { rpc } from '../lib/supabase';
import { outboxAll, outboxDel, outboxPut } from './store';

let running = false;
export const isNetworkError = (e: unknown) => /Failed to fetch|NetworkError|Load failed|No connection|fetch failed|ERR_/i.test(String((e as Error)?.message ?? e));

export async function syncOutbox(): Promise<{ sent: number; failed: number; waiting: number }> {
  if (running) return { sent: 0, failed: 0, waiting: (await outboxAll()).length };
  running = true;
  let sent = 0, failed = 0;
  try {
    for (const e of await outboxAll()) {
      if (!navigator.onLine) break;
      try {
        await rpc('submit_invoice', { p: e.payload });
        await outboxDel(e.id); sent++;
      } catch (err) {
        if (isNetworkError(err)) break;
        await outboxPut({ ...e, error: (err as Error).message, tries: e.tries + 1 }); failed++;
      }
    }
  } finally { running = false; }
  return { sent, failed, waiting: (await outboxAll()).length };
}

let timer: number | undefined;
export function startSync() {
  if (timer) return;
  const go = () => { void syncOutbox(); };
  window.addEventListener('online', go);
  timer = window.setInterval(go, 20000);
  go();
}
