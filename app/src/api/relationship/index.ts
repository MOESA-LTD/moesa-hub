import { defineResource } from '@/api/defineResource';
import { useFormTenant } from '@/api/formTenant';
import { useLookup } from '@/api/useLookup';
import { useAuthStore } from '@/store/auth';
import { computed, toValue, type MaybeRefOrGetter } from 'vue';

export * from './constants';

// The provider relationship: the provider tenant (tenant_id) works for a client tenant
// (client_tenant_id). When the provider procures, its orders, shipments and sourcing rows may name
// the client; the database lets them only under an active provider-procures relationship
// (relationship_inactive).

type Enums = Db['public']['Enums'];
export type ProcurementModel = Enums['procurement_model'];
export type RelationshipStatus = Enums['relationship_status'];
export type RelationshipRow = Tables['provider_relationship']['Row'];

export const relationshipResource = defineResource('provider_relationship');

/** What a client picker reads of a relationship. */
export type ClientRelationship = Pick<
   RelationshipRow,
   'tenant_id' | 'client_tenant_id' | 'client_code' | 'client_name' | 'procurement_model' | 'status'
>;

export const CLIENT_RELATIONSHIP_SELECT =
   'tenant_id, client_tenant_id, client_code, client_name, procurement_model, status';

export type ClientOption = {
   value: string;
   label: string;
   procurement_model: ProcurementModel;
   status: RelationshipStatus;
};

/**
 * The clients `tenantId` may name on a new record: its active provider-procures relationships, by
 * client code. `keep` (the client a saved record names) stays listed whatever its relationship's
 * state, so the record still shows it.
 */
export const toClientOptions = (
   rows: readonly ClientRelationship[],
   tenantId: string | null | undefined,
   keep?: string | null
): ClientOption[] =>
   rows
      .filter(
         (row) =>
            row.tenant_id === tenantId &&
            ((row.status === 'active' && row.procurement_model === 'provider') ||
               (!!keep && row.client_tenant_id === keep))
      )
      .sort((a, b) => a.client_code.localeCompare(b.client_code))
      .map((row) => ({
         value: row.client_tenant_id,
         label: `${row.client_code} · ${row.client_name}`,
         procurement_model: row.procurement_model,
         status: row.status
      }));

/**
 * The client options of the active tenant (inside a form, the form's tenant): see toClientOptions.
 * A client tenant reads its relationships too, as the client; they are not its own.
 */
export function useClientOptions(keep: MaybeRefOrGetter<string | null | undefined> = null) {
   const authStore = useAuthStore();
   const formTenant = useFormTenant();
   const { data } = useLookup<ClientRelationship>('provider_relationship', {
      select: CLIENT_RELATIONSHIP_SELECT,
      order: 'client_code'
   });
   return computed(() =>
      toClientOptions(
         data.value ?? [],
         formTenant?.value ?? authStore.currentTenant?.id,
         toValue(keep)
      )
   );
}
