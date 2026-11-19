import {
   isStaleReport,
   transferErrorText,
   transferFilesState,
   useCopyTransferFiles,
   useRehearseTransfer,
   useRunTransfer,
   useTransferOptions,
   type TransferArgs,
   type TransferDecision,
   type TransferDecisions,
   type TransferMode,
   type TransferReport,
   type TransferRow
} from '@/api/transfer';
import { computed, ref, toValue, watch, type MaybeRefOrGetter } from 'vue';

export type TransferStep = 'target' | 'report' | 'apply' | 'files';

/** JSON with every object's keys sorted, so the same decisions read the same in any order. */
const stableStringify = (value: unknown): string =>
   JSON.stringify(value, (_key, item: unknown) =>
      item && typeof item === 'object' && !Array.isArray(item)
         ? Object.fromEntries(
              Object.entries(item as Record<string, unknown>).sort(([a], [b]) =>
                 a < b ? -1 : a > b ? 1 : 0
              )
           )
         : item
   );

export type TransferWizardOptions = {
   sourceTenant: MaybeRefOrGetter<string | null>;
   /** The products to transfer, all of the source tenant. */
   productIds: MaybeRefOrGetter<string[]>;
};

/**
 * The state of the transfer wizard: the target and mode, the decisions on the conflicts, the
 * rehearsal's report, the run and the file copy. A run sends the hash of the last report, so it
 * is offered only while the report still describes what would run: no change since the
 * rehearsal, no conflict left open, and, in a move, no record left behind that blocks it.
 */
