import { defineResource } from '@/api/defineResource';
import { useFormTenant } from '@/api/formTenant';
import { queryKeys } from '@/api/queryKeys';
import { useLookup } from '@/api/useLookup';
import { useTenantKey } from '@/api/useTenantKey';
import { publicSchema, supabase } from '@/lib/supabase';
import { useAuthStore } from '@/store/auth';
import { useQuery } from '@tanstack/vue-query';
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

/** What a project's link (a new order opened from a project) says about the order's client. */
export type LinkedClient =
   | { status: 'pending' }
   | { status: 'own' }
   | { status: 'client'; clientTenantId: string }
   | { status: 'forbidden' };

/**
 * The client of a new order of `tenantId` opened from a project of `projectTenantId` (undefined
 * while loading, null when the project cannot be read): none for the tenant's own project, the
 * project's tenant when it is an active provider-procures client of `tenantId`, else forbidden
 * (the database would refuse it: relationship_inactive).
 */
export function linkedClient(
   projectTenantId: string | null | undefined,
   tenantId: string | null | undefined,
   relationships: readonly ClientRelationship[] | undefined
): LinkedClient {
   if (projectTenantId === undefined) return { status: 'pending' };
   if (projectTenantId && projectTenantId === tenantId) return { status: 'own' };
   if (!projectTenantId) return { status: 'forbidden' };
   if (!relationships) return { status: 'pending' };
   return toClientOptions(relationships, tenantId).some(({ value }) => value === projectTenantId)
      ? { status: 'client', clientTenantId: projectTenantId }
      : { status: 'forbidden' };
}

/**
 * The client of a new order opened from project `projectId` (see linkedClient). The project is
 * read in every tenant in scope, as the page that linked it showed it. Nothing is read without a
 * project.
 */
export function useLinkedClient(
   projectId: MaybeRefOrGetter<string | null | undefined>,
   tenantId: MaybeRefOrGetter<string | null | undefined>
) {
   const tenantKey = useTenantKey();
   const { data: project, isPending } = useQuery({
      queryKey: computed(() =>
         queryKeys.detail(tenantKey.value, 'project', `tenant:${toValue(projectId)}`)
      ),
      queryFn: async ({ signal }) => {
         const { data } = await supabase
            .from('project')
            .select('id, tenant_id')
            .eq('id', toValue(projectId)!)
            .abortSignal(signal)
            .maybeSingle()
            .throwOnError();
         return data;
      },
      enabled: computed(() => !!toValue(projectId))
   });
   const { data: relationships } = useLookup<ClientRelationship>(
      'provider_relationship',
      { select: CLIENT_RELATIONSHIP_SELECT, order: 'client_code' },
      () => !!toValue(projectId)
   );
   return computed(() =>
      linkedClient(
         isPending.value ? undefined : (project.value?.tenant_id ?? null),
         toValue(tenantId),
         relationships.value
      )
   );
}

/** How one of the active tenant's relationships as a client procures (public.client_procurement). */
export type ClientProcurement = Pick<RelationshipRow, 'procurement_model' | 'status'>;

/** Whether a provider procures for the client: an active provider-procures relationship. */
export const isProviderProcured = (rows: readonly ClientProcurement[]) =>
   rows.some((row) => row.status === 'active' && row.procurement_model === 'provider');

/**
 * Whether a provider procures for the active tenant. Its procurement data (cost, supplier) is then
 * kept in the provider's company, not here (the database refuses a sourcing row here:
 * sourcing_in_client_forbidden). Read through public.client_procurement, since the client side
 * cannot read the provider's relationship row.
 */
export function useProviderProcures() {
   const tenantKey = useTenantKey();
   const { data } = useQuery({
      queryKey: computed(() =>
         queryKeys.detail(tenantKey.value, 'provider_relationship', 'client_procurement')
      ),
      queryFn: async () => {
         const { data } = await publicSchema.rpc('client_procurement').throwOnError();
         return data ?? [];
      }
   });
   return computed(() => isProviderProcured(data.value ?? []));
}
