<script setup lang="ts">
import { provideFormTenant } from '@/api/formTenant';
import { transferRecordCount, useTransferLabels } from '@/api/transfer';
import ConflictDecision from './ConflictDecision.vue';
import type { TransferWizard } from './useTransferWizard';

// The rehearsal's report and the decisions on its conflicts. The report holds ids only, so the
// SKUs and supplier codes it names are read through the normal views (which mask for the caller).
// Every lookup in here reads the target tenant alone (provideFormTenant): without it, row-level
// security returns the active tenant's rows, and a conflict could be linked to a row the database
// refuses.
const props = defineProps<{ wizard: TransferWizard }>();
const {
   target,
   mode,
   decisions,
   report,
   stale,
   moveBlocked,
   duplicateCodes,
   error,
   canRehearse,
   canRun,
   rehearsing,
   decide,
   rehearse,
   back,
   toApply
} = props.wizard;

provideFormTenant(target);

const { t, te } = useI18n();

const source = computed(() => report.value?.source_tenant ?? null);
const productLabels = useTransferLabels(
   'product',
   source,
   () => report.value?.product_ids ?? []
).data;
const supplierLabels = useTransferLabels('supplier', source, () =>
   (report.value?.conflicts ?? []).filter((c) => c.table === 'supplier').map((c) => c.source_id)
).data;

const labelOf = (table: string, id: string): string | null =>
   (table === 'supplier' ? supplierLabels.value : productLabels.value)?.[id]?.key ?? null;

const tableLabel = (table: string) => (te(`fields.${table}`) ? t(`fields.${table}`) : table);
// A column by its field label; a foreign key (`product_id`) by its table's, else the raw name.
const columnLabel = (column: string) => {
   if (te(`fields.${column}`)) return t(`fields.${column}`);
   const table = column.replace(/_id$/, '');
   return table !== column && te(`fields.${table}`) ? t(`fields.${table}`) : column;
};

const counts = computed(() =>
   Object.entries(report.value?.counts ?? {}).filter(([, count]) => count > 0)
);

const excludedList = computed(() => (report.value?.excluded ?? []).map(tableLabel).join(', '));
// C1: into a client, the rows a client may not read stay behind and provider-only columns are emptied.
const withheldList = computed(() =>
   Object.entries(report.value?.excluded_rows ?? {})
      .filter(([, rows]) => rows > 0)
      .map(([table, rows]) => `${tableLabel(table)} (${rows})`)
      .join(', ')
);
const blankedList = computed(() =>
   (report.value?.blanked ?? [])
      .map(({ table, column, rows }) => `${tableLabel(table)}: ${columnLabel(column)} (${rows})`)
      .join(', ')
);
const linksList = computed(() =>
   Object.entries(report.value?.left_behind_links ?? {})
      .map(([table, rows]) => `${tableLabel(table)} (${rows})`)
      .join(', ')
);

const gapText = (gap: { rule: string; source_id: string; table: string }) => {
   const label = labelOf(gap.table, gap.source_id) ?? gap.source_id.slice(0, 8);
   return te(`ops.transfer.report.${gap.rule}`)
      ? t(`ops.transfer.report.${gap.rule}`, { label })
      : `${label}: ${gap.rule}`;
};
</script>

