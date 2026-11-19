<script setup lang="ts">
import {
   transferErrorText,
   transferFilesState,
   useRetryTransferFiles,
   type TransferRow
} from '@/api/transfer';

// The file status of a transfer (its files are copied after the run): pending, partly copied or
// done, with a retry of the copy while there is a file the app can copy. A file whose target
// object differs from its record (mismatch) is never retried: only an administrator can fix it.
const props = defineProps<{
   transfer: TransferRow;
   /** Says what the notice is about, where the transfer itself is not on screen. */
   heading?: boolean;
}>();

const { t } = useI18n();
const { mutateAsync: retryFiles, isPending: retrying } = useRetryTransferFiles();

const done = computed(() => props.transfer.files_status === 'done');
const state = computed(() => transferFilesState(props.transfer));

const statusText = computed(() => {
   const status = props.transfer.files_status;
   if (status === 'partial') {
      const count = state.value.retryable;
      return count ? t('ops.transfer.files.partial', { count }, count) : '';
   }
   return t(`ops.transfer.files.${status === 'done' ? 'done' : 'pending'}`);
});
const adminText = computed(() =>
   state.value.needsAdmin
      ? t(
           'ops.transfer.files.needs_admin',
           { count: state.value.needsAdmin },
           state.value.needsAdmin
        )
      : ''
);
const canRetry = computed(() => !done.value && state.value.canCopy && state.value.retryable > 0);

/** The text of the last failed retry; cleared by the next one. */
const error = ref<string | null>(null);

const retry = async () => {
   error.value = null;
   try {
      await retryFiles(props.transfer);
   } catch (failure) {
      // Shown here; rethrown for the app's error toast.
      error.value = transferErrorText(failure);
      throw failure;
   }
};
</script>

<template>
   <Message :severity="done ? 'success' : 'warn'">
      <div class="flex flex-col gap-2">
         <span v-if="heading" class="font-semibold" data-files-heading>
            {{ $t('ops.transfer.files.notice') }}
         </span>
         <span v-if="statusText" data-files-status>{{ statusText }}</span>
         <span v-if="adminText" data-files-admin>{{ adminText }}</span>
         <span v-if="!done && !state.canCopy" data-files-masked>
            {{ $t('ops.transfer.files.masked') }}
         </span>
         <span v-if="canRetry" data-retry>
            <Button
               :label="$t('ops.transfer.files.retry')"
               :icon="PrimeIcons.REFRESH"
               size="small"
               outlined
               :loading="retrying"
               @click="retry"
            />
         </span>
         <small v-if="error" class="text-red-500" data-files-error>{{ error }}</small>
      </div>
   </Message>
</template>
