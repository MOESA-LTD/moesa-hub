import { MEDIA_BUCKET } from '@/api/media';
import { invalidateTables, queryKeys } from '@/api/queryKeys';
import { useTenantKey } from '@/api/useTenantKey';
import { serializeCsv } from '@/lib/csv/serialize';
import { NAMED_ERRORS } from '@/lib/form/postgrestErrors';
import { publicSchema, supabase } from '@/lib/supabase';
import { useMutation, useQuery, useQueryClient, type QueryClient } from '@tanstack/vue-query';
import { computed, ref, toValue, type MaybeRefOrGetter } from 'vue';
import i18n from '@plugins/i18n';
import * as z from 'zod';

// --- types ---

export type TransferMode = 'copy' | 'move';

/** The decisions a conflict may offer (072, private.transfer_report). */
export const TRANSFER_ACTIONS = ['map', 'new_code', 'rename', 'clear_gtin', 'skip'] as const;
export type TransferAction = (typeof TRANSFER_ACTIONS)[number];

/**
 * The conflicts the rehearsal reports (072). A kind the app does not know yet is read as
 * 'unknown', so a newer database does not break the report.
 */
export const TRANSFER_CONFLICT_KINDS = ['supplier_code', 'sku', 'gtin'] as const;
export type TransferConflictKind = (typeof TRANSFER_CONFLICT_KINDS)[number] | 'unknown';

export type TransferDecision = {
   action: TransferAction;
   /** map: a supplier of the target. */
   target_id?: string;
   /** new_code: a supplier code. */
   code?: string;
   /** rename: appended to the SKU. */
   suffix?: string;
};
/** Keyed by the conflict's key (`supplier:<id>`, `sku:<id>`, `gtin:<id>`). */
export type TransferDecisions = Record<string, TransferDecision>;

const isTransferAction = (action: string): action is TransferAction =>
   (TRANSFER_ACTIONS as readonly string[]).includes(action);

const conflictSchema = z.object({
   key: z.string(),
   kind: z.enum([...TRANSFER_CONFLICT_KINDS, 'unknown']).catch('unknown'),
   table: z.string(),
   source_id: z.string(),
   existing_id: z.string().nullable(),
   // An action the app does not know is dropped: it cannot be offered.
   actions: z.array(z.string()).transform((actions) => actions.filter(isTransferAction)),
   // Only on a conflict that offers skip: what the skip drops with the row, {table: count}.
   skip_drops: z.record(z.string(), z.number()).optional(),
   // A typed code or renamed SKU that another decision or another package row already uses.
   taken: z.boolean().optional()
});
export type TransferConflict = z.infer<typeof conflictSchema>;

/**
 * The rehearsal's report: counts, ids, table and column names only (072). It carries no SKU,
 * name or price; the app reads those by id through the normal views, which mask for the caller.
 */
export const transferReportSchema = z.object({
   mode: z.enum(['copy', 'move']),
   source_tenant: z.string(),
   target_tenant: z.string(),
   product_ids: z.array(z.string()),
   counts: z.record(z.string(), z.number()),
   /** Tables left out because the target is a client of the source (supplier, sourcing, ...). */
   excluded: z.array(z.string()),
   /**
    * {table: n}: rows left out because the target is a client of the source and a client may not
    * read them (restricted documents, restricted files and their links). Absent in older reports.
    */
   excluded_rows: z.record(z.string(), z.number()).default({}),
   /** Provider-only columns emptied in the copies into a client, with the rows that had a value. */
   blanked: z
      .array(z.object({ table: z.string(), column: z.string(), rows: z.number() }))
      .default([]),
   /** A move into a client that would drop provider data: the run refuses it (copy instead). */
   move_loses_data: z.boolean().default(false),
   conflicts: z.array(conflictSchema),
   /** The source's rows outside the package that refer to a package row. */
   left_behind: z.array(
      z.object({
         table: z.string(),
         column: z.string(),
         refers_to: z.string(),
         refers_to_id: z.string(),
         rows: z.number(),
         /** A move could not remove the package row without breaking or deleting them. */
         blocks: z.boolean()
      })
   ),
   /** {table: n}: rows of other tenants that refer to a package row; a move leaves them a snapshot. */
   left_behind_links: z.record(z.string(), z.number()),
   /** Package rows whose reference to a row outside the package a copy clears. */
   cleared: z.array(
      z.object({
         table: z.string(),
         column: z.string(),
         refers_to: z.string(),
         rows: z.number()
      })
   ),
   settings_gaps: z.array(z.object({ rule: z.string(), table: z.string(), source_id: z.string() })),
   /** How many files (media and thumbnails) the run copies. */
   files: z.number(),
   /** How many conflicts have no valid decision. */
   unresolved: z.number(),
   report_hash: z.string()
});
export type TransferReport = z.infer<typeof transferReportSchema>;

