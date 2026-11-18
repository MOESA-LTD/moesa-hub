<script setup lang="ts">
import type { ProductRow } from '@/api/product';
import { useLookup } from '@/api/useLookup';

/**
 * Picks one of the form tenant's products for an order line; archived products are left out (the
 * selected one is kept, so a saved line still shows it). A pick by the user also emits the product
 * with its purchase price from the tenant's sourcing (none when the product has no sourcing row).
 */
type ProductOption = Pick<ProductRow, 'id' | 'sku' | 'display_name' | 'status'>;
type SourcingPrice = Pick<
   Tables['sourcing']['Row'],
   'product_id' | 'purchase_price' | 'purchase_currency'
>;
type LineProductOption = ProductOption & {
   purchase_price: number | null;
   purchase_currency: string | null;
};

const model = defineModel<string | null>();
const emit = defineEmits<{ pick: [product: LineProductOption | null] }>();

const { data: products } = useLookup<ProductOption>('product', {
   select: 'id, sku, display_name, status',
   order: 'sku'
});
const { data: prices } = useLookup<SourcingPrice>('sourcing', {
   select: 'product_id, purchase_price, purchase_currency'
});

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
   const price = prices.value?.find(({ product_id }) => product_id === value);
   emit('pick', {
      ...product,
      purchase_price: price?.purchase_price ?? null,
      purchase_currency: price?.purchase_currency ?? null
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
