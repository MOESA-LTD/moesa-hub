<script setup lang="ts">
import {
   completeSignup,
   fetchPendingSignup,
   fetchSignupPlans,
   SignupError
} from '@/api/auth/signup';
import { companySchema, setInvitationPassword, toCompany } from '@/api/invitation/accept';
import { useModules } from '@/api/subscription';
import { appErrorHandler } from '@/lib/appErrorHandler';
import { useForm } from '@/lib/form/useForm';
import type { PlanSummary } from '@/lib/planDiff';
import { useAuthStore } from '@/store/auth';
import SignedInAs from '@/views/pages/auth/SignedInAs.vue';
import AccountStep from '@/views/pages/auth/invitation/steps/AccountStep.vue';
import CompanyStep from '@/views/pages/auth/invitation/steps/CompanyStep.vue';
import { useToast } from 'primevue';

// The page behind the sign-up e-mail's link (create-account, verify-first). The link has signed the
// new owner in (the before-each middleware sets the session; invite links only), which proves the
// inbox. Here they set a password, confirm or edit the company the sign-up asked for (kept server
// side; only a default), choose a plan and complete: only then is the company created.
const route = useRoute();
const router = useRouter();
const toast = useToast();
const { t, te } = useI18n();
const authStore = useAuthStore();

