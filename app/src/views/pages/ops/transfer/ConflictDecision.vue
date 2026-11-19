<script setup lang="ts">
import { SUPPLIER_CODE } from '@/api/supplier';
import type { TransferAction, TransferConflict, TransferDecision } from '@/api/transfer';
import { useLookup } from '@/api/useLookup';

// One conflict of the rehearsal and its decision. Only the actions the database offers for it are
// listed: a supplier code may be mapped to a supplier of the target or given a new code; a SKU is
// renamed with a suffix (or skipped in a copy); an active GTIN is cleared (or the product skipped).
// The report carries no names, so the row is labelled by what the caller read through the views.
const props = defineProps<{
   conflict: TransferConflict;
   decision: TransferDecision | null;
   target: string;
   /** The SKU or supplier code of the conflict's row; null when the caller may not read it. */
   label: string | null;
   /** Another supplier is given the same new code (the report marks it taken after a rehearsal). */
   duplicate?: boolean;
   /** The decisions changed since the rehearsal, so its taken marks no longer describe them. */
   stale?: boolean;
}>();
const emit = defineEmits<{ decide: [decision: TransferDecision | null] }>();

const { t, te } = useI18n();

const tableLabel = (table: string) => (te(`fields.${table}`) ? t(`fields.${table}`) : table);

const SUFFIX = /^[A-Za-z0-9._-]{1,20}$/;

const shown = computed(() => props.label ?? props.conflict.source_id.slice(0, 8));

const skipDrops = computed(() =>
   Object.entries(props.conflict.skip_drops ?? {})
      .filter(([, count]) => count > 0)
      .map(([table, count]) =>
         t('ops.transfer.skip_drops_item', { table: tableLabel(table), count })
      )
      .join(', ')
);

const actionOptions = computed(() =>
   props.conflict.actions.map((action) => ({
      value: action,
      label: t(`ops.transfer.action.${action}`),
      hint:
         action === 'skip' && skipDrops.value
            ? t('ops.transfer.skip_drops', { list: skipDrops.value })
            : null
   }))
);

const action = computed({
   get: () => props.decision?.action ?? null,
   set: (value: TransferAction | null) => {
      if (!value) return emit('decide', null);
      if (value === 'map')
         return emit('decide', {
            action: 'map',
            ...(props.conflict.existing_id ? { target_id: props.conflict.existing_id } : {})
         });
      emit('decide', { action: value });
   }
});

// The target's suppliers, to map a supplier to and to know the codes a new code must not take.
const isSupplier = computed(() => props.conflict.kind === 'supplier_code');
const lookupEnabled = computed(
   () => isSupplier.value && (action.value === 'map' || action.value === 'new_code')
);
const { data: rows, isLoading: rowsLoading } = useLookup<{
   id: string;
   code: string;
   display_name: string;
}>(
   'supplier',
   () => ({
      select: 'id, code, display_name',
      order: 'code',
      in: { column: 'tenant_id', values: [props.target] }
   }),
   lookupEnabled
);
const rowOptions = computed(() =>
   (rows.value ?? []).map(({ id, code, display_name }) => ({
      id,
      label: `${code} · ${display_name}`
   }))
);

const targetId = computed({
   get: () => props.decision?.target_id ?? null,
   set: (value: string | null) =>
      emit('decide', { action: 'map', ...(value ? { target_id: value } : {}) })
});

const code = computed({
   get: () => props.decision?.code ?? '',
   set: (value: string) =>
      emit('decide', { action: 'new_code', ...(value ? { code: value.toUpperCase() } : {}) })
});
const suffix = computed({
   get: () => props.decision?.suffix ?? '',
   set: (value: string) => emit('decide', { action: 'rename', ...(value ? { suffix: value } : {}) })
});

// Why a typed value cannot be used: the format, a value taken in the target or by another row of
// the package (the rehearsal marks the conflict taken), or the same code twice.
const typedReason = computed(() => {
   if (action.value === 'new_code' && code.value) {
      if (!SUPPLIER_CODE.test(code.value)) return t('ops.transfer.conflict.code_format');
      if ((rows.value ?? []).some((row) => row.code === code.value))
         return t('ops.transfer.conflict.code_taken');
      if (props.duplicate) return t('ops.transfer.conflict.duplicate_code');
   }
   if (action.value === 'rename' && suffix.value && !SUFFIX.test(suffix.value))
      return t('ops.transfer.conflict.suffix_format');
   if (props.conflict.taken && !props.stale && (code.value || suffix.value))
      return t('ops.transfer.conflict.code_taken');
   return null;
});

const newSku = computed(() =>
   props.label && suffix.value
      ? t('ops.transfer.decision.new_sku', { sku: props.label + suffix.value })
      : null
);

const message = computed(() =>
   t(`ops.transfer.conflict.${props.conflict.kind}`, { label: shown.value })
);
</script>

<template>
   <div class="flex flex-col gap-2 py-3" :data-conflict="conflict.key">
      <div class="flex flex-wrap items-center gap-2">
         <Tag severity="secondary" :value="$t(`ops.transfer.conflict_kind.${conflict.kind}`)" />
         <span>{{ message }}</span>
      </div>
      <div class="flex flex-wrap items-start gap-3">
         <Select
            v-model="action"
            :options="actionOptions"
            optionLabel="label"
            optionValue="value"
            :placeholder="$t('common.select')"
            class="min-w-60"
            data-action
         >
            <template #option="{ option }">
               <span class="flex flex-col">
                  <span>{{ option.label }}</span>
                  <small v-if="option.hint" class="text-muted-color">{{ option.hint }}</small>
               </span>
            </template>
         </Select>

         <Select
            v-if="action === 'map' && isSupplier"
            v-model="targetId"
            :options="rowOptions"
            optionLabel="label"
            optionValue="id"
            :loading="rowsLoading"
            :placeholder="$t('ops.transfer.decision.target')"
            filter
            class="min-w-60"
            data-target-row
         />

         <span v-if="action === 'new_code'" class="flex flex-col gap-1">
            <InputText
               v-model="code"
               :placeholder="$t('ops.transfer.decision.code')"
               :aria-label="$t('ops.transfer.decision.code')"
               :invalid="!!typedReason"
               data-code
            />
         </span>

         <span v-if="action === 'rename'" class="flex flex-col gap-1">
            <InputText
               v-model="suffix"
               :placeholder="$t('ops.transfer.decision.suffix')"
               :aria-label="$t('ops.transfer.decision.suffix')"
               :invalid="!!typedReason"
               data-suffix
            />
            <small v-if="newSku" class="text-muted-color" data-new-sku>{{ newSku }}</small>
         </span>

         <small v-if="typedReason" class="self-center text-red-500" data-typed-reason>
            {{ typedReason }}
         </small>

         <small
            v-if="action === 'skip' && skipDrops"
            class="self-center text-muted-color"
            data-drops
         >
            {{ $t('ops.transfer.skip_drops', { list: skipDrops }) }}
         </small>
      </div>
   </div>
</template>
