<script setup lang="ts">
import {
   acceptInvitation,
   companySchema,
   InvitationError,
   previewInvitation,
   setInvitationPassword,
   toCompany,
   type InvitationPreview
} from '@/api/invitation/accept';
import { useModules } from '@/api/subscription';
import { useForm } from '@/lib/form/useForm';
import { appErrorHandler } from '@/lib/appErrorHandler';
import { localeDateString } from '@/lib/dayjs';
import { useAuthStore } from '@/store/auth';
import { useToast } from 'primevue';
import SignedInAs from '@/views/pages/auth/SignedInAs.vue';
import AccountStep from './steps/AccountStep.vue';
import CompanyStep from './steps/CompanyStep.vue';
import PlanStep from './steps/PlanStep.vue';

// The page behind the link of an invitation e-mail. The e-mail link has signed the invitee in (the
// before-each middleware sets the session from the address); here they set a password if they have
// none, name their company and choose a plan. The token is the path segment: it is sent to the
// preview and the accept call and nowhere else.
const route = useRoute();
const router = useRouter();
const toast = useToast();
const { t, te } = useI18n();
const authStore = useAuthStore();

const token = String(route.params.token ?? '');

// The link carries a secret: no other site may learn it from a Referer header (F21).
let referrerMeta: HTMLMetaElement | null = null;
let previousReferrer: string | null = null;
onMounted(() => {
   const existing = document.head.querySelector<HTMLMetaElement>('meta[name="referrer"]');
   previousReferrer = existing?.content ?? null;
   referrerMeta = existing ?? document.createElement('meta');
   referrerMeta.name = 'referrer';
   referrerMeta.content = 'no-referrer';
   if (!existing) document.head.appendChild(referrerMeta);
});
// Back to what the page had before: its own value, or no tag at all.
onBeforeUnmount(() => {
   if (!referrerMeta) return;
   if (previousReferrer === null) referrerMeta.remove();
   else referrerMeta.content = previousReferrer;
});

const { data: modules } = useModules();
const coreModules = computed(() =>
   (modules.value ?? []).filter(({ is_core }) => is_core).map(({ id }) => id)
);

const preview = ref<InvitationPreview | null>(null);
const loading = ref(authStore.isSignedIn);
/** The code that stops the page: the link is dead, or belongs to another address. */
const fatal = ref<string | null>(null);
/** The preview failed for a reason that is not a refusal (network, server): try again. */
const loadFailed = ref(false);
/** The code of a refusal the invitee can act on (shown above the step). */
const notice = ref<string | null>(null);

const step = ref(1);
const passwordSaving = ref(false);
const accepting = ref(false);
/** The company exists, but its tenant is not in the user's list yet. */
const accepted = ref(false);
const planId = ref<string | null>(null);
/** I2: the indexes of the provider staff the customer keeps (all of them to start with). */
const keptStaff = ref<number[]>([]);
const listedStaff = computed(() => preview.value?.staff ?? []);
/** The users the new company starts with: the owner and the staff kept. */
const seats = computed(
   () => (preview.value?.seats ?? 1) - (listedStaff.value.length - keptStaff.value.length)
);

