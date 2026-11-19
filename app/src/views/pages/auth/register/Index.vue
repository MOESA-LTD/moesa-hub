<script setup lang="ts">
import { createAccount, registerSchema } from '@/api/auth';
import { SignupError } from '@/api/auth/signup';
import { useSignupOpen } from '@/api/platformSetting';
import { appErrorHandler } from '@/lib/appErrorHandler';
import { useForm } from '@/lib/form/useForm';
import CompanyStep from '@/views/pages/auth/invitation/steps/CompanyStep.vue';

// Self-signup, when the platform opens it (decision 17); otherwise companies join by invitation.
// Verify-first (create-account): the owner gives an e-mail and the company, no password. The
// function mails a link and answers the same for every address; the link opens /register/complete,
// where the password is set, the plan chosen and the company created.
const { t, te } = useI18n();
const { open, isPending } = useSignupOpen();

const step = ref<'email' | 'company'>('email');
/** The address the link was sent to: the form is done. */
const sentTo = ref<string | null>(null);
/** Refused because signup was closed meanwhile. */
const closedMeanwhile = ref(false);
/** The code of a refusal shown above the form. */
const notice = ref<string | null>(null);

const { values, errors, validateFields, handleSubmit, isSubmitting } = useForm({
   schema: registerSchema,
   initialValues: {
      account: { email: '' },
      company: {
         display_name: '',
         legal_name: '',
         email: '',
         phone: '',
         website: '',
         country: '',
         city: '',
         district: '',
         address: '',
         tax_office: '',
         tax_number: ''
      }
   }
});

/** The company step's errors, by its own field names. */
const companyErrors = computed(() =>
   Object.fromEntries(
      Object.entries(errors.value)
         .filter(([path]) => path.startsWith('company.'))
         .map(([path, message]) => [path.slice('company.'.length), message])
   )
);

const toCompany = () => {
   if (!validateFields(['account'])) return;
   // The company's e-mail starts as the owner's.
   if (!values.value.company.email) values.value.company.email = values.value.account.email.trim();
   step.value = 'company';
};

const send = handleSubmit(async (data) => {
   notice.value = null;
   try {
      await createAccount(data);
      sentTo.value = data.account.email;
   } catch (error) {
      if (!(error instanceof SignupError)) return await appErrorHandler(error);
      if (error.code === 'signup_closed') closedMeanwhile.value = true;
      else notice.value = error.code;
   }
});

const submit = async () => {
   // An error of the e-mail step would be hidden on the company step.
   if (!validateFields(['account'])) return (step.value = 'email');
   await send();
};

const errorText = (code: string) =>
   te(`signup.error.${code}`) ? t(`signup.error.${code}`) : t('signup.error.generic');
</script>

<template>
   <div class="flex-auto w-full flex flex-col gap-8" data-register-page>
      <div class="w-full text-center flex flex-col justify-center gap-4">
         <div class="text-3xl font-medium" v-text="$t('auth.register.create_account')" />
      </div>

      <div v-if="isPending" class="text-muted-color text-center">{{ $t('signup.loading') }}</div>

      <!-- Closed: companies join through their provider's invitation. -->
      <div v-else-if="!open || closedMeanwhile" class="flex flex-col gap-4" data-signup-closed>
         <Message severity="info" :closable="false">
            <div class="font-medium">{{ $t('signup.closed_title') }}</div>
            <div>{{ $t('signup.closed_text') }}</div>
         </Message>
         <RouterLink custom :to="{ name: 'auth-login', replace: true }" v-slot="{ href, navigate }">
            <Button
               as="a"
               variant="outlined"
               class="self-center"
               :href
               :label="$t('signup.to_login')"
               :icon="PrimeIcons.SIGN_IN"
               @click="navigate"
            />
         </RouterLink>
      </div>

      <!-- Sent: the link proves the inbox; the same answer for every address. -->
      <div v-else-if="sentTo" class="flex flex-col gap-4" data-check-email>
         <Message severity="success" :closable="false">
            <div class="font-medium">{{ $t('signup.check_title') }}</div>
            <div>{{ $t('signup.check_text', { email: sentTo }) }}</div>
         </Message>
         <p class="m-0 text-muted-color">{{ $t('signup.check_existing') }}</p>
         <RouterLink custom :to="{ name: 'auth-login', replace: true }" v-slot="{ href, navigate }">
            <Button
               as="a"
               variant="outlined"
               class="self-center"
               :href
               :label="$t('signup.to_login')"
               :icon="PrimeIcons.SIGN_IN"
               @click="navigate"
            />
         </RouterLink>
      </div>

      <template v-else>
         <Message v-if="notice" severity="error" :closable="false" data-notice>
            {{ errorText(notice) }}
         </Message>

         <FormBox
            v-if="step === 'email'"
            class="!w-full"
            data-step="email"
            v-focustrap
            @submit="toCompany"
         >
            <p class="m-0 text-muted-color">{{ $t('signup.email_text') }}</p>
            <FormField
               v-slot="slotProps"
               fluid
               :label="$t('fields.email')"
               :error="errors['account.email']"
            >
               <InputText
                  autofocus
                  type="email"
                  autocomplete="email"
                  v-bind="slotProps"
                  v-model="values.account.email"
               />
            </FormField>
            <template #form-actions>
               <Button
                  data-next
                  class="self-end"
                  :label="$t('signup.next')"
                  :icon="PrimeIcons.CARET_RIGHT"
                  iconPos="right"
                  @click="toCompany"
               />
            </template>
         </FormBox>

         <div v-else class="flex flex-col gap-4">
            <CompanyStep
               :text="$t('signup.company_text')"
               v-model="values.company"
               :errors="companyErrors"
               @back="step = 'email'"
               @next="submit"
            />
            <div v-if="isSubmitting" class="text-muted-color">{{ $t('signup.sending') }}</div>
         </div>
      </template>
   </div>
</template>
