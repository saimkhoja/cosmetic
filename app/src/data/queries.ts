// Server reads, cached with TanStack Query. Rows are already filtered by role on the server (RLS).
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase, rows, rpc } from '../lib/supabase';
import type { Cost, Delivery, Invoice, Product, Profile, SaleOrder, Settings, Shop, StockRow } from '../lib/types';
import type { Report } from '../lib/print';

/** Reads every row of a query, 1000 at a time (Supabase returns at most 1000 per request). */
async function all<T>(make: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += 1000) {
    const page = rows(await make(from, from + 999));
    out.push(...page);
    if (page.length < 1000) return out;
  }
}
export const useSettings = () => useQuery({ queryKey: ['settings'], queryFn: async () => rows<Settings>(await supabase.from('settings').select('rate,vat,tz,company'))[0] });
export const useShops = () => useQuery({ queryKey: ['shops'], queryFn: async () => rows<Shop>(await supabase.from('shops').select('*').order('name')) });
export const useProducts = () => useQuery({ queryKey: ['products'], queryFn: () => all<Product>((a, b) => supabase.from('products').select('*').order('name').range(a, b)) });
export const useCosts = (enabled: boolean) => useQuery({ queryKey: ['costs'], enabled, queryFn: () => all<Cost>((a, b) => supabase.from('product_costs').select('*').range(a, b)) });
export const useStock = (shopId?: string | null) => useQuery({
  queryKey: ['stock', shopId ?? 'all'],
  queryFn: () => all<StockRow>((a, b) => { let q = supabase.from('shop_stock').select('*'); if (shopId) q = q.eq('shop_id', shopId); return q.range(a, b); }),
});
export const useDeliveries = (shopId?: string | null, enabled = true) => useQuery({
  queryKey: ['deliveries', shopId ?? 'all'], enabled, refetchInterval: 30000,
  queryFn: async () => { let q = supabase.from('deliveries').select('*, delivery_items(product_id,qty,price_usd,received_qty), delivery_edits(at,by_name,reason)').order('created_at', { ascending: false }).limit(400); if (shopId) q = q.eq('shop_id', shopId); return rows<Delivery>(await q); },
});
export const useInvoices = (shopId: string, sinceISO: string | null) => useQuery({
  queryKey: ['invoices', shopId, sinceISO],
  queryFn: async () => {
    let q = supabase.from('invoices').select('*, items:invoice_items(line_no,product_id,name,unit,mult,piece,qty,price,line), edits:invoice_edits(at,by_name,reason,from_total,to_total)').eq('shop_id', shopId).order('t', { ascending: false }).limit(500);
    if (sinceISO) q = q.gte('t', sinceISO);
    const list = rows<Invoice>(await q);
    list.forEach((i) => { i.items.sort((a, b) => (a.line_no ?? 0) - (b.line_no ?? 0)); i.edits?.sort((a, b) => a.at.localeCompare(b.at)); i.synced = true; });
    return list;
  },
});
export const useUsers = (enabled: boolean) => useQuery({ queryKey: ['users'], enabled, queryFn: async () => rows<Profile>(await supabase.from('profiles').select('*').order('created_at')) });
export const useAudit = () => useQuery({ queryKey: ['audit'], queryFn: async () => rows<{ id: number; at: string; username: string; action: string }>(await supabase.from('audit_log').select('*').order('id', { ascending: false }).limit(300)) });
export const useUpkeep = () => useQuery({ queryKey: ['upkeep'], queryFn: async () => rows<{ id: string; date: string; category: string; description: string; amount_usd: number; by_name: string; at: string }>(await supabase.from('upkeep').select('*').order('date', { ascending: false }).order('at', { ascending: false }).limit(500)) });
export const useReport = (from: string, to: string, shop: string | null, enabled = true) => useQuery({
  queryKey: ['report', from, to, shop], enabled, queryFn: () => rpc<Report>('sales_report', { p_from: from, p_to: to, p_shop: shop }),
});
/** Orders sent by till operators: the shop admin sees the shop's, a till operator only their own (RLS). */
export const useOrders = (status: 'pending' | 'all', sinceISO?: string) => useQuery({
  queryKey: ['orders', status, sinceISO ?? ''], refetchInterval: 15000,
  queryFn: async () => { let q = supabase.from('sale_orders').select('*').order('created_at', { ascending: status === 'pending' }).limit(200); if (status === 'pending') q = q.eq('status', 'pending'); if (sinceISO) q = q.gte('created_at', sinceISO); return rows<SaleOrder>(await q); },
});
/** After a change, refresh everything that may show it. */
export function useRefresh() {
  const qc = useQueryClient();
  return (...keys: string[]) => Promise.all((keys.length ? keys : ['products', 'costs', 'stock', 'deliveries', 'invoices', 'report', 'audit', 'orders']).map((k) => qc.invalidateQueries({ queryKey: [k] })));
}
