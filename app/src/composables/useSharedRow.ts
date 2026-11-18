import { useProviderNames } from '@/api/relationship';
import { CLIENT_VISIBLE_FIELDS } from '@/constants/clientVisible';
import { useAuthStore } from '@/store/auth';
import { computed } from 'vue';

/** A row of a table a provider may share: its own tenant, and the client it is shared with. */
export type SharedRowLike = { tenant_id?: string | null; client_tenant_id?: string | null };

/**
 * Whether `row` is a provider's row shared with the user's side: its tenant is none of the tenants
 * in scope, and its client is one of them. The database reads such a row through the client tenant
 * (client_select), masks every provider-only field and refuses every write (067). A row of a tenant
 * in scope is the user's own, even with a client: provider staff with both tenants in scope work on
 * it as the provider.
 */
export const isSharedRow = (
   row: SharedRowLike | null | undefined,
   scope: ReadonlySet<string>
): boolean =>
   !!row?.tenant_id &&
   !scope.has(row.tenant_id) &&
   !!row.client_tenant_id &&
   scope.has(row.client_tenant_id);

export type ClientVisibleTable = keyof typeof CLIENT_VISIBLE_FIELDS;

/** Whether a client tenant reads `field` of a shared `table` (every other column reads NULL). */
export const isClientVisible = (table: string, field: string): boolean =>
   ((CLIENT_VISIBLE_FIELDS as Record<string, readonly string[]>)[table] ?? []).includes(field);

/**
 * The columns of a list of shared `table` rows: those of client-visible fields, and the `derived`
 * columns of the list's view that only show client-visible data. The others would read empty, so
 * they are left out rather than shown as blanks.
 */
export const clientVisibleColumns = <C extends { field?: unknown }>(
   table: string,
   columns: readonly C[],
   derived: readonly string[] = []
): C[] =>
   columns.filter(
      ({ field }) =>
         typeof field !== 'string' || isClientVisible(table, field) || derived.includes(field)
   );

/**
 * Shared rows on the client side: `isShared` tells a provider's row shared with a tenant in scope
 * (see isSharedRow), `providerName` names its provider (provider_relationship.provider_name, which
 * the client reads), or null for a row that is not shared.
 */
export function useSharedRow() {
   const authStore = useAuthStore();
   const scope = computed(() => new Set((authStore.scopeTenants ?? []).map(({ id }) => id)));
   const { data: relationships } = useProviderNames();

   const isShared = (row: SharedRowLike | null | undefined) => isSharedRow(row, scope.value);

   const providerName = (row: SharedRowLike | null | undefined): string | null => {
      if (!row || !isShared(row)) return null;
      return (
         relationships.value?.find(
            (r) => r.tenant_id === row.tenant_id && r.client_tenant_id === row.client_tenant_id
         )?.provider_name ?? null
      );
   };

   return { isShared, providerName };
}
