<script setup lang="ts">
import { canInsertFields } from '@/composables/useFieldAccess';
import type { ResourceTableProps } from '@/components/service-components/resource-table/ResourceTable.vue';
import { createFilters } from '@/components/service-components/resource-table/createFilters';
import { useDeleteAction } from '@/composables/useDeleteAction';
import { DIALOG_POSITIONS } from '@/constants/router';

// The people of the active tenant; added and edited in a dialog.

type Props = ResourceTableProps<'contact'>;

const router = useRouter();
const { t } = useI18n();

const columns = computed<Props['columns']>(() => [
   { field: 'name', sortable: true, header: t('ops.company.contact.fields.name') },
   { field: 'role', sortable: true, header: t('ops.company.contact.fields.role') },
   { field: 'email', header: t('ops.company.contact.fields.email') },
   { field: 'phone', header: t('ops.company.contact.fields.phone') },
   { field: 'can_approve', header: t('ops.company.contact.fields.can_approve') }
]);

const filters = ref<NonNullable<Props['filters']>>(createFilters({ name: 'text' }));

const deleteAction = useDeleteAction('contact');
const rowActions: Props['rowActions'] = [
   deleteAction,
   {
      label: t('action.edit'),
      icon: PrimeIcons.PENCIL,
      requires: { action: 'modify', subject: 'contact' },
      command:
         ({ data }) =>
         () =>
            router.push({
               name: 'ops-company-contact-edit',
               params: { id: data.id },
               query: { showDialog: DIALOG_POSITIONS.CENTER }
            })
   }
];
</script>

<template>
   <ResourceTable
      stateKey="company-contact"
      from="contact"
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
            <span class="font-semibold">{{ $t('ops.company.tabs.contacts') }}</span>
            <CustomLink
               v-if="$can('create', 'contact') && canInsertFields('contact')"
               :to="{
                  name: 'ops-company-contact-add',
                  query: { showDialog: DIALOG_POSITIONS.CENTER }
               }"
            >
               <template #default="{ navigate }">
                  <Button variant="outlined" :label="$t('action.add')" @click="navigate" />
               </template>
            </CustomLink>
         </span>
      </template>
      <template #can_approve_body="{ data }">
         <i v-if="data.can_approve" :class="PrimeIcons.CHECK" />
      </template>
   </ResourceTable>
</template>
