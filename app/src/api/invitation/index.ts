import { defineResource } from '@/api/defineResource';
import { invalidateTables } from '@/api/queryKeys';
import { useLookup } from '@/api/useLookup';
import { COMMERCIAL_MODELS, CONTRACT_STATUSES, PACKAGES } from '@/api/relationship/constants';
import { allValues } from '@/lib/enumValues';
import { dateOnly, optional } from '@/lib/form/fields';
import { publicSchema, supabase } from '@/lib/supabase';
import i18n from '@plugins/i18n';
import { FunctionsHttpError } from '@supabase/supabase-js';
import { useAuthStore } from '@/store/auth';
import { useMutation, useQueryClient } from '@tanstack/vue-query';
import { computed } from 'vue';
import * as z from 'zod';

// A provider's invitations to its clients (decision 16). The list reads api.provider_invitation and
// api.provider_invitation_staff; there is no token or hash in either: the token is minted by the
// database, mailed as a link and forgotten. Create and resend go through the provider-invitation
// function (it sends the mail); revoke is a database function.

type Enums = Db['public']['Enums'];
export type InvitationRow = Tables['provider_invitation']['Row'];
export type InvitationStaffRow = Tables['provider_invitation_staff']['Row'];
export type ProcurementModelValue = Enums['procurement_model'];
export type InvitationStatus = Enums['invitation_status'];
/** What an invitation is shown as: a pending one past its expiry is expired. */
export type InvitationState = 'pending' | 'expired' | 'accepted' | 'revoked';

export const invitationResource = defineResource('provider_invitation');

/** An invitation is made with the client procuring or the provider procuring for it. */
export const INVITATION_PROCUREMENT_MODELS = allValues<ProcurementModelValue>()([
   'client',
   'provider'
]);

/** The roles invited staff get in the new client tenant (the database checks them too). */
export const INVITATION_STAFF_ROLES = ['management', 'coordinator', 'viewer'] as const;
export type InvitationStaffRole = (typeof INVITATION_STAFF_ROLES)[number];

/** The most staff an invitation may carry (the database and the function check it too). */
export const MAX_INVITATION_STAFF = 20;

/** The state an invitation is shown in; `now` is injected so the list and tests agree. */
export const invitationState = (
   row: Pick<InvitationRow, 'status' | 'expires_at'>,
   now: Date = new Date()
): InvitationState => {
   if (row.status === 'accepted' || row.status === 'revoked') return row.status;
   return row.expires_at && new Date(row.expires_at).getTime() <= now.getTime()
      ? 'expired'
      : 'pending';
};

/** Resend and revoke apply to an invitation that has not been accepted or revoked. */
export const canActOnInvitation = (state: InvitationState) =>
   state === 'pending' || state === 'expired';

const text = () => optional(z.string().trim());

export const invitationSchema = z.object({
   email: z
      .string({ error: () => i18n.t('form.required') })
      .trim()
      .toLowerCase()
      .min(1)
      .pipe(z.email({ error: () => i18n.t('errors.invalid_email') })),
   company_name: z
      .string({ error: () => i18n.t('form.required') })
      .trim()
      .min(3),
   client_code: z
      .string({ error: () => i18n.t('form.required') })
      .trim()
      .toUpperCase()
      .regex(/^[A-Z]{3}$/, { error: () => i18n.t('ops.client.invitation.invalid_code') }),
   procurement_model: z.enum(INVITATION_PROCUREMENT_MODELS),
   commercial_model: z.enum(COMMERCIAL_MODELS).nullable(),
   packages: z.array(z.enum(PACKAGES)),
   contract_status: z.enum(CONTRACT_STATUSES),
   start_on: optional(dateOnly()),
   deposit_rate: z.number().min(0).max(100).nullable(),
   extra_cost_rule: text(),
   eu_responsible_person: text(),
   recommended_plan_id: z.string().uuid().nullable(),
   staff: z
      .array(
         z.object({
            user_id: z.string().uuid(),
            role_name: z.enum(INVITATION_STAFF_ROLES)
         })
      )
      .max(MAX_INVITATION_STAFF)
});

export type InvitationFormValues = z.input<typeof invitationSchema>;
export type InvitationValues = z.output<typeof invitationSchema>;

