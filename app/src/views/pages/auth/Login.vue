<script setup lang="ts">
import { useDialogRef } from '@/composables/useDialogRef';
import { emailSchema, loginSchema } from '@/api/auth';
import { useForm } from '@/lib/form/useForm';
import { readStorage, removeStorage, writeStorage } from '@/lib/storage';
import { useConfirm, useToast } from 'primevue';

const authStore = useAuthStore();
const { loginWithPassword } = authStore;
const { isSignedIn } = storeToRefs(authStore);
const confirm = useConfirm();
const toast = useToast();
const router = useRouter();
const route = useRoute();

const rememberMe = ref(!!readStorage('remember-me'));

const dialogRef = useDialogRef();

const login = useForm({
   schema: loginSchema,
   initialValues: { email: readStorage('remember-me') ?? '', password: '' }
});

const forgotPasswordForm = useForm({ schema: emailSchema, initialValues: { email: '' } });

const forgotPassword = () =>
   confirm.require({
      group: 'forgot-password',
      header: i18n.t('auth.forgot_password.confirm.header'),
      icon: PrimeIcons.REFRESH,
      rejectProps: {
         label: i18n.t('action.cancel'),
         severity: 'secondary',
         outlined: true
      },
      // reactive() unwraps the computed, so the button follows the e-mail's validity.
      acceptProps: reactive({
         label: i18n.t('action.send'),
         disabled: computed(() => !emailSchema.safeParse(forgotPasswordForm.values.value).success)
      }),
      accept: forgotPasswordForm.handleSubmit(async ({ email }) => {
         await supabase.auth.resetPasswordForEmail(email);
         await router.push({
            path: 'forgot-password'
         });
         toast.add({
            severity: 'info',
            summary: i18n.t('toast.sended'),
            detail: i18n.t(
               'auth.otp.forgot_password.password_reset_email_sended_please_check_your_email'
            ),
            life: 0
         });
      })
   });

const submit = login.handleSubmit(async (credentials) => {
   await loginWithPassword({ email: credentials.email, password: credentials.password });

   removeStorage('remember-me');
   if (rememberMe.value) writeStorage('remember-me', credentials.email);

   // Back to the page that sent the user here (an invitation link, the sign-up completion): only
   // such a path, never another site.
   const redirect = route.query.redirect;
   if (
      typeof redirect === 'string' &&
      /^(\/[a-z]{2}(-[a-z]+)?)?\/(invitation\/[^/?#]+|register\/complete)$/i.test(redirect)
   ) {
      await router.replace(redirect);
   }
});

watch(
   () => isSignedIn.value,
   async (value) => {
      if (value) dialogRef?.value?.close?.();
   },
   { immediate: true }
);

const { values, errors } = login;
const { values: forgotValues, errors: forgotErrors } = forgotPasswordForm;
</script>

<template>
   <FormBox @submit="submit" class="!w-full self-center gap-8" v-focustrap>
      <div class="w-full flex flex-col gap-2">
         <h2
            class="m-0 text-3xl font-semibold tracking-tight"
            v-text="$t('auth.login.welcome_back')"
         />
         <p class="m-0 text-muted-color" v-text="$t('auth.login.please_login_to_continue')" />
      </div>
      <div class="w-full flex flex-col gap-6">
         <FormField v-slot="slotProps" fluid :label="$t('fields.email')" :error="errors.email">
            <InputText autofocus v-bind="slotProps" v-model="values.email" />
         </FormField>
         <FormField
            v-slot="slotProps"
            fluid
            :label="$t('fields.password')"
            :error="errors.password"
         >
            <Password
               v-bind="slotProps"
               v-model="values.password"
               :toggleMask="true"
               :feedback="false"
            />
         </FormField>
      </div>
      <template #form-actions>
         <div class="w-full flex flex-col gap-6">
            <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
               <FormField v-slot="slotProps" reverse :label="$t('fields.remember_me')">
                  <Checkbox v-bind="slotProps" v-model="rememberMe" binary />
               </FormField>
               <Button
                  variant="link"
                  class="!px-0"
                  @click="forgotPassword"
                  :label="$t('auth.login.forgot_your_password?')"
               />
            </div>
            <Button class="w-full" size="large" type="submit" :label="$t('route.label.login')" />
            <RouterLink
               custom
               v-slot="{ href, navigate }"
               :to="{
                  path: 'invite-code',
                  replace: true
               }"
            >
               <Button
                  variant="link"
                  as="a"
                  class="self-center"
                  :href
                  @click="navigate"
                  :label="$t('auth.login.do_you_have_invite_code?')"
               />
            </RouterLink>
         </div>
      </template>
   </FormBox>
   <ConfirmDialog group="forgot-password" :draggable="false">
      <template #message>
         <FormField
            :label="$t('fields.email')"
            fluid
            v-slot="slotProps"
            :error="forgotErrors.email"
         >
            <InputText v-bind="slotProps" v-model="forgotValues.email" :length="6" />
         </FormField>
      </template>
   </ConfirmDialog>
</template>
