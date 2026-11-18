<script setup lang="ts">
import { useAmazonAccounts } from '@/api/amazon';
import { matrixCounts, useMarketCells, type MarketCellRow } from '@/api/marketMatrix';
import { DIALOG_POSITIONS } from '@/constants/router';
import { useAbility } from '@casl/vue';

// The market matrix (S05) of the tenants in scope: the pivot of products by platform and country,
// or the cells as a list (?view=list).
type View = 'matrix' | 'list';

const route = useRoute();
const router = useRouter();
const { t } = useI18n();
const ability = useAbility();
const authStore = useAuthStore();

const view = computed<View>({
   get: () => (route.query.view === 'list' ? 'list' : 'matrix'),
   set: (value) => router.replace({ query: { ...route.query, view: value } })
});
const viewOptions = computed(() => [
   { value: 'matrix', label: t('ops.market.view.matrix') },
   { value: 'list', label: t('ops.market.view.list') }
]);

/** The matrix narrowed to one platform; none shows every platform. */
const platformId = ref<string | null>(null);

const {
   data: cells,
   isPending,
   isError
} = useMarketCells(() => ({ platformId: platformId.value }));

// Per tenant of the shown cells: its live cells against its target ones.
const counters = computed(() => {
   const names = new Map(authStore.branches.map(({ id, display_name }) => [id, display_name]));
   return Object.entries(
      matrixCounts((cells.value ?? []) as Pick<MarketCellRow, 'tenant_id' | 'status'>[])
   ).map(([tenantId, { live, target }]) => ({
      tenantId,
      label: t('ops.market.counter', { code: names.get(tenantId) ?? '', live, target })
   }));
});

const canCreate = computed(() => ability.can('create', 'market_cell'));

// N2: an Amazon cell of a tenant without a connected account shows draft. Without the right to
// read the accounts the stored states are shown (undefined); while they load, none (null).
const canReadAccounts = computed(() => ability.can('select', 'platform_account'));
const { data: amazonAccounts } = useAmazonAccounts(() => (canReadAccounts.value ? {} : null));
const amazonConnected = computed(() => {
   if (!canReadAccounts.value) return undefined;
   if (!amazonAccounts.value) return null;
   return amazonAccounts.value
      .filter((account) => account.api_connection === 'connected')
      .map((account) => account.tenant_id);
});

const dialog = { showDialog: DIALOG_POSITIONS.CENTER };

const openCell = (id: string) =>
   router.push({ name: 'ops-market-cell-edit', params: { id }, query: dialog });

const addCell = (cell: { productId: string; platformId: string; country: string }) =>
   router.push({
      name: 'ops-market-cell-add',
      query: {
         ...dialog,
         product_id: cell.productId,
         platform_id: cell.platformId,
         country: cell.country
      }
   });

const addCells = () => router.push({ name: 'ops-market-cells-add', query: dialog });
</script>

<template>
   <section class="flex flex-col gap-4 p-4">
      <div class="flex flex-wrap items-center gap-4">
         <h2 class="m-0 text-xl font-semibold">{{ $t('ops.market.title') }}</h2>
         <SelectButton
            v-model="view"
            :options="viewOptions"
            option-value="value"
            option-label="label"
            :allow-empty="false"
         />
         <span class="flex-1" />
         <Button
            v-if="canCreate"
            variant="outlined"
            :icon="PrimeIcons.PLUS"
            :label="$t('ops.market.add_cells')"
            @click="addCells"
         />
      </div>
      <template v-if="view === 'matrix'">
         <div class="flex flex-wrap items-center gap-2">
            <SelectPlatform v-model="platformId" show-clear class="w-56" />
            <Tag
               v-for="counter in counters"
               :key="counter.tenantId"
               :value="counter.label"
               severity="secondary"
            />
         </div>
         <MarketMatrixGrid
            :cells="cells ?? []"
            :canCreate
            :amazonConnected
            :loading="isPending"
            :error="isError"
            @open="openCell"
            @add="addCell"
         />
      </template>
      <MarketCellTable v-else />
   </section>
</template>