export function useTransferWizard({ sourceTenant, productIds }: TransferWizardOptions) {
   const { data: options, isLoading: optionsLoading } = useTransferOptions(sourceTenant);
   const { mutateAsync: rehearseTransfer, isPending: rehearsing } = useRehearseTransfer();
   const { mutateAsync: runTransfer, isPending: running } = useRunTransfer();
   const {
      mutateAsync: copyFiles,
      isPending: copying,
      progress: copyProgress
   } = useCopyTransferFiles();

   const step = ref<TransferStep>('target');
   const target = ref<string | null>(null);
   const mode = ref<TransferMode>('copy');
   const decisions = ref<TransferDecisions>({});
   const report = ref<TransferReport | null>(null);
   const transfer = ref<TransferRow | null>(null);

   const snapshot = () =>
      stableStringify({ target: target.value, mode: mode.value, decisions: decisions.value });
   /** The text of the last failed rehearsal or run; cleared by the next attempt. */
   const error = ref<string | null>(null);
   /** The run was refused because the products changed since the rehearsal. */
   const runStale = ref(false);
   /** What the last rehearsal was asked with; null before one. */
   const rehearsedWith = ref<string | null>(null);

   const sourceWritable = computed(() => options.value?.source_writable !== false);
   const targetOption = computed(
      () => options.value?.targets.find(({ id }) => id === target.value) ?? null
   );

   // A read-only source cannot lose its rows: only a copy.
   watch(
      [sourceWritable, mode],
      ([writable]) => {
         if (!writable && mode.value !== 'copy') mode.value = 'copy';
      },
      { immediate: true, flush: 'sync' }
   );

   // Another target or mode is another package: its conflicts, and so its decisions, differ.
   watch(
      [target, mode],
      () => {
         decisions.value = {};
         report.value = null;
         rehearsedWith.value = null;
         error.value = null;
         runStale.value = false;
         if (step.value === 'report' || step.value === 'apply') step.value = 'target';
      },
      { flush: 'sync' }
   );

   const stale = computed(() => rehearsedWith.value !== null && rehearsedWith.value !== snapshot());

   /**
    * A move into a client that would drop provider data (withheld rows, emptied columns): the
    * database refuses it (transfer_move_would_lose_data); a copy keeps the source whole.
    */
   const moveLosesData = computed(
      () => mode.value === 'move' && !!report.value && report.value.move_loses_data
   );

   /** A move that would leave records in the source that use the products: the database refuses it (transfer_product_in_use). */
   const moveBlocked = computed(
      () =>
         mode.value === 'move' && !!report.value && report.value.left_behind.some((l) => l.blocks)
   );

   /**
    * The supplier conflicts given the same new code as another. The rehearsal marks a code another
    * decision uses as taken, but only after it runs again; this shows it while typing.
    */
   const duplicateCodes = computed(() => {
      const byCode = new Map<string, string[]>();
      for (const { key, kind } of report.value?.conflicts ?? []) {
         if (kind !== 'supplier_code') continue;
         const decision = decisions.value[key];
         if (decision?.action !== 'new_code' || !decision.code) continue;
         byCode.set(decision.code, [...(byCode.get(decision.code) ?? []), key]);
      }
      return new Set([...byCode.values()].filter((keys) => keys.length > 1).flat());
   });

   const busy = computed(() => rehearsing.value || running.value || copying.value);

   const canRehearse = computed(
      () =>
         !!toValue(sourceTenant) &&
         toValue(productIds).length > 0 &&
         !!targetOption.value &&
         !targetOption.value.refusal &&
         !busy.value
   );

   const canRun = computed(
      () =>
         !!report.value &&
         report.value.unresolved === 0 &&
         !stale.value &&
         !moveBlocked.value &&
         !moveLosesData.value &&
         duplicateCodes.value.size === 0 &&
         !busy.value
   );

   const decide = (key: string, decision: TransferDecision | null) => {
      const next = { ...decisions.value };
      if (decision) next[key] = decision;
      else delete next[key];
      decisions.value = next;
   };

   const args = (): TransferArgs => ({
      source_tenant: toValue(sourceTenant)!,
      target_tenant: target.value!,
      mode: mode.value,
      decisions: decisions.value,
      product_ids: [...toValue(productIds)]
   });

   const rehearse = async () => {
      if (!canRehearse.value) return;
      const asked = snapshot();
      error.value = null;
      runStale.value = false;
      let result: TransferReport;
      try {
         result = await rehearseTransfer(args());
      } catch (failure) {
         // Shown in the wizard; rethrown for the app's error toast.
         error.value = transferErrorText(failure);
         throw failure;
      }
      report.value = result;
      rehearsedWith.value = asked;
      step.value = 'report';
   };

   const back = () => {
      if (step.value === 'apply') step.value = 'report';
      else if (step.value === 'report') step.value = 'target';
   };

   /** The report is reviewed: on to the confirmation. */
   const toApply = () => {
      if (canRun.value) step.value = 'apply';
   };

   /** The files of the run, copied now with their progress; a failure leaves the row pending for a retry. */
   const copy = async () => {
      const row = transfer.value;
      if (!row || row.files_status === 'done' || !transferFilesState(row).canCopy) return;
      transfer.value = await copyFiles(row);
   };

   const run = async () => {
      if (!canRun.value || !report.value) throw new Error('The transfer is not ready to run');
      error.value = null;
      runStale.value = false;
      let row: TransferRow;
      try {
         row = await runTransfer({ args: args(), reportHash: report.value.report_hash });
      } catch (failure) {
         error.value = transferErrorText(failure);
         // The products changed: the report is out of date, so it is rehearsed again, not retried.
         runStale.value = isStaleReport(failure);
         throw failure;
      }
      transfer.value = row;
      step.value = 'files';
      await copy();
      return transfer.value;
   };

   return {
      options,
      optionsLoading,
      sourceWritable,
      targetOption,
      step,
      target,
      mode,
      decisions,
      report,
      transfer,
      stale,
      runStale,
      moveBlocked,
      moveLosesData,
      duplicateCodes,
      error,
      canRehearse,
      canRun,
      rehearsing,
      running,
      copying,
      copyProgress,
      decide,
      rehearse,
      back,
      toApply,
      run
   };
}

export type TransferWizard = ReturnType<typeof useTransferWizard>;
