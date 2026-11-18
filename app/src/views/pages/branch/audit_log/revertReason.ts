import i18n from '@plugins/i18n';

type RevertRow = { table_name: string | null; reverted: boolean | null };

/**
 * Why an audit entry's revert is unavailable, for the disabled button's tooltip, or null: the
 * caller lacks the create and modify rights on its table. An entry reverted already says so in its
 * label.
 */
export function revertDisabledReason(
   row: RevertRow,
   can: (action: string, subject: string) => boolean
): string | null {
   if (row.reverted) return null;
   if (!row.table_name || !can('create', row.table_name) || !can('modify', row.table_name))
      return i18n.t('errors.insufficient_permission');
   return null;
}
