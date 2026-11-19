import '../setup/mockMain';
import en from '@/plugins/i18n/locales/en/index.json';
import LineProduct from '@/components/service-components/purchase-order-table/LineProduct.vue';
import PurchaseOrderTable from '@/components/service-components/purchase-order-table/PurchaseOrderTable.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, ref } from 'vue';

const api = vi.hoisted(() => ({
   ids: undefined as string[] | undefined,
   idFilters: [] as unknown[],
   tableFilters: null as null | Record<string, { constraints: unknown[] }>,
   rows: [] as Record<string, unknown>[]
}));

vi.mock('@/lib/supabase', () => ({ supabase: {} }));
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
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ query: {} }),
   useRouter: () => ({ push: vi.fn() })
}));
vi.mock('@/api/purchaseOrder', async (importOriginal) => {
   const { toValue } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/purchaseOrder')>()),
      usePurchaseOrderIds: (filter: () => unknown) => {
         api.idFilters.push(toValue(filter));
         return { data: ref(api.ids) };
      }
   };
});

type Column = { field?: string; header?: string };
type Action = {
   label?: string | ((body: { data: unknown }) => string);
   visible?: boolean | ((body: { data: unknown }) => boolean);
};
const evaluate = <V>(value: V | ((body: { data: unknown }) => V), data: unknown) =>
   typeof value === 'function' ? (value as (body: { data: unknown }) => V)({ data }) : value;

// Renders the column headers, and per row its code cell and its row actions' labels.
const ResourceTable = defineComponent({
   name: 'ResourceTable',
   props: ['filters', 'from', 'columns', 'rowActions', 'modelValue'],
   emits: ['update:modelValue'],
   setup: (props, { emit, slots }) => {
      api.tableFilters = props.filters;
      emit('update:modelValue', api.rows);
      return () =>
         h('div', { 'data-table': props.from }, [
            ...(props.columns as Column[]).map((column) =>
               h('th', { 'data-field': column.field }, column.header)
            ),
            ...api.rows.map((data) =>
               h('div', { 'data-row': data.id }, [
                  h('span', { 'data-cell': 'code' }, slots.code_body?.({ data })),
                  ...((props.rowActions ?? []) as Action[])
                     .filter((action) => evaluate(action.visible ?? true, data))
                     .map((action) => h('button', evaluate(action.label, data)))
               ])
            )
         ]);
   }
});

const mountTable = async (filters: Record<string, string>) => {
   const wrapper = mount(PurchaseOrderTable, {
      props: { filters },
      global: { plugins: [i18NPlugin, PrimeVue], stubs: { ResourceTable } }
   });
   await flushPromises();
   return wrapper;
};

describe('purchase order table', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));

   beforeEach(() => {
      api.ids = undefined;
      api.idFilters = [];
      api.tableFilters = null;
      api.rows = [];
   });

   it('shows no table, but "no orders", for a product on none', async () => {
      api.ids = [];
      const wrapper = await mountTable({ productId: 'p1' });

      expect(api.idFilters.at(-1)).toEqual({ productId: 'p1' });
      expect(wrapper.find('[data-table]').exists()).toBe(false);
      expect(wrapper.text()).toContain(i18n.t('ops.purchase_order.no_rows'));
   });

   it('shows no table while the orders of a product load', async () => {
      const wrapper = await mountTable({ productId: 'p1' });
      expect(wrapper.find('[data-table]').exists()).toBe(false);
   });

   it("narrows the table to the product's orders", async () => {
      api.ids = ['o1'];
      const wrapper = await mountTable({ productId: 'p1' });

      expect(wrapper.get('[data-table]').attributes('data-table')).toBe('purchase_order_overview');
      expect(api.tableFilters!.id!.constraints[0]).toEqual({ value: ['o1'], matchMode: 'in' });
   });

   it('hides provider-only columns and actions on a shared row', async () => {
      api.rows = [
         {
            id: 'o1',
            code: 'PO-1',
            tenant_id: 'moe',
            client_tenant_id: 'tho',
            client_status: 'pending'
         }
      ];
      const wrapper = mount(PurchaseOrderTable, {
         global: { plugins: [i18NPlugin, PrimeVue], stubs: { ResourceTable } }
      });
      await flushPromises();

      const fields = wrapper.findAll('th').map((th) => th.attributes('data-field'));
      expect(fields).toContain('client_status');
      for (const field of ['pi_total', 'system_total', 'supplier_id', 'status', 'deposit_paid_on'])
         expect(fields).not.toContain(field);
      const row = wrapper.get('[data-row="o1"]');
      expect(row.text()).toContain('From MOESA LTD');
      expect(row.findAll('button').map((b) => b.text())).not.toContain(i18n.t('action.edit'));
   });

   it('keeps every column and the edit action on an own row', async () => {
      api.rows = [{ id: 'o2', code: 'PO-2', tenant_id: 'tho', client_tenant_id: null }];
      const wrapper = mount(PurchaseOrderTable, {
         global: { plugins: [i18NPlugin, PrimeVue], stubs: { ResourceTable } }
      });
      await flushPromises();

      const fields = wrapper.findAll('th').map((th) => th.attributes('data-field'));
      expect(fields).toEqual(expect.arrayContaining(['status', 'system_total', 'supplier_id']));
      const row = wrapper.get('[data-row="o2"]');
      expect(row.text()).not.toContain('From');
      expect(row.findAll('button').map((b) => b.text())).toContain(i18n.t('action.edit'));
   });

   it("narrows the table to a supplier's and a project's orders", async () => {
      await mountTable({ supplierId: 's1', projectId: 'pr1' });

      expect(api.tableFilters!.supplier_id!.constraints[0]).toEqual({
         value: 's1',
         matchMode: 'equals'
      });
      expect(api.tableFilters!.project_id!.constraints[0]).toEqual({
         value: 'pr1',
         matchMode: 'equals'
      });
      expect(api.tableFilters).not.toHaveProperty('id');
   });
});

describe('order line product', () => {
   it('renders a line without product_id from its snapshot', () => {
      const wrapper = mount(LineProduct, {
         props: { line: { product_id: null, product_sku: 'THO-MOP', product_name: 'Mop' } }
      });
      expect(wrapper.text()).toBe('THO-MOP · Mop');
   });

   it('renders a linked line from its product, which may have been renamed', () => {
      const wrapper = mount(LineProduct, {
         props: {
            line: {
               product_id: 'p1',
               product_sku: 'THO-MOP',
               product_name: 'Mop',
               product: { sku: 'THO-MOP', display_name: 'Mop, 40 cm' }
            }
         }
      });
      expect(wrapper.text()).toBe('THO-MOP · Mop, 40 cm');
   });
});
