<script setup lang="ts">
import { barTotal, type ChartBar } from './types';

/** A chart's figures as a table, for screen readers: one row per bar, one column per part. */
const props = defineProps<{ caption: string; bars: ChartBar[] }>();

const series = computed(() =>
   _uniqBy(
      props.bars.flatMap((bar) => bar.segments),
      'key'
   ).map(({ key, label }) => ({ key, label }))
);

const valueOf = (bar: ChartBar, key: string) =>
   bar.segments.find((segment) => segment.key === key)?.value ?? 0;
</script>

<template>
   <table class="sr-only">
      <caption v-text="caption" />
      <thead>
         <tr>
            <th scope="col" v-text="caption" />
            <template v-if="series.length > 1">
               <th v-for="s in series" :key="s.key" scope="col" v-text="s.label" />
            </template>
            <th scope="col" v-text="$t('dashboard.charts.total')" />
         </tr>
      </thead>
      <tbody>
         <tr v-for="bar in bars" :key="bar.key">
            <th scope="row" v-text="bar.label" />
            <template v-if="series.length > 1">
               <td v-for="s in series" :key="s.key" v-text="valueOf(bar, s.key)" />
            </template>
            <td v-text="bar.value ?? barTotal(bar)" />
         </tr>
      </tbody>
   </table>
</template>
