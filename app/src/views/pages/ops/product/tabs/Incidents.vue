<script setup lang="ts">
import IncidentTable from '@/components/service-components/incident-table/IncidentTable.vue';
import { DIALOG_POSITIONS } from '@/constants/router';

// The incidents linked to the product (each opens its own card), e.g. a barcode or compliance
// problem. A new incident starts with the product filled in.
defineProps<{ id: string }>();
</script>

<template>
   <div class="flex flex-col gap-4">
      <span v-if="$can('create', 'incident')" class="flex justify-end">
         <CustomLink
            :to="{
               name: 'ops-incident-manage',
               query: {
                  entity_type: 'product',
                  entity_id: id,
                  showDialog: DIALOG_POSITIONS.CENTER
               }
            }"
         >
            <template #default="{ navigate }">
               <Button
                  data-test="new-incident"
                  variant="outlined"
                  :icon="PrimeIcons.PLUS"
                  :label="$t('ops.incident.new_for_project')"
                  @click="navigate"
               />
            </template>
         </CustomLink>
      </span>
      <IncidentTable :filters="{ entityType: 'product', entityId: id }" />
   </div>
</template>
