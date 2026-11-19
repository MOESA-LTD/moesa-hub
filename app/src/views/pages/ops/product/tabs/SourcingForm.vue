<script setup lang="ts">
import {
   sourcingResource,
   sourcingSchema,
   toSourcingFormValues,
   toSourcingPayload
} from '@/api/sourcing';
import { provideFieldAccess } from '@/composables/useFieldAccess';
import { useUpsertForm } from '@/composables/useUpsertForm';

// Hides the fields the user may not read (cost, supplier identity, sell price, internal note),
// makes read-only those they may not write.
provideFieldAccess('sourcing');

// The active tenant's sourcing row of a product: what it buys the product for, from whom, and the
// price it sells it at. A new row is for the card's product, naming its client when the product is
// a client's (the database checks the relationship: relationship_inactive).
const props = defineProps<{
   id: string | null;
   productId: string;
   clientTenantId: string | null;
}>();
const emit = defineEmits<{ saved: [id: string] }>();

const context = () => ({ productId: props.productId, clientTenantId: props.clientTenantId });

const { values, errors, isDirty, isSubmitting, readonly, reset, save, ready, draft } =
   useUpsertForm({
      id: () => props.id,
      useRow: sourcingResource.useOne,
      useSaveRow: sourcingResource.useSave,
      subject: 'sourcing',
      schema: sourcingSchema,
      toFormValues: (row) => toSourcingFormValues(row, context()),
      // Every new row shares one draft, so a new row always takes the card's product and client.
      toPayload: (data) =>
         toSourcingPayload(
            data.id
               ? data
               : { ...data, product_id: props.productId, client_tenant_id: props.clientTenantId }
         ),
      onSaved: (row) => emit('saved', row.id)
   });

await ready;

const PRICES = [
   { field: 'landed_cost_eur', digits: 4 },
   { field: 'target_price_eur', digits: 4 },
   { field: 'sell_price_eur', digits: 2 }
] as const;
const SUPPLIER_TEXTS = ['supplier_product_code', 'manufacturer_art_no'] as const;
const PURCHASE_TEXTS = ['purchase_incoterm', 'price_list_version'] as const;
</script>

<template>
   <FormBox
      @submit="save"
      @reset="() => reset()"
      v-focustrap
      :readonly
      :dirty="isDirty"
      :submitting="isSubmitting"
      :draft
      data-sourcing-form
   >
      <FormBox :legend="$t('ops.product.sections.supplier')" class="!flex-auto">
         <FormField
            field="supplier_id"
            fluid
            :label="$t('ops.product.fields.supplier_id')"
            :error="errors.supplier_id"
            :readonly
            v-slot="slotProps"
         >
            <SelectSupplier v-bind="slotProps" v-model="values.supplier_id" />
         </FormField>
         <FormField
            v-for="field in SUPPLIER_TEXTS"
            :field="field"
            :key="field"
            fluid
            :label="$t(`ops.product.fields.${field}`)"
            :error="errors[field]"
            :readonly
            v-slot="slotProps"
         >
            <InputText v-bind="slotProps" v-model="values[field]" />
         </FormField>
      </FormBox>

      <FormBox :legend="$t('ops.product.sections.purchase')" class="!flex-auto">
         <FormField
            field="purchase_price"
            fluid
            :label="$t('ops.product.fields.purchase_price')"
            :error="errors.purchase_price"
            :readonly
            v-slot="slotProps"
         >
            <InputNumber
               v-bind="slotProps"
               v-model="values.purchase_price"
               :min="0"
               :max-fraction-digits="4"
            />
         </FormField>
         <FormField
            field="purchase_currency"
            fluid
            :label="$t('ops.product.fields.purchase_currency')"
            :error="errors.purchase_currency"
            :readonly
            v-slot="slotProps"
         >
            <SelectCurrency v-bind="slotProps" v-model="values.purchase_currency" />
         </FormField>
         <FormField
            v-for="field in PURCHASE_TEXTS"
            :field="field"
            :key="field"
            fluid
            :label="$t(`ops.product.fields.${field}`)"
            :error="errors[field]"
            :readonly
            v-slot="slotProps"
         >
            <InputText v-bind="slotProps" v-model="values[field]" />
         </FormField>
      </FormBox>

      <FormBox :legend="$t('ops.product.sections.prices')" class="!flex-auto">
         <FormField
            v-for="{ field, digits } in PRICES"
            :field="field"
            :key="field"
            fluid
            :label="$t(`ops.product.fields.${field}`)"
            :error="errors[field]"
            :readonly
            v-slot="slotProps"
         >
            <InputNumber
               v-bind="slotProps"
               v-model="values[field]"
               :min="0"
               :max-fraction-digits="digits"
            />
         </FormField>
         <FormField
            field="landed_cost_on"
            fluid
            :label="$t('ops.product.fields.landed_cost_on')"
            :error="errors.landed_cost_on"
            :readonly
            v-slot="slotProps"
         >
            <DatePicker
               v-bind="slotProps"
               :model-value="values.landed_cost_on || null"
               @update:model-value="values.landed_cost_on = $event as Date | null"
               date-format="yy-mm-dd"
               show-icon
            />
         </FormField>
      </FormBox>

      <FormField
         field="notes"
         class="!flex-auto !max-w-none w-full"
         fluid
         :label="$t('ops.product.sourcing.notes')"
         :error="errors.notes"
         :readonly
         v-slot="slotProps"
      >
         <Textarea v-bind="slotProps" v-model="values.notes" auto-resize rows="3" />
      </FormField>
   </FormBox>
</template>
