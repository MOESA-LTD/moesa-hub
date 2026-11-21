import {
   evidenceTarget,
   groupGates,
   type DashboardEvidenceRow,
   type DashboardGateRow,
   type DashboardIncidentRow,
   type DashboardMarketRow,
   type DashboardPurchaseOrderRow,
   type DashboardShipmentRow,
   type DashboardTaskRow
} from '@/api/dashboard';
import { orderStatusLabel } from '@/api/purchaseOrder';
import type {
   ChartBar,
   ChartLegendItem,
   ChartMeterRow
} from '@/components/service-components/dashboard/charts/types';
import i18n from '@plugins/i18n';
import dayjs from 'dayjs';
import type { TenantName } from './views';

/** The chart colours (see _charts.scss); marks wear them, text never does. */
export const VIZ = {
   series1: 'var(--viz-series-1)',
   series2: 'var(--viz-series-2)',
   series3: 'var(--viz-series-3)',
   critical: 'var(--viz-critical)',
   serious: 'var(--viz-serious)',
   warning: 'var(--viz-warning)'
} as const;

/** What a chart box shows: its badge count, its marks and their legend. */
export type ChartView = {
   count: number;
   empty?: boolean;
   bars: ChartBar[];
   legend: ChartLegendItem[];
   /** One line under the chart that needs attention (e.g. incidents management was not told of). */
   alert?: string;
};

export type MeterView = { count: number; empty?: boolean; rows: ChartMeterRow[] };

const t = (key: string, params?: Record<string, unknown>) =>
   params ? i18n.t(key, params) : i18n.t(key);

const legendItem = (key: string, color: string, icon?: string): ChartLegendItem => ({
   key,
   label: t(`dashboard.charts.series.${key}`),
   color,
   icon
});

// --- gates: how long the pending gates have waited, by who has to act ---

/** Waiting-time bands in days; the last one is open-ended. */
export const GATE_AGE_BANDS = [
   { key: '0_7', from: 0, to: 7 },
   { key: '8_14', from: 8, to: 14 },
   { key: '15_30', from: 15, to: 30 },
   { key: '31', from: 31, to: Infinity }
] as const;

const bandLabel = (band: (typeof GATE_AGE_BANDS)[number]) =>
   band.to === Infinity
      ? t('dashboard.charts.days_over', { from: band.from })
      : t('dashboard.charts.days_range', { from: band.from, to: band.to });

const GATE_SERIES = [
   { key: 'team', color: VIZ.series1 },
   { key: 'management', color: VIZ.series2 },
   { key: 'customer', color: VIZ.series3 }
] as const;

/** One column per waiting band, stacked by who acts on the gate (team, management, customer). */
export const gateAgingChart = (rows: readonly DashboardGateRow[]): ChartView => {
   const groups = groupGates(rows);
   const bars = GATE_AGE_BANDS.map((band): ChartBar => {
      const inBand = (row: DashboardGateRow) => {
         const days = row.waiting_days ?? 0;
         return days >= band.from && days <= band.to;
      };
      return {
         key: band.key,
         label: bandLabel(band),
         // The open-ended band is the one to act on, when a gate is in it.
         emphasis: band.to === Infinity && rows.some(inBand) ? 'critical' : undefined,
         segments: GATE_SERIES.map((series) => ({
            key: series.key,
            label: t(`dashboard.charts.series.${series.key}`),
            color: series.color,
            value: groups[series.key].filter(inBand).length
         })),
         to: { name: 'ops-project-list' }
      };
   });
   return {
      count: rows.length,
      bars,
      legend: GATE_SERIES.map((series) => legendItem(series.key, series.color))
   };
};

// --- tasks: what falls due in the next days ---

/** The days the task chart shows after today (the view holds tasks due within five days). */
export const TASK_HORIZON_DAYS = 5;

/**
 * One column for the overdue tasks, then one per day from today on, stacked by whether the task
 * holds a gate. Days are counted from `today` (the view's own `days_left`).
 */
