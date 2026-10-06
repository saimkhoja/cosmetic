// Browser storage (IndexedDB) for the till: the catalogue snapshot used offline, the till's
// registration and invoice counter, and the outbox of sales not yet sent to the server.
import { openDB, type IDBPDatabase } from 'idb';
import type { Invoice, Product, Settings, Shop } from '../lib/types';

export interface Snapshot { shop: Shop; settings: Settings; products: Product[]; stock: Record<string, { qty: number; open_pieces: number }>; at: number }
export interface Device { id: string; code: string; shop_id: string; shop_code: string; last_seq: number }
export interface SalePayload {
  id: string; no: string; device_id: string; cashier_id: string; t: string; rate: number; vat_rate: number; disc_pct: number; tendered: number;
  customer: string; order_id: string | null;
  items: { product_id: string; mult: number; piece: boolean; qty: number; price: number }[];
}
export interface OrderPayload { id: string; customer: string; t: string; items: { product_id: string; mult: number; piece: boolean; qty: number }[] }
/** A completed sale (shop admin) or an order waiting to reach the shop admin (till operator). */
export type OutboxEntry =
  | { kind?: 'sale'; id: string; t: string; shop_id: string; payload: SalePayload; invoice: Invoice; error?: string; tries: number }
  | { kind: 'order'; id: string; t: string; shop_id: string; payload: OrderPayload; total: number; created_by: string; error?: string; tries: number };

let dbp: Promise<IDBPDatabase> | null = null;
export function db() {
  if (!dbp) dbp = openDB('sim', 1, { upgrade(d) { d.createObjectStore('kv'); d.createObjectStore('outbox', { keyPath: 'id' }); } });
  return dbp;
}
export const kvGet = async <T,>(k: string) => (await (await db()).get('kv', k)) as T | undefined;
export const kvSet = async (k: string, v: unknown) => { await (await db()).put('kv', v, k); };
export const kvDel = async (k: string) => { await (await db()).delete('kv', k); };

export const getSnapshot = (shopId: string) => kvGet<Snapshot>('snap:' + shopId);
export const setSnapshot = (s: Snapshot) => kvSet('snap:' + s.shop.id, s);
export const getDevice = (shopId: string) => kvGet<Device>('device:' + shopId);
export const setDevice = (d: Device) => kvSet('device:' + d.shop_id, d);

/** Next invoice number for this till: SHOP-T1-000123. Never reuses a number, even across restarts. */
export async function nextInvoiceNo(d: Device): Promise<string> {
  const k = 'seq:' + d.id, cur = Math.max((await kvGet<number>(k)) ?? 0, d.last_seq);
  await kvSet(k, cur + 1);
  return `${d.shop_code}-${d.code}-${String(cur + 1).padStart(6, '0')}`;
}

export async function outboxAll(): Promise<OutboxEntry[]> {
  const all = (await (await db()).getAll('outbox')) as OutboxEntry[];
  return all.sort((a, b) => a.t.localeCompare(b.t));
}
export const outboxPut = async (e: OutboxEntry) => { await (await db()).put('outbox', e); notify(); };
export const outboxDel = async (id: string) => { await (await db()).delete('outbox', id); notify(); };
export const notify = () => window.dispatchEvent(new Event('sim-outbox'));
