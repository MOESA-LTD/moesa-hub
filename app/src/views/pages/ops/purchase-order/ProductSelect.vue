<script setup lang="ts">
import type { ProductRow } from '@/api/product';
import { useSourcingPrices } from '@/api/sourcing';
import { useLookup } from '@/api/useLookup';

/**
 * Picks a product for an order line: one of the client's products (`clientTenantId`) on a client
 * order, else one of the order's tenant's (`tenantId`, or the form's). Archived products are left
 * out (the selected one is kept, so a saved line still shows it). A pick by the user also emits
 * the product with its purchase price from the order tenant's sourcing row (none without one).
 */
type ProductOption = Pick<ProductRow, 'id' | 'sku' | 'display_name' | 'status'>;
type LineProductOption = ProductOption & {
   purchase_price: number | null;
   purchase_currency: string | null;
   /** The sourcing row the price comes from: a client product's spec sheet is its document. */
   sourcing_id: string | null;
};

const props = defineProps<{ tenantId?: string | null; clientTenantId?: string | null }>();
const model = defineModel<string | null>();
const emit = defineEmits<{ pick: [product: LineProductOption | null] }>();

const { data: products } = useLookup<ProductOption>('product', () => ({
   select: 'id, sku, display_name, status',
   order: 'sku',
   tenantId: props.clientTenantId || props.tenantId
}));
const prices = useSourcingPrices(() => props.tenantId);

const options = computed(() =>
   (products.value ?? [])
      .filter((product) => product.status !== 'archived' || product.id === model.value)
      .map((product) => ({
         value: product.id,
         label: [product.sku, product.display_name].filter(Boolean).join(' — ')
      }))
);

const onChange = ({ value }: { value: string | null }) => {
   const product = products.value?.find(({ id }) => id === value);
   if (!product) return emit('pick', null);
   const price = prices.value.find(({ product_id }) => product_id === value);
   emit('pick', {
      ...product,
      purchase_price: price?.purchase_price ?? null,
      purchase_currency: price?.purchase_currency ?? null,
      sourcing_id: price?.id ?? null
   });
};
</script>

<template>
   <Select
      v-model="model"
      :options
      option-value="value"
      option-label="label"
      filter
      showClear
      :placeholder="$t('ops.product.select')"
      @change="onChange"
   />
</template>
