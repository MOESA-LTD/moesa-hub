<script setup lang="ts">
import {
   formatAmount,
   PURCHASE_ORDER_CLIENT_STATUSES,
   PURCHASE_ORDER_STATUSES,
   usePurchaseOrderIds
} from '@/api/purchaseOrder';
import type { ResourceTableProps } from '@/components/service-components/resource-table/ResourceTable.vue';
import {
   createFilters,
   equalsFilter,
   type FilterSpec
} from '@/components/service-components/resource-table/createFilters';
import { clientVisibleColumns, useSharedRow } from '@/composables/useSharedRow';
import { DIALOG_POSITIONS } from '@/constants/router';

// Purchase orders (public.purchase_order_overview) of the tenants in scope, optionally of one
// supplier, project or product. Embedded in
// another card (with filters), the table keeps its state for the session only.
// A provider's order shared with the client side (useSharedRow) is tagged with its provider and
// opens read-only; its status is the client status. When every row shown is shared, the columns
// are the client-visible ones (the others would read empty).
type Props = ResourceTableProps<'purchase_order_overview'>;

const props = defineProps<{
   filters?: { supplierId?: string; projectId?: string; productId?: string };
}>();

const router = useRouter();
const { t } = useI18n();

const embedded = computed(() => !!props.filters);
const productId = computed(() => props.filters?.productId);

// The orders with a line of the product. Until they are known, or when there are none, the table
// is not shown: an empty IN filter is skipped and would match every order.
const { data: productOrderIds } = usePurchaseOrderIds(() => ({ productId: productId.value }));
const showTable = computed(() => !productId.value || (productOrderIds.value?.length ?? 0) > 0);

const enumFilterColumn = {
   showFilterMatchModes: false,
   showFilterOperator: false,
   showAddButton: false
};

const { isShared, providerName } = useSharedRow();
const rows = ref<Views['purchase_order_overview']['Row'][]>([]);
const allShared = computed(() => rows.value.length > 0 && rows.value.every(isShared));

// The derived columns of the overview that show client-visible data only.
const SHARED_DERIVED = ['line_count', 'total_quantity'];

const allColumns = computed<Props['columns']>(() => [
   {
      field: 'code',
      sortable: true,
      sortOrder: { value: -1 },
      header: t('ops.purchase_order.fields.code')
   },
   { field: 'client_code', sortable: true, header: t('ops.purchase_order.fields.client') },
   {
      field: 'supplier_id',
      sortField: 'supplier_code',
      sortable: true,
      header: t('ops.purchase_order.fields.supplier'),
      ...enumFilterColumn
   },
   { field: 'project_code', sortable: true, header: t('ops.purchase_order.fields.project') },
   {
      field: allShared.value ? 'client_status' : 'status',
      sortable: true,
      header: t('ops.purchase_order.fields.status'),
      ...enumFilterColumn
   },
   { field: 'ready_on', sortable: true, header: t('ops.purchase_order.fields.ready_on') },
   ...(allShared.value
      ? [{ field: 'total_quantity', header: t('ops.purchase_order.fields.quantity') }]
      : []),
   { field: 'system_total', sortable: true, header: t('ops.purchase_order.fields.total') },
   {
      field: 'deposit_paid_on',
      sortable: true,
      header: t('ops.purchase_order.fields.deposit_paid_on')
   },
   {
      field: 'balance_planned_on',
      sortable: true,
      header: t('ops.purchase_order.fields.balance_planned_on')
   }
]);

const columns = computed<Props['columns']>(() =>
   allShared.value
      ? clientVisibleColumns('purchase_order', allColumns.value ?? [], SHARED_DERIVED)
      : allColumns.value
);

const idFilter = (ids: readonly string[]) => ({
   operator: FilterOperator.AND,
   constraints: [{ value: [...ids], matchMode: FilterMatchMode.IN }]
});

// The keyword search reads the order code only; the enum and id filter columns, compared
// as text, would fail the request.
const KEYWORD_COLUMNS = ['code'] as const;
const filters = ref<NonNullable<Props['filters']>>(
   createFilters({
      code: 'startsWith',
      status: equalsFilter(),
      client_status: equalsFilter(),
      supplier_id: equalsFilter(props.filters?.supplierId ?? null),
      project_id: equalsFilter(props.filters?.projectId ?? null),
      ...(productId.value ? { id: idFilter([]) as FilterSpec } : {})
   })
);

// Set before the table mounts (it shows once the ids are there) and kept current after.
watch(
   productOrderIds,
   (ids) => {
      if (productId.value && ids) filters.value.id = idFilter(ids);
   },
   { immediate: true }
);

// A shared order opens read-only: viewed, not edited.
const rowActions: Props['rowActions'] = [
   {
      label: ({ data }) => (isShared(data) ? t('action.view') : t('action.edit')),
      icon: ({ data }) => (isShared(data) ? PrimeIcons.EYE : PrimeIcons.PENCIL),
      command:
         ({ data }) =>
         async () =>
            router.push({
               name: 'ops-purchase-order-manage',
               params: { id: data.id },
               query: { showDialog: DIALOG_POSITIONS.CENTER }
            })
   }
];
</script>

<template>
   <ResourceTable
      v-if="showTable"
      stateKey="purchase-order"
      from="purchase_order_overview"
      select="*"
      :useMeta="!embedded"
      :columns
      :rowActions
      :enableExpansion="false"
      v-model:filters="filters"
      v-model="rows"
      :keywordColumns="KEYWORD_COLUMNS"
   >
      <template #header>
         <KeywordSearchInput v-model="filters.global.value" />
      </template>
      <template #code_body="{ data }">
         <span class="inline-flex flex-wrap items-center gap-2">
            {{ data.code }}
            <SharedTag v-if="isShared(data)" :provider="providerName(data)" />
         </span>
      </template>
      <template #supplier_id_body="{ data }">{{ data.supplier_code }}</template>
      <template #supplier_id_filter="{ filterModel }">
         <SelectSupplier v-model="filterModel.value" />
      </template>
      <template #status_body="{ data }">
         <OrderStatusTag :order="data" />
      </template>
      <template #client_status_body="{ data }">
         <OrderStatusTag :order="data" />
      </template>
      <template #client_status_filter="{ filterModel }">
         <SelectEnum
            v-model="filterModel.value"
            :values="PURCHASE_ORDER_CLIENT_STATUSES"
            i18n-prefix="ops.purchase_order.client_status"
         />
      </template>
      <template #status_filter="{ filterModel }">
         <SelectEnum
            v-model="filterModel.value"
            :values="PURCHASE_ORDER_STATUSES"
            i18n-prefix="ops.purchase_order.status"
            glossary="purchase_order_status"
         />
      </template>
      <template #system_total_body="{ data }">
         {{ formatAmount(data.system_total, data.currency) }}
      </template>
   </ResourceTable>
   <p v-else class="m-0 p-4 text-muted-color">{{ $t('ops.purchase_order.no_rows') }}</p>
</template>
