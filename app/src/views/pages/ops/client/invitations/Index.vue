<script setup lang="ts">
import {
   canActOnInvitation,
   invitationState,
   useResendInvitation,
   useRevokeInvitation,
   type InvitationRow,
   type InvitationState
} from '@/api/invitation';
import type { ResourceTableProps } from '@/components/service-components/resource-table/ResourceTable.vue';
import { createFilters } from '@/components/service-components/resource-table/createFilters';
import { useConfirmAction } from '@/composables/useConfirmAction';
import { useDialogRef } from '@/composables/useDialogRef';
import { DIALOG_POSITIONS } from '@/constants/router';
import { ToastSeverity } from '@primevue/core/api';
import { useToast } from 'primevue/usetoast';

// The invitations of the active provider: pending ones can be sent again or revoked. The list
// reads no token and no hash (there are none in the view); the e-mail is personal data, so a role
// without that right sees a dash.

// A staff row count embedded from provider_invitation_staff.
type Row = InvitationRow & { staff?: { count: number }[] };
type Props = ResourceTableProps<'provider_invitation', Row>;

defineOptions({
   inheritAttrs: false
});

const attrs = useAttrs();
const { t } = useI18n();
const toast = useToast();
const confirmAction = useConfirmAction();
const { mutateAsync: resend } = useResendInvitation();
const { mutateAsync: revoke } = useRevokeInvitation();

const columns = computed<Props['columns']>(() => [
   { field: 'status', sortable: true, header: t('ops.client.invitation.fields.state') },
   { field: 'email', sortable: true, header: t('ops.client.invitation.fields.email') },
   {
      field: 'company_name',
      sortable: true,
      header: t('ops.client.invitation.fields.company_name')
   },
   { field: 'client_code', sortable: true, header: t('ops.client.invitation.fields.client_code') },
   {
      field: 'procurement_model',
      sortable: true,
      header: t('ops.client.invitation.fields.procurement_model')
   },
   { field: 'expires_at', sortable: true, header: t('ops.client.invitation.fields.expires_at') },
   { field: 'staff', header: t('ops.client.invitation.fields.staff') }
]);

const filters = ref<NonNullable<Props['filters']>>(
   createFilters(
      { email: 'text', company_name: 'text', client_code: 'startsWith' },
      attrs.filters as Props['filters']
   )
);

const SEVERITY: Record<InvitationState, string> = {
   pending: 'info',
   expired: 'warn',
   accepted: 'success',
   revoked: 'secondary'
};

const stateOf = (row: InvitationRow) => invitationState(row);
const staffCount = (row: Row) => row.staff?.[0]?.count ?? 0;

const done = (detail: string) =>
   toast.add({
      life: 3000,
      severity: ToastSeverity.SUCCESS,
      summary: t('toast.success'),
      detail
   });

const rowActions: Props['rowActions'] = [
   {
      label: t('ops.client.invitation.resend.action'),
      icon: PrimeIcons.SEND,
      requires: { action: 'modify', subject: 'provider_invitation' },
      visible: ({ data }) => canActOnInvitation(stateOf(data)),
      command:
         ({ data }) =>
         async () => {
            await resend(data.id);
            done(t('ops.client.invitation.resend.done'));
         }
   },
   {
      label: t('ops.client.invitation.revoke.action'),
      icon: PrimeIcons.BAN,
      severity: 'danger',
      requires: { action: 'modify', subject: 'provider_invitation' },
      visible: ({ data }) => canActOnInvitation(stateOf(data)),
      command:
         ({ data }) =>
         async () => {
            const revoked = await confirmAction({
               header: t('ops.client.invitation.revoke.title'),
               message: t('ops.client.invitation.revoke.message'),
               acceptLabel: t('ops.client.invitation.revoke.action'),
               accept: () => revoke(data.id)
            });
            if (!revoked) return;
            done(t('ops.client.invitation.revoke.done'));
         }
   }
];

const dialogRef = useDialogRef();
</script>
<template>
   <ResourceTable
      v-bind="attrs"
      stateKey="provider_invitation"
      from="provider_invitation"
      select="*, staff:provider_invitation_staff(count)"
      :columns
      :rowActions
      :enableExpansion="false"
      v-model:filters="filters"
   >
      <template #header>
         <Teleport to="#page-toolbar" :disabled="!!dialogRef">
            <span class="flex-1 flex justify-end gap-4 flex-wrap-reverse">
               <KeywordSearchInput v-model="filters.global.value" />
               <CustomLink
                  v-if="$can('create', 'provider_invitation')"
                  :to="{
                     name: 'ops-client-invitation-create',
                     query: { showDialog: DIALOG_POSITIONS.CENTER }
                  }"
               >
                  <template #default="{ navigate }">
                     <Button
                        variant="outlined"
                        :label="$t('ops.client.invitation.add')"
                        @click="navigate"
                     />
                  </template>
               </CustomLink>
            </span>
         </Teleport>
      </template>
      <template #status_body="{ data }">
         <Tag
            :value="$t(`ops.client.invitation.state.${stateOf(data)}`)"
            :severity="SEVERITY[stateOf(data)]"
         />
      </template>
      <template #email_body="{ data }">
         <!-- Personal data: a role without the right reads it as null. -->
         <span>{{ data.email || '—' }}</span>
      </template>
      <template #procurement_model_body="{ data }">
         {{ $t(`ops.client.procurement_model.${data.procurement_model}`) }}
      </template>
      <template #staff_body="{ data }">
         {{ staffCount(data) }}
      </template>
   </ResourceTable>
</template>