<template>
   <div v-if="report && target" class="flex flex-col gap-6">
      <Message v-if="report.excluded.length" severity="info" data-excluded>
         <span class="font-semibold">{{ $t('ops.transfer.report.excluded_title') }}</span>
         {{ $t('ops.transfer.report.excluded', { list: excludedList }) }}
      </Message>

      <Message v-if="withheldList || blankedList" severity="info" data-withheld>
         <span class="font-semibold">{{ $t('ops.transfer.report.withheld_title') }}</span>
         {{ $t('ops.transfer.report.withheld_intro') }}
         <span v-if="withheldList" data-withheld-rows>
            {{ $t('ops.transfer.report.withheld', { list: withheldList }) }}
         </span>
         <span v-if="blankedList" data-blanked>
            {{ $t('ops.transfer.report.blanked', { list: blankedList }) }}
         </span>
      </Message>

      <section class="flex flex-col gap-2">
         <h4 class="font-semibold">{{ $t('ops.transfer.report.counts') }}</h4>
         <table class="w-full max-w-md text-sm" data-counts>
            <tbody>
               <tr v-for="[table, count] in counts" :key="table" class="border-b border-surface">
                  <td class="py-1">{{ tableLabel(table) }}</td>
                  <td class="py-1 text-end tabular-nums">{{ count }}</td>
               </tr>
            </tbody>
         </table>
         <small class="text-muted-color">{{ transferRecordCount(report) }}</small>
      </section>

      <section class="flex flex-col gap-1">
         <h4 class="font-semibold">{{ $t('ops.transfer.report.conflicts') }}</h4>
         <p v-if="!report.conflicts.length" class="text-muted-color">
            {{ $t('ops.transfer.report.no_conflicts') }}
         </p>
         <div v-else class="flex flex-col divide-y divide-surface">
            <ConflictDecision
               v-for="conflict in report.conflicts"
               :key="conflict.key"
               :conflict
               :decision="decisions[conflict.key] ?? null"
               :target
               :label="labelOf(conflict.table, conflict.source_id)"
               :duplicate="duplicateCodes.has(conflict.key)"
               :stale
               @decide="decide(conflict.key, $event)"
            />
         </div>
         <Message v-if="report.unresolved > 0" severity="warn" size="small" data-unresolved>
            {{ $t('ops.transfer.unresolved', { count: report.unresolved }) }}
         </Message>
      </section>

      <Message v-if="mode === 'move' && linksList" severity="warn" data-left-behind-links>
         <span class="font-semibold">{{ $t('ops.transfer.report.links_title') }}</span>
         {{ $t('ops.transfer.report.links', { list: linksList }) }}
      </Message>

      <section v-if="report.left_behind.length" class="flex flex-col gap-1" data-left-behind>
         <h4 class="font-semibold">{{ $t('ops.transfer.report.left_behind') }}</h4>
         <ul class="list-disc ps-5">
            <li v-for="(link, index) in report.left_behind" :key="index">
               {{
                  $t('ops.transfer.report.left_behind_item', {
                     table: tableLabel(link.table),
                     column: columnLabel(link.column),
                     rows: link.rows
                  })
               }}
            </li>
         </ul>
         <Message v-if="moveBlocked" severity="error" size="small" data-move-blocked>
            {{ $t('ops.transfer.move_blocked') }}
         </Message>
      </section>

      <section
         v-if="report.cleared.length && mode === 'copy'"
         class="flex flex-col gap-1"
         data-cleared
      >
         <h4 class="font-semibold">{{ $t('ops.transfer.report.cleared') }}</h4>
         <ul class="list-disc ps-5">
            <li v-for="(item, index) in report.cleared" :key="index">
               {{
                  $t('ops.transfer.report.cleared_item', {
                     table: tableLabel(item.table),
                     column: columnLabel(item.column),
                     rows: item.rows
                  })
               }}
            </li>
         </ul>
      </section>

      <section v-if="report.settings_gaps.length" class="flex flex-col gap-1" data-gaps>
         <h4 class="font-semibold">{{ $t('ops.transfer.report.settings_gaps') }}</h4>
         <ul class="list-disc ps-5">
            <li v-for="(gap, index) in report.settings_gaps" :key="index">{{ gapText(gap) }}</li>
         </ul>
      </section>

      <p v-if="report.files" data-files>
         {{ $t('ops.transfer.report.files', { count: report.files }) }}
      </p>

      <Message v-if="error" severity="error" size="small" data-run-error>{{ error }}</Message>

      <div class="flex flex-wrap justify-end gap-2">
         <Button
            :label="$t('action.back')"
            severity="secondary"
            outlined
            :disabled="rehearsing"
            @click="back"
         />
         <Button
            v-if="stale"
            :label="$t('ops.transfer.rehearse_again')"
            :icon="PrimeIcons.REFRESH"
            outlined
            :disabled="!canRehearse"
            :loading="rehearsing"
            data-rehearse-again
            @click="rehearse"
         />
         <Button
            :label="$t('ops.transfer.next')"
            :icon="PrimeIcons.ARROW_RIGHT"
            :disabled="!canRun"
            data-next
            @click="toApply"
         />
      </div>
   </div>
</template>
