<script setup lang="ts">
import { useEndRelationship, type RelationshipRow } from '@/api/relationship';
import type { ResourceTableProps } from '@/components/service-components/resource-table/ResourceTable.vue';
import { useConfirmAction } from '@/composables/useConfirmAction';
import { clientVisibleColumns } from '@/composables/useSharedRow';
import { DIALOG_POSITIONS } from '@/constants/router';
import { useAuthStore } from '@/store/auth';
import { ToastSeverity } from '@primevue/core/api';
import { useToast } from 'primevue/usetoast';

// The relationships of the active tenant, both sides on one page: its clients (rows it owns as the
// provider) and its providers (rows that name it as the client). A client reads only what its
// provider shares, so that list has fewer columns and its terms cannot be edited.
type Props = ResourceTableProps<'provider_relationship'>;

const authStore = useAuthStore();
const router = useRouter();
const { t } = useI18n();
const toast = useToast();
const confirmAction = useConfirmAction();
const { mutateAsync: end } = useEndRelationship();

const activeId = computed(() => authStore.currentTenant?.id ?? null);

// The split follows the tenants in scope (as isSharedRow does) and is no table state: it is not
// stored or put in the URL, so a tenant switch always recomputes it. Clients are the rows of a
// tenant in scope; providers are the rows that name one as the client, of a tenant outside it.
const scopeIds = computed(() => authStore.scopeTenants.map(({ id }) => id));
const clientFixed = computed(() => [{ column: 'tenant_id', in: scopeIds.value }]);
const providerFixed = computed(() => [
   { column: 'client_tenant_id', in: scopeIds.value },
   { column: 'tenant_id', notIn: scopeIds.value }
]);

const header = (field: string) => t(`ops.client.fields.${field}`);

const clientColumns = computed<Props['columns']>(() => [
   { field: 'client_code', sortable: true, header: header('client_code') },
   { field: 'client_name', sortable: true, header: header('client_name') },
   { field: 'procurement_model', sortable: true, header: header('procurement_model') },
   { field: 'contract_status', sortable: true, header: header('contract_status') },
   { field: 'commercial_model', sortable: true, header: header('commercial_model') },
   { field: 'deposit_rate', sortable: true, header: header('deposit_rate') },
   { field: 'status', sortable: true, header: header('status') },
   { field: 'notes', header: header('notes') },
   { field: 'restricted_drive_url', header: header('restricted_drive_url') }
]);

// What a client reads of its provider's row: the client-visible columns only.
const providerColumns = computed<Props['columns']>(() =>
   clientVisibleColumns(
      'provider_relationship',
      [
         { field: 'provider_name', sortable: true, header: header('provider_name') },
         { field: 'procurement_model', sortable: true, header: header('procurement_model') },
         { field: 'contract_status', sortable: true, header: header('contract_status') },
         { field: 'commercial_model', sortable: true, header: header('commercial_model') },
         { field: 'deposit_rate', sortable: true, header: header('deposit_rate') },
         { field: 'status', sortable: true, header: header('status') }
      ],
      ['provider_name']
   )
);

const open = (id: string) =>
   router.push({
      name: 'ops-client-manage',
      params: { id },
      query: { showDialog: DIALOG_POSITIONS.CENTER }
   });

const endAction = (
   nameOf: (row: RelationshipRow) => string | null
): NonNullable<Props['rowActions']>[number] => ({
   label: t('ops.client.end.action'),
   icon: PrimeIcons.BAN,
   severity: 'danger',
   visible: ({ data }) => data.status === 'active',
   command:
      ({ data }) =>
      async () => {
         const ended = await confirmAction({
            header: t('ops.client.end.title', { name: nameOf(data) }),
            message: t('ops.client.end.message'),
            acceptLabel: t('ops.client.end.accept'),
            accept: () => end(data.id!)
         });
         if (!ended) return;
         toast.add({
            life: 3000,
            severity: ToastSeverity.SUCCESS,
            summary: t('toast.success'),
            detail: t('ops.client.end.done')
         });
      }
});

const clientActions: Props['rowActions'] = [
   {
      label: t('action.edit'),
      icon: PrimeIcons.PENCIL,
      command:
         ({ data }) =>
         () =>
            open(data.id!)
   },
   {
      ...endAction((row) => row.client_name),
      requires: { action: 'modify', subject: 'provider_relationship' }
   }
];

// The client's owner may end it; the database decides (relationship_end_forbidden).
const providerActions: Props['rowActions'] = [
   {
      label: t('action.view'),
      icon: PrimeIcons.EYE,
      command:
         ({ data }) =>
         () =>
            open(data.id!)
   },
   endAction((row) => row.provider_name)
];

const SEVERITY = { active: 'success', ended: 'secondary' } as const;
</script>
<template>
   <div :key="activeId ?? undefined" class="flex flex-col gap-8">
      <section>
         <h2 class="mb-2 text-lg font-semibold">{{ $t('ops.client.sections.clients') }}</h2>
         <ResourceTable
            stateKey="provider_relationship_clients"
            from="provider_relationship"
            select="*"
            :columns="clientColumns"
            :rowActions="clientActions"
            :enableExpansion="false"
            :fixedFilters="clientFixed"
         >
            <template #empty>{{ $t('ops.client.empty.clients') }}</template>
            <template #procurement_model_body="{ data }">
               {{ $t(`ops.client.procurement_model.${data.procurement_model}`) }}
            </template>
            <template #contract_status_body="{ data }">
               {{ $t(`ops.client.contract_status.${data.contract_status}`) }}
            </template>
            <template #commercial_model_body="{ data }">
               {{
                  data.commercial_model
                     ? $t(`ops.client.commercial_model.${data.commercial_model}`)
                     : '—'
               }}
            </template>
            <template #status_body="{ data }">
               <Tag
                  :value="$t(`ops.client.status.${data.status}`)"
                  :severity="SEVERITY[data.status as 'active' | 'ended']"
               />
            </template>
         </ResourceTable>
      </section>
      <section>
         <h2 class="mb-2 text-lg font-semibold">{{ $t('ops.client.sections.providers') }}</h2>
         <ResourceTable
            stateKey="provider_relationship_providers"
            from="provider_relationship"
            select="*"
            :columns="providerColumns"
            :rowActions="providerActions"
            :enableExpansion="false"
            :fixedFilters="providerFixed"
         >
            <template #empty>{{ $t('ops.client.empty.providers') }}</template>
            <template #procurement_model_body="{ data }">
               {{ $t(`ops.client.procurement_model.${data.procurement_model}`) }}
            </template>
            <template #contract_status_body="{ data }">
               {{ $t(`ops.client.contract_status.${data.contract_status}`) }}
            </template>
            <template #commercial_model_body="{ data }">
               {{
                  data.commercial_model
                     ? $t(`ops.client.commercial_model.${data.commercial_model}`)
                     : '—'
               }}
            </template>
            <template #status_body="{ data }">
               <Tag
                  :value="$t(`ops.client.status.${data.status}`)"
                  :severity="SEVERITY[data.status as 'active' | 'ended']"
               />
            </template>
         </ResourceTable>
      </section>
   </div>
</template>
