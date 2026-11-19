<script setup lang="ts">
import {
   asIdMap,
   idMapCsv,
   transferRecordCount,
   useTransfer,
   type TransferProgress,
   type TransferReport,
   type TransferRow
} from '@/api/transfer';
import TransferFilesNotice from '@/components/service-components/transfer/TransferFilesNotice.vue';
import dayjs from 'dayjs';

// The last step: what the run wrote, its ID map to download, and the copy of its files with their
// progress. The row is read again (with the source and the target in scope, so the masked fields
// follow the caller's rights in both), which shows a retried file copy.
const props = defineProps<{
   transfer: TransferRow;
   report: TransferReport;
   /** The file copy is running; null once it is not. */
   progress: TransferProgress | null;
   copying: boolean;
}>();

const { data: current } = useTransfer(
   () => props.transfer.id,
   () => props.report.source_tenant,
   () => props.report.target_tenant
);
// The row the wizard holds is the newest while the files copy; the read one after a retry.
const row = computed(() => (props.copying ? props.transfer : (current.value ?? props.transfer)));

// Masked for a caller without the rights in both tenants: nothing to download.
const idMap = computed(() => {
   const json = row.value.id_map;
   return json && typeof json === 'object' && !Array.isArray(json) ? asIdMap(json) : {};
});
const count = computed(() => transferRecordCount(props.report));

const downloadIdMap = () => {
   // With a byte order mark, so spreadsheets read the file as UTF-8 (as the product export).
   const blob = new Blob([String.fromCharCode(0xfeff), idMapCsv(idMap.value)], {
      type: 'text/csv;charset=utf-8'
   });
   const url = URL.createObjectURL(blob);
   const link = document.createElement('a');
   link.href = url;
   link.download = `transfer_${dayjs().format('YYYYMMDD')}.csv`;
   link.click();
   URL.revokeObjectURL(url);
};
</script>

<template>
   <div class="flex flex-col gap-4">
      <Message severity="success" data-done>
         {{ $t('ops.transfer.result.done', { count }) }}
      </Message>
      <div v-if="Object.keys(idMap).length">
         <Button
            :label="$t('ops.transfer.result.id_map')"
            :icon="PrimeIcons.DOWNLOAD"
            variant="outlined"
            data-id-map
            @click="downloadIdMap"
         />
      </div>
      <div v-if="copying" class="flex flex-col gap-2" data-progress>
         <span>
            {{
               $t('ops.transfer.files.progress', {
                  done: progress?.done ?? 0,
                  total: progress?.total ?? report.files
               })
            }}
         </span>
         <ProgressBar
            :value="
               progress && progress.total ? Math.round((progress.done / progress.total) * 100) : 0
            "
            :showValue="false"
         />
      </div>
      <TransferFilesNotice v-else :transfer="row" />
   </div>
</template>
