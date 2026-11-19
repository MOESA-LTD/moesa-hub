<script setup lang="ts">
import ApplyStep from './ApplyStep.vue';
import ReportStep from './ReportStep.vue';
import ResultStep from './ResultStep.vue';
import TargetStep from './TargetStep.vue';
import { useTransferWizard } from './useTransferWizard';

// Some products of one company copied or moved to another company or branch, as a route dialog:
// pick the target and mode, rehearse, decide the conflicts, apply, then copy the files. The
// products come from the product list's selection (see transferProps in the router).
const props = defineProps<{ sourceTenant: string | null; productIds: string[] }>();

const wizard = useTransferWizard({
   sourceTenant: () => props.sourceTenant,
   productIds: () => props.productIds
});
const { step, transfer, report, copying, copyProgress } = wizard;

// PrimeVue's Step shows its value in the badge, so the steps are numbered 1..4 there; the wizard
// keeps its named steps.
const STEPS = ['target', 'report', 'apply', 'files'] as const;
const stepNumber = computed(() => STEPS.indexOf(step.value) + 1);
</script>

<template>
   <div class="card flex flex-col gap-4">
      <h3 class="text-lg font-semibold">
         {{ $t('ops.transfer.title', { count: productIds.length }, productIds.length) }}
      </h3>
      <Message v-if="!sourceTenant || !productIds.length" severity="secondary" data-no-selection>
         {{ $t('ops.transfer.no_selection') }}
      </Message>
      <Stepper v-else :value="stepNumber" linear>
         <StepList>
            <Step v-for="(name, index) in STEPS" :key="name" :value="index + 1">
               {{ $t(`ops.transfer.steps.${name}`) }}
            </Step>
         </StepList>
         <StepPanels>
            <StepPanel :value="1">
               <TargetStep :wizard />
            </StepPanel>
            <StepPanel :value="2">
               <ReportStep v-if="step === 'report'" :wizard />
            </StepPanel>
            <StepPanel :value="3">
               <ApplyStep v-if="step === 'apply'" :wizard />
            </StepPanel>
            <StepPanel :value="4">
               <ResultStep
                  v-if="step === 'files' && transfer && report"
                  :transfer
                  :report
                  :progress="copyProgress"
                  :copying
               />
            </StepPanel>
         </StepPanels>
      </Stepper>
   </div>
</template>
