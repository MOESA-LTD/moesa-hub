import { queryKeys, type TableName } from '@/api/queryKeys';
import { useTenantKey } from '@/api/useTenantKey';
import { supabase } from '@/lib/supabase';
import { useQuery } from '@tanstack/vue-query';
import { computed } from 'vue';
import type { RouteLocationRaw } from 'vue-router';

export type DashboardGateRow = Views['dashboard_gate_pending']['Row'];
export type DashboardTaskRow = Views['dashboard_task_due']['Row'];
export type DashboardEvidenceRow = Views['dashboard_product_evidence']['Row'];
export type DashboardPurchaseOrderRow = Views['dashboard_purchase_order']['Row'];
export type DashboardShipmentRow = Views['dashboard_shipment']['Row'];
export type DashboardMarketRow = Views['dashboard_market']['Row'];
export type DashboardIncidentRow = Views['dashboard_incident']['Row'];
export type DashboardChangeRequestRow = Views['dashboard_change_request']['Row'];

type DashboardView = Extract<
   TableName,
   | 'dashboard_gate_pending'
   | 'dashboard_task_due'
   | 'dashboard_product_evidence'
   | 'dashboard_purchase_order'
   | 'dashboard_shipment'
   | 'dashboard_market'
   | 'dashboard_incident'
   | 'dashboard_change_request'
>;

/** A dashboard view's rows, of the tenants in scope. */
function useDashboardView<Row>(
   view: DashboardView,
   order?: { column: string; ascending: boolean }
) {
   const tenantKey = useTenantKey();

   return useQuery({
      queryKey: computed(() => queryKeys.list(tenantKey.value, view)),
      queryFn: async ({ signal }) => {
         let query = supabase.from(view).select('*').abortSignal(signal);
         if (order) query = query.order(order.column, { ascending: order.ascending });
         const { data } = await query.throwOnError();
         return (data ?? []) as Row[];
      }
   });
}

/** The gate each active project waits on, longest waiting first. */
export const useDashboardGates = () =>
   useDashboardView<DashboardGateRow>('dashboard_gate_pending', {
      column: 'waiting_days',
      ascending: false
   });

/** The open tasks due within five days (overdue ones included), earliest first. */
export const useDashboardTasks = () =>
   useDashboardView<DashboardTaskRow>('dashboard_task_due', { column: 'due_on', ascending: true });

/** Per tenant, the evidence behind its active products. */
export const useDashboardEvidence = () =>
   useDashboardView<DashboardEvidenceRow>('dashboard_product_evidence');

/**
 * The open purchase orders (neither draft, closed nor cancelled; a shared order on the client side
 * neither delivered nor cancelled), the earliest ready date first.
 */
export const useDashboardPurchaseOrders = () =>
   useDashboardView<DashboardPurchaseOrderRow>('dashboard_purchase_order', {
      column: 'ready_on',
      ascending: true
   });

/** The open shipments (neither accepted nor cancelled), the earliest ETA first. */
export const useDashboardShipments = () =>
   useDashboardView<DashboardShipmentRow>('dashboard_shipment', {
      column: 'eta',
      ascending: true
   });

/** Per tenant, its market cells by status (live, preparing, suppressed) and its target. */
export const useDashboardMarket = () => useDashboardView<DashboardMarketRow>('dashboard_market');

/** The incidents that are not closed, S1 first (the spec's "S1/S2 öne"). */
export const useDashboardIncidents = () =>
   useDashboardView<DashboardIncidentRow>('dashboard_incident', {
      column: 'severity',
      ascending: true
   });

/** The open and approved change requests, the earliest decision date first. */
export const useDashboardChangeRequests = () =>
   useDashboardView<DashboardChangeRequestRow>('dashboard_change_request', {
      column: 'decision_due_on',
      ascending: true
   });

/**
 * Who has to act on each pending gate: management (a management gate), else the customer (an (M)
 * gate waiting for their approval), else the team. Each group keeps the rows' order.
 */
export function groupGates<
   Row extends Pick<DashboardGateRow, 'needs_management' | 'needs_customer_approval'>
