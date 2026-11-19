<script setup lang="ts">
import {
   INVITATION_PROCUREMENT_MODELS,
   INVITATION_STAFF_ROLES,
   MAX_INVITATION_STAFF,
   invitationSchema,
   toInvitationFormValues,
   useCreateInvitation,
   useStaffOptions
} from '@/api/invitation';
import { COMMERCIAL_MODELS, CONTRACT_STATUSES, PACKAGES } from '@/api/relationship/constants';
import { usePlans } from '@/api/subscription';
import { useDialogRef } from '@/composables/useDialogRef';
import { useUnsavedChangesGuard } from '@/composables/useUnsavedChangesGuard';
import { useForm } from '@/lib/form/useForm';
import { ToastSeverity } from '@primevue/core/api';
import { useToast } from 'primevue/usetoast';

// A new invitation: who is invited, the contract terms the new relationship starts with, the staff
// of the provider who get access to the new company, and the plan recommended to it. The function
// mails the link; the token is never shown here.
const { t } = useI18n();
const router = useRouter();
const toast = useToast();
const dialogRef = useDialogRef();

const { values, errors, isDirty, isSubmitting, reset, handleSubmit } = useForm({
   schema: invitationSchema,
   initialValues: toInvitationFormValues()
});
useUnsavedChangesGuard(isDirty);

const { mutateAsync: create } = useCreateInvitation();
const staffOptions = useStaffOptions();
const { plans, suspense: plansReady } = usePlans();
await plansReady();

const save = handleSubmit(async (data) => {
   await create(data);
   // The guard must not ask about a form that was just sent.
   reset(values.value);
   toast.add({
      life: 3000,
      severity: ToastSeverity.SUCCESS,
      summary: t('toast.success'),
      detail: t('ops.client.invitation.created')
   });
   if (dialogRef) dialogRef.value.close();
   else router.replace({ name: 'ops-client-invitations' });
});

const commercialModels = computed(() =>
   COMMERCIAL_MODELS.map((value) => ({ value, label: t(`ops.client.commercial_model.${value}`) }))
);

// A member is listed once: the options of a row leave out those another row already took.
const optionsFor = (index: number) =>
   staffOptions.value.filter(
      (option) =>
         option.value === values.value.staff[index]?.user_id ||
         !values.value.staff.some((entry) => entry.user_id === option.value)
   );
const addStaff = () => values.value.staff.push({ user_id: '', role_name: 'viewer' });
const removeStaff = (index: number) => values.value.staff.splice(index, 1);
const atLimit = computed(() => values.value.staff.length >= MAX_INVITATION_STAFF);

const staffError = computed(
   () =>
      errors.value.staff ||
      Object.entries(errors.value).find(([path]) => path.startsWith('staff.'))?.[1]
);
</script>

