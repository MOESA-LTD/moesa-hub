<script setup lang="ts">
import { canInsertFields } from '@/composables/useFieldAccess';
import type { ResourceTableProps } from '@/components/service-components/resource-table/ResourceTable.vue';
import { createFilters } from '@/components/service-components/resource-table/createFilters';
import { useDeleteAction } from '@/composables/useDeleteAction';
import { DIALOG_POSITIONS } from '@/constants/router';

// The brands of the active tenant; added and edited in a dialog.

type Props = ResourceTableProps<'brand'>;

const router = useRouter();
const { t } = useI18n();

const columns = computed<Props['columns']>(() => [
   { field: 'name', sortable: true, header: t('ops.company.brand.fields.name') },
   {
      field: 'registration_status',
      header: t('ops.company.brand.fields.registration_status')
   },
   {
      field: 'brand_program_status',
      header: t('ops.company.brand.fields.brand_program_status')
   },
   { field: 'gs1_prefix_owner', header: t('ops.company.brand.fields.gs1_prefix_owner') }
]);

const filters = ref<NonNullable<Props['filters']>>(createFilters({ name: 'text' }));

const deleteAction = useDeleteAction('brand');
const rowActions: Props['rowActions'] = [
   deleteAction,
   {
      label: t('action.edit'),
      icon: PrimeIcons.PENCIL,
      requires: { action: 'modify', subject: 'brand' },
      command:
         ({ data }) =>
         () =>
            router.push({
               name: 'ops-company-brand-edit',
               params: { id: data.id },
               query: { showDialog: DIALOG_POSITIONS.CENTER }
            })
   }
];
</script>

<template>
   <ResourceTable
      stateKey="company-brand"
      from="brand"
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
            <span class="font-semibold">{{ $t('ops.company.tabs.brands') }}</span>
            <CustomLink
               v-if="$can('create', 'brand') && canInsertFields('brand')"
               :to="{
                  name: 'ops-company-brand-add',
                  query: { showDialog: DIALOG_POSITIONS.CENTER }
               }"
            >
               <template #default="{ navigate }">
                  <Button variant="outlined" :label="$t('action.add')" @click="navigate" />
               </template>
            </CustomLink>
         </span>
      </template>
   </ResourceTable>
</template>
