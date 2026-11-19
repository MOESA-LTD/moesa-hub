<script setup lang="ts">
import type { PlanSummary } from '@/lib/planDiff';

// Step 3: the plans side by side, and the acceptance.
defineProps<{
   plans: PlanSummary[];
   recommendedId: string | null;
   seats: number;
   providerName: string | null;
   coreModules: string[];
   accepting: boolean;
}>();
const planId = defineModel<string | null>({ required: true });
const emit = defineEmits<{ back: []; accept: [] }>();
</script>

<template>
   <div class="flex flex-col gap-4" data-step="plan">
      <h2 class="m-0 text-xl font-medium">{{ $t('invitation.plan.title') }}</h2>
      <p class="m-0 text-muted-color">
         {{ $t('invitation.plan.text') }}
         {{ $t('invitation.plan.seats', { count: seats }, seats) }}
      </p>

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