export type TransferRow = Tables['transfer']['Row'];
export type TransferFile = { media_id: string; from: string; to: string; keep_source: boolean };
/** {table: {source id: target id}}. */
export type TransferIdMap = Record<string, Record<string, string>>;

export type TransferOptions = {
   source_writable: boolean;
   targets: { id: string; display_name: string; same_company: boolean; refusal: string | null }[];
};

export type TransferArgs = {
   source_tenant: string;
   target_tenant: string;
   mode: TransferMode;
   decisions: TransferDecisions;
   product_ids: string[];
};

// --- narrowing of the Json columns ---

export const transferIdMapSchema = z.record(z.string(), z.record(z.string(), z.string()));
export const transferFilesSchema = z.array(
   z.object({ media_id: z.string(), from: z.string(), to: z.string(), keep_source: z.boolean() })
);

/** The transfer's id_map; a malformed column throws a ZodError instead of being read silently. */
export const asIdMap = (json: Json): TransferIdMap => transferIdMapSchema.parse(json);

/** The transfer's files; a malformed column throws a ZodError. */
export const asTransferFiles = (json: Json): TransferFile[] => transferFilesSchema.parse(json);

/** The rehearsal's report (or a transfer's report column); another shape throws a ZodError. */
export const asTransferReport = (json: Json): TransferReport => transferReportSchema.parse(json);

/** How many records a transfer writes: the sum of the report's counts, which leave out skipped and mapped rows. */
export const transferRecordCount = (report: Pick<TransferReport, 'counts'>): number =>
   Object.values(report.counts).reduce((sum, count) => sum + count, 0);

/** The text of a failed rehearsal, run or file copy: a named transfer error by its message, else as is. */
export const transferErrorText = (error: unknown): string => {
   const { message } = (error ?? {}) as { message?: string };
   const named = NAMED_ERRORS.find(({ name }) => message?.includes(name));
   if (named) return i18n.t(named.message);
   if (message && i18n.te(`errors.${message}`)) return i18n.t(`errors.${message}`);
   return message || i18n.t('errors.unknown');
};

/** The run's refusal because the products changed since the rehearsal: rehearse again. */
export const isStaleReport = (error: unknown): boolean =>
   ((error ?? {}) as { message?: string }).message?.includes('transfer_report_stale') ?? false;

// --- requests ---

/** The targets of a transfer out of `sourceTenant`, each with the refusal of a copy into it. */
export async function fetchTransferOptions(sourceTenant: string): Promise<TransferOptions> {
   const { data } = await publicSchema
      .rpc('transfer_options', { source_tenant: sourceTenant })
      .throwOnError();
   return data as TransferOptions;
}

const transferCall = (args: TransferArgs, decisions: Json, rehearse: boolean) =>
   publicSchema
      .rpc('transfer_products', {
         source_tenant: args.source_tenant,
         target_tenant: args.target_tenant,
         product_ids: args.product_ids,
         mode: args.mode,
         decisions,
         rehearse
      })
      .throwOnError();

