<script setup lang="ts">
import IncidentTable from '@/components/service-components/incident-table/IncidentTable.vue';
import RouteAddActions from '@/components/ui/route-add-actions/RouteAddActions.vue';

// Every incident of the tenants in scope, the most severe first. A new incident is added with the
// page's Add (also in the menu's context menu).
</script>

<template>
   <section class="flex flex-col gap-4 p-4">
      <div class="flex items-center justify-between gap-4">
         <h2 class="m-0 text-xl font-semibold">{{ $t('ops.incident.title') }}</h2>
         <RouteAddActions name="ops-incident" />
      </div>
      <IncidentTable />
   </section>
</template>
