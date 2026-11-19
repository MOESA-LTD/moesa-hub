<script setup lang="ts">
import { LIMIT_KEYS } from '@/api/subscription';
import { isDowngrade, planDiff, type PlanSummary } from '@/lib/planDiff';

// The plans of an invitation side by side: price, trial, modules, limits and who each suits. The
// chosen plan explains what every other plan would change. A plan with fewer users than the
// invitation brings cannot be chosen.
const props = defineProps<{
   plans: PlanSummary[];
   recommendedId: string | null;
   seats: number;
   modelValue: string | null;
   providerName?: string | null;
   /** Modules every plan includes (module.is_core); listed once, not per plan. */
   coreModules?: string[];
}>();
const emit = defineEmits<{ 'update:modelValue': [id: string] }>();

const { t, n, locale } = useI18n();

const core = computed(() => new Set(props.coreModules ?? []));
const moduleName = (id: string) => t(`fields.${id}`);

// Every module a plan offers beyond the core ones, so the columns line up.
const optionalModules = computed(() => [
   ...new Set(props.plans.flatMap((plan) => plan.modules).filter((id) => !core.value.has(id)))
]);
const coreList = computed(() => (props.coreModules ?? []).map(moduleName).join(', '));

const price = (plan: PlanSummary) => {
   // No price set is not free: only an explicit 0 is.
   if (plan.price == null) return t('invitation.plan.on_request');
   if (plan.price === 0) return t('invitation.plan.free');
   const amount = plan.currency
      ? new Intl.NumberFormat(locale.value, { style: 'currency', currency: plan.currency }).format(
           plan.price
        )
      : n(plan.price);
   return plan.billing_period
      ? t('invitation.plan.per', {
           price: amount,
           period: t(`admin.plan.period.${plan.billing_period}`)
        })
      : amount;
};

const limitValue = (value: number | null | undefined) =>
   value == null ? t('admin.plan.unlimited') : String(value);

const tooSmall = (plan: PlanSummary) => {
   const max = plan.limits.max_users;
   return max != null && max < props.seats;
};

const selected = computed(() => props.plans.find((plan) => plan.id === props.modelValue) ?? null);

/** What moving from the chosen plan to each other plan changes, as one sentence. */
const changes = computed(() => {
   const from = selected.value;
   if (!from) return [];
   return props.plans
      .filter((plan) => plan.id !== from.id)
      .map((plan) => {
         const diff = planDiff(from, plan, props.coreModules);
         const parts: string[] = [];
         if (diff.modulesGained.length) {
            parts.push(
               t('invitation.plan.adds', { modules: diff.modulesGained.map(moduleName).join(', ') })
            );
         }
         if (diff.modulesLost.length) {
            parts.push(
               t('invitation.plan.removes', {
                  modules: diff.modulesLost.map(moduleName).join(', ')
               })
            );
         }
         for (const limit of diff.limits) {
            const name = t(`subscription.limit.${limit.key}`).toLowerCase();
            if (limit.to === null) parts.push(t('invitation.plan.limit_removed', { limit: name }));
            else {
               const key =
                  limit.from === null || limit.to < limit.from ? 'limit_to' : 'limit_raise';
               parts.push(t(`invitation.plan.${key}`, { limit: name, value: limit.to }));
            }
         }
         const kind = !parts.length ? 'switch' : isDowngrade(diff) ? 'downgrade' : 'upgrade';
         return {
            id: plan.id,
            kind,
            text: t(`invitation.plan.${kind}`, {
               plan: plan.display_name,
               changes: parts.length ? parts.join(', ') : t('invitation.plan.same')
            })
         };
      });
});
</script>

