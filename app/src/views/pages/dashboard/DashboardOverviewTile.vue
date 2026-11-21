<script setup lang="ts">
import {
   groupGates,
   groupPurchaseOrders,
   groupShipments,
   splitTasks,
   useDashboardGates,
   useDashboardIncidents,
   useDashboardMarket,
   useDashboardPurchaseOrders,
   useDashboardShipments,
   useDashboardTasks
} from '@/api/dashboard';
import StatTile from '@/components/service-components/dashboard/charts/StatTile.vue';
import {
   DASHBOARD_AREA_CLASSES,
   DASHBOARD_EDITING,
   type DashboardArea
} from '@/constants/dashboard';
import type { RouteLocationRaw } from 'vue-router';

export type OverviewKind = 'gates' | 'tasks' | 'orders' | 'shipments' | 'incidents' | 'market';

/** One headline figure of the overview; it reads the same query as the boxes of its area. */
const props = defineProps<{ kind: OverviewKind }>();

const { t } = useI18n();
const editing = inject(DASHBOARD_EDITING, ref(false));

type Figure = { value: number; sub: string; alert?: boolean };
type Tile = {
   icon: string;
   area: DashboardArea;
   to?: RouteLocationRaw;
   data: Ref<unknown[] | undefined>;
   figure: (rows: never[]) => Figure;
};

// The hook of the tile's kind only; the kind of a tile never changes.
const tile = ((): Tile => {
   switch (props.kind) {
      case 'gates':
         return {
            icon: PrimeIcons.FLAG,
            area: 'projects',
            to: { name: 'ops-project-list' },
            data: useDashboardGates().data,
            figure: (rows: Parameters<typeof groupGates>[0]) => {
               const groups = groupGates(rows);
               return {
                  value: rows.length,
                  sub: t('dashboard.overview.gates_sub', {
                     management: groups.management.length,
                     customer: groups.customer.length
                  })
               };
            }
         };
      case 'tasks':
         return {
            icon: PrimeIcons.CLOCK,
            area: 'projects',
            data: useDashboardTasks().data,
            figure: (rows: Parameters<typeof splitTasks>[0]) => {
               const { overdue, dueSoon } = splitTasks(rows);
               return {
                  value: overdue.length,
                  sub: t('dashboard.overview.tasks_sub', { n: dueSoon.length })
               };
            }
         };
      case 'orders':
         return {
            icon: PrimeIcons.SHOPPING_CART,
            area: 'supply',
            to: { name: 'ops-purchase-order-list' },
            data: useDashboardPurchaseOrders().data,
            figure: (rows: Parameters<typeof groupPurchaseOrders>[0]) => ({
               value: rows.length,
               sub: t('dashboard.overview.orders_sub', {
                  n: groupPurchaseOrders(rows).action.length
               })
            })
         };
      case 'shipments': {
         return {
            icon: PrimeIcons.SEND,
            area: 'logistics',
            to: { name: 'ops-shipment-list' },
            data: useDashboardShipments().data,
            figure: (rows: Parameters<typeof groupShipments>[0]) => {
               const { inTransit, late } = groupShipments(rows);
               return {
                  value: inTransit.length,
                  sub: t('dashboard.overview.shipments_sub', { n: late.length }),
                  alert: late.length > 0
               };
            }
         };
      }
      case 'incidents':
         return {
            icon: PrimeIcons.EXCLAMATION_CIRCLE,
            area: 'incidents',
            to: { name: 'ops-incident-list' },
            data: useDashboardIncidents().data,
            figure: (rows: { severity: string | null }[]) => {
               const s1 = rows.filter((row) => row.severity === 's1').length;
               return {
                  value: rows.length,
                  sub: t('dashboard.overview.incidents_sub', { n: s1 }),
                  alert: s1 > 0
               };
            }
         };
      case 'market':
         return {
            icon: PrimeIcons.GLOBE,
            area: 'market',
            to: { name: 'ops-market-list' },
            data: useDashboardMarket().data,
            figure: (rows: { live_count: number | null; preparing_count: number | null }[]) => ({
               value: _sumBy(rows, (row) => row.live_count ?? 0),
               sub: t('dashboard.overview.market_sub', {
                  n: _sumBy(rows, (row) => row.preparing_count ?? 0)
               })
            })
         };
   }
})() as Tile;

const figure = computed(() => (tile.data.value ? tile.figure(tile.data.value as never[]) : null));
// Overdue tasks are the figure itself: it needs attention whenever it is not zero.
const critical = computed(() => props.kind === 'tasks' && (figure.value?.value ?? 0) > 0);
</script>

<template>
   <StatTile
      :label="$t(`dashboard.overview.${kind}`)"
      :icon="tile.icon"
      :icon-class="DASHBOARD_AREA_CLASSES[tile.area].icon"
      :value="figure?.value ?? null"
      :sub="figure?.sub"
      :alert="figure?.alert"
      :to="tile.to"
      :disabled="editing"
      :critical="critical"
   />
</template>
