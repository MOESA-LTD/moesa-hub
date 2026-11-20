import '../setup/mockMain';
import BulkCellDialog from '@/components/service-components/market-cell-table/BulkCellDialog.vue';
import en from '@/plugins/i18n/locales/en/index.json';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import Select from 'primevue/select';
import ToastService from 'primevue/toastservice';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

// Several market cells changed at once from the list view.
const api = vi.hoisted(() => ({
   mutateAsync: vi.fn(async () => ({ updated: 2, failed: [] as unknown[] }))
}));
vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('@/api/marketMatrix', async (importOriginal) => {
   const { ref } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/marketMatrix')>()),
      useBulkUpdateCells: () => ({ mutateAsync: api.mutateAsync, isPending: ref(false) })
   };
});

const cells = [
   { id: 'c1', status: 'planned', notes: 'Checked', sku: 'OKA-REC', country: 'DE' },
   { id: 'c2', status: 'planned', notes: null, sku: 'OKA-REC', country: 'FR' }
] as const;

const mountDialog = (rows: readonly object[] = cells) =>
   mount(BulkCellDialog, {
      props: { cells: rows as never, visible: true },
      attachTo: document.body,
      global: { plugins: [i18NPlugin, PrimeVue, ToastService], stubs: { teleport: true } }
   });

describe('BulkCellDialog', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   beforeEach(() => api.mutateAsync.mockClear());

   it('offers the moves every selected cell may make', async () => {
      const wrapper = mountDialog();
      await flushPromises();
      const statusSelect = wrapper.findAllComponents(Select)[0];
      expect(statusSelect.props('options')).toEqual(['preparing', 'paused']);

      const mixed = mountDialog([cells[0], { ...cells[1], status: 'preparing' }]);
      await flushPromises();
      expect(mixed.findAllComponents(Select)[0].props('disabled')).toBe(true);
   });

   it('saves the chosen move, content status and note for every cell', async () => {
      const wrapper = mountDialog();
      await flushPromises();
      const [statusSelect, contentSelect] = wrapper.findAllComponents(Select);
      statusSelect.vm.$emit('update:modelValue', 'preparing');
      contentSelect.vm.$emit('update:modelValue', 'translated');
      await wrapper.get('[data-bulk-note]').setValue('Listing report v1');
      await wrapper.get('form[data-bulk-cells]').trigger('submit');
      await flushPromises();

      expect(api.mutateAsync).toHaveBeenCalledWith({
         cells,
         patch: { content_status: 'translated' },
         note: 'Listing report v1',
         status: 'preparing'
      });
      expect(wrapper.emitted('done')).toHaveLength(1);
   });
});
