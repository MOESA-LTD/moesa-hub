import { queryKeys } from '@/api/queryKeys';
import { useTenantKey } from '@/api/useTenantKey';
import { supabase } from '@/lib/supabase';
import { useQuery } from '@tanstack/vue-query';
import { computed, toValue, type MaybeRefOrGetter } from 'vue';

// A product family: a parent product and its variants (product.parent_id), for the product list's
// tree view.

/** How many variants each parent has, from the variants' parent ids. */
export const variantCounts = (rows: readonly { parent_id: string | null }[]) => {
   const counts = new Map<string, number>();
   for (const { parent_id } of rows) {
      if (parent_id) counts.set(parent_id, (counts.get(parent_id) ?? 0) + 1);
   }
   return counts;
};

/** Rows per request when reading the variants' parent ids: the API's max_rows cap. */
export const VARIANT_PAGE_SIZE = 1000;

/** The number of variants of every parent in scope (one column of the variants only). The API
 * returns at most VARIANT_PAGE_SIZE rows a request, so the ids are read page by page. */
export async function fetchVariantCounts(signal: AbortSignal) {
   const rows: { parent_id: string | null }[] = [];
   for (let from = 0; ; from += VARIANT_PAGE_SIZE) {
      const { data } = await supabase
         .from('product')
         .select('parent_id')
         .not('parent_id', 'is', null)
         .order('id')
         .range(from, from + VARIANT_PAGE_SIZE - 1)
         .abortSignal(signal)
         .throwOnError();
      rows.push(...(data ?? []));
      if ((data?.length ?? 0) < VARIANT_PAGE_SIZE) break;
   }
   return variantCounts(rows);
}

export function useVariantCounts(enabled: MaybeRefOrGetter<boolean> = true) {
   const tenantKey = useTenantKey();
   return useQuery({
      queryKey: computed(() =>
         queryKeys.list(tenantKey.value, 'product', { view: 'variant_counts' })
      ),
      queryFn: ({ signal }) => fetchVariantCounts(signal),
      enabled: computed(() => toValue(enabled))
   });
}

/** A parent's variants, by SKU, with the list's evidence columns. */
export function useVariants(parentId: MaybeRefOrGetter<string>) {
   const tenantKey = useTenantKey();
   return useQuery({
      queryKey: computed(() =>
         queryKeys.list(tenantKey.value, 'product_with_evidence', {
            view: 'variants',
            parentId: toValue(parentId)
         })
      ),
      queryFn: async ({ signal }) => {
         const { data } = await supabase
            .from('product_with_evidence')
            .select('*')
            .eq('parent_id', toValue(parentId))
            .order('sku')
            .abortSignal(signal)
            .throwOnError();
         return data ?? [];
      }
   });
}
