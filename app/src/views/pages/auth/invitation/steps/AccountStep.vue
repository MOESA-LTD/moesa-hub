<script setup lang="ts">
import { requiredText } from '@/lib/form/fields';
import { useForm } from '@/lib/form/useForm';
import * as z from 'zod';

// Step 1: the invitee's password, unless they already have one.
const props = defineProps<{ email: string; needsPassword: boolean; saving: boolean }>();
const emit = defineEmits<{ save: [password: string]; next: [] }>();

const { t } = useI18n();

const schema = z
   .object({ password: z.string().min(8), password_confirmation: requiredText() })
   .refine(({ password, password_confirmation }) => password === password_confirmation, {
      path: ['password_confirmation'],
      error: () => t('form.passwords_do_not_match')
   });

const { values, errors, handleSubmit } = useForm({
   schema,
   initialValues: { password: '', password_confirmation: '' }
});

const submit = handleSubmit(({ password }) => emit('save', password));
</script>

<template>
   <div class="flex flex-col gap-4" data-step="account">
      <h2 class="m-0 text-xl font-medium">{{ $t('invitation.account.title') }}</h2>

      <template v-if="props.needsPassword">
         <p class="m-0 text-muted-color">{{ $t('invitation.account.text', { email }) }}</p>
         <FormBox class="!w-full max-w-md" @submit="submit">
            <FormField
               v-slot="slotProps"
               fluid
               :label="$t('fields.password')"
               :error="errors['password']"
            >
               <Password
                  v-bind="slotProps"
                  v-model="values.password"
                  autocomplete="new-password"
                  :toggleMask="true"
                  :feedback="false"
               />
            </FormField>
            <FormField
               v-slot="slotProps"
               fluid
               :label="$t('fields.password_confirmation')"
               :error="errors['password_confirmation']"
            >
               <Password
                  v-bind="slotProps"
                  v-model="values.password_confirmation"
                  autocomplete="new-password"
                  :toggleMask="true"
                  :feedback="false"
               />
            </FormField>
            <Button
               type="submit"
               :loading="saving"
               :label="$t('invitation.account.save')"
               :icon="PrimeIcons.LOCK"
            />
         </FormBox>
      </template>
      <template v-else>
         <p class="m-0 text-muted-color">{{ $t('invitation.account.has_password', { email }) }}</p>
         <Button
            class="self-start"
            :label="$t('invitation.next')"
            :icon="PrimeIcons.CARET_RIGHT"
            iconPos="right"
            @click="emit('next')"
         />
      </template>
   </div>
</template>
