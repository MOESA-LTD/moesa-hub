<script setup lang="ts">
import PurchaseOrderTable from '@/components/service-components/purchase-order-table/PurchaseOrderTable.vue';
import RouteAddActions from '@/components/ui/route-add-actions/RouteAddActions.vue';

// Every purchase order of the tenants in scope.
// A new one is added with the page's Add (also in the menu's context menu).
</script>

<template>
   <section class="flex flex-col gap-4 p-4">
      <div class="flex items-center justify-between gap-4">
         <h2 class="m-0 text-xl font-semibold">{{ $t('ops.purchase_order.title') }}</h2>
         <RouteAddActions name="ops-purchase-order" />
      </div>
      <PurchaseOrderTable />
   </section>
</template>
