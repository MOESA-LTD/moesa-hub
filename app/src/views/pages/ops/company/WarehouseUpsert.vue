<script setup lang="ts">
import { provideFieldAccess } from '@/composables/useFieldAccess';
import {
   WAREHOUSE_TYPES,
   warehouseResource,
   warehouseSchema,
   toWarehouseFormValues,
   toWarehousePayload
} from '@/api/company';
import { useUpsertForm } from '@/composables/useUpsertForm';

// Hides the fields the user may not read, makes read-only those they may not write.
provideFieldAccess('warehouse');

// Opened as a dialog from the company profile: a new row goes to the active tenant.
const props = defineProps<{ id?: string | null }>();

const { values, errors, isDirty, isSubmitting, readonly, reset, save, ready, draft } =
   useUpsertForm({
      id: () => props.id,
      useRow: warehouseResource.useOne,
      useSaveRow: warehouseResource.useSave,
      subject: 'warehouse',
      schema: warehouseSchema,
      toFormValues: toWarehouseFormValues,
      toPayload: toWarehousePayload
   });
await ready;

const ADDRESS = ['city', 'address', 'postal_code'] as const;
const RECEIVING = [
   'dock_hours',
   'appointment_rule',
   'pallet_standard',
   'receiving_person'
] as const;
</script>

<template>
   <div class="card">
      <FormBox
         @submit="save"
         @reset="() => reset()"
         v-focustrap
         :dirty="isDirty"
         :submitting="isSubmitting"
         :draft
         :readonly
      >
         <FormField
            fluid
            :label="$t('ops.company.warehouse.fields.display_name')"
            :error="errors.display_name"
            :readonly
            v-slot="slotProps"
         >
            <InputText v-bind="slotProps" v-model="values.display_name" />
         </FormField>
         <FormField
            fluid
            :label="$t('ops.company.warehouse.fields.type')"
            :error="errors.type"
            :readonly
            v-slot="slotProps"
         >
            <SelectEnum
               v-bind="slotProps"
               v-model="values.type"
               :values="WAREHOUSE_TYPES"
               i18n-prefix="ops.company.warehouse.type"
            />
         </FormField>
         <FormField
            fluid
            :label="$t('ops.company.warehouse.fields.country')"
            :error="errors.country"
            :readonly
            v-slot="slotProps"
         >
            <SelectCountry v-bind="slotProps" v-model="values.country" showClear />
         </FormField>
         <FormField
            v-for="field in [...ADDRESS, ...RECEIVING]"
            :field="field"
            :key="field"
            fluid
            :label="$t(`ops.company.warehouse.fields.${field}`)"
            :error="errors[field]"
            :readonly
            v-slot="slotProps"
         >
            <InputText v-bind="slotProps" v-model="values[field]" />
         </FormField>
         <span class="flex items-center gap-2">
            <ToggleSwitch
               v-model="values.is_default"
               inputId="warehouse-is-default"
               :disabled="readonly"
            />
            <label for="warehouse-is-default">
               {{ $t('ops.company.warehouse.fields.is_default') }}
            </label>
         </span>
      </FormBox>
   </div>
</template>
