<script setup lang="ts">
import { completeSignup, fetchSignupPlans, pendingSignup, SignupError } from '@/api/auth/signup';
import { setInvitationPassword } from '@/api/invitation/accept';
import { useModules } from '@/api/subscription';
import { appErrorHandler } from '@/lib/appErrorHandler';
import type { PlanSummary } from '@/lib/planDiff';
import { useAuthStore } from '@/store/auth';
import AccountStep from '@/views/pages/auth/invitation/steps/AccountStep.vue';
import { useToast } from 'primevue';

// The page behind the sign-up e-mail's link (create-account, verify-first). The link has signed the
// new owner in (the before-each middleware sets the session; invite links only), which proves the
// inbox. Here they set a password, choose a plan and complete: only then is the company created,
// from the details kept in the account's app_metadata at sign-up.
const router = useRouter();
const toast = useToast();
const { t, te } = useI18n();
const authStore = useAuthStore();

const pending = computed(() => pendingSignup(authStore.user));

const { data: modules } = useModules();
const coreModules = computed(() =>
   (modules.value ?? []).filter(({ is_core }) => is_core).map(({ id }) => id)
);

const plans = ref<PlanSummary[]>([]);
const loading = ref(false);
const planId = ref<string | null>(null);
const step = ref(1);
const passwordSaving = ref(false);
const completing = ref(false);
/** The company exists, but its tenant is not in the user's list yet. */
const completed = ref(false);
/** The code that stops the page. */
const fatal = ref<string | null>(null);
/** The code of a refusal the owner can act on (shown above the step). */
const notice = ref<string | null>(null);

const loadPlans = async () => {
   plans.value = await fetchSignupPlans();
   if (!plans.value.some(({ id }) => id === planId.value)) planId.value = null;
};

onMounted(async () => {
   if (!authStore.isSignedIn || !pending.value) return;
   step.value = authStore.user?.user_metadata?.password_set === true ? 2 : 1;
   loading.value = true;
   try {
      planId.value = pending.value.plan_id ?? null;
      await loadPlans();
   } catch (error) {
      await appErrorHandler(error);
   } finally {
      loading.value = false;
   }
});

const steps = computed(() => ['account', 'plan'].map((key) => t(`signup.complete.steps.${key}`)));

const errorText = (code: string) =>
   te(`signup.error.${code}`) ? t(`signup.error.${code}`) : t('signup.error.generic');

const savePassword = async (password: string) => {
   passwordSaving.value = true;
   try {
      await setInvitationPassword(password);
      step.value = 2;
   } catch (error) {
      await appErrorHandler(error);
   } finally {
      passwordSaving.value = false;
   }
};

const complete = async () => {
   if (completing.value) return;
   completing.value = true;
   notice.value = null;
   try {
      const { tenant: created } = await completeSignup(planId.value);
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
      if (error.code === 'plan_inactive') {
         // The plan was withdrawn meanwhile: show the plans as they are now.
         notice.value = error.code;
         await loadPlans().catch(() => undefined);
      } else {
         fatal.value = error.code;
      }
   } finally {
      completing.value = false;
   }
};

const signInTo = { name: 'auth-login', query: { redirect: '/register/complete' } };
</script>

<template>
   <div class="mx-auto w-full max-w-6xl px-4 py-6 flex flex-col gap-6" data-register-complete>
      <!-- No session: the link of the e-mail has not been opened. -->
      <div v-if="!authStore.isSignedIn" class="card !mb-0 flex flex-col gap-2" data-no-session>
         <h1 class="m-0 text-2xl">{{ $t('signup.complete.no_session_title') }}</h1>
         <p class="m-0 text-muted-color">{{ $t('signup.complete.no_session_text') }}</p>
         <Button
            class="self-start"
            :label="$t('signup.complete.sign_in')"
            :icon="PrimeIcons.SIGN_IN"
            @click="router.push(signInTo)"
         />
      </div>

      <div v-else-if="completed" class="card !mb-0 flex flex-col gap-4" data-completed>
         <Message severity="warn" :closable="false">
            {{ $t('signup.complete.reload_needed') }}
         </Message>
         <Button class="self-start" :label="$t('signup.complete.reload')" @click="router.go(0)" />
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

      <div v-else-if="!pending" class="card !mb-0 flex flex-col gap-4" data-nothing-pending>
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

      <template v-else>
         <div class="flex flex-col gap-2">
            <h1 class="m-0 text-2xl">
               {{ $t('signup.complete.title', { company: pending.company.display_name ?? '' }) }}
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
               :needsPassword="true"
               :saving="passwordSaving"
               @save="savePassword"
               @next="step = 2"
            />

            <div v-else class="flex flex-col gap-4" data-step="plan">
               <h2 class="m-0 text-xl font-medium">{{ $t('signup.complete.plan_title') }}</h2>
               <p class="m-0 text-muted-color">{{ $t('signup.complete.plan_text') }}</p>

               <div v-if="loading" class="text-muted-color">
                  {{ $t('signup.complete.loading') }}
               </div>
               <PlanCompare
                  v-else-if="plans.length"
                  v-model="planId"
                  :plans
                  :recommendedId="null"
                  :seats="1"
                  :coreModules
               />
               <Message v-else severity="warn" :closable="false">
                  {{ $t('signup.complete.plans_none') }}
               </Message>

               <div class="flex flex-wrap justify-end gap-2">
                  <Button
                     data-complete
                     :disabled="loading || (plans.length > 0 && !planId)"
                     :loading="completing"
                     :label="$t('signup.complete.action')"
                     :icon="PrimeIcons.CHECK"
                     @click="complete"
                  />
               </div>
            </div>
         </div>
      </template>
   </div>
</template>
