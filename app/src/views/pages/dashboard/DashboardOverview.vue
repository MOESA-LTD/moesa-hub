<script setup lang="ts">
import { useAbility } from '@casl/vue';
import DashboardOverviewTile, { type OverviewKind } from './DashboardOverviewTile.vue';

/** The headline figures above the boxes, each where the user may read its records. */
const OVERVIEW: readonly { kind: OverviewKind; permission: string }[] = [
   { kind: 'gates', permission: 'project_gate' },
   { kind: 'tasks', permission: 'project_task' },
   { kind: 'orders', permission: 'purchase_order' },
   { kind: 'shipments', permission: 'shipment' },
   { kind: 'incidents', permission: 'incident' },
   { kind: 'market', permission: 'market_cell' }
];

const ability = useAbility();
const tiles = computed(() => OVERVIEW.filter((tile) => ability.can('read', tile.permission)));
</script>

<template>
   <section
      v-if="tiles.length"
      class="dashboard-overview"
      :aria-label="$t('dashboard.overview.title')"
   >
      <DashboardOverviewTile v-for="tile in tiles" :key="tile.kind" :kind="tile.kind" />
   </section>
</template>

<style scoped>
.dashboard-overview {
   display: grid;
   grid-template-columns: repeat(auto-fit, minmax(min(100%, 8.5rem), 1fr));
   gap: 0.75rem;
}
</style>