export const taskHorizonChart = (rows: readonly DashboardTaskRow[]): ChartView => {
   const series = [
      {
         key: 'blocks_gate',
         color: VIZ.series2,
         test: (row: DashboardTaskRow) => !!row.blocks_gate
      },
      { key: 'other_tasks', color: VIZ.series1, test: (row: DashboardTaskRow) => !row.blocks_gate }
   ];
   const column = (
      key: string,
      label: string,
      match: (days: number) => boolean,
      emphasis?: ChartBar['emphasis']
   ): ChartBar => {
      const inColumn = rows.filter((row) => match(row.days_left ?? 0));
      return {
         key,
         label,
         emphasis: inColumn.length ? emphasis : undefined,
         segments: series.map((s) => ({
            key: s.key,
            label: t(`dashboard.charts.series.${s.key}`),
            color: s.color,
            value: inColumn.filter(s.test).length
         }))
      };
   };
   const days = Array.from({ length: TASK_HORIZON_DAYS + 1 }, (_, day) =>
      column(
         `d${day}`,
         day === 0 ? t('dashboard.charts.today') : dayjs().add(day, 'day').format('dd D'),
         (left) => left === day
      )
   );
   return {
      count: rows.length,
      bars: [
         column('overdue', t('dashboard.charts.overdue'), (left) => left < 0, 'critical'),
         ...days
      ],
      legend: series.map((s) => legendItem(s.key, s.color))
   };
};

// --- purchase orders: where the open orders are in their flow ---

/** The open order stages in flow order: the provider's statuses, then a client's view of them. */
const ORDER_STAGES = [
   'ops.purchase_order.status.sent',
   'ops.purchase_order.status.pi_received',
   'ops.purchase_order.status.pi_approved',
   'ops.purchase_order.status.deposit_paid',
   'ops.purchase_order.status.in_production',
   'ops.purchase_order.status.ready',
   'ops.purchase_order.status.balance_paid'
];
const CLIENT_STAGES = [
   'ops.purchase_order.client_status.pending',
   'ops.purchase_order.client_status.confirmed',
   'ops.purchase_order.client_status.in_production',
   'ops.purchase_order.client_status.shipped',
   'ops.purchase_order.client_status.delivered'
];

/**
 * One bar per stage of the order flow, in flow order. The provider's stages are always listed (an
 * empty stage is part of the picture); a client's stages only when one of its shared orders is in
 * them.
 */
export const orderPipelineChart = (rows: readonly DashboardPurchaseOrderRow[]): ChartView => {
   const counts = _countBy(rows, (row) => orderStatusLabel(row)?.key ?? '');
   const hasProvider = rows.some((row) => !!row.status);
   const stages = [
      ...(hasProvider ? ORDER_STAGES : []),
      ...CLIENT_STAGES.filter((key) => counts[key])
   ];
   return {
      count: rows.length,
      bars: stages.map((key) => ({
         key,
         label: t(key),
         segments: [{ key: 'orders', label: t(key), color: VIZ.series1, value: counts[key] ?? 0 }],
         to: { name: 'ops-purchase-order-list' }
      })),
      legend: []
   };
};

// --- shipments: where the open shipments are, and which are late ---

const SHIPMENT_STAGES = [
   'planned',
   'booked',
   'loaded',
   'in_transit',
   'at_customs',
   'delivered',
   'disputed'
] as const;

/** One bar per open shipment status in flow order, split into on time and late. */
export const shipmentStatusChart = (rows: readonly DashboardShipmentRow[]): ChartView => {
   const stages = SHIPMENT_STAGES.filter(
      (status) => status !== 'disputed' || rows.some((row) => row.status === status)
   );
   const series = [
      { key: 'on_time', color: VIZ.series1, test: (row: DashboardShipmentRow) => !row.overdue },
      { key: 'late', color: VIZ.critical, test: (row: DashboardShipmentRow) => !!row.overdue }
   ];
   return {
      count: rows.length,
      bars: stages.map((status) => {
         const inStage = rows.filter((row) => row.status === status);
         return {
            key: status,
            label: t(`ops.shipment.status.${status}`),
            segments: series.map((s) => ({
               key: s.key,
               label: t(`dashboard.charts.series.${s.key}`),
               color: s.color,
               value: inStage.filter(s.test).length
            })),
            to: { name: 'ops-shipment-list' }
         };
      }),
      legend: [
         legendItem('on_time', VIZ.series1),
         legendItem('late', VIZ.critical, 'pi pi-exclamation-triangle')
      ]
   };
};

// --- incidents: open incidents by severity ---

const SEVERITIES = [
   { key: 's1', color: VIZ.critical, icon: 'pi pi-times-circle' },
   { key: 's2', color: VIZ.serious, icon: 'pi pi-exclamation-triangle' },
   { key: 's3', color: VIZ.warning, icon: 'pi pi-info-circle' }
] as const;

