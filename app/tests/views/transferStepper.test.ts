import '../setup/mockMain';
import en from '@/plugins/i18n/locales/en/index.json';
import Transfer from '@/views/pages/ops/transfer/Transfer.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { beforeAll, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

// The dialog's frame alone: the transfer API is a stand-in.
vi.mock('@/api/transfer', async (importOriginal) => {
   const original = await importOriginal<typeof import('@/api/transfer')>();
   return {
      ...original,
      useTransferOptions: () => ({
         data: ref({ source_writable: true, targets: [] }),
         isLoading: ref(false)
      }),
      useRehearseTransfer: () => ({ mutateAsync: vi.fn(), isPending: ref(false) }),
      useRunTransfer: () => ({ mutateAsync: vi.fn(), isPending: ref(false) }),
      useCopyTransferFiles: () => ({
         mutateAsync: vi.fn(),
         isPending: ref(false),
         progress: ref(null)
      })
   };
});

beforeAll(() => i18n.setLocaleMessage('en', en));

const mountTransfer = (props: { sourceTenant: string | null; productIds: string[] }) =>
   mount(Transfer, {
      props,
      global: {
         plugins: [i18NPlugin, PrimeVue, [VueQueryPlugin, { queryClient: new QueryClient() }]],
         directives: { tooltip: {} }
      }
   });

describe('transfer dialog', () => {
   it('numbers its steps 1 to 4 and titles them', async () => {
      const wrapper = mountTransfer({ sourceTenant: 'source', productIds: ['p1', 'p2'] });
      await flushPromises();

      expect(wrapper.findAll('[data-pc-section="number"]').map((n) => n.text())).toEqual([
         '1',
         '2',
         '3',
         '4'
      ]);
      expect(wrapper.findAll('[data-pc-section="title"]').map((n) => n.text())).toEqual([
         en.ops.transfer.steps.target,
         en.ops.transfer.steps.report,
         en.ops.transfer.steps.apply,
         en.ops.transfer.steps.files
      ]);
      expect(wrapper.find('h3').text()).toBe('Copy or move 2 products');
   });

   it('asks for a selection when it was opened without products', async () => {
      const wrapper = mountTransfer({ sourceTenant: null, productIds: [] });
      await flushPromises();

      expect(wrapper.find('[data-no-selection]').text()).toBe(en.ops.transfer.no_selection);
      expect(wrapper.find('[data-pc-section="number"]').exists()).toBe(false);
   });
});
