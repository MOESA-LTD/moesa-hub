import '../setup/mockMain';
import { ability } from '@/plugins/casl';
import en from '@/plugins/i18n/locales/en/index.json';
import ProductIndex from '@/views/pages/ops/product/Index.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { abilitiesPlugin } from '@casl/vue';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { enableAutoUnmount, mount } from '@vue/test-utils';
import { FilterMatchMode } from '@primevue/core/api';
import { createPinia, setActivePinia } from 'pinia';
import PrimeVue from 'primevue/config';
import ToggleSwitch from 'primevue/toggleswitch';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, nextTick } from 'vue';

// The product list's tree view: parents (and products without one) with their variants under
// their row; a search or a filter, or the switch, shows a flat list.
vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ query: {} }),
   useRouter: () => ({ push: vi.fn() })
}));
vi.mock('@/api/useTenantKey', async () => {
   const { computed } = await import('vue');
   return { useTenantKey: () => computed(() => 't1') };
});
vi.mock('@/api/product/variants', async () => {
   const { ref } = await import('vue');
   return { useVariantCounts: () => ({ data: ref(new Map([['rec', 12]])) }) };
});

const Table = defineComponent({
   name: 'ResourceTable',
   props: {
      filters: { type: Object, default: undefined },
      fixedFilters: { type: Array, default: undefined },
      enableExpansion: Boolean
   },
   emits: ['update:filters'],
   setup:
      (_props, { slots }) =>
      () =>
         h('div', [slots.header?.(), slots.sku_body?.({ data: { id: 'rec', sku: 'OKA-REC' } })])
});

const mountList = () =>
   mount(ProductIndex, {
      global: {
         plugins: [
            i18NPlugin,
            PrimeVue,
            [VueQueryPlugin, { queryClient: new QueryClient() }],
            [abilitiesPlugin, ability, { useGlobalProperties: true }]
         ] as never,
         stubs: { ResourceTable: Table, CustomLink: true, teleport: true, PendingTransfers: true }
      }
   });

enableAutoUnmount(afterEach);
beforeAll(() => i18n.setLocaleMessage('en', en));
beforeEach(() => {
   setActivePinia(createPinia());
   ability.update([{ action: 'manage', subject: 'all' }]);
});

describe('product list tree view', () => {
   it('lists parents with their variant count and expands them', () => {
      const wrapper = mountList();
      const table = wrapper.getComponent(Table);
      expect(table.props('fixedFilters')).toEqual([{ column: 'parent_id', isNull: true }]);
      expect(table.props('enableExpansion')).toBe(true);
      expect(wrapper.get('[data-variant-count]').text()).toBe('12 variants');
   });

   it('shows a flat list while searching', async () => {
      const wrapper = mountList();
      const table = wrapper.getComponent(Table);
      table.vm.$emit('update:filters', {
         ...table.props('filters'),
         global: { value: 'OKA-REC-3', matchMode: FilterMatchMode.CONTAINS }
      });
      await nextTick();
      expect(table.props('fixedFilters')).toEqual([]);
      expect(table.props('enableExpansion')).toBe(false);
      expect(wrapper.find('[data-variant-count]').exists()).toBe(false);
   });

   it('shows a flat list when the switch is off', async () => {
      const wrapper = mountList();
      wrapper.getComponent(ToggleSwitch).vm.$emit('update:modelValue', false);
      await nextTick();
      expect(wrapper.getComponent(Table).props('fixedFilters')).toEqual([]);
   });
});
