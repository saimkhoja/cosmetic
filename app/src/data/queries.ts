// Server reads, cached with TanStack Query. Rows are already filtered by role on the server (RLS).
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase, rows, rpc } from '../lib/supabase';
import type { Category, Cost, Delivery, Grn, Invoice, Ledger, Product, Profile, Rank, SaleOrder, Settings, Shop, ShopReturn, StockRequest, StockRow, Supplier, SupplierReturn, SupplierReturnValue } from '../lib/types';
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
export const useSettings = () => useQuery({ queryKey: ['settings'], queryFn: async () => rows<Settings>(await supabase.from('settings').select('*'))[0] });
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
export const useCategories = () => useQuery({ queryKey: ['categories'], queryFn: async () => rows<Category>(await supabase.from('categories').select('id,name,seasonal,season_months').order('name')) });
/** Units sold per item in the last 30 days (one shop, or all) and whether it is in season: hot items first. */
export const useRanks = (shopId?: string | null) => useQuery({ queryKey: ['ranks', shopId ?? 'all'], staleTime: 300000, queryFn: () => rpc<Rank[]>('item_ranks', { p_shop: shopId ?? null }) });
export const useSuppliers = (enabled = true) => useQuery({ queryKey: ['suppliers'], enabled, queryFn: async () => rows<Supplier>(await supabase.from('suppliers').select('*, supplier_items(product_id)').order('name')) });
export const useGrns = (enabled = true) => useQuery({ queryKey: ['grns'], enabled, queryFn: async () => rows<Grn>(await supabase.from('grns').select('*, grn_items(product_id,qty,std_cost_usd)').order('received_at', { ascending: false }).limit(300)) });
export const useReturns = (enabled = true) => useQuery({ queryKey: ['returns'], enabled, refetchInterval: 30000, queryFn: async () => rows<ShopReturn>(await supabase.from('shop_returns').select('*, return_items(product_id,qty,received_qty)').order('created_at', { ascending: false }).limit(300)) });
/** Returns to suppliers and claims for goods billed but not received (no values: the warehouse sees no costs). */
export const useSupplierReturns = (enabled = true) => useQuery({ queryKey: ['sreturns'], enabled, staleTime: 0, refetchInterval: 30000, queryFn: async () => rows<SupplierReturn>(await supabase.from('supplier_returns')
  .select('id,no,supplier_id,kind,grn_id,reason,note,status,voucher_id,bill_id,created_by_name,created_at,settled_by_name,settled_at,cancel_reason,supplier_return_items(product_id,qty)')
  .order('created_at', { ascending: false }).limit(300)) });
/** Admin only: what each return or claim is worth and what the supplier credits. */
export const useSupplierReturnValues = (enabled = true) => useQuery({ queryKey: ['sreturns', 'values'], enabled, staleTime: 0, refetchInterval: 30000, queryFn: () => rpc<SupplierReturnValue[]>('supplier_return_values') });
/** Ledgers the signed-in user may open, with balances in USD (Dr positive). */
export const useLedgers = (enabled = true) => useQuery({ queryKey: ['ledgers'], enabled, queryFn: () => rpc<Ledger[]>('ledger_list') });
/** Stock requests from the shops: the shop admin sees the shop's, the warehouse and Admin all (RLS). */
export const useStockRequests = () => useQuery({ queryKey: ['requests'], refetchInterval: 30000, queryFn: async () => rows<StockRequest>(await supabase.from('stock_requests').select('*, stock_request_items(product_id,qty,approved_qty)').order('created_at', { ascending: false }).limit(300)) });
/** After a change, refresh everything that may show it. */
export function useRefresh() {
  const qc = useQueryClient();
  return (...keys: string[]) => Promise.all((keys.length ? [...keys, 'ledgers', 'books'] : ['products', 'costs', 'stock', 'deliveries', 'invoices', 'report', 'audit', 'orders', 'ledgers', 'books', 'grns', 'returns', 'ranks', 'requests', 'sreturns']).map((k) => qc.invalidateQueries({ queryKey: [k] })));
}
