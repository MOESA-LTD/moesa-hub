<script setup lang="ts">
import {
   COMMERCIAL_MODELS,
   CONTRACT_STATUSES,
   PACKAGES,
   procurementModelChoices,
   relationshipResource,
   relationshipSchema,
   relationshipSide,
   toRelationshipFormValues,
   toRelationshipPayload
} from '@/api/relationship';
import { provideFieldAccess } from '@/composables/useFieldAccess';
import { useUpsertForm } from '@/composables/useUpsertForm';
import { useAuthStore } from '@/store/auth';

// One relationship, seen from its provider or its client. The provider edits the contract terms
// (and may move the procurement model from provider to client, never back: only an invitation
// starts a provider-procured relationship); the client reads the terms its provider set and edits
// nothing.
const props = defineProps<{ id?: string | null }>();

const authStore = useAuthStore();
const { t } = useI18n();

const { values, errors, isDirty, isSubmitting, readonly, reset, save, ready, draft, row } =
   useUpsertForm({
      id: () => props.id,
      useRow: relationshipResource.useOne,
      useSaveRow: relationshipResource.useSave,
      subject: 'provider_relationship',
      schema: relationshipSchema,
      toFormValues: toRelationshipFormValues,
      toPayload: toRelationshipPayload
   });
await ready;

// Without a row (not loaded, or not readable) the page is the client's: locked until the row
// confirms the provider side.
const side = computed(() =>
   row.value
      ? relationshipSide(row.value, new Set(authStore.scopeTenants.map(({ id }) => id)))
      : 'client'
);
// The client side sees only what the client may read, and cannot change any of it.
const locked = computed(
   () => readonly.value || side.value === 'client' || row.value?.status === 'ended'
);
provideFieldAccess('provider_relationship', () => side.value === 'client');

const title = computed(() =>
   row.value
      ? side.value === 'client'
         ? row.value.provider_name
         : `${row.value.client_code} — ${row.value.client_name}`
      : null
);

const commercialModels = computed(() =>
   COMMERCIAL_MODELS.map((value) => ({ value, label: t(`ops.client.commercial_model.${value}`) }))
);
// Chosen from the saved model, so picking client does not make the other value vanish.
const procurementChoices = computed(() =>
   procurementModelChoices(row.value?.procurement_model ?? values.value.procurement_model)
);
</script>

