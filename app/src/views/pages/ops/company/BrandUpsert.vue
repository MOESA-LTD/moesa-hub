<script setup lang="ts">
import { brandResource, brandSchema, toBrandFormValues, toBrandPayload } from '@/api/company';
import { useUpsertForm } from '@/composables/useUpsertForm';

// Opened as a dialog from the company profile: a new row goes to the active tenant.
const props = defineProps<{ id?: string | null }>();

const { values, errors, isDirty, isSubmitting, readonly, reset, save, ready, draft } =
   useUpsertForm({
      id: () => props.id,
      useRow: brandResource.useOne,
      useSaveRow: brandResource.useSave,
      subject: 'brand',
      schema: brandSchema,
      toFormValues: toBrandFormValues,
      toPayload: toBrandPayload
   });
await ready;

const FIELDS = ['name', 'registration_status', 'brand_program_status', 'gs1_prefix_owner'] as const;
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
            v-for="field in FIELDS"
            :key="field"
            fluid
            :label="$t(`ops.company.brand.fields.${field}`)"
            :error="errors[field]"
            :readonly
            v-slot="slotProps"
         >
            <InputText v-bind="slotProps" v-model="values[field]" />
         </FormField>
      </FormBox>
   </div>
</template>
