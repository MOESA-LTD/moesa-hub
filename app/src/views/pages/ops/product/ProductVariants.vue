<script setup lang="ts">
import type { ProductStatus } from '@/api/product';
import { useVariants } from '@/api/product/variants';
import MediaThumb from '@/components/service-components/media/MediaThumb.vue';
import { DIALOG_POSITIONS } from '@/constants/router';

// A parent product's variants, shown under its row in the product list's tree view.
const props = defineProps<{
   parentId: string;
   statusSeverity: Record<ProductStatus, string>;
}>();

const { data: variants, isPending } = useVariants(() => props.parentId);
</script>

<template>
   <DataTable
      :value="variants ?? []"
      :loading="isPending"
      dataKey="id"
      size="small"
      data-product-variants
   >
      <template #empty>{{ $t('ops.product.variants.none') }}</template>
      <Column class="w-0">
         <template #body="{ data }">
            <MediaThumb :path="data.primary_image_path" :alt="data.display_name" :size="32" />
         </template>
      </Column>
      <Column field="sku" :header="$t('ops.product.fields.sku')" />
      <Column field="display_name" :header="$t('ops.product.fields.display_name')" />
      <Column field="variant_label" :header="$t('ops.product.fields.variant_label')" />
      <Column field="gtin" :header="$t('ops.product.fields.gtin')" />
      <Column :header="$t('ops.product.fields.status')">
         <template #body="{ data }">
            <Tag
               :value="$t(`ops.product.status.${data.status}`)"
               :severity="statusSeverity[data.status as ProductStatus]"
            />
         </template>
      </Column>
      <Column class="w-0">
         <template #body="{ data }">
            <CustomLink
               :to="{
                  name: 'ops-product-manage',
                  params: { id: data.id },
                  query: { showDialog: DIALOG_POSITIONS.CENTER }
               }"
            >
               <template #default="{ navigate }">
                  <Button
                     variant="text"
                     :icon="PrimeIcons.PENCIL"
                     :aria-label="$t('action.edit')"
                     @click="navigate"
                  />
               </template>
            </CustomLink>
         </template>
      </Column>
   </DataTable>
</template>
