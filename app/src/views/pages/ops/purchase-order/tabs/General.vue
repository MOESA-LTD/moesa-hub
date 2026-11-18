<script setup lang="ts">
import { provideFieldAccess } from '@/composables/useFieldAccess';
import {
   INCOTERMS,
   PO_LOCKED_FIELDS,
   supplierDefaults,
   useEntityDocumentOptions
} from '@/api/purchaseOrder';
import ProjectSelect from '../ProjectSelect.vue';
import { injectPurchaseOrderForm, useOrderLocked } from '../usePurchaseOrderForm';

// Hides the fields the user may not read, makes read-only those they may not write.
const fieldAccess = provideFieldAccess('purchase_order');

// The order's parties and terms, in the card's shared form. The supplier and the client (empty for
// an own order) are chosen on a new order only; the project while the order is a draft
// (po_project_locked), among the client's projects on a client order; the terms are fixed from
// pi_approved on (PO_LOCKED_FIELDS).
const form = injectPurchaseOrderForm();
const { values, errors, isDirty, isSubmitting, readonly, reset, submit, draft } = form;

const { t } = useI18n();

const id = computed(() => values.value.id ?? null);
const locked = useOrderLocked(form);
/** Past its draft, the order keeps its project (po_project_locked). */
const projectLocked = computed(() => !!form.row.value && form.row.value.status !== 'draft');

const isLocked = (field: string) =>
   locked.value && (PO_LOCKED_FIELDS as readonly string[]).includes(field);
const lockHint = (field: string) =>
   isLocked(field) ? t('ops.purchase_order.locked_hint') : undefined;

const packingOptions = useEntityDocumentOptions(() => ({
   entityType: 'purchase_order',
   entityId: id.value
}));

/**
 * A picked supplier's incoterm and deposit fill the terms the order has none of yet, if the user
 * may write them (a coordinator reads the supplier terms only).
 */
const applySupplier = (
   supplier: Parameters<typeof supplierDefaults>[0] | null | undefined
): void => {
   if (!supplier) return;
   const defaults = supplierDefaults(supplier);
   if (!values.value.incoterm && defaults.incoterm && fieldAccess.canWrite('incoterm'))
      values.value.incoterm = defaults.incoterm;
   if (
      (values.value.deposit_rate === null || values.value.deposit_rate === undefined) &&
      fieldAccess.canWrite('deposit_rate') &&
      defaults.deposit_rate !== null
   )
      values.value.deposit_rate = defaults.deposit_rate;
};
</script>

