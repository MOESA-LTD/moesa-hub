import { defineResource, type ResourceInput } from '@/api/defineResource';
import { email, optional, phone, required, requiredText, sensitive } from '@/lib/form/fields';
import * as z from 'zod';

// The company profile of the active tenant: its brands, contacts, warehouses and platform
// accounts. They belong to the tenant, so no row names a customer and the forms send no tenant
// (customFetch adds the active one to every write). The contract terms are relationship data (see
// api/relationship).

type Enums = Db['public']['Enums'];
export type WarehouseType = Enums['warehouse_type'];
export type PlatformAccess = Enums['platform_access'];
export type BrandRow = Tables['brand']['Row'];
export type ContactRow = Tables['contact']['Row'];
export type WarehouseRow = Tables['warehouse']['Row'];
export type PlatformAccountRow = Tables['platform_account']['Row'];

export const WAREHOUSE_TYPES = [
   'own',
   'third_party',
   'fba'
] as const satisfies readonly WarehouseType[];

export const PLATFORM_ACCESSES = [
   'authorized_user',
   'none'
] as const satisfies readonly PlatformAccess[];

export const brandResource = defineResource('brand');
export const contactResource = defineResource('contact');
export const warehouseResource = defineResource('warehouse');
export const platformAccountResource = defineResource('platform_account');

const text = () => optional(z.string().trim());

/** Empty form strings for the given text columns of a row. */
const textValues = <C extends string>(
   columns: readonly C[],
   row?: Partial<Record<C, unknown>> | null
) =>
   Object.fromEntries(columns.map((column) => [column, row?.[column] ?? ''])) as Record<C, string>;

/**
 * The row to save: only the given columns, the id only when editing, empty fields as null. A
 * value the schema never produced (a stale customer_id) is dropped here too.
 */
const toPayload = <T extends { id?: string }>(columns: readonly string[], values: T) => {
   const { id, ...rest } = values as Record<string, unknown> & { id?: string };
   return {
      ...(id ? { id } : {}),
      ...Object.fromEntries(columns.map((column) => [column, rest[column] ?? null]))
   } as { id?: string } & {
      [K in keyof Omit<T, 'id'>]-?: undefined extends T[K] ? Exclude<T[K], undefined> | null : T[K];
   };
};

// --- contacts ---

const CONTACT_COLUMNS = ['name', 'role', 'email', 'phone', 'can_approve'] as const;

export const contactSchema = z.strictObject({
   id: z.string().optional(),
   name: sensitive('contact', 'name', requiredText()),
   role: text(),
   email: optional(email()),
   phone: optional(phone()),
   can_approve: z.boolean()
});

export type ContactFormValues = z.input<typeof contactSchema>;

export const toContactFormValues = (contact?: Partial<ContactRow> | null): ContactFormValues => ({
   id: contact?.id ?? undefined,
   name: contact?.name ?? '',
   can_approve: contact?.can_approve ?? false,
   ...textValues(['role', 'email', 'phone'] as const, contact)
});

export const toContactPayload = (
   contact: z.output<typeof contactSchema>
): ResourceInput<'contact'> => toPayload(CONTACT_COLUMNS, contact);

// --- warehouses ---

const WAREHOUSE_TEXT_COLUMNS = [
   'city',
   'address',
   'postal_code',
   'dock_hours',
   'appointment_rule',
   'pallet_standard',
   'receiving_person'
] as const;

const WAREHOUSE_COLUMNS = [
   'display_name',
   'type',
   'country',
   'is_default',
   ...WAREHOUSE_TEXT_COLUMNS
] as const;

export const warehouseSchema = z.strictObject({
   id: z.string().optional(),
   display_name: requiredText(),
   type: required(z.enum(WAREHOUSE_TYPES)),
   country: z.string().trim().min(1).nullish(),
   city: text(),
   address: text(),
   postal_code: text(),
   dock_hours: text(),
   appointment_rule: text(),
   pallet_standard: text(),
   receiving_person: text(),
   is_default: z.boolean()
});

export type WarehouseFormValues = z.input<typeof warehouseSchema>;

export const toWarehouseFormValues = (
   warehouse?: Partial<WarehouseRow> | null
): WarehouseFormValues => ({
   id: warehouse?.id ?? undefined,
   display_name: warehouse?.display_name ?? '',
   type: warehouse?.type ?? 'own',
   country: warehouse?.country ?? null,
   is_default: warehouse?.is_default ?? false,
   ...textValues(WAREHOUSE_TEXT_COLUMNS, warehouse)
});

export const toWarehousePayload = (
   warehouse: z.output<typeof warehouseSchema>
): ResourceInput<'warehouse'> => toPayload(WAREHOUSE_COLUMNS, warehouse);

// --- platform accounts (no passwords or tokens are kept) ---

const PLATFORM_ACCOUNT_COLUMNS = [
   'platform_id',
   'countries',
   'account_holder',
   'access',
   'notes'
] as const;

export const platformAccountSchema = z.strictObject({
   id: z.string().optional(),
   platform_id: required(z.string().min(1)),
   countries: z.array(z.string()),
   account_holder: text(),
   access: z.enum(PLATFORM_ACCESSES).default('none'),
   notes: text()
});

export type PlatformAccountFormValues = z.input<typeof platformAccountSchema>;

export const toPlatformAccountFormValues = (
   account?: Partial<PlatformAccountRow> | null
): PlatformAccountFormValues => ({
   id: account?.id ?? undefined,
   platform_id: account?.platform_id ?? null,
   countries: account?.countries ?? [],
   access: account?.access ?? 'none',
   ...textValues(['account_holder', 'notes'] as const, account)
});

export const toPlatformAccountPayload = (
   account: z.output<typeof platformAccountSchema>
): ResourceInput<'platform_account'> => toPayload(PLATFORM_ACCOUNT_COLUMNS, account);

// --- brands ---

const BRAND_COLUMNS = [
   'name',
   'registration_status',
   'brand_program_status',
   'gs1_prefix_owner'
] as const;

export const brandSchema = z.strictObject({
   id: z.string().optional(),
   name: requiredText(),
   registration_status: text(),
   brand_program_status: text(),
   gs1_prefix_owner: text()
});

export type BrandFormValues = z.input<typeof brandSchema>;

export const toBrandFormValues = (brand?: Partial<BrandRow> | null): BrandFormValues => ({
   id: brand?.id ?? undefined,
   name: brand?.name ?? '',
   ...textValues(
      ['registration_status', 'brand_program_status', 'gs1_prefix_owner'] as const,
      brand
   )
});

export const toBrandPayload = (brand: z.output<typeof brandSchema>): ResourceInput<'brand'> =>
   toPayload(BRAND_COLUMNS, brand);
