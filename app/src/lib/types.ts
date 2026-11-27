export type Role = 'admin' | 'whop' | 'shopadmin' | 'till';
export interface Profile { id: string; username: string; name: string; role: Role; shop_id: string | null; active: boolean; must_change_password: boolean; created_at?: string }
export interface Company { name?: string; address?: string; phone?: string; email?: string; rccm?: string; idnat?: string; nif?: string; footer?: string }
/** Switches the Admin turns on in Settings; both off by default. */
export interface Features { customer_optional?: boolean; barcode?: boolean; till_sells?: boolean; cash_change?: boolean; usd_pay?: boolean; one_copy?: boolean;
  /** the business has no central store: goods from a supplier go straight into a shop */
  no_warehouse?: boolean;
  /** the shop admin keeps vendeurs: goods on credit, their payments, promo items and the monthly promo report */
  vendeurs?: boolean;
  /** the shop admin gives promo items free with cash sales (not invoiced); they add up in the monthly promo report */
  cash_promo?: boolean;
  /** the shop admin changes money at the counter: buys and sells dollars at the rates set in Settings */
  money_exchange?: boolean }
/** rate: the sales rate (prices, tickets, tills). book_rate: the internal rate (suppliers, expenses, vouchers). */
export interface Settings {
  rate: number; book_rate?: number; vat: number; tz: string; company: Company; features?: Features;
  /** money exchange at the counter: the shop buys dollars at fx_buy_rate and sells them at fx_sell_rate (1 USD in CDF) */
  fx_buy_rate?: number | null; fx_sell_rate?: number | null;
  /** sales worth more than this (USD, at the rate of the sale) are not shown to the Shop Admin; empty = no limit */
  shop_sales_limit_usd?: number | null;
}
export interface Shop { id: string; code: string; name: string; address: string; active: boolean }
export interface Product {
  id: string; sku: string; name: string; category: string; stock_unit: 'pcs' | 'set'; is_bundle: boolean;
  per_carton: number; pieces_per_set: number; price_usd: number; half_dozen_usd: number; dozen_usd: number; carton_usd: number; piece_usd: number;
  reorder: number; wh_qty: number; active: boolean; archived_at?: string | null; barcode?: string | null; barcodes?: string[] | null;
}
/** An item's cost (Admin only). carton_cost_usd is the gross cost of one carton (or set); net_cost_usd the optional
 *  net cost of one carton (or set), empty when the gross cost counts; cost_usd the cost that counts, per pc (or set). */
export interface Cost { product_id: string; carton_cost_usd: number; net_cost_usd?: number | null; cost_usd: number }
export interface StockRow { shop_id: string; product_id: string; qty: number; open_pieces: number }
export interface InvoiceItem { line_no?: number; product_id: string; name: string; unit: string; mult: number; piece: boolean; qty: number; price: number; line: number }
export interface InvoiceEdit { at: string; by_name: string; reason: string; from_total: number; to_total: number }
export interface Invoice {
  id: string; no: string; shop_id: string; cashier_id?: string; cashier_name: string; t: string; rate: number; vat_rate: number;
  gross: number; disc_pct: number; disc: number; total: number; vat: number; ht: number; tendered: number; change: number;
  /** copies printed when it was made (1 or 2, the Settings switch); printed above it are duplicates */
  copies?: number;
  printed: number; till_printed_at?: string | null; items: InvoiceItem[]; edits?: InvoiceEdit[]; synced?: boolean;
  customer?: string; prepared_by_name?: string | null; order_id?: string | null;
  paid_usd?: number; paid_cdf?: number; change_usd?: number; change_cdf?: number;
  /** the rate the dollars on this invoice were taken at (the internal rate); empty on sales made before it was kept */
  usd_rate?: number | null;
  /** the total the till operator printed, when the shop admin changed the order before approving it */
  revised_from?: number | null;
  /** goods on credit: the vendeur who owes the invoice, and when it falls due */
  vendeur_id?: string | null; due_date?: string | null;
}
/** What a vendeur owes, from the server: payments settle the oldest goods first. Amounts in CDF. */
export interface VendeurOpen { invoice_id: string | null; no: string; date: string; due: string; amount: number; owed: number; days_overdue: number }
/** What a vendeur owes, in USD: balance, credit limit and credit left, overdue; balance_cdf is the balance at today's sales rate. */
export interface VendeurState {
  balance: number; balance_cdf?: number; credit_limit_usd: number; available: number; over_limit: boolean; overdue: boolean; overdue_amount: number; oldest_due: string | null; days_overdue: number;
  open: VendeurOpen[]; last_payment: { no: string; at: string; amount: number; amount_cdf?: number } | null; promo_open: number; promo_open_n: number;
}
export interface Vendeur extends VendeurState {
  id: string; shop_id: string; shop_name: string; name: string; phone: string; address: string; notes: string;
  credit_days: number; credit_limit: number; opening_balance: number; active: boolean;
  /** what was owed from before, as entered: dollars at opening_rate and Francs (opening_balance is the total in CDF) */
  opening_usd?: number; opening_cdf?: number; opening_rate?: number | null; opening_value_usd?: number; created_at: string; created_by_name: string;
}
export interface PromoLine { name: string; unit: string; qty: number; value?: number; line?: number }
/** The promo items of a shop still open at the end of a month: each item and how many were given out, all vendeurs
 *  together (no vendeur names). qty is in the item's stock unit (pcs, or sets); carried, from earlier months. */
