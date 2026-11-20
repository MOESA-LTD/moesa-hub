<script setup lang="ts">
import type { ProductRow } from '@/api/product';
import { productsToLink, projectResource, useLinkProduct, useUnlinkProduct } from '@/api/project';
import { useLookup } from '@/api/useLookup';
import { appErrorHandler } from '@/lib/appErrorHandler';

// The products the project is about: linked from its tenant's products, several at once (a picked
// family parent brings its variants), unlinked at will. The links come embedded in the card's
// cached project.
const props = defineProps<{ id: string }>();

type ProductOption = Pick<ProductRow, 'id' | 'sku' | 'display_name' | 'parent_id'>;

const { data: project } = projectResource.useOne(() => props.id);

const linked = computed(() =>
   (project.value?.project_product ?? []).flatMap(({ product }) => (product ? [product] : []))
);

const { data: products } = useLookup<ProductOption>(
   'product',
   () => ({
      select: 'id, sku, display_name, parent_id',
      order: 'sku',
      in: { column: 'tenant_id', values: [project.value?.tenant_id] }
   }),
   () => !!project.value
);

const label = (product: ProductOption) =>
   [product.sku, product.display_name].filter(Boolean).join(' — ');

const linkedIds = computed(() => new Set(linked.value.map(({ id }) => id)));

const options = computed(() =>
   (products.value ?? [])
      .filter(({ id }) => !linkedIds.value.has(id))
      .map((product) => ({ value: product.id, label: label(product) }))
);

const selected = ref<string[]>([]);
/** A picked family parent brings its variants too. */
const withVariants = ref(true);
const toLink = computed(() =>
   productsToLink(selected.value, products.value ?? [], linkedIds.value, withVariants.value)
);

const { mutateAsync: link, isPending: isLinking } = useLinkProduct();
const { mutateAsync: unlink } = useUnlinkProduct();

const linkSelected = async () => {
   const current = project.value;
   if (!current || !toLink.value.length) return;
   await link(
      toLink.value.map((productId) => ({
         project_id: current.id,
         product_id: productId,
         tenant_id: current.tenant_id
      }))
   ).then(() => (selected.value = []), appErrorHandler);
};

const unlinkProduct = (productId: string) =>
   unlink({ projectId: props.id, productId }).catch(appErrorHandler);
</script>

<template>
   <div class="flex flex-col gap-4">
      <span v-if="$can('create', 'project_product')" class="flex flex-wrap items-center gap-2">
         <MultiSelect
            v-model="selected"
            :options
            option-value="value"
            option-label="label"
            filter
            showClear
            :maxSelectedLabels="3"
            :placeholder="$t('ops.product.select')"
            class="flex-1 min-w-64"
            data-project-products-pick
         />
         <label class="flex items-center gap-2">
            <Checkbox v-model="withVariants" binary data-project-products-variants />
            {{ $t('ops.project.products.with_variants') }}
         </label>
         <Button
            :icon="PrimeIcons.LINK"
            :label="
               toLink.length
                  ? $t('ops.project.products.link_count', { count: toLink.length }, toLink.length)
                  : $t('ops.project.products.link')
            "
            :disabled="!toLink.length"
            :loading="isLinking"
            data-project-products-link
            @click="linkSelected"
         />
      </span>

      <DataTable :value="linked" dataKey="id" size="small">
         <template #empty>{{ $t('ops.project.products.empty') }}</template>
         <Column field="sku" :header="$t('ops.product.fields.sku')" />
         <Column field="display_name" :header="$t('ops.product.fields.display_name')" />
         <Column v-if="$can('modify', 'project_product')" class="w-0">
            <template #body="{ data }">
               <Button
                  variant="text"
                  severity="danger"
                  :icon="PrimeIcons.TIMES"
                  :label="$t('ops.project.products.unlink')"
                  @click="unlinkProduct(data.id)"
               />
            </template>
         </Column>
      </DataTable>
   </div>
</template>
