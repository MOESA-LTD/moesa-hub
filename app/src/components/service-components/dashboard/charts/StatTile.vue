<script setup lang="ts">
import type { RouteLocationRaw } from 'vue-router';

/**
 * A headline figure: its name, the number and one line of context. A context line that needs
 * attention carries an icon as well as its colour. The whole tile leads to its list.
 */
const props = defineProps<{
   label: string;
   icon: string;
   /** The area's icon chip classes (see DASHBOARD_AREA_CLASSES). */
   iconClass: string;
   /** Null while loading. */
   value: number | null;
   sub?: string;
   /** The context line needs attention (e.g. late shipments). */
   alert?: boolean;
   /** The figure itself needs attention (e.g. overdue tasks). */
   critical?: boolean;
   to?: RouteLocationRaw;
   disabled?: boolean;
}>();

const router = useRouter();
const linked = computed(() => !!props.to && !props.disabled);
</script>

<template>
   <component
      :is="linked ? 'button' : 'div'"
      :type="linked ? 'button' : undefined"
      class="stat-tile w-full text-left rounded-xl bg-surface-0 dark:bg-surface-900 border border-surface-200 dark:border-surface-700 p-4 flex flex-col gap-2 min-w-0"
      :class="{ 'stat-tile--link': linked }"
      @click="linked && router.push(to!)"
   >
      <span class="flex items-start gap-2 min-w-0">
         <span
            class="w-7 h-7 rounded-lg flex items-center justify-center shrink-0"
            :class="iconClass"
            aria-hidden="true"
         >
            <i :class="icon" class="!text-sm" />
         </span>
         <span
            class="text-sm leading-tight text-muted-color line-clamp-2 self-center"
            v-text="label"
         />
      </span>
      <Skeleton v-if="value === null" width="3rem" height="2rem" />
      <span v-else class="flex items-center gap-2">
         <span class="text-3xl font-semibold leading-none" v-text="value.toLocaleString()" />
         <i
            v-if="critical"
            class="pi pi-exclamation-triangle"
            style="color: var(--viz-critical)"
            :aria-label="$t('dashboard.overview.needs_attention')"
         />
      </span>
      <span
         v-if="sub"
         class="text-xs flex items-start gap-1 min-w-0 mt-auto"
         :class="alert ? 'font-semibold' : 'text-muted-color'"
      >
         <i
            v-if="alert"
            class="pi pi-exclamation-triangle !text-xs shrink-0"
            style="color: var(--viz-critical)"
            aria-hidden="true"
         />
         <span class="leading-tight" v-text="sub" />
      </span>
   </component>
</template>

<style scoped>
.stat-tile {
   transition:
      border-color 0.15s,
      box-shadow 0.15s,
      transform 0.15s;
}

.stat-tile--link {
   cursor: pointer;
}

.stat-tile--link:hover,
.stat-tile--link:focus-visible {
   border-color: var(--p-primary-color);
   box-shadow: 0 4px 12px -4px rgb(0 0 0 / 0.12);
}
</style>