/**
 * One bar per severity in its status colour (its label and icon name it too), with how many are
 * contained; the incidents management was not told of yet are called out under the chart.
 */
export const incidentSeverityChart = (rows: readonly DashboardIncidentRow[]): ChartView => {
   const missing = rows.filter((row) => row.management_notice_missing).length;
   return {
      count: rows.length,
      bars: SEVERITIES.map((severity) => {
         const of = rows.filter((row) => row.severity === severity.key);
         const contained = of.filter((row) => row.status === 'contained').length;
         return {
            key: severity.key,
            label: t(`ops.incident.severity.${severity.key}`),
            icon: severity.icon,
            note: contained ? t('dashboard.charts.contained', { n: contained }) : undefined,
            segments: [
               {
                  key: severity.key,
                  label: t(`ops.incident.severity.${severity.key}`),
                  color: severity.color,
                  value: of.length
               }
            ],
            to: { name: 'ops-incident-list' }
         };
      }),
      legend: [],
      alert: missing ? t('dashboard.charts.notice_missing', { n: missing }) : undefined
   };
};

// --- market matrix: per company, its cells by status against its target ---

const MARKET_SERIES = [
   { key: 'live', color: VIZ.series1, of: (row: DashboardMarketRow) => row.live_count ?? 0 },
   {
      key: 'preparing',
      color: VIZ.series3,
      of: (row: DashboardMarketRow) => row.preparing_count ?? 0
   },
   {
      key: 'suppressed',
      color: VIZ.series2,
      of: (row: DashboardMarketRow) => row.suppressed_count ?? 0
   }
] as const;

/**
 * Per company with a target, its live, preparing and suppressed cells, the most live first, read
 * against its target. Empty when no company has a target (as the matrix box).
 */
export const marketCoverageChart =
   (tenantName: TenantName) =>
   (rows: readonly DashboardMarketRow[]): ChartView => {
      const targeted = rows
         .filter((row) => (row.target_count ?? 0) > 0)
         .sort((a, b) => (b.live_count ?? 0) - (a.live_count ?? 0));
      return {
         count: _sumBy(rows, (row) => row.live_count ?? 0),
         empty: targeted.length === 0,
         bars: targeted.map((row) => ({
            key: row.tenant_id ?? '',
            label: tenantName(row.tenant_id),
            value: t('dashboard.charts.of_target', {
               n: row.live_count ?? 0,
               target: row.target_count ?? 0
            }),
            total: row.target_count ?? 0,
            segments: MARKET_SERIES.map((s) => ({
               key: s.key,
               label: t(`dashboard.charts.series.${s.key}`),
               color: s.color,
               value: s.of(row)
            })),
            to: { name: 'ops-market-list' }
         })),
         legend: MARKET_SERIES.map((s) => legendItem(s.key, s.color))
      };
   };

// --- products: how much of each company's active range has its evidence ---

/**
 * Per company with active SKUs, the share with a signed spec sheet and the share with complete
 * compliance, the least ready first. The count is the active SKUs.
 */
export const productReadinessChart =
   (tenantName: TenantName) =>
   (rows: readonly DashboardEvidenceRow[]): MeterView => {
      const active = rows.filter((row) => (row.active_sku_count ?? 0) > 0);
      const share = (row: DashboardEvidenceRow) =>
         ((row.signed_spec_count ?? 0) + (row.compliance_complete_count ?? 0)) /
         (2 * (row.active_sku_count ?? 1));
      return {
         count: _sumBy(active, (row) => row.active_sku_count ?? 0),
         empty: active.length === 0,
         rows: [...active]
            .sort((a, b) => share(a) - share(b))
            .map((row) => ({
               key: row.tenant_id ?? '',
               label: tenantName(row.tenant_id),
               meters: [
                  {
                     key: 'signed_spec',
                     label: t('dashboard.charts.series.signed_spec'),
                     value: row.signed_spec_count ?? 0,
                     total: row.active_sku_count ?? 0,
                     to: evidenceTarget('unsigned_spec')
                  },
                  {
                     key: 'compliance',
                     label: t('dashboard.charts.series.compliance'),
                     value: row.compliance_complete_count ?? 0,
                     total: row.active_sku_count ?? 0,
                     to: evidenceTarget('compliance')
                  }
               ]
            }))
      };
   };
