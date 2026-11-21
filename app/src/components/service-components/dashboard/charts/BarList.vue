<script setup lang="ts">
import { DASHBOARD_EDITING } from '@/constants/dashboard';
import ChartLegend from './ChartLegend.vue';
import ChartTable from './ChartTable.vue';
import { barDescription, barTotal, type ChartBar, type ChartLegendItem } from './types';

/**
 * Horizontal bars, one per row, all on one baseline: a label, the bar (its parts stacked with a
 * surface gap between them) and its figure. A bar read against a total (e.g. a target) shows where
 * that total lies. On a narrow box the label goes above its bar.
 */
const props = withDefaults(
   defineProps<{
      bars: ChartBar[];
      legend?: ChartLegendItem[];
      /** What the table view calls the rows' column. */
      caption: string;
   }>(),
   { legend: () => [] }
);

const editing = inject(DASHBOARD_EDITING, ref(false));
const router = useRouter();

/** A bar leads to its list, except while the dashboard is being arranged. */
const linked = (bar: ChartBar) => !!bar.to && !editing.value;

// Bars are read against the longest bar or total, so the longest fills the track.
const scale = computed(() =>
   Math.max(1, ...props.bars.map((bar) => Math.max(barTotal(bar), bar.total ?? 0)))
);

const pct = (value: number) => `${(value / scale.value) * 100}%`;

/** The parts that draw something; the last one carries the bar's rounded end. */
const drawn = (bar: ChartBar) => bar.segments.filter((segment) => segment.value > 0);

const hasTarget = (bar: ChartBar) => (bar.total ?? 0) > barTotal(bar);
</script>

<template>
   <div class="flex flex-col gap-3">
      <ChartLegend :items="legend" />
      <ul class="bar-list m-0 p-0 list-none flex flex-col">
         <li v-for="bar in bars" :key="bar.key">
            <component
               :is="linked(bar) ? 'button' : 'div'"
               v-tooltip.top="{ value: barDescription(bar), showDelay: 150 }"
               :type="linked(bar) ? 'button' : undefined"
               class="bar-row w-full text-left rounded-md px-1.5 py-1.5"
               :class="{ 'bar-row--link': linked(bar) }"
               :aria-label="barDescription(bar)"
               @click="linked(bar) && router.push(bar.to!)"
            >
               <span class="bar-label flex flex-col min-w-0 text-sm">
                  <span class="flex items-center gap-1.5 min-w-0">
                     <i
                        v-if="bar.icon"
                        :class="bar.icon"
                        class="!text-xs shrink-0"
                        aria-hidden="true"
                     />
                     <span class="truncate" v-text="bar.label" />
                  </span>
                  <span
                     v-if="bar.note"
                     class="text-xs leading-tight text-muted-color truncate"
                     v-text="bar.note"
                  />
               </span>
               <span class="bar-track" aria-hidden="true">
                  <span
                     v-for="(segment, index) in drawn(bar)"
                     :key="segment.key"
                     class="bar-segment"
                     :class="{ 'bar-segment--end': index === drawn(bar).length - 1 }"
                     :style="{ width: pct(segment.value), background: segment.color }"
                  />
                  <span
                     v-if="hasTarget(bar)"
                     class="bar-target"
                     :style="{ insetInlineStart: pct(bar.total!) }"
                  />
               </span>
               <span
                  class="bar-value text-sm font-semibold tabular-nums"
                  :class="{ 'text-muted-color font-normal': barTotal(bar) === 0 }"
                  v-text="bar.value ?? barTotal(bar)"
               />
            </component>
         </li>
      </ul>
      <ChartTable :caption :bars />
   </div>
</template>

<style scoped>
.bar-row {
   display: grid;
   grid-template-columns: minmax(0, 9rem) minmax(0, 1fr) auto;
   align-items: center;
   column-gap: 0.75rem;
   row-gap: 0.25rem;
   transition: background-color 0.15s;
}

.bar-row--link {
   cursor: pointer;
}

.bar-row--link:hover,
.bar-row--link:focus-visible {
   background: var(--p-content-hover-background);
}

.bar-track {
   position: relative;
   display: flex;
   gap: 2px;
   height: 0.625rem;
   border-inline-start: 1px solid var(--viz-baseline);
}

.bar-segment {
   display: block;
   height: 100%;
   min-width: 2px;
   transition: width 0.3s ease-out;
}

/* The data end is rounded, the baseline end square. */
.bar-segment--end {
   border-start-end-radius: 4px;
   border-end-end-radius: 4px;
}

.bar-target {
   position: absolute;
   top: -3px;
   bottom: -3px;
   width: 2px;
   margin-inline-start: -1px;
   border-radius: 1px;
   background: var(--p-text-muted-color);
}

.bar-value {
   min-width: 1.5rem;
   text-align: end;
}

/* A narrow box: the label on its own line, the bar and its figure below it. */
@container (max-width: 22rem) {
   .bar-row {
      grid-template-columns: minmax(0, 1fr) auto;
   }

   .bar-label {
      grid-column: 1 / -1;
   }
}
</style>
