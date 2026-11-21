<script setup lang="ts">
import type { ChartLegendItem } from './types';

/** The series of a chart: a swatch (and, for a status, its icon) beside each name. */
defineProps<{ items: ChartLegendItem[] }>();
</script>

<template>
   <ul
      v-if="items.length"
      class="m-0 p-0 list-none flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-color"
   >
      <li v-for="item in items" :key="item.key" class="flex items-center gap-1.5">
         <span
            aria-hidden="true"
            class="w-2.5 h-2.5 rounded-sm shrink-0"
            :style="{ background: item.color }"
         />
         <i v-if="item.icon" :class="item.icon" class="!text-xs" aria-hidden="true" />
         <span v-text="item.label" />
      </li>
   </ul>
</template>