>(rows: readonly Row[]) {
   const groups = { management: [] as Row[], customer: [] as Row[], team: [] as Row[] };
   for (const row of rows) {
      if (row.needs_management) groups.management.push(row);
      else if (row.needs_customer_approval) groups.customer.push(row);
      else groups.team.push(row);
   }
   return groups;
}

/** The tasks past their due date, and those due within the next five days. */
export function splitTasks<Row extends Pick<DashboardTaskRow, 'overdue'>>(rows: readonly Row[]) {
   return {
      overdue: rows.filter((row) => row.overdue),
      dueSoon: rows.filter((row) => !row.overdue)
   };
}

/**
 * Where an evidence card leads: the product list; the unsigned SKU card (`unsigned_spec`) narrows
 * it to products without a signed spec sheet (`?spec=false`, see specFilterFromQuery).
 */
export const evidenceTarget = (
   card: 'unsigned_spec' | 'compliance' = 'compliance'
): RouteLocationRaw =>
   card === 'unsigned_spec'
      ? { name: 'ops-product-list', query: { spec: 'false' } }
      : { name: 'ops-product-list' };

type PurchaseOrderStatus = NonNullable<DashboardPurchaseOrderRow['status']>;
type ClientStatus = NonNullable<DashboardPurchaseOrderRow['client_status']>;
type ShipmentStatus = NonNullable<DashboardShipmentRow['status']>;

/** The order statuses that wait for an action of ours (send, chase or approve the PI, pay). */
const PO_ACTION: readonly PurchaseOrderStatus[] = ['sent', 'pi_received', 'pi_approved'];
/** The order statuses from the deposit to the balance: the goods are being made or are ready. */
const PO_PRODUCTION: readonly PurchaseOrderStatus[] = [
   'deposit_paid',
   'in_production',
   'ready',
   'balance_paid'
];
/**
 * A shared order on the client side reads no raw status (Q1), only its client status: one not yet
 * in production waits on the provider, so it shows with the orders waiting for action.
 */
const PO_CLIENT_WAITING: readonly ClientStatus[] = ['pending', 'confirmed'];
/** The shipment statuses of goods on the way, from the loading to customs. */
const SHIPMENT_IN_TRANSIT: readonly ShipmentStatus[] = ['loaded', 'in_transit', 'at_customs'];

/**
 * The open orders waiting for action, and those in production. Each group keeps the rows' order. A
 * shared order on the client side is grouped by its client status.
 */
export function groupPurchaseOrders<
   Row extends Pick<DashboardPurchaseOrderRow, 'status'> &
      Partial<Pick<DashboardPurchaseOrderRow, 'client_status'>>
>(rows: readonly Row[]) {
   const has =
      (statuses: readonly PurchaseOrderStatus[], clientStatuses: readonly ClientStatus[]) =>
      (row: Row) =>
         row.status
            ? statuses.includes(row.status)
            : !!row.client_status && clientStatuses.includes(row.client_status);
   return {
      action: rows.filter(has(PO_ACTION, PO_CLIENT_WAITING)),
      production: rows.filter(has(PO_PRODUCTION, ['in_production']))
   };
}

/**
 * The shipments on the way, and the late ones (ETA passed before delivery, whatever their
 * status), so a late shipment on the way is in both. Each group keeps the rows' order.
 */
export function groupShipments<Row extends Pick<DashboardShipmentRow, 'status' | 'overdue'>>(
   rows: readonly Row[]
) {
   return {
      inTransit: rows.filter((row) => !!row.status && SHIPMENT_IN_TRANSIT.includes(row.status)),
      late: rows.filter((row) => !!row.overdue)
   };
}

/**
 * The market matrix box: the live cells of every tenant, and the tenants with a target (a cell in
 * TARGET_STATUSES), the most live first.
 */
export function marketSummary<Row extends Pick<DashboardMarketRow, 'live_count' | 'target_count'>>(
   rows: readonly Row[]
): { live: number; items: Row[] } {
   return {
      live: _sumBy(rows, (row) => row.live_count ?? 0),
      items: rows
         .filter((row) => (row.target_count ?? 0) > 0)
         .sort((a, b) => (b.live_count ?? 0) - (a.live_count ?? 0))
   };
}