/** The rehearsal: the report, nothing written. */
export async function rehearseTransfer(args: TransferArgs): Promise<TransferReport> {
   const { data } = await transferCall(args, args.decisions as Json, true);
   return asTransferReport(data);
}

/**
 * The run. The rehearsal's `report_hash` travels inside the decisions; without it, or after the
 * products changed, the database refuses with transfer_report_stale (409).
 */
export async function runTransfer(args: TransferArgs, reportHash: string): Promise<TransferRow> {
   const { data } = await transferCall(
      args,
      { ...args.decisions, report_hash: reportHash } as Json,
      false
   );
   return data as unknown as TransferRow;
}

const MISMATCH = 'mismatch:';

export type TransferFilesState = {
   /** Files the app can copy now: the whole list while pending, else the missing ones. */
   retryable: number;
   /** Files whose target object differs from the record: only an administrator can fix them. */
   needsAdmin: number;
   /** False when the files column is masked for this caller. */
   canCopy: boolean;
};

/** What a caller can still do for a transfer's files. */
export function transferFilesState(transfer: TransferRow): TransferFilesState {
   const files = transfer.files;
   if (!Array.isArray(files)) return { retryable: 0, needsAdmin: 0, canCopy: false };
   const missing = transfer.missing_files ?? [];
   const needsAdmin = missing.filter((path) => path.startsWith(MISMATCH)).length;
   const retryable =
      transfer.files_status === 'pending'
         ? files.length
         : missing.filter((path) => !path.startsWith(MISMATCH)).length;
   return { retryable, needsAdmin, canCopy: true };
}

const REMOVE_BATCH = 1000;

/** Storage's answer when the target object is there already (409 Duplicate). */
const alreadyExists = (error: { message?: string; statusCode?: string | number }) =>
   /already exists/i.test(error.message ?? '') || String(error.statusCode) === '409';

export type TransferProgress = { done: number; total: number };

/**
 * Copies the transfer's files to their target paths, then checks them (transfer_check_files).
 * While the files are pending it copies every entry, afterwards only the missing ones; a
 * `mismatch:` entry is never copied (the object is there but differs, and only the service role
 * can replace it). A failed copy is logged, never thrown: the check lists it in missing_files and
 * a retry copies it again. Only a move whose files are all there ('done') removes the sources,
 * and only those marked keep_source false; a failed removal leaves an unreachable object, logged.
 */
export async function copyTransferFiles(
   transfer: TransferRow,
   onProgress?: (progress: TransferProgress) => void
): Promise<TransferRow> {
   const files = asTransferFiles(transfer.files);
   const missing = new Set(transfer.missing_files);
   const toCopy =
      transfer.files_status === 'pending' ? files : files.filter(({ to }) => missing.has(to));
   const bucket = supabase.storage.from(MEDIA_BUCKET);

   const failed: { file: TransferFile; error: unknown }[] = [];
   let done = 0;
   onProgress?.({ done, total: toCopy.length });
   for (const file of toCopy) {
      if (file.from !== file.to) {
         try {
            const { error } = await bucket.copy(file.from, file.to);
            if (error && !alreadyExists(error)) failed.push({ file, error });
         } catch (error) {
            failed.push({ file, error });
         }
      }
      onProgress?.({ done: ++done, total: toCopy.length });
   }
   if (failed.length) console.warn('Transfer files not copied', transfer.id, failed);

   const { data } = await publicSchema
      .rpc('transfer_check_files', { transfer_id: transfer.id })
      .throwOnError();
   const checked = data as TransferRow;

   if (checked.mode === 'move' && checked.files_status === 'done') {
      const sources = files
         .filter(({ keep_source, from, to }) => !keep_source && from !== to)
         .map(({ from }) => from);
      // Storage deletes at most 1000 objects per request.
      for (let start = 0; start < sources.length; start += REMOVE_BATCH) {
         try {
            const { error } = await bucket.remove(sources.slice(start, start + REMOVE_BATCH));
            if (error) console.warn('Transfer source files left in storage', transfer.id, error);
         } catch (error) {
            console.warn('Transfer source files left in storage', transfer.id, error);
         }
      }
   }

   return checked;
}

