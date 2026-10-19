export type Role = 'admin' | 'whop' | 'shopadmin' | 'till';
export interface Profile { id: string; username: string; name: string; role: Role; shop_id: string | null; active: boolean; must_change_password: boolean; created_at?: string }
export interface Company { name?: string; address?: string; phone?: string; email?: string; rccm?: string; idnat?: string; nif?: string; footer?: string }
/** Switches the Admin turns on in Settings; both off by default. */
export interface Features { customer_optional?: boolean; barcode?: boolean; till_sells?: boolean }
export interface Settings { rate: number; vat: number; tz: string; company: Company; features?: Features }
export interface Shop { id: string; code: string; name: string; address: string; active: boolean }
export interface Product {
  id: string; sku: string; name: string; category: string; stock_unit: 'pcs' | 'set'; is_bundle: boolean;
  per_carton: number; pieces_per_set: number; price_usd: number; half_dozen_usd: number; dozen_usd: number; carton_usd: number; piece_usd: number;
  reorder: number; wh_qty: number; active: boolean; archived_at?: string | null; barcode?: string | null;
}
export interface Cost { product_id: string; carton_cost_usd: number; cost_usd: number }
export interface StockRow { shop_id: string; product_id: string; qty: number; open_pieces: number }
export interface InvoiceItem { line_no?: number; product_id: string; name: string; unit: string; mult: number; piece: boolean; qty: number; price: number; line: number }
export interface InvoiceEdit { at: string; by_name: string; reason: string; from_total: number; to_total: number }
export interface Invoice {
  id: string; no: string; shop_id: string; cashier_id?: string; cashier_name: string; t: string; rate: number; vat_rate: number;
  gross: number; disc_pct: number; disc: number; total: number; vat: number; ht: number; tendered: number; change: number;
  printed: number; till_printed_at?: string | null; items: InvoiceItem[]; edits?: InvoiceEdit[]; synced?: boolean;
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
export interface Category { id: string; name: string; seasonal: boolean; season_months: number[] }
export interface Rank { product_id: string; sold_30: number; in_season: boolean }
export interface Supplier {
  id: string; name: string; contact: string; phone: string; email: string; address: string; tax_no: string; credit_days: number; credit_limit: number;
  currency: 'USD' | 'FC'; notes: string; active: boolean; account_id: string; supplier_items?: { product_id: string }[];
}
export interface Grn { id: string; no: string; supplier_id: string; ref: string; note: string; status: 'awaiting_bill' | 'billed'; bill_voucher_id: string | null; received_by_name: string; received_at: string; grn_items: { product_id: string; qty: number; std_cost_usd?: number }[] }
export interface ShopReturn {
  id: string; no: string; shop_id: string; reason: string; status: 'pending' | 'received' | 'cancelled'; created_by_name: string; created_at: string;
  received_by_name: string | null; received_at: string | null; received_note: string | null; return_items: { product_id: string; qty: number; received_qty: number | null }[];
}
export type Cur = 'USD' | 'FC';
export interface Ledger {
  id: string; code: string | null; name: string; group_code: string; group_name: string; nature: 'asset' | 'liability' | 'equity' | 'income' | 'expense'; sort: number;
  currency: Cur; system: boolean; active: boolean; supplier_id: string | null; shop_id: string | null;
  opening_amount: number; opening_side: 'Dr' | 'Cr'; opening_currency: Cur; opening_rate: number | null; balance: number;
}
export interface AccountGroup { code: string; name: string; nature: Ledger['nature']; parent: string | null; sort: number }
export interface StatementLine { id: number; date: string; no: string; type: string; narration: string; memo: string; side: 'Dr' | 'Cr'; amount: number; currency: Cur; rate: number; base: number; bill_ref: string | null; due_date: string | null }
export interface Statement {
  account: { id: string; name: string; group: string; currency: Cur; opening_amount: number; opening_side: 'Dr' | 'Cr'; opening_currency: Cur };
  from: string; to: string; with_opening: boolean; brought_forward: number; lines: StatementLine[]; total_dr: number; total_cr: number; closing: number;
}
export interface DayBookEntry { id: string; no: string; type: string; date: string; narration: string; ref: string; status: 'posted' | 'cancelled'; cancel_reason: string | null; created_by_name: string; source_type: string | null;
  lines: { account: string; side: 'Dr' | 'Cr'; amount: number; currency: Cur; rate: number; base: number; memo: string }[] }
export interface PayableBill { id: string; no: string; date: string; bill_ref: string; due_date: string; amount: number; original: number; currency: Cur; outstanding: number; days_overdue: number }
export interface Payable { id: string; name: string; credit_days: number; phone: string; balance: number; bills: PayableBill[] }
export interface StockRequest {
  id: string; no: string; shop_id: string; note: string; status: 'pending' | 'approved' | 'rejected' | 'cancelled';
  created_by_name: string; created_at: string; reviewed_by_name: string | null; reviewed_at: string | null; reason: string | null; delivery_id: string | null;
  stock_request_items: { product_id: string; qty: number; approved_qty: number | null }[];
}