<template>
   <div class="flex flex-col gap-6" data-plan-compare>
      <div
         class="grid gap-4 grid-cols-1 sm:grid-cols-2 xl:grid-cols-[repeat(auto-fit,minmax(16rem,1fr))]"
         role="group"
         :aria-label="$t('invitation.plan.title')"
      >
         <div
            v-for="plan in plans"
            :key="plan.id"
            class="card !mb-0 flex flex-col gap-4 border-2"
            :class="[
               modelValue === plan.id ? 'border-primary' : 'border-transparent',
               tooSmall(plan) && 'opacity-70'
            ]"
            :data-plan="plan.id"
         >
            <div class="flex flex-col gap-2">
               <Tag
                  v-if="plan.id === recommendedId"
                  data-recommended
                  severity="success"
                  :icon="PrimeIcons.STAR"
                  :value="$t('invitation.plan.recommended_by', { provider: providerName ?? '' })"
                  class="self-start"
               />
               <h3 class="m-0 text-xl">{{ plan.display_name }}</h3>
               <p v-if="plan.description" class="m-0 text-muted-color">{{ plan.description }}</p>
            </div>

            <div class="flex flex-col">
               <span class="text-2xl font-semibold">{{ price(plan) }}</span>
               <span class="text-muted-color text-sm">
                  {{
                     plan.trial_days
                        ? $t('invitation.plan.trial', { days: plan.trial_days }, plan.trial_days)
                        : $t('invitation.plan.no_trial')
                  }}
               </span>
            </div>

            <div v-if="plan.audience" class="flex flex-col gap-1">
               <span class="text-sm font-medium">{{ $t('invitation.plan.audience') }}</span>
               <span class="text-muted-color">{{ plan.audience }}</span>
            </div>

            <ul class="list-none p-0 m-0 flex flex-col gap-1">
               <li v-for="key in LIMIT_KEYS" :key="key" class="flex justify-between gap-2">
                  <span>{{ $t(`subscription.limit.${key}`) }}</span>
                  <span class="font-medium">{{ limitValue(plan.limits[key]) }}</span>
               </li>
            </ul>

            <ul class="list-none p-0 m-0 flex flex-col gap-1">
               <li v-for="id in optionalModules" :key="id" class="flex items-center gap-2">
                  <i
                     :class="
                        plan.modules.includes(id)
                           ? 'pi pi-check-circle text-green-500'
                           : 'pi pi-minus-circle text-muted-color'
                     "
                  />
                  <span :class="!plan.modules.includes(id) && 'text-muted-color'">
                     {{ moduleName(id) }}
                  </span>
                  <span class="sr-only">
                     {{
                        plan.modules.includes(id)
                           ? $t('invitation.plan.included')
                           : $t('invitation.plan.not_included')
                     }}
                  </span>
               </li>
            </ul>
            <p v-if="coreList" class="m-0 text-sm text-muted-color">
               {{ $t('invitation.plan.core_modules', { modules: coreList }) }}
            </p>

            <p v-if="tooSmall(plan)" class="m-0 text-sm text-red-500" data-too-small>
               {{ $t('invitation.plan.too_small', { max: plan.limits.max_users, seats }) }}
            </p>

            <Button
               class="mt-auto"
               :disabled="tooSmall(plan)"
               :variant="modelValue === plan.id ? undefined : 'outlined'"
               :icon="modelValue === plan.id ? PrimeIcons.CHECK : undefined"
               :label="
                  modelValue === plan.id
                     ? $t('invitation.plan.chosen')
                     : $t('invitation.plan.choose')
               "
               :aria-pressed="modelValue === plan.id"
               @click="emit('update:modelValue', plan.id)"
            />
         </div>
      </div>

      <div v-if="changes.length" class="card !mb-0 flex flex-col gap-2" data-plan-changes>
         <h4 class="m-0">
            {{ $t('invitation.plan.changes', { plan: selected?.display_name ?? '' }) }}
         </h4>
         <ul class="m-0 pl-5 flex flex-col gap-1">
            <li v-for="change in changes" :key="change.id" :data-change="change.kind">
               {{ change.text }}
            </li>
         </ul>
      </div>
   </div>
</template>
