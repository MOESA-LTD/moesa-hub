<script setup lang="ts">
import { productResource } from '@/api/product';
import { useClientOptions, useProviderProcures } from '@/api/relationship';
import { ownSourcing, useSourcing, type SourcingCard } from '@/api/sourcing';
import { canInsertFields, useFieldAccess } from '@/composables/useFieldAccess';
import { useAuthStore } from '@/store/auth';
import { useAbility } from '@casl/vue';
import SourcingForm from './SourcingForm.vue';

// The product's sourcing: the active tenant's row in a form, and the rows of the other tenants in
// scope read-only beside it (a provider with both tenants in scope sees its own row next to the
// client's). The active tenant adds a row for the product if it has none: for its own product, or
// for a client's under an active provider-procures relationship. On a provider's row for a
// client's product, the provider keeps its own spec sheet as a document of that row. In a company
// its provider procures for, procurement data is kept in the provider's company: the tab says so
// and adds no row here.
const props = defineProps<{ id: string }>();

const authStore = useAuthStore();
const ability = useAbility();
const { canRead } = useFieldAccess('sourcing');

const { data: product } = productResource.useOne(() => props.id);
const { data: rows, isPending } = useSourcing(() => props.id);

const activeTenantId = computed(() => authStore.currentTenant?.id ?? null);
const own = computed(() => ownSourcing(rows.value ?? [], activeTenantId.value));
const others = computed(() => (rows.value ?? []).filter((row) => row !== own.value));

/** The client a new row names: the product's tenant when it is not the active one. */
const clientTenantId = computed(() =>
   product.value && product.value.tenant_id !== activeTenantId.value
      ? product.value.tenant_id
      : null
);
const clientOptions = useClientOptions();
const providerProcures = useProviderProcures();

/** Why the active tenant cannot add a row, if it cannot. */
const blocked = computed(() => {
   if (providerProcures.value) return 'provider_procures';
   if (!ability.can('create', 'sourcing') || !canInsertFields('sourcing')) return 'forbidden';
   if (
      clientTenantId.value &&
      !clientOptions.value.some(({ value }) => value === clientTenantId.value)
   )
      return 'no_relationship';
   return null;
});

// Opened by "add"; a saved row is then the active tenant's own.
const adding = ref(false);
watch(own, (row) => {
   if (row) adding.value = false;
});

const { t } = useI18n();
const tenantName = (row: SourcingCard) =>
   authStore.scopeTenants.find(({ id }) => id === row.tenant_id)?.display_name ??
   t('ops.product.sourcing.other_company');

/** The read-only facts of another tenant's row, those the user may read. */
const facts = (row: SourcingCard) =>
   [
      { field: 'supplier_id', value: row.supplier?.code },
      {
         field: 'purchase_price',
         value:
            row.purchase_price === null
               ? null
               : `${row.purchase_price} ${row.purchase_currency ?? ''}`.trim()
      },
      { field: 'landed_cost_eur', value: row.landed_cost_eur },
      { field: 'target_price_eur', value: row.target_price_eur },
      { field: 'sell_price_eur', value: row.sell_price_eur }
   ].filter(({ field }) => canRead(field));
</script>

<template>
   <div class="flex flex-col gap-6">
      <Message
         v-if="providerProcures"
         severity="info"
         :closable="false"
         data-sourcing-provider-procures
      >
         {{ $t('ops.product.sourcing.kept_by_provider') }}
      </Message>
      <section>
         <SourcingForm
            v-if="own || adding"
            :key="own?.id ?? 'new'"
            :id="own?.id ?? null"
            :productId="id"
            :clientTenantId="own ? own.client_tenant_id : clientTenantId"
         />
         <div v-else-if="!isPending" class="flex flex-col items-start gap-2" data-sourcing-empty>
            <p class="m-0 text-muted-color">{{ $t('ops.product.sourcing.none') }}</p>
            <Button
               v-if="!blocked"
               :label="$t('ops.product.sourcing.add')"
               icon="pi pi-plus"
               size="small"
               data-sourcing-add
               @click="adding = true"
            />
            <small v-else-if="blocked === 'no_relationship'" class="text-muted-color">
               {{ $t('ops.product.sourcing.no_relationship') }}
            </small>
         </div>
      </section>

      <!-- The provider's own spec sheet of a client's product (a document of its row). -->
      <section v-if="own?.client_tenant_id && product" data-sourcing-documents>
         <h3 class="m-0 mb-2 text-base font-semibold">
            {{ $t('ops.product.sourcing.spec_sheets') }}
         </h3>
         <EntityDocuments entityType="sourcing" :entityId="own.id" :code="product.sku" />
      </section>

      <section v-if="others.length" data-sourcing-others>
         <h3 class="m-0 mb-2 text-base font-semibold">{{ $t('ops.product.sourcing.others') }}</h3>
         <div v-for="row in others" :key="row.id" class="mb-3">
            <div class="font-medium">{{ tenantName(row) }}</div>
            <dl class="m-0 grid grid-cols-[auto_1fr] gap-x-3 text-sm">
               <template v-for="fact in facts(row)" :key="fact.field">
                  <dt class="text-muted-color">{{ $t(`ops.product.fields.${fact.field}`) }}</dt>
                  <dd class="m-0">{{ fact.value ?? '—' }}</dd>
               </template>
            </dl>
         </div>
      </section>
   </div>
</template>