/** The ID map as CSV: `table,source_id,target_id`, by table, then source id. No BOM. */
export function idMapCsv(idMap: TransferIdMap): string {
   const byText = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
   const rows = Object.entries(idMap)
      .sort(([a], [b]) => byText(a, b))
      .flatMap(([table, ids]) =>
         Object.entries(ids)
            .sort(([a], [b]) => byText(a, b))
            .map(([sourceId, targetId]) => [table, sourceId, targetId])
      );
   return serializeCsv(['table', 'source_id', 'target_id'], rows);
}

// --- hooks ---

/** Marks stale every query reading any of the tenants (a key holds the tenants read, joined). */
const invalidateTenants = (queryClient: QueryClient, tenantIds: readonly string[]) =>
   queryClient.invalidateQueries({
      predicate: ({ queryKey }) =>
         queryKey[0] === 'tenant' &&
         typeof queryKey[1] === 'string' &&
         queryKey[1].split(',').some((id) => tenantIds.includes(id))
   });

/** The candidate targets of a transfer out of `sourceTenant`. */
export function useTransferOptions(sourceTenant: MaybeRefOrGetter<string | null>) {
   const tenantKey = useTenantKey();

   return useQuery({
      queryKey: computed(() =>
         queryKeys.list(tenantKey.value, 'transfer', {
            view: 'options',
            sourceTenant: toValue(sourceTenant)
         })
      ),
      queryFn: () => fetchTransferOptions(toValue(sourceTenant)!),
      enabled: computed(() => !!toValue(sourceTenant))
   });
}

/** The rehearsal, as a mutation: each one is asked for, never cached. */
export function useRehearseTransfer() {
   return useMutation({ mutationFn: rehearseTransfer });
}

/** The run (the files are copied after it, see useCopyTransferFiles). Both tenants' queries go stale. */
export function useRunTransfer() {
   const queryClient = useQueryClient();

   return useMutation({
      mutationFn: ({ args, reportHash }: { args: TransferArgs; reportHash: string }) =>
         runTransfer(args, reportHash),
      onSettled: (_data, _error, { args }) =>
         invalidateTenants(queryClient, [args.source_tenant, args.target_tenant])
   });
}

/**
 * The file copy of a run, with its progress. The run has committed by then, so a failed copy or
 * check returns the run's row (files pending; a retry copies them) instead of failing.
 */
export function useCopyTransferFiles() {
   const queryClient = useQueryClient();
   const progress = ref<TransferProgress | null>(null);

   const mutation = useMutation({
      mutationFn: async (transfer: TransferRow) => {
         progress.value = null;
         try {
            return await copyTransferFiles(transfer, (next) => (progress.value = next));
         } catch (error) {
            console.warn('Transfer files not checked', transfer.id, error);
            return transfer;
         }
      },
      onSettled: () => invalidateTables(queryClient, ['transfer'])
   });
   return { ...mutation, progress };
}

/** Copies the missing files of a transfer again and checks them. */
export function useRetryTransferFiles() {
   const queryClient = useQueryClient();

   return useMutation({
      mutationFn: (transfer: TransferRow) => copyTransferFiles(transfer),
      onSuccess: () => invalidateTables(queryClient, ['transfer'])
   });
}

type HeaderBuilder<Q> = { setHeader(name: string, value: string): Q };

/**
 * The masked fields of api.transfer follow the request's tenants, so a read names the source
 * (whose rights unmask the report, files and ID map) and the target (which the row belongs to).
 */
const forTransferScope = <Q extends HeaderBuilder<Q>>(query: Q, tenants: string[]) =>
   query
      .setHeader('x-tenant-id', tenants[tenants.length - 1]!)
      .setHeader('x-tenant-ids', tenants.join(','));

