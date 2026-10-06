export type Role = 'admin' | 'whop' | 'shopadmin' | 'till';
export interface Profile { id: string; username: string; name: string; role: Role; shop_id: string | null; active: boolean; must_change_password: boolean; created_at?: string }
export interface Company { name?: string; address?: string; phone?: string; email?: string; rccm?: string; idnat?: string; nif?: string; footer?: string }
export interface Settings { rate: number; vat: number; tz: string; company: Company }
export interface Shop { id: string; code: string; name: string; address: string; active: boolean }
export interface Product {
  id: string; sku: string; name: string; category: string; stock_unit: 'pcs' | 'set'; is_bundle: boolean;
  per_carton: number; pieces_per_set: number; price_usd: number; dozen_usd: number; carton_usd: number; piece_usd: number;
  reorder: number; wh_qty: number; active: boolean;
}
export interface Cost { product_id: string; carton_cost_usd: number; cost_usd: number }
export interface StockRow { shop_id: string; product_id: string; qty: number; open_pieces: number }
export interface InvoiceItem { line_no?: number; product_id: string; name: string; unit: string; mult: number; piece: boolean; qty: number; price: number; line: number }
export interface InvoiceEdit { at: string; by_name: string; reason: string; from_total: number; to_total: number }
export interface Invoice {
  id: string; no: string; shop_id: string; cashier_id?: string; cashier_name: string; t: string; rate: number; vat_rate: number;
  gross: number; disc_pct: number; disc: number; total: number; vat: number; ht: number; tendered: number; change: number;
  printed: number; items: InvoiceItem[]; edits?: InvoiceEdit[]; synced?: boolean;
  customer?: string; prepared_by_name?: string | null; order_id?: string | null;
}
export interface DeliveryItem { product_id: string; qty: number; price_usd: number; received_qty?: number | null }
export interface DeliveryEdit { at: string; by_name: string; reason: string }
export interface Delivery {
  id: string; no: string; shop_id: string; rate: number; created_by_name: string; created_at: string; edited_at: string | null;
  status: 'pending' | 'received' | 'cancelled'; received_at: string | null; received_by_name: string | null; received_note: string | null;
  delivery_items: DeliveryItem[]; delivery_edits: DeliveryEdit[];
}
export interface OrderItem { product_id: string; mult: number; piece: boolean; qty: number }
export interface SaleOrder {
  id: string; shop_id: string; customer: string; items: OrderItem[]; status: 'pending' | 'approved' | 'rejected';
  created_by: string; created_by_name: string; created_at: string; reviewed_by_name: string | null; reviewed_at: string | null; reason: string | null; invoice_id: string | null;
}
