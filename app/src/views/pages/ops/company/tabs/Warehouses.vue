<script setup lang="ts">
import { canInsertFields } from '@/composables/useFieldAccess';
import type { ResourceTableProps } from '@/components/service-components/resource-table/ResourceTable.vue';
import { createFilters } from '@/components/service-components/resource-table/createFilters';
import { useDeleteAction } from '@/composables/useDeleteAction';
import { DIALOG_POSITIONS } from '@/constants/router';

// Where the active tenant's goods are delivered; added and edited in a dialog.

type Props = ResourceTableProps<'warehouse'>;

const router = useRouter();
const { t } = useI18n();

const columns = computed<Props['columns']>(() => [
   {
      field: 'display_name',
      sortable: true,
      header: t('ops.company.warehouse.fields.display_name')
   },
   { field: 'type', sortable: true, header: t('ops.company.warehouse.fields.type') },
   { field: 'country', sortable: true, header: t('ops.company.warehouse.fields.country') },
   { field: 'city', sortable: true, header: t('ops.company.warehouse.fields.city') },
   { field: 'is_default', header: t('ops.company.warehouse.fields.is_default') }
]);

const filters = ref<NonNullable<Props['filters']>>(createFilters({ display_name: 'text' }));

const deleteAction = useDeleteAction('warehouse');
const rowActions: Props['rowActions'] = [
   deleteAction,
   {
      label: t('action.edit'),
      icon: PrimeIcons.PENCIL,
      requires: { action: 'modify', subject: 'warehouse' },
      command:
         ({ data }) =>
         () =>
            router.push({
               name: 'ops-company-warehouse-edit',
               params: { id: data.id },
               query: { showDialog: DIALOG_POSITIONS.CENTER }
            })
   }
];
</script>

<template>
   <ResourceTable
      stateKey="company-warehouse"
      from="warehouse"
      select="*"
      :useMeta="false"
      :columns
      :rowActions
      :rows="10"
      :enableExpansion="false"
      v-model:filters="filters"
   >
      <template #header>
         <span class="flex items-center justify-between gap-4">
            <span class="font-semibold">{{ $t('ops.company.tabs.warehouses') }}</span>
            <CustomLink
               v-if="$can('create', 'warehouse') && canInsertFields('warehouse')"
               :to="{
                  name: 'ops-company-warehouse-add',
                  query: { showDialog: DIALOG_POSITIONS.CENTER }
               }"
            >
               <template #default="{ navigate }">
                  <Button variant="outlined" :label="$t('action.add')" @click="navigate" />
               </template>
            </CustomLink>
         </span>
      </template>
      <template #type_body="{ data }">
         {{ $t(`ops.company.warehouse.type.${data.type}`) }}
      </template>
      <template #is_default_body="{ data }">
         <i v-if="data.is_default" :class="PrimeIcons.CHECK" />
      </template>
   </ResourceTable>
</template>