export interface PromoData {
  month: string; n: number; value: number; pcs: number; carried_pcs: number;
  /** pieces given with cash sales and with goods on credit (reports made before the split have neither) */
  cash_pcs?: number; credit_pcs?: number;
  items: { name: string; unit: string; qty: number; carried: number; cash_qty?: number; credit_qty?: number }[];
  /** the promos given with cash sales, one by one */
  cash_promos?: { id: string; no: string; date: string; invoice: string | null; value: number; by_name: string; items: { name: string; unit: string; qty: number }[] | null }[];
}
export interface PromoReport extends PromoData {
  shop_id: string; shop_name: string; oldest_open: string | null;
  reports: { id: string; month: string; status: 'kept' | 'settled'; n: number; total: number; by_name: string; at: string; data: PromoData }[];
}
/** What vendeur_pay answers: amount is what came off the debt, in CDF; the rest says how it was paid. */
export interface VendeurPaid { id: string; no: string; amount: number; amount_cdf?: number; at: string; by_name: string; vendeur: string; before: number; state: VendeurState;
  paid_usd: number; paid_cdf: number; usd_rate: number | null; change_cdf: number }
export interface VendeurStatement {
  vendeur: Omit<Vendeur, keyof VendeurState>; from: string; to: string; brought_forward: number; total_dr: number; total_cr: number; closing: number;
  /** dr and cr in USD; cdf what the line was in Francs (goods at their sale's rate) */
  lines: { date: string; no: string; what: string; dr: number; cr: number; cdf?: number | null; rate?: number | null; due: string | null; invoice_id: string | null }[];
  promos: { id: string; no: string; date: string; value: number; status: 'open' | 'settled'; note: string; invoice: string | null; items: { name: string; unit: string; qty: number; line: number }[] }[];
  payments: { id: string; no: string; at: string; amount: number; amount_cdf?: number; note: string; status: 'ok' | 'cancelled'; by_name: string; cancel_reason: string | null;
    paid_usd?: number; paid_cdf?: number; usd_rate?: number | null; change_cdf?: number }[];
  state: VendeurState;
}
export interface DeliveryItem { product_id: string; qty: number; price_usd: number; received_qty?: number | null }
export interface DeliveryEdit { at: string; by_name: string; reason: string }
export interface Delivery {
  id: string; no: string; shop_id: string; rate: number; created_by_name: string; created_at: string; edited_at: string | null;
  status: 'pending' | 'received' | 'cancelled'; received_at: string | null; received_by_name: string | null; received_note: string | null;
  delivery_items: DeliveryItem[]; delivery_edits: DeliveryEdit[];
}
export interface OrderItem { product_id: string; mult: number; piece: boolean; qty: number; price?: number; unit?: string }
export interface SaleOrder {
  id: string; shop_id: string; customer: string; items: OrderItem[]; status: 'pending' | 'approved' | 'rejected';
  created_by: string; created_by_name: string; created_at: string; reviewed_by_name: string | null; reviewed_at: string | null; reason: string | null; invoice_id: string | null;
  /** the invoice the till operator printed when sending it (orders from tills with the old app have none) */
  invoice_no?: string | null; device_id?: string | null; rate?: number | null; vat_rate?: number | null; total?: number | null;
  /** the discount (CDF) the till operator gave on that invoice, with the Discount passcode */
  disc?: number | null;
}
export interface Category { id: string; name: string; seasonal: boolean; season_months: number[] }
export interface Rank { product_id: string; sold_30: number; in_season: boolean }
export interface Supplier {
  id: string; name: string; contact: string; phone: string; email: string; address: string; tax_no: string; credit_days: number; credit_limit: number;
  currency: 'USD' | 'FC'; notes: string; active: boolean; account_id: string; supplier_items?: { product_id: string }[];
}
export interface Grn { id: string; no: string; supplier_id: string; shop_id?: string | null; ref: string; note: string; status: 'awaiting_bill' | 'billed' | 'cancelled'; bill_voucher_id: string | null; received_by_name: string; received_at: string;
  cancel_reason?: string | null; cancelled_by_name?: string | null; edited_by_name?: string | null; edited_at?: string | null; grn_items: { product_id: string; qty: number; std_cost_usd?: number }[] }
/** Goods sent back to a supplier, or billed but not received. Values come separately, for the Admin only. */
export interface SupplierReturn {
  id: string; no: string; supplier_id: string; kind: 'return' | 'short'; grn_id: string | null; reason: string; note: string; status: 'open' | 'settled' | 'cancelled';
  voucher_id: string | null; bill_id: string | null; created_by_name: string; created_at: string; settled_by_name: string | null; settled_at: string | null; cancel_reason: string | null;
  supplier_return_items: { product_id: string; qty: number }[];
  /** made by the Admin from a shop's return (no central store); cancelling it puts the goods back in that shop */
  from_return_id?: string | null;
}
export interface SupplierReturnValue { id: string; value_usd: number; amount_usd: number; bill_no: string | null }
export interface ShopReturn {
  id: string; no: string; shop_id: string; reason: string; status: 'pending' | 'received' | 'cancelled'; created_by_name: string; created_at: string;
  received_by_name: string | null; received_at: string | null; received_note: string | null; return_items: { product_id: string; qty: number; received_qty: number | null }[];
  /** what became of it: received into the central store, or (no central store) the Admin's decision */
  outcome?: 'store' | 'supplier' | 'shop' | 'writeoff' | null; to_shop_id?: string | null; supplier_return_id?: string | null;
}
/** Stock added straight into a shop (no central store): the Shop Admin is told what came in. */
export interface StockArrival {
  id: string; shop_id: string; kind: 'stock_in' | 'goods_in'; what: string; note: string; by_name: string; at: string; seen_at: string | null; seen_by_name: string | null;
  stock_arrival_items: { product_id: string; qty: number }[];
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
