<script setup lang="ts">
import { provideFieldAccess } from '@/composables/useFieldAccess';
import {
   PLATFORM_ACCESSES,
   platformAccountResource,
   platformAccountSchema,
   toPlatformAccountFormValues,
   toPlatformAccountPayload
} from '@/api/company';
import { usePlatformOptions } from '@/api/platform';
import { useUpsertForm } from '@/composables/useUpsertForm';
import dayjs from 'dayjs';
import AmazonConnection from './AmazonConnection.vue';

// Hides the fields the user may not read, makes read-only those they may not write.
provideFieldAccess('platform_account');

// Opened as a dialog from the company profile: a new row goes to the active tenant.
const props = defineProps<{ id?: string | null }>();

const { values, errors, isDirty, isSubmitting, readonly, reset, save, ready, draft, row } =
   useUpsertForm({
      id: () => props.id,
      useRow: platformAccountResource.useOne,
      useSaveRow: platformAccountResource.useSave,
      subject: 'platform_account',
      schema: platformAccountSchema,
      toFormValues: toPlatformAccountFormValues,
      toPayload: toPlatformAccountPayload
   });
await ready;

// The countries offered are the chosen platform's.
const { data: platforms } = usePlatformOptions();
const countryOptions = computed(
   () =>
      platforms.value?.find((platform) => platform.id === values.value.platform_id)?.countries ?? []
);
</script>

<template>
   <div class="card">
      <div
         v-if="row?.platform_id === 'amazon'"
         class="mb-4 flex flex-wrap items-center gap-2"
         data-amazon-connection
      >
         <span class="font-semibold">{{ $t('ops.amazon.platform.api_connection') }}</span>
         <AmazonConnection :account="row" />
         <small v-if="row.authorized_at" class="text-muted-color">
            {{
               $t('ops.amazon.connect.connected_on', {
                  date: dayjs(row.authorized_at).format('YYYY-MM-DD')
               })
            }}
         </small>
      </div>
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
            :label="$t('ops.company.platform.fields.platform_id')"
            :error="errors.platform_id"
            :readonly
            v-slot="slotProps"
         >
            <SelectPlatform v-bind="slotProps" v-model="values.platform_id" />
         </FormField>
         <FormField
            fluid
            :label="$t('ops.company.platform.fields.countries')"
            :error="errors.countries"
            :readonly
            v-slot="slotProps"
         >
            <MultiSelect
               v-bind="slotProps"
               v-model="values.countries"
               :options="countryOptions"
               display="chip"
            />
         </FormField>
         <FormField
            field="account_holder"
            fluid
            :label="$t('ops.company.platform.fields.account_holder')"
            :error="errors.account_holder"
            :readonly
            v-slot="slotProps"
         >
            <InputText v-bind="slotProps" v-model="values.account_holder" />
         </FormField>
         <FormField
            fluid
            :label="$t('ops.company.platform.fields.access')"
            :error="errors.access"
            :readonly
            v-slot="slotProps"
         >
            <SelectEnum
               v-bind="slotProps"
               v-model="values.access"
               :values="PLATFORM_ACCESSES"
               i18n-prefix="ops.company.platform.access"
            />
         </FormField>
         <FormField
            field="notes"
            class="!flex-auto !max-w-none w-full"
            fluid
            :label="$t('ops.company.platform.fields.notes')"
            :error="errors.notes"
            :readonly
            v-slot="slotProps"
         >
            <Textarea v-bind="slotProps" v-model="values.notes" auto-resize rows="2" />
         </FormField>
      </FormBox>
   </div>
</template>
