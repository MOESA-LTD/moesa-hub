<script setup lang="ts">
import {
   SHIPMENT_MODES,
   SHIPMENT_STATUSES,
   SHIPMENT_STATUS_SEVERITY,
   etaState,
   useShipmentIds,
   type ShipmentStatus
} from '@/api/shipment';
import type { ResourceTableProps } from '@/components/service-components/resource-table/ResourceTable.vue';
import {
   createFilters,
   equalsFilter,
   type FilterSpec
} from '@/components/service-components/resource-table/createFilters';
import { clientVisibleColumns, useSharedRow } from '@/composables/useSharedRow';
import { DIALOG_POSITIONS } from '@/constants/router';
import dayjs from 'dayjs';

// Shipments (public.shipment_overview) of the tenants in scope, optionally only those carrying some
// orders or a product. Embedded in another card (with filters), the table keeps its state for the
// session only. A provider's shipment shared with the client side (useSharedRow) is tagged with its
// provider and opens read-only. When every row shown is shared, the columns are the client-visible
// ones (the others would read empty), with the tracking (carrier, container) added.
type Props = ResourceTableProps<'shipment_overview'>;

const props = defineProps<{
   filters?: { purchaseOrderIds?: string[]; productId?: string };
}>();

const router = useRouter();
const { t } = useI18n();

const embedded = computed(() => !!props.filters);
const narrowed = computed(() => !!props.filters?.purchaseOrderIds || !!props.filters?.productId);

// The shipments of the orders or the product. Until they are known, or when there are none, the
// table is not shown: an empty IN filter is skipped and would match every shipment.
const { data: shipmentIds } = useShipmentIds(() => ({
   ...(props.filters?.purchaseOrderIds ? { purchaseOrderIds: props.filters.purchaseOrderIds } : {}),
   ...(props.filters?.productId ? { productId: props.filters.productId } : {})
}));
const showTable = computed(() => !narrowed.value || (shipmentIds.value?.length ?? 0) > 0);

const enumFilterColumn = {
   showFilterMatchModes: false,
   showFilterOperator: false,
   showAddButton: false
};

const { isShared, providerName } = useSharedRow();
const rows = ref<Views['shipment_overview']['Row'][]>([]);
const allShared = computed(() => rows.value.length > 0 && rows.value.every(isShared));

// The derived columns of the overview that show client-visible data only: the client's own
// warehouse and the shipment's order codes.
const SHARED_DERIVED = ['warehouse_name', 'purchase_order_codes'];

const allColumns = computed<Props['columns']>(() => [
   {
      field: 'code',
      sortable: true,
      sortOrder: { value: -1 },
      header: t('ops.shipment.fields.code')
   },
   { field: 'client_code', sortable: true, header: t('ops.shipment.fields.client') },
   {
      field: 'warehouse_name',
      sortable: true,
      header: t('ops.shipment.fields.delivery_warehouse')
   },
   { field: 'mode', sortable: true, header: t('ops.shipment.fields.mode'), ...enumFilterColumn },
   {
      field: 'status',
      sortable: true,
      header: t('ops.shipment.fields.status'),
      ...enumFilterColumn
   },
   { field: 'etd', sortable: true, header: t('ops.shipment.fields.etd') },
   { field: 'eta', sortable: true, header: t('ops.shipment.fields.eta') },
   ...(allShared.value
      ? [
           { field: 'carrier', sortable: true, header: t('ops.shipment.fields.carrier') },
           { field: 'container_no', header: t('ops.shipment.fields.container_no') }
        ]
      : []),
   { field: 'purchase_order_codes', header: t('ops.shipment.fields.purchase_orders') }
]);

const columns = computed<Props['columns']>(() =>
   allShared.value
      ? clientVisibleColumns('shipment', allColumns.value ?? [], SHARED_DERIVED)
      : allColumns.value
);

const idFilter = (ids: readonly string[]) => ({
   operator: FilterOperator.AND,
   constraints: [{ value: [...ids], matchMode: FilterMatchMode.IN }]
});

// The keyword search reads the shipment code only; the enum and id filter columns, compared
// as text, would fail the request.
const KEYWORD_COLUMNS = ['code'] as const;
const tableFilters = ref<NonNullable<Props['filters']>>(
   createFilters({
      code: 'startsWith',
      status: equalsFilter(),
      mode: equalsFilter(),
      ...(narrowed.value ? { id: idFilter([]) as FilterSpec } : {})
   })
);

// Set before the table mounts (it shows once the ids are there) and kept current after.
watch(
   shipmentIds,
   (ids) => {
      if (narrowed.value && ids) tableFilters.value.id = idFilter(ids);
   },
   { immediate: true }
);

const today = dayjs().format('YYYY-MM-DD');
const isLate = (row: { eta: string | null; status: ShipmentStatus | null }) =>
   !!row.status && etaState({ eta: row.eta, status: row.status }, today) === 'late';

// A shared shipment opens read-only: viewed, not edited.
const rowActions: Props['rowActions'] = [
   {
      label: ({ data }) => (isShared(data) ? t('action.view') : t('action.edit')),
      icon: ({ data }) => (isShared(data) ? PrimeIcons.EYE : PrimeIcons.PENCIL),
      command:
         ({ data }) =>
         async () =>
            router.push({
               name: 'ops-shipment-manage',
               params: { id: data.id },
               query: { showDialog: DIALOG_POSITIONS.CENTER }
            })
   }
];
</script>

<template>
   <ResourceTable
      v-if="showTable"
      stateKey="shipment"
      from="shipment_overview"
      select="*"
      :useMeta="!embedded"
      :columns
      :rowActions
      :enableExpansion="false"
      v-model:filters="tableFilters"
      v-model="rows"
      :keywordColumns="KEYWORD_COLUMNS"
   >
      <template #header>
         <KeywordSearchInput v-model="tableFilters.global.value" />
      </template>
      <template #code_body="{ data }">
         <span class="inline-flex flex-wrap items-center gap-2">
            {{ data.code }}
            <SharedTag v-if="isShared(data)" :provider="providerName(data)" />
         </span>
      </template>
      <template #mode_body="{ data }">
         {{ data.mode ? $t(`ops.shipment.mode.${data.mode}`) : '' }}
      </template>
      <template #mode_filter="{ filterModel }">
         <SelectEnum
            v-model="filterModel.value"
            :values="SHIPMENT_MODES"
            i18n-prefix="ops.shipment.mode"
            glossary="shipment_mode"
         />
      </template>
      <template #status_body="{ data }">
         <Tag
            v-if="data.status"
            :value="$t(`ops.shipment.status.${data.status}`)"
            :severity="SHIPMENT_STATUS_SEVERITY[data.status as ShipmentStatus]"
         />
      </template>
      <template #status_filter="{ filterModel }">
         <SelectEnum
            v-model="filterModel.value"
            :values="SHIPMENT_STATUSES"
            i18n-prefix="ops.shipment.status"
            glossary="shipment_status"
         />
      </template>
      <template #eta_body="{ data }">
         <Tag v-if="isLate(data)" data-test="eta-late" severity="danger" :value="data.eta" />
         <template v-else>{{ data.eta }}</template>
      </template>
      <template #purchase_order_codes_body="{ data }">
         {{ (data.purchase_order_codes ?? []).join(', ') }}
      </template>
   </ResourceTable>
   <p v-else class="m-0 p-4 text-muted-color">{{ $t('ops.shipment.no_rows') }}</p>
</template>
