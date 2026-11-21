<script setup lang="ts">
import {
   useDashboardEvidence,
   useDashboardGates,
   useDashboardIncidents,
   useDashboardMarket,
   useDashboardPurchaseOrders,
   useDashboardShipments,
   useDashboardTasks
} from '@/api/dashboard';
import DashboardBox from '@/components/service-components/dashboard/DashboardBox.vue';
import BarList from '@/components/service-components/dashboard/charts/BarList.vue';
import ColumnChart from '@/components/service-components/dashboard/charts/ColumnChart.vue';
import MeterList from '@/components/service-components/dashboard/charts/MeterList.vue';
import type { BoxSize, DashboardBoxDef, DashboardBoxId } from '@/constants/dashboard';
import type { Ref } from 'vue';
import {
   gateAgingChart,
   incidentSeverityChart,
   marketCoverageChart,
   orderPipelineChart,
   productReadinessChart,
   shipmentStatusChart,
   taskHorizonChart,
   type ChartView,
   type MeterView
} from './charts';

/** A dashboard box drawing its area's records as a chart (see charts.ts). */
const props = defineProps<{ box: DashboardBoxDef; size: BoxSize }>();

const { t } = useI18n();

// Read when the view is computed, so a renamed or newly shared tenant shows at once.
const authStore = useAuthStore();
const tenantName = (id: string | null) =>
   authStore.branches.find((tenant) => tenant.id === id)?.display_name ?? '';

type Source = {
   form: 'columns' | 'bars' | 'meters';
   query: { data: Ref<unknown[] | undefined>; isPending: Ref<boolean> };
   view: (rows: never[]) => ChartView | MeterView;
};

// The query of the box's chart only; a box's id never changes.
const SOURCES: Partial<Record<DashboardBoxId, () => Source>> = {
   chart_gate_aging: () => ({
      form: 'columns',
      query: useDashboardGates(),
      view: gateAgingChart
   }),
   chart_task_horizon: () => ({
      form: 'columns',
      query: useDashboardTasks(),
      view: taskHorizonChart
   }),
   chart_po_pipeline: () => ({
      form: 'bars',
      query: useDashboardPurchaseOrders(),
      view: orderPipelineChart
   }),
   chart_shipments: () => ({
      form: 'bars',
      query: useDashboardShipments(),
      view: shipmentStatusChart
   }),
   chart_incidents: () => ({
      form: 'bars',
      query: useDashboardIncidents(),
      view: incidentSeverityChart
   }),
   chart_market: () => ({
      form: 'bars',
      query: useDashboardMarket(),
      view: marketCoverageChart(tenantName)
   }),
   chart_product_readiness: () => ({
      form: 'meters',
      query: useDashboardEvidence(),
      view: productReadinessChart(tenantName)
   })
};

const source = SOURCES[props.box.id]!();
const view = computed(() => source.view((source.query.data.value ?? []) as never[]));
const chart = computed(() => view.value as ChartView);
const meters = computed(() => view.value as MeterView);
</script>

<template>
   <DashboardBox
      :box
      :size
      :count="view.count"
      :empty="view.empty"
      :loading="source.query.isPending.value"
   >
      <ColumnChart
         v-if="source.form === 'columns'"
         :bars="chart.bars"
         :legend="chart.legend"
         :caption="t(box.title)"
      />
      <BarList
         v-else-if="source.form === 'bars'"
         :bars="chart.bars"
         :legend="chart.legend"
         :caption="t(box.title)"
      />
      <MeterList v-else :rows="meters.rows" />
      <p
         v-if="chart.alert"
         class="m-0 text-sm font-semibold flex items-center gap-2"
         data-test="chart-alert"
      >
         <i
            class="pi pi-exclamation-triangle"
            style="color: var(--viz-critical)"
            aria-hidden="true"
         />
         <span v-text="chart.alert" />
      </p>
   </DashboardBox>
</template>
