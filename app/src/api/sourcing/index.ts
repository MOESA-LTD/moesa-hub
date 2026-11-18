import { defineResource, type ResourceInput } from '@/api/defineResource';
import { queryKeys } from '@/api/queryKeys';
import { useLookup } from '@/api/useLookup';
import { useTenantKey } from '@/api/useTenantKey';
import { dateOnly, optional, parseDateOnly, required } from '@/lib/form/fields';
import { supabase } from '@/lib/supabase';
import { useQuery } from '@tanstack/vue-query';
import { computed, toValue, type MaybeRefOrGetter } from 'vue';
import * as z from 'zod';

// A product's sourcing: what the procuring tenant buys it for, from whom and sells it at. One row
// per (procuring tenant, product). A provider procuring for a client keeps its row in its own
// tenant, naming the client (client_tenant_id) and pointing at the client's product; the row keeps
// the product's SKU and name (product_sku, product_name) in case the client deletes it. Cost,
// supplier identity, sell price and the notes are sensitive fields (useFieldAccess('sourcing')).

export type SourcingRow = Tables['sourcing']['Row'];
/** A sourcing row as the product card loads it: with its supplier. */
export type SourcingCard = SourcingRow & {
   supplier: Pick<Tables['supplier']['Row'], 'code' | 'display_name'> | null;
};

export const SOURCING_SELECT = '*, supplier(code, display_name)';

export const sourcingResource = defineResource<'sourcing', SourcingCard>('sourcing', {
   select: SOURCING_SELECT
});

/**
 * The sourcing rows of a product in every tenant in scope, so a provider with both tenants in
 * scope sees its own row next to the client's product (and the client's own, if any). No tenant
 * filter: the scope decides.
 */
export function useSourcing(productId: MaybeRefOrGetter<string | null | undefined>) {
   const tenantKey = useTenantKey();

   return useQuery({
      queryKey: computed(() =>
         queryKeys.list(tenantKey.value, 'sourcing', {
            view: 'product',
            productId: toValue(productId)
         })
      ),
      queryFn: async ({ signal }) => {
         const { data } = await supabase
            .from('sourcing')
            .select(SOURCING_SELECT)
            .eq('product_id', toValue(productId)!)
            .order('created_at')
            .abortSignal(signal)
            .throwOnError();
         return data as unknown as SourcingCard[];
      },
      enabled: computed(() => !!toValue(productId))
   });
}

/** The row of `tenantId` (the procuring tenant whose row is edited) among a product's rows. */
export const ownSourcing = <R extends Pick<SourcingRow, 'tenant_id'>>(
   rows: readonly R[],
   tenantId: string | null | undefined
): R | null => rows.find((row) => row.tenant_id === tenantId) ?? null;

/** A procuring tenant's purchase price of a product, and the row the price comes from. */
export type SourcingPrice = Pick<
   SourcingRow,
   'id' | 'product_id' | 'purchase_price' | 'purchase_currency'
>;

/**
 * The purchase prices of the procuring tenant `tenantId` (an order's tenant), by product: an order
 * line's unit price defaults from them, and a client product's spec sheet is a document of that
 * row (entity_type 'sourcing').
 */
export function useSourcingPrices(tenantId: MaybeRefOrGetter<string | null | undefined>) {
   const { data } = useLookup<SourcingPrice>('sourcing', () => ({
      select: 'id, product_id, purchase_price, purchase_currency',
      tenantId: toValue(tenantId)
   }));
   return computed(() => data.value ?? []);
}

const text = () => optional(z.string().trim());
const amount = () => z.number().min(0).nullable();

const TEXT_COLUMNS = [
   'supplier_product_code',
   'manufacturer_art_no',
   'purchase_incoterm',
   'price_list_version',
   'notes'
] as const;

const NUMBER_COLUMNS = [
   'purchase_price',
   'landed_cost_eur',
   'target_price_eur',
   'sell_price_eur'
] as const;

/** The columns the form edits; the product and the client go with a new row only. */
const EDITABLE_COLUMNS = [
   'supplier_id',
   'purchase_currency',
   'landed_cost_on',
   ...TEXT_COLUMNS,
   ...NUMBER_COLUMNS
] as const;

export const sourcingSchema = z.strictObject({
   id: z.string().optional(),
   product_id: required(z.uuid()),
   client_tenant_id: z.uuid().nullable(),
   supplier_id: optional(z.uuid()),
   supplier_product_code: text(),
   manufacturer_art_no: text(),
   purchase_price: amount(),
   purchase_currency: optional(z.string().regex(/^[A-Z]{3}$/)),
   purchase_incoterm: text(),
   landed_cost_eur: amount(),
   landed_cost_on: optional(dateOnly()),
   target_price_eur: amount(),
   sell_price_eur: amount(),
   price_list_version: text(),
   notes: text()
});

export type SourcingFormValues = z.input<typeof sourcingSchema>;

/**
 * The form of a sourcing row; a new one is for `productId`, naming `clientTenantId` when the
 * product is a client's (null for the tenant's own product).
 */
export const toSourcingFormValues = (
   row: Partial<SourcingRow> | null | undefined,
   { productId, clientTenantId }: { productId: string | null; clientTenantId: string | null }
): SourcingFormValues => ({
   id: row?.id ?? undefined,
   product_id: row?.product_id ?? productId,
   client_tenant_id: row ? (row.client_tenant_id ?? null) : clientTenantId,
   supplier_id: row?.supplier_id ?? null,
   purchase_currency: row?.purchase_currency ?? null,
   landed_cost_on: parseDateOnly(row?.landed_cost_on),
   ...(Object.fromEntries(
      NUMBER_COLUMNS.map((column) => [column, row?.[column] ?? null])
   ) as Record<(typeof NUMBER_COLUMNS)[number], number | null>),
   ...(Object.fromEntries(TEXT_COLUMNS.map((column) => [column, row?.[column] ?? ''])) as Record<
      (typeof TEXT_COLUMNS)[number],
      string
   >)
});

/**
 * The row to save, empty fields as null. The product and the client never change
 * (client_tenant_immutable), so they go with a new row only; the snapshot and the tenant are the
 * database's and customFetch's.
 */
export function toSourcingPayload({
   id,
   product_id,
   client_tenant_id,
   ...values
}: z.output<typeof sourcingSchema>): ResourceInput<'sourcing'> {
   const editable = Object.fromEntries(
      EDITABLE_COLUMNS.map((column) => [column, values[column] ?? null])
   );
   if (id) return { id, ...editable } as ResourceInput<'sourcing'>;
   return { product_id, client_tenant_id, ...editable } as ResourceInput<'sourcing'>;
}