/** A new invitation's form: the client procures, and the contract starts in onboarding. */
export const toInvitationFormValues = (): InvitationFormValues => ({
   email: '',
   company_name: '',
   client_code: '',
   procurement_model: 'client',
   commercial_model: null,
   packages: [],
   contract_status: 'onboarding',
   start_on: null,
   deposit_rate: null,
   extra_cost_rule: '',
   eu_responsible_person: '',
   recommended_plan_id: null,
   staff: []
});

/**
 * The body the provider-invitation function takes: `{ invitation, staff }`. The invitation names
 * only what the database allows (never a token, tenant or id); an empty term is left out so the
 * database default applies.
 */
export const toInvitationBody = ({ staff, ...invitation }: InvitationValues) => ({
   invitation: Object.fromEntries(
      Object.entries(invitation).filter(
         ([, value]) => value != null && !(Array.isArray(value) && value.length === 0)
      )
   ) as { email: string } & Record<string, unknown>,
   staff: staff.map(({ user_id, role_name }) => ({ user_id, role_name }))
});

/**
 * A refusal of the function as an error that names its code (its message, as in a database error)
 * so a field can show it (mapPostgrestError) or the error handler can toast it. Without a code in
 * the body, the HTTP status stands in.
 */
const named = async (error: unknown) => {
   if (!(error instanceof FunctionsHttpError)) return error;
   const body = await error.context
      .clone()
      .json()
      .catch(() => null);
   if (typeof body?.message !== 'string') return error;
   return Object.assign(new Error(body.message), {
      name: 'PostgrestError',
      code: typeof body.code === 'string' ? body.code : String(error.context.status),
      details: null
   });
};

const call = async <T>(path: string, body: object) => {
   const { data, error } = await supabase.functions.invoke<T>(path, { method: 'POST', body });
   if (error) throw await named(error);
   return data as T;
};

/** Creates an invitation and mails its link. The caller never sees the token. */
export const createInvitation = (values: InvitationValues) =>
   call<{ id: string }>('provider-invitation', toInvitationBody(values));

/** Mails the invitation's link again under a new token (the old one stops working). */
export const resendInvitation = (id: string) =>
   call<{ id: string }>(`provider-invitation/${id}/resend`, {});

/** Revokes a pending invitation. */
export const revokeInvitation = async (id: string) => {
   await publicSchema.rpc('revoke_provider_invitation', { invitation_id: id }).throwOnError();
};

const TABLES = ['provider_invitation', 'provider_invitation_staff'] as const;

export function useCreateInvitation() {
   const queryClient = useQueryClient();
   return useMutation({
      mutationFn: createInvitation,
      onSuccess: () => invalidateTables(queryClient, [...TABLES])
   });
}

export function useResendInvitation() {
   const queryClient = useQueryClient();
   return useMutation({
      mutationFn: resendInvitation,
      onSuccess: () => invalidateTables(queryClient, [...TABLES])
   });
}

export function useRevokeInvitation() {
   const queryClient = useQueryClient();
   return useMutation({
      mutationFn: revokeInvitation,
      onSuccess: () => invalidateTables(queryClient, [...TABLES])
   });
}

type Member = Pick<Views['tenant_member']['Row'], 'id' | 'email' | 'user_metadata'>;

export type StaffOption = { value: string; label: string };

/** A member as the staff picker names them: their display name, else their e-mail. */
export const toStaffOptions = (members: readonly Member[]): StaffOption[] => {
   const seen = new Set<string>();
   return members
      .flatMap((member) => {
         if (!member.id || seen.has(member.id)) return [];
         seen.add(member.id);
         const name = (member.user_metadata as { display_name?: string } | null)?.display_name;
         return [{ value: member.id, label: name || member.email || member.id }];
      })
      .sort((a, b) => a.label.localeCompare(b.label));
};

/** The members of the active tenant (the provider), who may be invited along as staff. */
export function useStaffOptions() {
   const authStore = useAuthStore();
   const { data } = useLookup<Member>(
      'tenant_member',
      () => ({
         select: 'id, email, user_metadata',
         tenantId: authStore.currentTenant?.id
      }),
      () => !!authStore.currentTenant?.id
   );
   return computed(() => toStaffOptions(data.value ?? []));
}
