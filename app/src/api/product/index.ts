import { allValues } from '@/lib/enumValues';
import { defineResource, type ResourceInput } from '@/api/defineResource';
import { dateOnly, optional, parseDateOnly, requiredText } from '@/lib/form/fields';
import { gtinValid } from '@/lib/gtin';
import i18n from '@plugins/i18n';
import * as z from 'zod';

type Enums = Db['public']['Enums'];
export type ProductStatus = Enums['product_status'];
export type ComplianceStatus = Enums['compliance_status'];
export type ProductRow = Tables['product']['Row'];
export type ProductEvidenceRow = Views['product_evidence']['Row'];
/** A row of the product list: the product and its evidence. */
export type ProductListRow = Views['product_with_evidence']['Row'];

/**
 * The product list's Spec filter from the route's query (`?spec=true|false`, e.g. from the
 * dashboard's unsigned SKU card): whether the product must have a signed spec sheet, or null when
 * the query does not say.
 */
export const specFilterFromQuery = (query: Record<string, unknown>): boolean | null => {
   const value = Array.isArray(query.spec) ? query.spec[0] : query.spec;
   if (value === 'true') return true;
   if (value === 'false') return false;
   return null;
};

export const PRODUCT_STATUSES = allValues<ProductStatus>()([
   'concept',
   'development',
   'approved',
   'ordering',
   'on_sale',
   'paused',
   'archived'
]);

export const COMPLIANCE_STATUSES = [
   'none',
   'partial',
   'complete'
] as const satisfies readonly ComplianceStatus[];

export const PURCHASE_CURRENCIES = ['EUR', 'USD', 'CNY', 'TRY'] as const;

/** Capital letters, digits and dashes, e.g. THO-MOP40-2P. Unique within the tenant. */
export const PRODUCT_SKU = /^[A-Z0-9-]+$/;

export const productResource = defineResource('product', {
   select: '*'
});

const text = () => optional(z.string().trim());
const amount = () => z.number().min(0).nullable();
const quantity = () => z.number().int().min(0).nullable();
const invalidGtin = { error: () => i18n.t('errors.invalid_gtin') };

const TEXT_COLUMNS = [
   'variant_label',
   'category',
   'brand',
   'gs1_prefix_owner',
   'golden_sample_locations',
   'eu_responsible_person',
   'hs_code',
   'unit_dims_mm',
   'pack_dims_mm',
   'carton_dims_mm',
   'pallet_type',
   'lot_rule',
   'notes'
] as const;

const NUMBER_COLUMNS = [
   'unit_net_g',
   'pack_qty',
   'pack_gross_g',
   'carton_pack_qty',
   'carton_net_kg',
   'carton_gross_kg',
   'pallet_carton_qty'
] as const;

export const productSchema = z.object({
   id: z.string().optional(),
   parent_id: optional(z.uuid()),
   sku: requiredText()
      .toUpperCase()
      .regex(PRODUCT_SKU, { error: () => i18n.t('ops.product.errors.invalid_sku') }),
   display_name: requiredText(),
   variant_label: text(),
   category: text(),
   brand: text(),
   // A malformed GTIN reports once: the check digit is checked only on 8, 12, 13 or 14 digits.
   gtin: optional(
      z
         .string()
         .trim()
         .regex(/^\d{8}$|^\d{12,14}$/, { ...invalidGtin, abort: true })
         .refine(gtinValid, invalidGtin)
   ),
   gs1_prefix_owner: text(),
   status: z.enum(PRODUCT_STATUSES).default('concept'),
   golden_sample_on: optional(dateOnly()),
   golden_sample_locations: text(),
   is_hazmat: z.boolean().default(false),
   compliance_status: z.enum(COMPLIANCE_STATUSES).default('none'),
   eu_responsible_person: text(),
   hs_code: text(),
   origin_country: z.string().trim().min(1).nullish(),
   // Dimensions and weights, from unit to pallet.
   unit_dims_mm: text(),
   unit_net_g: amount(),
   pack_qty: quantity(),
   pack_dims_mm: text(),
   pack_gross_g: amount(),
   carton_pack_qty: quantity(),
   carton_dims_mm: text(),
   carton_net_kg: amount(),
   carton_gross_kg: amount(),
   pallet_carton_qty: quantity(),
   pallet_type: text(),
   lot_rule: text(),
   notes: text()
});

export type ProductFormValues = z.input<typeof productSchema>;

export const toProductFormValues = (product?: Partial<ProductRow> | null): ProductFormValues => ({
   id: product?.id ?? undefined,
   parent_id: product?.parent_id ?? null,
   sku: product?.sku ?? '',
   display_name: product?.display_name ?? '',
   gtin: product?.gtin ?? '',
   status: product?.status ?? 'concept',
   compliance_status: product?.compliance_status ?? 'none',
   is_hazmat: product?.is_hazmat ?? false,
   golden_sample_on: parseDateOnly(product?.golden_sample_on),
   origin_country: product?.origin_country ?? null,
   ...(Object.fromEntries(
      NUMBER_COLUMNS.map((column) => [column, product?.[column] ?? null])
   ) as Record<(typeof NUMBER_COLUMNS)[number], number | null>),
   ...(Object.fromEntries(
      TEXT_COLUMNS.map((column) => [column, product?.[column] ?? ''])
   ) as Record<(typeof TEXT_COLUMNS)[number], string>)
});

/** The row to save: the id only when editing, empty fields as null. */
export const toProductPayload = ({
   id,
   ...values
}: z.output<typeof productSchema>): ResourceInput<'product'> => ({
   ...(id ? { id } : {}),
   ...(Object.fromEntries(
      Object.entries(values).map(([column, value]) => [column, value ?? null])
   ) as typeof values)
});
