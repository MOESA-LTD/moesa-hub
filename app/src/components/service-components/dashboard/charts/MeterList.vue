<script setup lang="ts">
import { DASHBOARD_EDITING } from '@/constants/dashboard';
import type { ChartMeter, ChartMeterRow } from './types';

/**
 * Named rows of ratios: each meter a fill on a lighter track of its own hue, with its figure and
 * share. The meters of a row sit side by side where the box is wide, one under the other where not.
 */
defineProps<{ rows: ChartMeterRow[] }>();

const editing = inject(DASHBOARD_EDITING, ref(false));
const router = useRouter();
const { t } = useI18n();

const share = (meter: ChartMeter) =>
   meter.total > 0 ? Math.round((meter.value / meter.total) * 100) : 0;
const describe = (row: ChartMeterRow, meter: ChartMeter) =>
   `${row.label} · ${meter.label}: ${t('dashboard.charts.of_total', {
      n: meter.value,
      total: meter.total
   })} (${share(meter)}%)`;
const linked = (meter: ChartMeter) => !!meter.to && !editing.value;
</script>

<template>
   <ul class="m-0 p-0 list-none flex flex-col gap-3">
      <li v-for="row in rows" :key="row.key" class="flex flex-col gap-1.5">
         <span class="text-sm font-semibold truncate" v-text="row.label" />
         <div class="meter-grid">
            <component
               :is="linked(meter) ? 'button' : 'div'"
               v-for="meter in row.meters"
               :key="meter.key"
               v-tooltip.top="{ value: describe(row, meter), showDelay: 150 }"
               :type="linked(meter) ? 'button' : undefined"
               class="meter text-left rounded-md px-1.5 py-1"
               :class="{ 'meter--link': linked(meter) }"
               :aria-label="describe(row, meter)"
               @click="linked(meter) && router.push(meter.to!)"
            >
               <span class="flex items-baseline justify-between gap-2 text-xs">
                  <span class="text-muted-color truncate" v-text="meter.label" />
                  <span class="tabular-nums shrink-0">
                     <span class="font-semibold" v-text="`${share(meter)}%`" />
                     <span
                        class="text-muted-color"
                        v-text="
                           ` · ${t('dashboard.charts.of_total', { n: meter.value, total: meter.total })}`
                        "
                     />
                  </span>
               </span>
               <span class="meter-track" aria-hidden="true">
                  <span class="meter-fill" :style="{ width: `${share(meter)}%` }" />
               </span>
            </component>
         </div>
      </li>
   </ul>
</template>

<style scoped>
.meter-grid {
   display: grid;
   grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
   gap: 0.25rem 0.75rem;
}

.meter {
   display: flex;
   flex-direction: column;
   gap: 0.375rem;
   transition: background-color 0.15s;
}

.meter--link {
   cursor: pointer;
}

.meter--link:hover,
.meter--link:focus-visible {
   background: var(--p-content-hover-background);
}

.meter-track {
   display: block;
   height: 0.5rem;
   border-radius: 999px;
   background: var(--viz-track);
   overflow: hidden;
}

.meter-fill {
   display: block;
   height: 100%;
   border-radius: 999px;
   background: var(--viz-series-1);
   transition: width 0.3s ease-out;
}
</style>
