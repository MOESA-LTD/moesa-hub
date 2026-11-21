import type { DashboardBoxDef, DashboardBoxId } from '@/constants/dashboard';
import { computed, type ComputedRef, type Ref } from 'vue';
import type { BoxView } from './views';

/**
 * A box's view of its query's rows: the hook runs once, the view follows its data; `loading` until
 * the first answer.
 */
export function useBoxView<Row>(
   box: DashboardBoxDef,
   useRows: () => { data: Ref<Row[] | undefined>; isPending?: Ref<boolean> },
   view: (rows: readonly Row[], id: DashboardBoxId) => BoxView
): ComputedRef<BoxView & { loading: boolean }> {
   const { data, isPending } = useRows();
   return computed(() => ({ ...view(data.value ?? [], box.id), loading: !!isPending?.value }));
}
