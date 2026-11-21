<script setup lang="ts">
import { DASHBOARD_EDITING } from '@/constants/dashboard';
import ChartLegend from './ChartLegend.vue';
import ChartTable from './ChartTable.vue';
import { barDescription, barTotal, niceMax, type ChartBar, type ChartLegendItem } from './types';

/**
 * Columns on one baseline, their parts stacked with a surface gap, each total on its cap, hairline
 * gridlines at clean values. Each column's whole band is its hover and click target.
 */
const props = withDefaults(
   defineProps<{
      bars: ChartBar[];
      legend?: ChartLegendItem[];
      /** What the table view calls the columns. */
      caption: string;
   }>(),
   { legend: () => [] }
);

const editing = inject(DASHBOARD_EDITING, ref(false));
const router = useRouter();

const max = computed(() => niceMax(Math.max(0, ...props.bars.map(barTotal))));
const ticks = computed(() => {
   const half = max.value / 2;
   return Number.isInteger(half) && half > 0 ? [max.value, half, 0] : [max.value, 0];
});

const pct = (value: number) => `${(value / max.value) * 100}%`;
const drawn = (bar: ChartBar) => bar.segments.filter((segment) => segment.value > 0);
const linked = (bar: ChartBar) => !!bar.to && !editing.value;
</script>

<template>
   <div class="flex flex-col gap-3">
      <ChartLegend :items="legend" />
      <div class="column-chart" aria-hidden="true">
         <div class="column-axis">
            <span
               v-for="tick in ticks"
               :key="tick"
               class="column-tick tabular-nums"
               :style="{ bottom: pct(tick) }"
               v-text="tick"
            />
         </div>
         <div class="column-plot">
            <span
               v-for="tick in ticks"
               :key="tick"
               class="column-grid"
               :class="{ 'column-grid--base': tick === 0 }"
               :style="{ bottom: pct(tick) }"
            />
            <div
               class="column-bands"
               :style="{ gridTemplateColumns: `repeat(${bars.length}, minmax(0, 1fr))` }"
            >
               <component
                  :is="linked(bar) ? 'button' : 'div'"
                  v-for="bar in bars"
                  :key="bar.key"
                  v-tooltip.top="{ value: barDescription(bar), showDelay: 150 }"
                  :type="linked(bar) ? 'button' : undefined"
                  tabindex="-1"
                  class="column-band"
                  :class="{ 'column-band--link': linked(bar) }"
                  @click="linked(bar) && router.push(bar.to!)"
               >
                  <span class="column-stack" :style="{ height: pct(barTotal(bar)) }">
                     <span
                        v-if="barTotal(bar) > 0"
                        class="column-cap text-xs font-semibold tabular-nums"
                        v-text="barTotal(bar)"
                     />
                     <span
                        v-for="(segment, index) in drawn(bar)"
                        :key="segment.key"
                        class="column-segment"
                        :class="{ 'column-segment--end': index === drawn(bar).length - 1 }"
                        :style="{ flexGrow: segment.value, background: segment.color }"
                     />
                  </span>
               </component>
            </div>
         </div>
         <span />
         <div
            class="column-labels"
            :style="{ gridTemplateColumns: `repeat(${bars.length}, minmax(0, 1fr))` }"
         >
            <span
               v-for="bar in bars"
               :key="bar.key"
               class="column-label text-xs"
               :class="bar.emphasis === 'critical' ? 'font-semibold' : 'text-muted-color'"
            >
               <i
                  v-if="bar.emphasis === 'critical'"
                  class="pi pi-exclamation-triangle !text-[0.625rem]"
                  style="color: var(--viz-critical)"
               />
               {{ bar.label }}
            </span>
         </div>
      </div>
      <ChartTable :caption :bars />
   </div>
</template>

<style scoped>
.column-chart {
   display: grid;
   grid-template-columns: auto minmax(0, 1fr);
   grid-template-rows: 8rem auto;
   column-gap: 0.5rem;
   row-gap: 0.375rem;
   /* Room above the tallest column for its cap figure. */
   padding-top: 1.25rem;
}

.column-axis {
   position: relative;
   min-width: 1rem;
}

.column-tick {
   position: absolute;
   inset-inline-end: 0;
   transform: translateY(50%);
   font-size: 0.6875rem;
   line-height: 1;
   color: var(--p-text-muted-color);
}

.column-plot {
   position: relative;
}

.column-grid {
   position: absolute;
   inset-inline: 0;
   height: 1px;
   background: var(--viz-grid);
}

.column-grid--base {
   background: var(--viz-baseline);
}

.column-bands {
   position: absolute;
   inset: 0;
   display: grid;
}

.column-band {
   position: relative;
   display: flex;
   align-items: flex-end;
   justify-content: center;
   height: 100%;
   border-radius: 0.375rem 0.375rem 0 0;
   transition: background-color 0.15s;
}

.column-band--link {
   cursor: pointer;
}

.column-band:hover {
   background: var(--p-content-hover-background);
}

.column-stack {
   position: relative;
   display: flex;
   flex-direction: column-reverse;
   gap: 2px;
   width: min(1.5rem, 60%);
   transition: height 0.3s ease-out;
}

.column-segment {
   display: block;
   flex-basis: 0;
   min-height: 2px;
}

/* The data end (the top) is rounded, the baseline square. */
.column-segment--end {
   border-radius: 4px 4px 0 0;
}

.column-cap {
   position: absolute;
   bottom: 100%;
   inset-inline: -1rem;
   padding-bottom: 0.125rem;
   text-align: center;
   line-height: 1;
}

.column-labels {
   display: grid;
}

.column-label {
   display: flex;
   flex-wrap: wrap;
   align-items: center;
   justify-content: center;
   gap: 0 0.25rem;
   min-width: 0;
   padding-inline: 1px;
   font-size: 0.6875rem;
   line-height: 1.2;
   text-align: center;
   overflow-wrap: anywhere;
}
</style>
