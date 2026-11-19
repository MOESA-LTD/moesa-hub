import { defineResource, type ResourceInput } from '@/api/defineResource';
import { useFormTenant } from '@/api/formTenant';
import { invalidateTables, queryKeys } from '@/api/queryKeys';
import { useLookup } from '@/api/useLookup';
import { useTenantKey } from '@/api/useTenantKey';
import { dateOnly, optional, parseDateOnly, website } from '@/lib/form/fields';
import { publicSchema, supabase } from '@/lib/supabase';
import { useAuthStore } from '@/store/auth';
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query';
import { computed, toValue, type MaybeRefOrGetter } from 'vue';
import * as z from 'zod';
import { COMMERCIAL_MODELS, CONTRACT_STATUSES, PACKAGES } from './constants';

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

/** What a client side reads of a provider's relationship with it: who the provider is. */
export type ProviderName = Pick<
   RelationshipRow,
   'tenant_id' | 'client_tenant_id' | 'provider_name'
>;

/**
 * The relationships readable in scope with their provider's name: the active tenant's as a provider
 * and, shared with it as the client (provider_name is client-visible), its providers'. Read with
 * the request's own scope, never a form's tenant, so a shared row's card names its provider too.
 */
export function useProviderNames() {
   const tenantKey = useTenantKey();
   return useQuery({
      queryKey: computed(() => queryKeys.detail(tenantKey.value, 'provider_relationship', 'mine')),
      queryFn: async ({ signal }) => {
         const { data } = await supabase
            .from('provider_relationship')
            .select('tenant_id, client_tenant_id, provider_name')
            .abortSignal(signal)
            .throwOnError();
         return (data ?? []) as ProviderName[];
      },
      enabled: computed(() => !!tenantKey.value)
   });
}

/**
 * Which side of a relationship the user is on, by the tenants in scope (as isSharedRow does): the
 * provider when the row's tenant is one of them, else the client.
 */
export const relationshipSide = (
   row: Pick<RelationshipRow, 'tenant_id'>,
   scope: ReadonlySet<string>
): 'provider' | 'client' => (!!row.tenant_id && scope.has(row.tenant_id) ? 'provider' : 'client');

/**
 * The procurement models a relationship may be set to. Only an invitation starts a relationship as
 * provider-procured: the database refuses client to provider (procurement_model_widen_forbidden),
 * so a client-procured one offers its own value alone.
 */
export const procurementModelChoices = (current: ProcurementModel): ProcurementModel[] =>
   current === 'provider' ? ['provider', 'client'] : ['client'];

/**
 * Ends a relationship, for good: no new shared orders or shipments; everything shared before stays
 * and no membership changes. The provider side or the client's owner may end it (the database
 * decides: relationship_end_forbidden).
 */
export const endRelationship = async (id: string) => {
   await publicSchema.rpc('end_provider_relationship', { relationship_id: id }).throwOnError();
};

export function useEndRelationship() {
   const queryClient = useQueryClient();
   return useMutation({
      mutationFn: endRelationship,
      onSuccess: () => invalidateTables(queryClient, ['provider_relationship'])
   });
}

const text = () => optional(z.string().trim());

/** What the provider side edits of a relationship: its contract terms, procurement model and notes. */
export const relationshipSchema = z.object({
   id: z.string().optional(),
   procurement_model: z.enum(['client', 'provider']),
   commercial_model: z.enum(COMMERCIAL_MODELS).nullable(),
   packages: z.array(z.enum(PACKAGES)),
   contract_status: z.enum(CONTRACT_STATUSES),
   start_on: optional(dateOnly()),
   deposit_rate: z.number().min(0).max(100).nullable(),
   extra_cost_rule: text(),
   eu_responsible_person: text(),
   notes: text(),
   restricted_drive_url: optional(website())
});

export type RelationshipFormValues = z.input<typeof relationshipSchema>;

export const toRelationshipFormValues = (
   row?: Partial<RelationshipRow> | null
): RelationshipFormValues => ({
   id: row?.id ?? undefined,
   procurement_model: row?.procurement_model ?? 'client',
   commercial_model: row?.commercial_model ?? null,
   packages: (row?.packages ?? []) as (typeof PACKAGES)[number][],
   contract_status: row?.contract_status ?? 'onboarding',
   start_on: parseDateOnly(row?.start_on),
   deposit_rate: row?.deposit_rate ?? null,
   extra_cost_rule: row?.extra_cost_rule ?? '',
   eu_responsible_person: row?.eu_responsible_person ?? '',
   notes: row?.notes ?? '',
   restricted_drive_url: row?.restricted_drive_url ?? ''
});

/** The row to save; empty fields as null. The companies, code and status are never sent. */
export const toRelationshipPayload = ({
   id,
   ...terms
}: z.output<typeof relationshipSchema>): ResourceInput<'provider_relationship'> =>
   ({
      ...(id ? { id } : {}),
      ...Object.fromEntries(Object.entries(terms).map(([key, value]) => [key, value ?? null]))
   }) as ResourceInput<'provider_relationship'>;
