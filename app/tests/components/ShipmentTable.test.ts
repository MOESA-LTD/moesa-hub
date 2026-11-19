import '../setup/mockMain';
import en from '@/plugins/i18n/locales/en/index.json';
import ShipmentTable from '@/components/service-components/shipment-table/ShipmentTable.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';

// The shipment list on the client side: a provider's shipment shared with the client shows its
// ETA and tracking under a "From <provider>" tag, read-only, without the provider-only columns.
const api = vi.hoisted(() => ({ rows: [] as Record<string, unknown>[] }));

vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ query: {} }),
   useRouter: () => ({ push: vi.fn() })
}));
vi.mock('@/store/auth', () => ({
   useAuthStore: () => ({ scopeTenants: [{ id: 'tho' }] })
}));
vi.mock('@/api/relationship', async () => {
   const { ref } = await import('vue');
   return {
      useProviderNames: () => ({
         data: ref([{ tenant_id: 'moe', client_tenant_id: 'tho', provider_name: 'MOESA LTD' }])
      })
   };
});
vi.mock('@/api/shipment', async (importOriginal) => {
   const { ref } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/shipment')>()),
      useShipmentIds: () => ({ data: ref(undefined) })
   };
});

type Column = { field?: string; header?: string };
type Action = { label?: string | ((body: { data: unknown }) => string) };
const label = (action: Action, data: unknown) =>
   typeof action.label === 'function' ? action.label({ data }) : action.label;

// Renders the column headers, and per row its code and ETA cells and its row actions' labels.
const ResourceTable = defineComponent({
   name: 'ResourceTable',
   props: ['filters', 'from', 'columns', 'rowActions', 'modelValue'],
   emits: ['update:modelValue'],
   setup: (props, { emit, slots }) => {
      emit('update:modelValue', api.rows);
      return () =>
         h('div', { 'data-table': props.from }, [
            ...(props.columns as Column[]).map((column) =>
               h('th', { 'data-field': column.field }, column.header)
            ),
            ...api.rows.map((data) =>
               h('div', { 'data-row': data.id }, [
                  h('span', { 'data-cell': 'code' }, slots.code_body?.({ data })),
                  h('span', { 'data-cell': 'eta' }, slots.eta_body?.({ data })),
                  ...((props.rowActions ?? []) as Action[]).map((action) =>
                     h('button', label(action, data))
                  )
               ])
            )
         ]);
   }
});

const mountTable = async () => {
   const wrapper = mount(ShipmentTable, {
      global: { plugins: [i18NPlugin, PrimeVue], stubs: { ResourceTable } }
   });
   await flushPromises();
   return wrapper;
};

describe('shipment table', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   beforeEach(() => (api.rows = []));

   it('shows eta and tracking on a shared shipment', async () => {
      api.rows = [
         {
            id: 's1',
            code: 'SHP-1',
            tenant_id: 'moe',
            client_tenant_id: 'tho',
            status: 'in_transit',
            eta: '2099-01-02',
            carrier: 'Maersk',
            container_no: 'MSKU1234567'
         }
      ];
      const wrapper = await mountTable();

      const fields = wrapper.findAll('th').map((th) => th.attributes('data-field'));
      expect(fields).toEqual(expect.arrayContaining(['eta', 'carrier', 'container_no', 'status']));
      expect(fields).not.toContain('client_code');
      const row = wrapper.get('[data-row="s1"]');
      expect(row.get('[data-cell="eta"]').text()).toBe('2099-01-02');
      expect(row.text()).toContain('From MOESA LTD');
      expect(row.findAll('button').map((b) => b.text())).toEqual([i18n.t('action.view')]);
   });

   it('keeps the provider columns and the edit action on an own shipment', async () => {
      api.rows = [{ id: 's2', code: 'SHP-2', tenant_id: 'tho', client_tenant_id: null }];
      const wrapper = await mountTable();

      const fields = wrapper.findAll('th').map((th) => th.attributes('data-field'));
      expect(fields).toContain('client_code');
      expect(wrapper.get('[data-row="s2"]').text()).not.toContain('From');
      expect(wrapper.findAll('button').map((b) => b.text())).toEqual([i18n.t('action.edit')]);
   });
});