/** One transfer row, keyed by the target tenant it belongs to. */
export function useTransfer(
   id: MaybeRefOrGetter<string | null>,
   sourceTenant: MaybeRefOrGetter<string | null>,
   targetTenant: MaybeRefOrGetter<string | null>
) {
   return useQuery({
      queryKey: computed(() => queryKeys.detail(toValue(targetTenant), 'transfer', toValue(id))),
      queryFn: async ({ signal }) => {
         const { data } = await forTransferScope(
            supabase.from('transfer').select('*').eq('id', toValue(id)!).abortSignal(signal),
            [toValue(sourceTenant)!, toValue(targetTenant)!]
         )
            .maybeSingle()
            .throwOnError();
         return data;
      },
      enabled: computed(() => !!toValue(id) && !!toValue(sourceTenant) && !!toValue(targetTenant))
   });
}

/**
 * The transfers whose files are not all copied yet, into or out of any of `tenants`, newest first.
 * The list is read in `tenants`; a row whose files come back masked (the source is not in that
 * scope) is read again with its source and target both in `x-tenant-ids`, which unmasks it for a
 * caller with the rights, so the copy can be retried from where the transfer blocks.
 */
export function usePendingTransfers(tenants: MaybeRefOrGetter<readonly string[]>) {
   return useQuery({
      queryKey: computed(() =>
         queryKeys.list(toValue(tenants).join(',') || null, 'transfer', { view: 'pending' })
      ),
      queryFn: async ({ signal }) => {
         const scope = [...toValue(tenants)];
         const list = scope.join(',');
         const { data } = await forTransferScope(
            supabase
               .from('transfer')
               .select('*')
               .neq('files_status', 'done')
               .or(`tenant_id.in.(${list}),source_tenant_id.in.(${list})`)
               .order('created_at', { ascending: false })
               .abortSignal(signal),
            scope
         ).throwOnError();
         return Promise.all(
            data.map(async (row): Promise<TransferRow> => {
               if (Array.isArray(row.files)) return row;
               const { data: full } = await forTransferScope(
                  supabase.from('transfer').select('*').eq('id', row.id).abortSignal(signal),
                  [row.source_tenant_id, row.tenant_id]
               )
                  .maybeSingle()
                  .throwOnError();
               return full ?? row;
            })
         );
      },
      enabled: computed(() => toValue(tenants).length > 0)
   });
}

// --- labels ---

/** The label columns of a table the report names by id. */
const LABEL_COLUMNS = {
   product: { key: 'sku', select: 'id, sku, display_name' },
   supplier: { key: 'code', select: 'id, code, display_name' }
} as const;
export type TransferLabelTable = keyof typeof LABEL_COLUMNS;
export type TransferLabel = { key: string | null; name: string | null };

const LABEL_BATCH = 100;

/**
 * The report holds ids only (no SKU, name or price). This reads them through the normal views, in
 * the tenant they belong to, so the caller's masking applies: a hidden value comes back null.
 */
export function useTransferLabels(
   table: TransferLabelTable,
   tenant: MaybeRefOrGetter<string | null>,
   ids: MaybeRefOrGetter<readonly string[]>
) {
   return useQuery({
      queryKey: computed(() =>
         queryKeys.list(toValue(tenant), table, { view: 'transfer_labels', ids: [...toValue(ids)] })
      ),
      queryFn: async ({ signal }) => {
         const { key, select } = LABEL_COLUMNS[table];
         const wanted = [...new Set(toValue(ids))];
         const labels: Record<string, TransferLabel> = {};
         for (let start = 0; start < wanted.length; start += LABEL_BATCH) {
            const { data } = await forTransferScope(
               (supabase.from(table) as any)
                  .select(select)
                  .in('id', wanted.slice(start, start + LABEL_BATCH))
                  .abortSignal(signal),
               [toValue(tenant)!]
            ).throwOnError();
            for (const row of data as Record<string, string | null>[]) {
               labels[row.id!] = { key: row[key] ?? null, name: row.display_name ?? null };
            }
         }
         return labels;
      },
      enabled: computed(() => !!toValue(tenant) && toValue(ids).length > 0)
   });
}