<template>
   <div class="card">
      <FormBox
         @submit="save"
         @reset="() => reset()"
         v-focustrap
         :dirty="isDirty"
         :submitting="isSubmitting"
      >
         <FormBox :legend="$t('ops.client.invitation.sections.company')" class="!flex-auto">
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.email')"
               :error="errors.email"
               v-slot="slotProps"
            >
               <InputText v-bind="slotProps" v-model="values.email" type="email" />
            </FormField>
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.company_name')"
               :error="errors.company_name"
               v-slot="slotProps"
            >
               <InputText v-bind="slotProps" v-model="values.company_name" />
            </FormField>
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.client_code')"
               :error="errors.client_code"
               v-slot="slotProps"
            >
               <InputText
                  v-bind="slotProps"
                  v-model="values.client_code"
                  maxlength="3"
                  placeholder="THO"
               />
            </FormField>
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.procurement_model')"
               :error="errors.procurement_model"
               v-slot="slotProps"
            >
               <SelectEnum
                  v-bind="slotProps"
                  v-model="values.procurement_model"
                  :values="INVITATION_PROCUREMENT_MODELS"
                  i18n-prefix="ops.client.procurement_model"
               />
            </FormField>
         </FormBox>

         <FormBox :legend="$t('ops.client.invitation.sections.contract')" class="!flex-auto">
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.commercial_model')"
               :error="errors.commercial_model"
               v-slot="slotProps"
            >
               <Select
                  v-bind="slotProps"
                  v-model="values.commercial_model"
                  :options="commercialModels"
                  option-value="value"
                  option-label="label"
                  show-clear
               />
            </FormField>
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.packages')"
               :error="errors.packages"
               v-slot="slotProps"
            >
               <SelectEnum
                  v-bind="slotProps"
                  v-model="values.packages"
                  :values="PACKAGES"
                  multiple
               />
            </FormField>
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.contract_status')"
               :error="errors.contract_status"
               v-slot="slotProps"
            >
               <SelectEnum
                  v-bind="slotProps"
                  v-model="values.contract_status"
                  :values="CONTRACT_STATUSES"
                  i18n-prefix="ops.client.contract_status"
               />
            </FormField>
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.start_on')"
               :error="errors.start_on"
               v-slot="slotProps"
            >
               <DatePicker
                  v-bind="slotProps"
                  :model-value="(values.start_on as Date | null | undefined) || null"
                  @update:model-value="values.start_on = $event as Date | null"
                  date-format="yy-mm-dd"
                  show-icon
               />
            </FormField>
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.deposit_rate')"
               :error="errors.deposit_rate"
               v-slot="slotProps"
            >
               <InputNumber
                  v-bind="slotProps"
                  v-model="values.deposit_rate"
                  :min="0"
                  :max="100"
                  :max-fraction-digits="2"
                  suffix=" %"
               />
            </FormField>
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.extra_cost_rule')"
               :error="errors.extra_cost_rule"
               v-slot="slotProps"
            >
               <InputText v-bind="slotProps" v-model="values.extra_cost_rule" />
            </FormField>
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.eu_responsible_person')"
               :error="errors.eu_responsible_person"
               v-slot="slotProps"
            >
               <InputText v-bind="slotProps" v-model="values.eu_responsible_person" />
            </FormField>
         </FormBox>

         <FormBox :legend="$t('ops.client.invitation.sections.plan')" class="!flex-auto">
            <FormField
               fluid
               :label="$t('ops.client.invitation.fields.recommended_plan_id')"
               :error="errors.recommended_plan_id"
               v-slot="slotProps"
            >
               <Select
                  v-bind="slotProps"
                  v-model="values.recommended_plan_id"
                  :options="plans"
                  option-value="id"
                  option-label="display_name"
                  :placeholder="$t('ops.client.invitation.no_plan')"
                  show-clear
               />
            </FormField>
         </FormBox>

         <FormBox :legend="$t('ops.client.invitation.sections.staff')" class="!flex-auto">
            <p class="text-sm text-muted-color w-full">
               {{ $t('ops.client.invitation.staff_hint') }}
            </p>
            <div
               v-for="(entry, index) in values.staff"
               :key="index"
               class="flex gap-2 items-end w-full"
               data-test="staff-row"
            >
               <FormField
                  fluid
                  class="flex-1"
                  :label="$t('ops.client.invitation.staff_member')"
                  :error="errors[`staff.${index}.user_id`]"
                  v-slot="slotProps"
               >
                  <Select
                     v-bind="slotProps"
                     v-model="entry.user_id"
                     :options="optionsFor(index)"
                     option-value="value"
                     option-label="label"
                     filter
                  />
               </FormField>
               <FormField
                  fluid
                  class="flex-1"
                  :label="$t('ops.client.invitation.staff_role')"
                  :error="errors[`staff.${index}.role_name`]"
                  v-slot="slotProps"
               >
                  <SelectEnum
                     v-bind="slotProps"
                     v-model="entry.role_name"
                     :values="INVITATION_STAFF_ROLES"
                     i18n-prefix="ops.client.invitation.role"
                  />
               </FormField>
               <Button
                  :icon="PrimeIcons.TRASH"
                  severity="secondary"
                  variant="text"
                  :aria-label="$t('action.delete')"
                  @click="removeStaff(index)"
               />
            </div>
            <small v-if="staffError" class="p-error w-full">{{ staffError }}</small>
            <Button
               type="button"
               variant="outlined"
               size="small"
               :icon="PrimeIcons.PLUS"
               :label="$t('ops.client.invitation.staff_add')"
               :disabled="atLimit"
               @click="addStaff"
            />
         </FormBox>
      </FormBox>
   </div>
</template>