const { values, errors, validateFields, setErrors } = useForm({
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

const fitsSeats = (plan: InvitationPreview['plans'][number]) =>
   plan.limits.max_users == null || plan.limits.max_users >= seats.value;

// More staff kept than the chosen plan allows: the plan is no longer chosen.
watch(seats, () => {
   const chosen = preview.value?.plans.find(({ id }) => id === planId.value);
   if (chosen && !fitsSeats(chosen)) planId.value = null;
});

/** The plan to start from: the provider's recommendation, when it fits. */
const defaultPlan = () => {
   const recommended = preview.value?.plans.find(
      ({ id }) => id === preview.value?.recommended_plan_id
   );
   return recommended && fitsSeats(recommended) ? recommended.id : null;
};

const load = async () => {
   loading.value = true;
   loadFailed.value = false;
   try {
      preview.value = await previewInvitation(token);
      values.value.display_name = preview.value.company_name ?? '';
      values.value.email = preview.value.email;
      keptStaff.value = listedStaff.value.map(({ index }) => index);
      planId.value = defaultPlan();
      step.value = preview.value.needs_password ? 1 : 2;
   } catch (error) {
      if (error instanceof InvitationError) fatal.value = error.code;
      else {
         loadFailed.value = true;
         await appErrorHandler(error);
      }
   } finally {
      loading.value = false;
   }
};
onMounted(() => {
   if (authStore.isSignedIn) load();
});

const steps = computed(() =>
   ['account', 'company', 'plan'].map((key) => t(`invitation.steps.${key}`))
);

const errorText = (code: string) =>
   te(`invitation.error.${code}`)
      ? t(`invitation.error.${code}`, { email: authStore.user?.email ?? '' })
      : t('invitation.error.generic');

const savePassword = async (password: string) => {
   passwordSaving.value = true;
   try {
      await setInvitationPassword(password);
      if (preview.value) preview.value.needs_password = false;
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

/** The refusals that end the page: the link cannot be accepted by this account (decision 19 too). */
const FATAL_REFUSALS = [
   'invitation_invalid',
   'invitation_email_mismatch',
   'invitation_self_invite'
];

/** The refusals that belong to one company field show on it. */
const FIELD_REFUSALS: Record<string, string> = {
   company_email_exists: 'email',
   company_phone_exists: 'phone'
};

const accept = async () => {
   if (!planId.value || accepting.value) return;
   const parsed = companySchema.safeParse(values.value);
   if (!parsed.success) return (step.value = 2);

   accepting.value = true;
   notice.value = null;
   try {
      const { tenant_id } = await acceptInvitation(
         token,
         toCompany(parsed.data),
         planId.value,
         preview.value?.staff ? keptStaff.value : undefined
      );
      toast.add({ life: 3000, severity: ToastSeverity.SUCCESS, summary: t('toast.success') });

      // The tenant was just created: read the user's tenants again until it is among them.
      let tenant;
      for (let attempt = 0; attempt < 4 && !tenant; attempt++) {
         if (attempt) await new Promise((resolve) => setTimeout(resolve, 500 * attempt));
         await authStore.refreshAccess();
         tenant = authStore.branches.find(({ id }) => id === tenant_id);
      }
      if (!tenant) {
         // Created, but not listed yet: say so, never carry on as if it were switched to.
         accepted.value = true;
         return;
      }
      await authStore.changeCurrentTenant(tenant);
      await router.replace({ name: 'dashboard' });
   } catch (error) {
      if (!(error instanceof InvitationError)) return await appErrorHandler(error);

      const code = error.code;
      if (FATAL_REFUSALS.includes(code)) {
         fatal.value = code;
      } else if (FIELD_REFUSALS[code]) {
         setErrors({ [FIELD_REFUSALS[code]]: errorText(code) });
         step.value = 2;
      } else if (code === 'invitation_payload_invalid') {
         notice.value = code;
         step.value = 2;
      } else {
         notice.value = code;
         // The plan changed meanwhile: show the plans as they are now.
         if (code === 'plan_inactive' || code === 'plan_not_for_clients') await reloadPlans();
      }
   } finally {
      accepting.value = false;
   }
};

const reloadPlans = async () => {
   try {
      const fresh = await previewInvitation(token);
      if (preview.value) preview.value.plans = fresh.plans;
      if (!fresh.plans.some(({ id }) => id === planId.value)) planId.value = null;
   } catch {
      // The notice stays; the next accept names whatever is wrong.
   }
};

const signInTo = computed(() => ({
   name: 'auth-login',
   query: { redirect: route.fullPath }
}));

const signOut = async () => {
   await authStore.logout();
   preview.value = null;
   fatal.value = null;
};

const expires = computed(() =>
   preview.value?.expires_at
      ? localeDateString({ value: preview.value.expires_at, validate: false })
      : ''
);
</script>

<template>
   <div class="mx-auto w-full max-w-6xl px-4 py-6 flex flex-col gap-6" data-invitation-page>
      <!-- No session: the link of the e-mail has not been opened. -->
      <div v-if="!authStore.isSignedIn" class="card !mb-0 flex flex-col gap-2" data-no-session>
         <h1 class="m-0 text-2xl">{{ $t('invitation.no_session_title') }}</h1>
         <p class="m-0 text-muted-color">{{ $t('invitation.no_session_text') }}</p>
         <p class="m-0 text-muted-color">{{ $t('invitation.resend_hint') }}</p>
         <Button
            data-sign-in
            class="self-start"
            :label="$t('invitation.sign_in')"
            :icon="PrimeIcons.SIGN_IN"
            @click="router.push(signInTo)"
         />
      </div>

      <template v-else>
         <!-- The link signed someone in: the address stays in view on every step (Task 11 M3). -->
         <SignedInAs :email="authStore.user?.email ?? ''" @signOut="signOut" />

         <div v-if="accepted" class="card !mb-0 flex flex-col gap-4" data-accepted>
            <Message severity="warn" :closable="false">{{
               $t('invitation.reload_needed')
            }}</Message>
            <Button class="self-start" :label="$t('invitation.reload')" @click="router.go(0)" />
         </div>

         <div v-else-if="loadFailed" class="card !mb-0 flex flex-col gap-4" data-load-failed>
            <Message severity="error" :closable="false">{{ $t('invitation.load_failed') }}</Message>
            <Button
               class="self-start"
               data-retry
               :icon="PrimeIcons.REFRESH"
               :label="$t('invitation.retry')"
               @click="load"
            />
         </div>

         <div v-else-if="fatal" class="card !mb-0 flex flex-col gap-4" data-fatal>
            <Message severity="error" :closable="false">{{ errorText(fatal) }}</Message>
            <Button
               v-if="fatal === 'invitation_email_mismatch'"
               class="self-start"
               variant="outlined"
               data-sign-out
               :icon="PrimeIcons.SIGN_OUT"
               :label="$t('invitation.sign_out')"
               @click="signOut"
            />
         </div>

         <div v-else-if="loading || !preview" class="card !mb-0 text-muted-color">
            {{ $t('invitation.loading') }}
         </div>

         <template v-else>
            <div class="flex flex-col gap-2">
               <h1 class="m-0 text-2xl">
                  {{ $t('invitation.title', { provider: preview.provider_name ?? '' }) }}
               </h1>
               <p class="m-0 text-muted-color">
                  {{
                     $t('invitation.intro', {
                        provider: preview.provider_name ?? '',
                        company: preview.company_name ?? preview.email
                     })
                  }}
                  <span v-if="expires">{{ $t('invitation.expires', { date: expires }) }}</span>
               </p>
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
                  :email="authStore.user?.email ?? preview.email"
                  :needsPassword="preview.needs_password"
                  :saving="passwordSaving"
                  @save="savePassword"
                  @next="step = 2"
               />
               <CompanyStep
                  v-else-if="step === 2"
                  v-model="values"
                  :errors
                  @back="step = 1"
                  @next="toPlan"
               />
               <PlanStep
                  v-else
                  v-model="planId"
                  v-model:staff="keptStaff"
                  :plans="preview.plans"
                  :recommendedId="preview.recommended_plan_id"
                  :seats
                  :listedStaff
                  :providerName="preview.provider_name"
                  :coreModules
                  :accepting
                  @back="step = 2"
                  @accept="accept"
               />
            </div>
         </template>
      </template>
   </div>
</template>