<template>
   <FormBox
      @submit="submit"
      @reset="() => reset()"
      v-focustrap
      :readonly
      :dirty="isDirty"
      :submitting="isSubmitting"
      :draft
   >
      <FormField
         field="supplier_id"
         fluid
         :label="$t('ops.purchase_order.fields.supplier')"
         :error="errors.supplier_id"
         :readonly="readonly || !!id"
         v-slot="slotProps"
      >
         <SelectSupplier
            v-bind="slotProps"
            v-model="values.supplier_id"
            :disabled="!!id"
            @pick="applySupplier"
         />
      </FormField>
      <FormField
         fluid
         :label="$t('ops.purchase_order.fields.client')"
         :error="errors.client_tenant_id"
         :readonly="readonly || !!id"
         v-slot="slotProps"
      >
         <!-- A project is the client's, so another client clears it. -->
         <SelectClient
            v-bind="slotProps"
            v-model="values.client_tenant_id"
            data-field="client_tenant_id"
            :disabled="!!id"
            @change="values.project_id = null"
         />
      </FormField>
      <FormField
         fluid
         :label="$t('ops.purchase_order.fields.project')"
         :error="errors.project_id"
         :readonly="readonly || projectLocked"
         v-tooltip.top="projectLocked ? $t('ops.purchase_order.project_locked_hint') : undefined"
         v-slot="slotProps"
      >
         <ProjectSelect
            v-bind="slotProps"
            v-model="values.project_id"
            data-field="project_id"
            :tenantId="values.client_tenant_id"
            :disabled="projectLocked"
         />
      </FormField>
      <FormField
         fluid
         :label="$t('ops.purchase_order.fields.currency')"
         :error="errors.currency"
         :readonly
         v-tooltip.top="lockHint('currency')"
         v-slot="slotProps"
      >
         <SelectCurrency
            v-bind="slotProps"
            v-model="values.currency"
            data-field="currency"
            :disabled="isLocked('currency')"
         />
      </FormField>
      <FormField
         field="incoterm"
         fluid
         :label="$t('ops.purchase_order.fields.incoterm')"
         :error="errors.incoterm"
         :readonly
         v-tooltip.top="lockHint('incoterm')"
         v-slot="slotProps"
      >
         <SelectEnum
            v-bind="slotProps"
            v-model="values.incoterm"
            :values="INCOTERMS"
            data-field="incoterm"
            :disabled="isLocked('incoterm')"
         />
      </FormField>
      <FormField
         field="incoterm_place"
         fluid
         :label="$t('ops.purchase_order.fields.incoterm_place')"
         :error="errors.incoterm_place"
         :readonly
         v-tooltip.top="lockHint('incoterm_place')"
         v-slot="slotProps"
      >
         <InputText
            v-bind="slotProps"
            v-model="values.incoterm_place"
            data-field="incoterm_place"
            :disabled="isLocked('incoterm_place')"
         />
      </FormField>
      <FormField
         field="deposit_rate"
         fluid
         :label="$t('ops.purchase_order.fields.deposit_rate')"
         :error="errors.deposit_rate"
         :readonly
         v-tooltip.top="lockHint('deposit_rate')"
         v-slot="slotProps"
      >
         <InputNumber
            v-bind="slotProps"
            v-model="values.deposit_rate"
            data-field="deposit_rate"
            :min="0"
            :max="100"
            :maxFractionDigits="2"
            suffix=" %"
            :disabled="isLocked('deposit_rate')"
         />
      </FormField>
      <FormField
         fluid
         :label="$t('ops.purchase_order.fields.ready_on')"
         :error="errors.ready_on"
         :readonly
         v-slot="slotProps"
      >
         <DatePicker
            v-bind="slotProps"
            data-field="ready_on"
            :model-value="values.ready_on || null"
            @update:model-value="values.ready_on = $event as Date | null"
            date-format="yy-mm-dd"
            show-icon
         />
      </FormField>
      <FormField
         field="tolerance_pct"
         fluid
         :label="$t('ops.purchase_order.fields.tolerance_pct')"
         :error="errors.tolerance_pct"
         :readonly
         v-slot="slotProps"
      >
         <InputNumber
            v-bind="slotProps"
            v-model="values.tolerance_pct"
            :min="0"
            :max="100"
            :maxFractionDigits="2"
            suffix=" %"
         />
      </FormField>
      <FormField
         field="penalty_rule"
         fluid
         :label="$t('ops.purchase_order.fields.penalty_rule')"
         :error="errors.penalty_rule"
         :readonly
         v-slot="slotProps"
      >
         <InputText v-bind="slotProps" v-model="values.penalty_rule" />
      </FormField>
      <FormField
         fluid
         :label="$t('ops.purchase_order.fields.packing_instruction')"
         :error="errors.packing_instruction_document_id"
         :readonly
         v-slot="slotProps"
      >
         <!-- One of the order's own documents (Documents tab), so only once it is saved. -->
         <Select
            v-bind="slotProps"
            v-model="values.packing_instruction_document_id"
            :options="packingOptions"
            option-value="value"
            option-label="label"
            showClear
            :disabled="!id"
         />
      </FormField>
      <FormField
         field="notes"
         class="!flex-auto !max-w-none w-full"
         fluid
         :label="$t('ops.purchase_order.fields.notes')"
         :error="errors.notes"
         :readonly
         v-slot="slotProps"
      >
         <Textarea v-bind="slotProps" v-model="values.notes" auto-resize rows="3" />
      </FormField>
   </FormBox>
</template>
