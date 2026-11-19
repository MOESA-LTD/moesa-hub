<script setup lang="ts">
import type { InvitationStaff } from '@/api/invitation/accept';
import type { PlanSummary } from '@/lib/planDiff';

// Step 3: the provider staff who would join (the customer keeps whom it chooses, final review I2),
// the plans side by side, and the acceptance.
defineProps<{
   plans: PlanSummary[];
   recommendedId: string | null;
   seats: number;
   listedStaff: InvitationStaff[];
   providerName: string | null;
   coreModules: string[];
   accepting: boolean;
}>();
const planId = defineModel<string | null>({ required: true });
/** The indexes of the staff kept. */
const kept = defineModel<number[]>('staff', { required: true });
const emit = defineEmits<{ back: []; accept: [] }>();

const { t, te } = useI18n();
const roleLabel = (role: string) =>
   te(`invitation.staff.role.${role}`) ? t(`invitation.staff.role.${role}`) : role;
</script>

<template>
   <div class="flex flex-col gap-4" data-step="plan">
      <h2 class="m-0 text-xl font-medium">{{ $t('invitation.plan.title') }}</h2>
      <p class="m-0 text-muted-color">
         {{ $t('invitation.plan.text') }}
         {{ $t('invitation.plan.seats', { count: seats }, seats) }}
      </p>

      <section v-if="listedStaff.length" class="flex flex-col gap-2" data-staff>
         <h3 class="m-0 text-lg font-medium">
            {{ $t('invitation.staff.title', { provider: providerName ?? '' }) }}
         </h3>
         <p class="m-0 text-muted-color">{{ $t('invitation.staff.text') }}</p>
         <ul class="list-none p-0 m-0 flex flex-col gap-2">
            <li
               v-for="member in listedStaff"
               :key="member.index"
               class="flex items-center gap-2"
               :data-staff-member="member.index"
            >
               <Checkbox
                  v-model="kept"
                  :inputId="`invitation-staff-${member.index}`"
                  :value="member.index"
               />
               <label :for="`invitation-staff-${member.index}`" class="flex flex-wrap gap-x-2">
                  <span class="font-medium">
                     {{ member.display_name ?? $t('invitation.staff.unnamed') }}
                  </span>
                  <span class="text-muted-color">{{ roleLabel(member.role_name) }}</span>
               </label>
            </li>
         </ul>
         <small v-if="!kept.length" class="text-muted-color" data-staff-none>
            {{ $t('invitation.staff.none_kept') }}
         </small>
      </section>

      <PlanCompare
         v-if="plans.length"
         v-model="planId"
         :plans
         :recommendedId
         :seats
         :providerName
         :coreModules
      />
      <Message v-else severity="warn" :closable="false">{{ $t('invitation.plan.none') }}</Message>

      <p class="m-0 text-sm text-muted-color">{{ $t('invitation.accept.contract') }}</p>

      <div class="flex flex-wrap justify-between gap-2">
         <Button
            variant="outlined"
            :label="$t('invitation.back')"
            :icon="PrimeIcons.CARET_LEFT"
            @click="emit('back')"
         />
         <Button
            data-accept
            :disabled="!planId"
            :loading="accepting"
            :label="$t('invitation.accept.action')"
            :icon="PrimeIcons.CHECK"
            @click="emit('accept')"
         />
      </div>
   </div>
</template>