<template>
   <div class="card">
      <h2 v-if="title" class="mb-4 text-xl font-semibold" v-text="title" />
      <p v-if="side === 'client'" class="mb-4 text-sm text-muted-color">
         {{ $t('ops.client.manage.provider_terms') }}
      </p>
      <FormBox
         @submit="save"
         @reset="() => reset()"
         v-focustrap
         :readonly="locked"
         :dirty="isDirty"
         :submitting="isSubmitting"
         :draft
      >
         <FormBox :legend="$t('ops.client.sections.contract')" class="!flex-auto">
            <FormField
               field="procurement_model"
               fluid
               :label="$t('ops.client.fields.procurement_model')"
               :error="errors.procurement_model"
               :readonly="locked"
               v-slot="slotProps"
            >
               <SelectEnum
                  v-bind="slotProps"
                  v-model="values.procurement_model"
                  :values="procurementChoices"
                  i18n-prefix="ops.client.procurement_model"
                  :disabled="locked || procurementChoices.length < 2"
               />
               <small v-if="side === 'provider'" class="text-muted-color">
                  {{ $t('ops.client.manage.model_note') }}
               </small>
            </FormField>
            <FormField
               field="commercial_model"
               fluid
               :label="$t('ops.client.fields.commercial_model')"
               :error="errors.commercial_model"
               :readonly="locked"
               v-slot="slotProps"
            >
               <Select
                  v-bind="slotProps"
                  v-model="values.commercial_model"
                  :options="commercialModels"
                  option-value="value"
                  option-label="label"
                  show-clear
                  :disabled="locked"
               />
            </FormField>
            <FormField
               field="packages"
               fluid
               :label="$t('ops.client.fields.packages')"
               :error="errors.packages"
               :readonly="locked"
               v-slot="slotProps"
            >
               <SelectEnum
                  v-bind="slotProps"
                  v-model="values.packages"
                  :values="PACKAGES"
                  multiple
                  :disabled="locked"
               />
            </FormField>
            <FormField
               field="contract_status"
               fluid
               :label="$t('ops.client.fields.contract_status')"
               :error="errors.contract_status"
               :readonly="locked"
               v-slot="slotProps"
            >
               <SelectEnum
                  v-bind="slotProps"
                  v-model="values.contract_status"
                  :values="CONTRACT_STATUSES"
                  i18n-prefix="ops.client.contract_status"
                  :disabled="locked"
               />
            </FormField>
            <FormField
               field="start_on"
               fluid
               :label="$t('ops.client.fields.start_on')"
               :error="errors.start_on"
               :readonly="locked"
               v-slot="slotProps"
            >
               <DatePicker
                  v-bind="slotProps"
                  :model-value="(values.start_on as Date | null | undefined) || null"
                  @update:model-value="values.start_on = $event as Date | null"
                  date-format="yy-mm-dd"
                  show-icon
                  :disabled="locked"
               />
            </FormField>
            <FormField
               field="deposit_rate"
               fluid
               :label="$t('ops.client.fields.deposit_rate')"
               :error="errors.deposit_rate"
               :readonly="locked"
               v-slot="slotProps"
            >
               <InputNumber
                  v-bind="slotProps"
                  v-model="values.deposit_rate"
                  :min="0"
                  :max="100"
                  :max-fraction-digits="2"
                  suffix=" %"
                  :disabled="locked"
               />
            </FormField>
            <FormField
               field="extra_cost_rule"
               fluid
               :label="$t('ops.client.fields.extra_cost_rule')"
               :error="errors.extra_cost_rule"
               :readonly="locked"
               v-slot="slotProps"
            >
               <InputText v-bind="slotProps" v-model="values.extra_cost_rule" :disabled="locked" />
            </FormField>
            <FormField
               field="eu_responsible_person"
               fluid
               :label="$t('ops.client.fields.eu_responsible_person')"
               :error="errors.eu_responsible_person"
               :readonly="locked"
               v-slot="slotProps"
            >
               <InputText
                  v-bind="slotProps"
                  v-model="values.eu_responsible_person"
                  :disabled="locked"
               />
            </FormField>
         </FormBox>

         <!-- Provider-internal: hidden from the client side, and from roles that may not read them. -->
         <FormBox
            v-if="side === 'provider'"
            :legend="$t('ops.client.sections.internal')"
            class="!flex-auto"
         >
            <FormField
               field="restricted_drive_url"
               fluid
               :label="$t('ops.client.fields.restricted_drive_url')"
               :error="errors.restricted_drive_url"
               :readonly="locked"
               v-slot="slotProps"
            >
               <InputText
                  v-bind="slotProps"
                  v-model="values.restricted_drive_url"
                  :disabled="locked"
               />
            </FormField>
            <FormField
               field="notes"
               fluid
               class="!flex-auto !max-w-none w-full"
               :label="$t('ops.client.fields.notes')"
               :error="errors.notes"
               :readonly="locked"
               v-slot="slotProps"
            >
               <Textarea
                  v-bind="slotProps"
                  v-model="values.notes"
                  auto-resize
                  rows="3"
                  :disabled="locked"
               />
            </FormField>
         </FormBox>
      </FormBox>
      <!-- The relationship's documents (contract, invoices), named after the client's code. -->
      <section v-if="id && row" class="mt-6" data-relationship-documents>
         <h3 class="mt-0 mb-2 text-lg font-semibold">{{ $t('ops.document.title') }}</h3>
         <EntityDocuments
            entityType="provider_relationship"
            :entityId="id"
            :code="row.client_code"
         />
      </section>
   </div>
</template>
