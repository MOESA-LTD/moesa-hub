import { useFormDraft } from '@/composables/useFormDraft';
import { provideFormTenant } from '@/api/formTenant';
import { useFormReadonly } from '@/composables/useFormReadonly';
import { isSharedRow, type SharedRowLike } from '@/composables/useSharedRow';
import { useUnsavedChangesGuard } from '@/composables/useUnsavedChangesGuard';
import { useForm } from '@/lib/form/useForm';
import i18n from '@plugins/i18n';
import { ToastSeverity } from '@primevue/core/api';
import type { UseMutationReturnType, UseQueryReturnType } from '@tanstack/vue-query';
import { useToast } from 'primevue/usetoast';
import {
   computed,
   reactive,
   readonly as readonlyReactive,
   toValue,
   watch,
   type MaybeRefOrGetter
} from 'vue';
import type * as z from 'zod';

export type UseUpsertFormOptions<S extends z.ZodType, Row, Payload> = {
   /** Id of the row to edit; empty for a new row. */
   id: MaybeRefOrGetter<string | null | undefined>;
   /** Prefill for a new row. */
   prefill?: MaybeRefOrGetter<Partial<Row> | null | undefined>;
   /** Loads the row, e.g. `resource.useOne`. */
   useRow: (
      id: MaybeRefOrGetter<string | null | undefined>
   ) => UseQueryReturnType<Row | null, Error>;
   /** Saves the payload and returns the saved row (null if it cannot be read back). */
   useSaveRow: () => UseMutationReturnType<Row | null, Error, Payload, unknown>;
   /** Table checked for `modify` / `create` permission. */
   subject: keyof Tables;
   /** May depend on the form state (e.g. limits from a selected row) through a getter. */
   schema: MaybeRefOrGetter<S>;
   toFormValues: (row?: Partial<Row> | null) => z.input<S>;
   toPayload: (data: z.output<S>) => Payload;
   onSaved?: (row: Row) => void;
   /** Makes the form read-only for some rows regardless of permissions (e.g. shared records). */
   lockRow?: (row: Row) => boolean;
   /** Replaces the permission check on `subject`, for a rule that is no table permission. */
   canSubmit?: (values: z.input<S>) => boolean;
};

/**
 * The links of a prefill (`*_id`, `*_type`: which record the new row belongs to) with a value,
 * sorted by name. Other prefilled values, such as today's date, do not tell records apart and would
 * change between a reload and the restore.
 */
const linkText = (prefill: object) =>
   JSON.stringify(
      Object.entries(prefill)
         .filter(([name, field]) => /_(id|type)$/.test(name) && field != null && field !== '')
         .sort(([a], [b]) => a.localeCompare(b))
   );

/** A short, stable hash (FNV-1a) for a draft key. */
const hashText = (text: string) => {
   let hash = 0x811c9dc5;
   for (let i = 0; i < text.length; i++) hash = Math.imul(hash ^ text.charCodeAt(i), 0x01000193);
   return (hash >>> 0).toString(36);
};

/**
 * The draft of a form: a saved row's own, or for a new row the one of what it was opened for (the
 * links in its prefill, e.g. the record a new document is attached to). A new row abandoned for one record must
 * not come back, with that record's link, in the new row form of another.
 */
export function draftForm(subject: string, id: string | null | undefined, prefill?: object | null) {
   if (id) return `${subject}:${id}`;
   const context = prefill ? linkText(prefill) : '[]';
   return context === '[]' ? `${subject}:new` : `${subject}:new:${hashText(context)}`;
}

/**
 * Edit form for one row: loads it, keeps the form on fresh server data while it is clean, guards
 * unsaved changes, applies permissions, saves with a toast and resets to the saved row.
 *
 * Every composable is set up synchronously; await `ready` in the component (it keeps the route's
 * Suspense waiting for the row).
 */
export function useUpsertForm<S extends z.ZodType, Row, Payload>(
   options: UseUpsertFormOptions<S, Row, Payload>
) {
   const { data: row, suspense } = options.useRow(options.id);

   const form = useForm({
      schema: options.schema,
      initialValues: options.toFormValues(row.value ?? toValue(options.prefill))
   });

   // Follow fresh server data (e.g. saved in another view) unless the user has unsaved edits.
   watch(row, (value) => {
      if (value && !form.isDirty.value) form.reset(options.toFormValues(value));
   });

   const formValues = () => options.toFormValues(row.value ?? toValue(options.prefill));

   // Unsaved edits survive a reload; leaving without saving drops them.
   const draft = useFormDraft({
      form: draftForm(options.subject, toValue(options.id), toValue(options.prefill)),
      values: form.values,
      isDirty: form.isDirty,
      base: formValues,
      restore: form.restore,
      enabled: () => !readonly.value
   });

   useUnsavedChangesGuard(form.isDirty, { onDiscard: draft.discard });

   // A provider's row shared with a tenant in scope (see isSharedRow): read-only, and read through
   // the client tenant, whose lookups (its warehouses, projects) name what the row points at.
   const authStore = useAuthStore();
   const shared = computed(() =>
      isSharedRow(
         row.value as SharedRowLike | null | undefined,
         new Set((authStore.scopeTenants ?? []).map(({ id }) => id))
      )
   );

   // The row's own tenant, which may be another of the branches shown; a new row goes to the
   // active one. The form's lookups read that tenant only (see provideFormTenant).
   const tenantId = computed(() => {
      const saved = row.value as SharedRowLike | null | undefined;
      if (shared.value) return saved?.client_tenant_id ?? null;
      return saved?.tenant_id ?? authStore.currentTenant?.id ?? null;
   });
   provideFormTenant(tenantId);

   const { canSubmit } = options;
   const cannotSubmit = canSubmit
      ? computed(() => !canSubmit(form.values.value as z.input<S>))
      : useFormReadonly(
           options.subject,
           () => (form.values.value as { id?: string } | undefined)?.id,
           tenantId
        );
   const readonly = computed(
      () => shared.value || cannotSubmit.value || (!!row.value && !!options.lockRow?.(row.value))
   );

   const toast = useToast();
   const { mutateAsync: saveRow } = options.useSaveRow();

   const save = form.handleSubmit(async (data) => {
      const saved = await saveRow(options.toPayload(data));
      form.reset(options.toFormValues(saved));

      toast.add({
         life: 3000,
         severity: ToastSeverity.SUCCESS,
         summary: i18n.t('toast.success'),
         detail: i18n.t('toast.saved')
      });

      if (saved) options.onSaved?.(saved);
   });

   const ready: Promise<void> = (
      toValue(options.id)
         ? suspense().then(() => {
              if (row.value && !form.isDirty.value) form.reset(options.toFormValues(row.value));
           })
         : Promise.resolve()
   ).then(draft.apply);

   return {
      ...form,
      row,
      /** The row's tenant, or the active one for a new row (see provideFormTenant). */
      tenantId,
      /** Whether the row is a provider's, shared with a tenant in scope: read-only here. */
      shared,
      readonly,
      save,
      ready,
      /** Drops this form's draft for good, e.g. once a new row is saved and edited under its id. */
      discardDraft: draft.discard,
      /** Whether a draft was restored, and whether the row changed since (see FormBox). */
      draft: readonlyReactive(reactive({ restored: draft.restored, stale: draft.stale }))
   };
}
