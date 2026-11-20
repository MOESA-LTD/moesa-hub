<script setup lang="ts">
import {
   CONTENT_STATUSES,
   commonNextStatuses,
   useBulkUpdateCells,
   type ContentStatus,
   type MarketCellStatus
} from '@/api/marketMatrix';
import i18n from '@plugins/i18n';
import { ToastSeverity } from '@primevue/core/api';
import dayjs from 'dayjs';
import { useToast } from 'primevue/usetoast';

// Several market cells changed at once (the list view's selection): a status move all of them may
// make, the content status, the target launch and a line added to their notes. Each cell is saved
// on its own; one that needs more before the move fails alone and is named with its reason.
type Cell = {
   id: string;
   status: MarketCellStatus;
   notes: string | null;
   sku: string | null;
   country: string;
};

const props = defineProps<{ cells: readonly Cell[] }>();
const visible = defineModel<boolean>('visible', { default: false });
const emit = defineEmits<{ done: [] }>();

const { t } = useI18n();
const toast = useToast();

const moves = computed(() => commonNextStatuses(props.cells.map(({ status }) => status)));

const status = ref<MarketCellStatus | null>(null);
const contentStatus = ref<ContentStatus | null>(null);
const targetLaunch = ref<Date | null>(null);
const note = ref('');

watch(visible, (open) => {
   if (!open) return;
   status.value = null;
   contentStatus.value = null;
   targetLaunch.value = null;
   note.value = '';
});

const hasChange = computed(
   () => !!(status.value || contentStatus.value || targetLaunch.value || note.value.trim())
);

/** A refusal's text: its errors.<code> translation when there is one. */
const reason = (error: unknown) => {
   const message = String((error as { message?: string })?.message ?? error);
   return i18n.te(`errors.${message}`) ? i18n.t(`errors.${message}`) : message;
};

const { mutateAsync, isPending } = useBulkUpdateCells();

async function apply() {
   const { updated, failed } = await mutateAsync({
      cells: props.cells,
      patch: {
         ...(contentStatus.value ? { content_status: contentStatus.value } : {}),
         ...(targetLaunch.value
            ? { target_launch_on: dayjs(targetLaunch.value).format('YYYY-MM-DD') }
            : {})
      },
      note: note.value.trim() || null,
      status: status.value
   });

   if (updated)
      toast.add({
         life: 5000,
         severity: ToastSeverity.SUCCESS,
         summary: t('toast.success'),
         detail: t('ops.market.bulk.updated', { count: updated }, updated)
      });
   if (failed.length) {
      const byId = new Map(props.cells.map((cell) => [cell.id, cell]));
      toast.add({
         life: 0,
         severity: ToastSeverity.WARN,
         summary: t('ops.market.bulk.failed', { count: failed.length }, failed.length),
         detail: failed
            .map(({ id, error }) => {
               const cell = byId.get(id);
               return `${[cell?.sku, cell?.country].filter(Boolean).join(' ')}: ${reason(error)}`;
            })
            .join('\n')
      });
   }
   visible.value = false;
   emit('done');
}
</script>

<template>
   <Dialog
      v-model:visible="visible"
      modal
      :header="$t('ops.market.bulk.title', { count: cells.length }, cells.length)"
      class="w-full max-w-lg"
   >
      <form class="flex flex-col gap-4" data-bulk-cells @submit.prevent="apply">
         <label class="flex flex-col gap-1">
            {{ $t('ops.market.bulk.status') }}
            <Select
               v-model="status"
               :options="moves"
               :optionLabel="(value: MarketCellStatus) => $t(`ops.market.status.${value}`)"
               :placeholder="
                  moves.length ? $t('ops.market.bulk.keep') : $t('ops.market.bulk.no_move')
               "
               :disabled="!moves.length"
               showClear
               data-bulk-status
            />
         </label>
         <label class="flex flex-col gap-1">
            {{ $t('ops.market.fields.content_status') }}
            <Select
               v-model="contentStatus"
               :options="[...CONTENT_STATUSES]"
               :optionLabel="(value: ContentStatus) => $t(`ops.market.content_status.${value}`)"
               :placeholder="$t('ops.market.bulk.keep')"
               showClear
               data-bulk-content
            />
         </label>
         <label class="flex flex-col gap-1">
            {{ $t('ops.market.fields.target_launch_on') }}
            <DatePicker
               v-model="targetLaunch"
               date-format="yy-mm-dd"
               show-icon
               showButtonBar
               :placeholder="$t('ops.market.bulk.keep')"
            />
         </label>
         <label class="flex flex-col gap-1">
            {{ $t('ops.market.bulk.note') }}
            <Textarea v-model="note" auto-resize rows="2" data-bulk-note />
         </label>
         <div class="flex justify-end gap-2">
            <Button
               type="button"
               variant="text"
               :label="$t('action.cancel')"
               @click="visible = false"
            />
            <Button
               type="submit"
               :label="$t('ops.market.bulk.apply', { count: cells.length }, cells.length)"
               :disabled="!hasChange"
               :loading="isPending"
               data-bulk-apply
            />
         </div>
      </form>
   </Dialog>
</template>
