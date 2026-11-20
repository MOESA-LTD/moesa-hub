<script setup lang="ts">
import ChangeRequestTable from '@/components/service-components/change-request-table/ChangeRequestTable.vue';
import RouteAddActions from '@/components/ui/route-add-actions/RouteAddActions.vue';

// Every change request of the tenants in scope.
// A new one is added with the page's Add (also in the menu's context menu).
</script>

<template>
   <section class="flex flex-col gap-4 p-4">
      <div class="flex items-center justify-between gap-4">
         <h2 class="m-0 text-xl font-semibold">{{ $t('ops.change_request.title') }}</h2>
         <RouteAddActions name="ops-change-request" />
      </div>
      <ChangeRequestTable />
   </section>
</template>
