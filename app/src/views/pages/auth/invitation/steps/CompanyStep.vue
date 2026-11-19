<script setup lang="ts">
import type { CompanyValues } from '@/api/invitation/accept';

// Step 2: the new company's details (the keys private.create_company takes). The form lives in
// the page, which owns its validation and the refusals of the accept call.
defineProps<{ errors: Record<string, string | undefined> }>();
const values = defineModel<CompanyValues>({ required: true });
const emit = defineEmits<{ back: []; next: [] }>();
</script>

<template>
   <div class="flex flex-col gap-4" data-step="company">
      <h2 class="m-0 text-xl font-medium">{{ $t('invitation.company.title') }}</h2>
      <p class="m-0 text-muted-color">{{ $t('invitation.company.text') }}</p>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
         <FormField
            v-slot="slotProps"
            fluid
            :label="$t('fields.name')"
            :error="errors.display_name"
         >
            <InputText
               v-bind="slotProps"
               v-model="values.display_name"
               autocomplete="organization"
            />
         </FormField>
         <FormField
            v-slot="slotProps"
            fluid
            :label="$t('fields.legal_name')"
            :error="errors.legal_name"
         >
            <InputText v-bind="slotProps" v-model="values.legal_name" />
         </FormField>
         <FormField v-slot="slotProps" fluid :label="$t('fields.email')" :error="errors.email">
            <InputText v-bind="slotProps" v-model="values.email" type="email" />
         </FormField>
         <FormField v-slot="slotProps" fluid :label="$t('fields.phone')" :error="errors.phone">
            <PhoneInput v-bind="slotProps" v-model="values.phone" />
         </FormField>
         <FormField v-slot="slotProps" fluid :label="$t('fields.website')" :error="errors.website">
            <InputText v-bind="slotProps" v-model="values.website" />
         </FormField>
         <FormField v-slot="slotProps" fluid :label="$t('fields.country')" :error="errors.country">
            <SelectCountry v-bind="slotProps" v-model="values.country" showClear />
         </FormField>
         <FormField v-slot="slotProps" fluid :label="$t('fields.city')" :error="errors.city">
            <InputText v-bind="slotProps" v-model="values.city" />
         </FormField>
         <FormField
            v-slot="slotProps"
            fluid
            :label="$t('fields.district')"
            :error="errors.district"
         >
            <InputText v-bind="slotProps" v-model="values.district" />
         </FormField>
         <FormField
            class="md:col-span-2"
            v-slot="slotProps"
            fluid
            :label="$t('fields.address')"
            :error="errors.address"
         >
            <InputText v-bind="slotProps" v-model="values.address" />
         </FormField>
         <FormField
            v-slot="slotProps"
            fluid
            :label="$t('fields.tax_office')"
            :error="errors.tax_office"
         >
            <InputText v-bind="slotProps" v-model="values.tax_office" />
         </FormField>
         <FormField
            v-slot="slotProps"
            fluid
            :label="$t('fields.tax_number')"
            :error="errors.tax_number"
         >
            <InputText v-bind="slotProps" v-model="values.tax_number" />
         </FormField>
      </div>

      <div class="flex flex-wrap justify-between gap-2">
         <Button
            variant="outlined"
            :label="$t('invitation.back')"
            :icon="PrimeIcons.CARET_LEFT"
            @click="emit('back')"
         />
         <Button
            :label="$t('invitation.next')"
            :icon="PrimeIcons.CARET_RIGHT"
            iconPos="right"
            @click="emit('next')"
         />
      </div>
   </div>
</template>