/** The link was refused by Auth (expired or used): GoTrue puts the reason in the address hash. */
const linkFailed = /(^|[#&])error(_code)?=/.test(route.hash ?? '');

const { data: modules } = useModules();
const coreModules = computed(() =>
   (modules.value ?? []).filter(({ is_core }) => is_core).map(({ id }) => id)
);

const plans = ref<PlanSummary[]>([]);
const loading = ref(authStore.isSignedIn);
/** Nothing waits for this account (completed, accepted an invitation, or never signed up). */
const nothingPending = ref(false);
const planId = ref<string | null>(null);
const step = ref(1);
const passwordSet = ref(authStore.user?.user_metadata?.password_set === true);
const passwordSaving = ref(false);
const completing = ref(false);
/** The company exists, but its tenant is not in the user's list yet. */
const completed = ref(false);
/** The code that stops the page. */
const fatal = ref<string | null>(null);
/** The code of a refusal the owner can act on (shown above the step). */
const notice = ref<string | null>(null);

const { values, errors, validateFields, setErrors, reset } = useForm({
   schema: companySchema,
   initialValues: {
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
});

const loadPlans = async () => {
   plans.value = await fetchSignupPlans();
   if (!plans.value.some(({ id }) => id === planId.value)) planId.value = null;
};

const load = async () => {
   loading.value = true;
   try {
      const pending = await fetchPendingSignup();
      // The sign-up's company is only the default: the owner confirms or edits it.
      reset({ ...values.value, ...pending.company });
      planId.value = pending.plan_id;
      step.value = passwordSet.value ? 2 : 1;
      await loadPlans();
   } catch (error) {
      if (!(error instanceof SignupError)) await appErrorHandler(error);
      else if (error.code === 'signup_not_pending') nothingPending.value = true;
      else fatal.value = error.code;
   } finally {
      loading.value = false;
   }
};
onMounted(() => {
   if (authStore.isSignedIn) load();
});

const steps = computed(() =>
   ['account', 'company', 'plan'].map((key) => t(`signup.complete.steps.${key}`))
);

const errorText = (code: string) =>
   te(`signup.error.${code}`) ? t(`signup.error.${code}`) : t('signup.error.generic');

const savePassword = async (password: string) => {
   passwordSaving.value = true;
   try {
      await setInvitationPassword(password);
      passwordSet.value = true;
      step.value = 2;
   } catch (error) {
      await appErrorHandler(error);
   } finally {
      passwordSaving.value = false;
   }
};

const toPlan = () => {
   if (validateFields(Object.keys(values.value))) step.value = 3;
};

/** The refusals that belong to one company field show on it. */
const FIELD_REFUSALS: Record<string, string> = {
   company_email_exists: 'email',
   company_phone_exists: 'phone'
};

const complete = async () => {
   if (completing.value) return;
   const parsed = companySchema.safeParse(values.value);
   if (!parsed.success) return (step.value = 2);

   completing.value = true;
   notice.value = null;
   try {
      const { tenant: created } = await completeSignup(planId.value, toCompany(parsed.data));
      toast.add({ life: 3000, severity: ToastSeverity.SUCCESS, summary: t('toast.success') });

      // The tenant was just created: read the user's tenants again until it is among them.
      let tenant;
      for (let attempt = 0; attempt < 4 && !tenant; attempt++) {
         if (attempt) await new Promise((resolve) => setTimeout(resolve, 500 * attempt));
         await authStore.refreshAccess();
         tenant = authStore.branches.find(({ id }) => id === created.id);
      }
      if (!tenant) {
         completed.value = true;
         return;
      }
      await authStore.changeCurrentTenant(tenant);
      await router.replace({ name: 'dashboard' });
   } catch (error) {
      if (!(error instanceof SignupError)) return await appErrorHandler(error);
      const code = error.code;
      if (FIELD_REFUSALS[code]) {
         // Taken by another company: the owner changes it and tries again.
         setErrors({ [FIELD_REFUSALS[code]]: errorText(code) });
         step.value = 2;
      } else if (code === 'signup_payload_invalid' || code === 'company_payload_invalid') {
         notice.value = code;
         step.value = 2;
      } else if (code === 'plan_inactive' || code === 'plan_not_for_clients') {
         // The plan was withdrawn, or is no longer offered to clients (decision 21), meanwhile:
         // show the plans as they are now.
         notice.value = code;
         await loadPlans().catch(() => undefined);
      } else {
         fatal.value = code;
      }
   } finally {
      completing.value = false;
   }
};

const signOut = async () => {
   await authStore.logout();
   fatal.value = null;
   nothingPending.value = false;
};

const signInTo = { name: 'auth-login', query: { redirect: '/register/complete' } };
</script>

<template>
   <div class="mx-auto w-full max-w-6xl px-4 py-6 flex flex-col gap-6" data-register-complete>
      <!-- The link of the e-mail failed (expired or used): a new sign-up mails a new one. -->
      <div
         v-if="!authStore.isSignedIn && linkFailed"
         class="card !mb-0 flex flex-col gap-4"
         data-link-expired
      >
         <Message severity="warn" :closable="false">
            {{ $t('signup.complete.link_expired') }}
         </Message>
         <Button
            class="self-start"
            :label="$t('signup.complete.sign_up_again')"
            :icon="PrimeIcons.USER_PLUS"
            @click="router.push({ name: 'auth-register' })"
         />
      </div>

      <!-- No session: the link of the e-mail has not been opened. -->
      <div v-else-if="!authStore.isSignedIn" class="card !mb-0 flex flex-col gap-2" data-no-session>
         <h1 class="m-0 text-2xl">{{ $t('signup.complete.no_session_title') }}</h1>
         <p class="m-0 text-muted-color">{{ $t('signup.complete.no_session_text') }}</p>
         <Button
            class="self-start"
            :label="$t('signup.complete.sign_in')"
            :icon="PrimeIcons.SIGN_IN"
            @click="router.push(signInTo)"
         />
      </div>

      <template v-else>
         <SignedInAs :email="authStore.user?.email ?? ''" @signOut="signOut" />

         <div v-if="completed" class="card !mb-0 flex flex-col gap-4" data-completed>
            <Message severity="warn" :closable="false">
               {{ $t('signup.complete.reload_needed') }}
            </Message>
            <Button
               class="self-start"
               :label="$t('signup.complete.reload')"
               @click="router.go(0)"
            />
         </div>

         <div v-else-if="fatal" class="card !mb-0 flex flex-col gap-4" data-fatal>
            <Message severity="error" :closable="false">{{ errorText(fatal) }}</Message>
            <Button
               class="self-start"
               variant="outlined"
               :label="$t('signup.complete.to_dashboard')"
               @click="router.replace({ name: 'dashboard' })"
            />
         </div>

         <div
            v-else-if="nothingPending"
            class="card !mb-0 flex flex-col gap-4"
            data-nothing-pending
         >
            <Message severity="info" :closable="false">
               {{ $t('signup.complete.nothing_pending') }}
            </Message>
            <Button
               class="self-start"
               variant="outlined"
               :label="$t('signup.complete.to_dashboard')"
               @click="router.replace({ name: 'dashboard' })"
            />
         </div>

         <div v-else-if="loading" class="card !mb-0 text-muted-color">
            {{ $t('signup.complete.loading') }}
         </div>

         <template v-else>
            <div class="flex flex-col gap-2">
               <h1 class="m-0 text-2xl">
                  {{ $t('signup.complete.title', { company: values.display_name }) }}
               </h1>
               <p class="m-0 text-muted-color">{{ $t('signup.complete.intro') }}</p>
            </div>

            <ol class="list-none p-0 m-0 flex flex-wrap gap-2">
               <li v-for="(label, i) in steps" :key="label" class="flex-1 min-w-32">
                  <div
                     class="flex items-center gap-2 rounded-border border px-3 py-2"
                     :class="
                        step === i + 1
                           ? 'border-primary text-primary font-medium'
                           : 'border-surface text-muted-color'
                     "
                     :aria-current="step === i + 1 ? 'step' : undefined"
                  >
                     <i :class="step > i + 1 ? 'pi pi-check-circle' : 'pi pi-circle'" />
                     {{ label }}
                  </div>
               </li>
            </ol>

            <Message v-if="notice" severity="error" :closable="false" data-notice>
               {{ errorText(notice) }}
            </Message>

            <div class="card !mb-0">
               <AccountStep
                  v-if="step === 1"
                  :email="authStore.user?.email ?? ''"
                  :needsPassword="!passwordSet"
                  :saving="passwordSaving"
                  @save="savePassword"
                  @next="step = 2"
               />

               <CompanyStep
                  :text="$t('signup.company_text')"
                  v-else-if="step === 2"
                  v-model="values"
                  :errors
                  @back="step = 1"
                  @next="toPlan"
               />

               <div v-else class="flex flex-col gap-4" data-step="plan">
                  <h2 class="m-0 text-xl font-medium">{{ $t('signup.complete.plan_title') }}</h2>
                  <p class="m-0 text-muted-color">{{ $t('signup.complete.plan_text') }}</p>

                  <PlanCompare
                     v-if="plans.length"
                     v-model="planId"
                     :plans
                     :recommendedId="null"
                     :seats="1"
                     :coreModules
                  />
                  <Message v-else severity="warn" :closable="false">
                     {{ $t('signup.complete.plans_none') }}
                  </Message>

                  <div class="flex flex-wrap justify-between gap-2">
                     <Button
                        variant="outlined"
                        :label="$t('signup.complete.back')"
                        :icon="PrimeIcons.CARET_LEFT"
                        @click="step = 2"
                     />
                     <Button
                        data-complete
                        :disabled="plans.length > 0 && !planId"
                        :loading="completing"
                        :label="$t('signup.complete.action')"
                        :icon="PrimeIcons.CHECK"
                        @click="complete"
                     />
                  </div>
               </div>
            </div>
         </template>
      </template>
   </div>
</template>
