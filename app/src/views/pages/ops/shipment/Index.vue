<script setup lang="ts">
import ShipmentTable from '@/components/service-components/shipment-table/ShipmentTable.vue';
import RouteAddActions from '@/components/ui/route-add-actions/RouteAddActions.vue';

// Every shipment of the tenants in scope.
// A new one is added with the page's Add (also in the menu's context menu).
</script>

<template>
   <section class="flex flex-col gap-4 p-4">
      <div class="flex items-center justify-between gap-4">
         <h2 class="m-0 text-xl font-semibold">{{ $t('ops.shipment.title') }}</h2>
         <RouteAddActions name="ops-shipment" />
      </div>
      <ShipmentTable />
   </section>
</template>
