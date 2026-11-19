<script setup lang="ts">
import { transferRecordCount } from '@/api/transfer';
import { useConfirmAction } from '@/composables/useConfirmAction';
import type { TransferWizard } from './useTransferWizard';

// The third step: what will be written, and the run. The run is bound to the last rehearsal; when
// the products changed since (transfer_report_stale) the run is refused and the wizard offers a
// new rehearsal instead of a retry.
const props = defineProps<{ wizard: TransferWizard }>();
const {
   mode,
   report,
   targetOption,
   error,
   runStale,
   canRehearse,
   rehearsing,
   running,
   rehearse,
   back,
   run
} = props.wizard;

const { t } = useI18n();
const confirmAction = useConfirmAction();

const total = computed(() => (report.value ? transferRecordCount(report.value) : 0));
const params = computed(() => ({
   count: total.value,
   target: targetOption.value?.display_name ?? ''
}));

const onRun = () =>
   confirmAction({
      header: t('ops.transfer.run'),
      message: t(`ops.transfer.confirm.${mode.value}`, params.value),
      acceptLabel: t('ops.transfer.run'),
      accept: async () => {
         await run();
      }
   });
</script>

<template>
   <div v-if="report" class="flex flex-col gap-6">
      <section class="flex flex-col gap-2">
         <h4 class="font-semibold">{{ $t('ops.transfer.apply.heading') }}</h4>
         <p data-summary>{{ $t(`ops.transfer.apply.${mode}`, params) }}</p>
      </section>

      <Message v-if="runStale" severity="warn" data-stale>
         {{ $t('ops.transfer.apply.stale') }}
      </Message>
      <Message v-if="error" severity="error" size="small" data-run-error>{{ error }}</Message>

      <div class="flex flex-wrap justify-end gap-2">
         <Button
            :label="$t('action.back')"
            severity="secondary"
            outlined
            :disabled="running"
            @click="back"
         />
         <Button
            v-if="runStale"
            :label="$t('ops.transfer.rehearse_again')"
            :icon="PrimeIcons.REFRESH"
            :disabled="!canRehearse"
            :loading="rehearsing"
            data-rehearse-again
            @click="rehearse"
         />
         <Button
            v-else
            :label="$t('ops.transfer.run')"
            :icon="PrimeIcons.ARROW_RIGHT_ARROW_LEFT"
            :loading="running"
            data-run
            @click="onRun"
         />
      </div>
   </div>
</template>
