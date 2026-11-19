import '../setup/mockMain';
import {
   purchaseOrderLineSchema,
   toPurchaseOrderLineFormValues,
   type PurchaseOrderLineFormValues
} from '@/api/purchaseOrder';
import en from '@/plugins/i18n/locales/en/index.json';
import LineUpsert from '@/views/pages/ops/purchase-order/LineUpsert.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, nextTick, ref, Suspense, type Ref } from 'vue';

// The form is useUpsertForm (a stand-in holding the values, as a restored draft would leave them);
// what the dialog adds is checked: prices, spec sheets, positions and the order of a new line.
const api = vi.hoisted(() => ({
   values: null as unknown as Ref<PurchaseOrderLineFormValues>,
   options: undefined as undefined | { toPayload: (data: unknown) => Record<string, unknown> },
   order: null as unknown,
   specs: {} as Record<string, { value: string; label: string }[]>,
   sourcing: [] as { id: string; product_id: string }[],
   specParams: [] as { entityType: string; entityId: string | null }[]
}));

vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('@/api/sourcing', async () => {
   const { computed } = await import('vue');
   return { useSourcingPrices: () => computed(() => api.sourcing) };
});
vi.mock('@/composables/useUpsertForm', async () => {
   const { ref } = await import('vue');
   return {
      useUpsertForm: (options: typeof api.options) => {
         api.options = options;
         return {
            values: api.values,
            errors: ref({}),
            isDirty: ref(false),
            isSubmitting: ref(false),
            readonly: ref(false),
            reset: vi.fn(),
            save: vi.fn(),
            ready: Promise.resolve(),
            draft: {},
            row: ref(null)
         };
      }
   };
});
vi.mock('@/api/purchaseOrder', async (importOriginal) => {
   const { computed, ref, toValue } = await import('vue');
   const original = await importOriginal<typeof import('@/api/purchaseOrder')>();
   return {
      ...original,
      purchaseOrderResource: {
         ...original.purchaseOrderResource,
         useOne: () => ({ data: ref(api.order), suspense: () => Promise.resolve() })
      },
      useEntityDocumentOptions: (params: () => { entityType: string; entityId: string | null }) =>
         computed(() => {
            api.specParams.push(toValue(params));
            return api.specs[toValue(params).entityId ?? ''] ?? [];
         })
   };
});

const ORDER = '00000000-0000-4000-8000-000000000011';
const OTHER_ORDER = '00000000-0000-4000-8000-000000000012';
const MOP = '00000000-0000-4000-8000-000000000021';
const TIPS = '00000000-0000-4000-8000-000000000022';
const SPEC_MOP_V3 = '00000000-0000-4000-8000-000000000031';
const SPEC_MOP_V2 = '00000000-0000-4000-8000-000000000032';
const SPEC_TIPS_V1 = '00000000-0000-4000-8000-000000000033';

const mop = { id: MOP, purchase_price: 1.9, purchase_currency: 'USD' };
const tips = { id: TIPS, purchase_price: 0.5, purchase_currency: 'EUR' };

const order = (positions: number[]) => ({
   id: ORDER,
   currency: 'USD',
   purchase_order_line: positions.map((position, i) => ({ id: `l${i}`, position }))
});

const Slot = defineComponent({
   setup:
      (_, { slots }) =>
      () =>
         h('div', slots.default?.({}))
});
const ProductSelect = defineComponent({
   name: 'ProductSelect',
   props: ['modelValue'],
   emits: ['update:modelValue', 'pick'],
   setup: () => () => h('span')
});

const mountLine = async (values: Partial<PurchaseOrderLineFormValues> = {}) => {
   api.values = ref({
      ...toPurchaseOrderLineFormValues(),
      purchase_order_id: ORDER,
      ...values
   });
   const wrapper = mount(
      defineComponent({
         render: () =>
            h(Suspense, null, {
               default: () => h(LineUpsert, { purchaseOrderId: ORDER })
            })
      }),
      {
         global: {
            plugins: [i18NPlugin, PrimeVue],
            directives: { focustrap: {} },
            stubs: { FormBox: Slot, FormField: Slot, ProductSelect }
         }
      }
   );
   await flushPromises();
   return wrapper;
};

/** Picks a product in the dialog, as ProductSelect reports a user's pick. */
const pick = async (wrapper: Awaited<ReturnType<typeof mountLine>>, product: typeof mop) => {
   const select = wrapper.getComponent(ProductSelect);
   api.values.value.product_id = product.id;
   select.vm.$emit('pick', product);
   await nextTick();
};

const submitted = () => api.options!.toPayload(purchaseOrderLineSchema.parse(api.values.value));

describe('order line dialog', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));

   beforeEach(() => {
      api.order = order([1, 3]);
      api.specs = {
         [MOP]: [
            { value: SPEC_MOP_V3, label: 'v03' },
            { value: SPEC_MOP_V2, label: 'v02' }
         ],
         [TIPS]: [{ value: SPEC_TIPS_V1, label: 'v01' }]
      };
      api.sourcing = [];
      api.specParams = [];
   });

   it("offers a client line the spec sheets of the order tenant's sourcing row", async () => {
      api.order = { ...order([1]), tenant_id: 'provider', client_tenant_id: 'client' };
      api.sourcing = [{ id: 'src-mop', product_id: MOP }];
      api.specs['src-mop'] = [{ value: 'provider-spec', label: 'v01' }];
      const wrapper = await mountLine();

      const select = wrapper.getComponent(ProductSelect);
      expect(select.attributes('clienttenantid')).toBe('client');
      expect(select.attributes('tenantid')).toBe('provider');
      await pick(wrapper, mop);

      expect(api.specParams.at(-1)).toMatchObject({ entityType: 'sourcing', entityId: 'src-mop' });
      expect(api.values.value.spec_document_id).toBe('provider-spec');
   });

   it("prices a picked product at its purchase price in the order's currency", async () => {
      const wrapper = await mountLine();
      await pick(wrapper, mop);
      expect(api.values.value.unit_price).toBe(1.9);
   });

   it('leaves the price empty for a product bought in another currency', async () => {
      const wrapper = await mountLine();
      await pick(wrapper, tips);
      expect(api.values.value.unit_price).toBeNull();
   });

   it('keeps a price already entered', async () => {
      const wrapper = await mountLine({ unit_price: 2.1 });
      await pick(wrapper, mop);
      expect(api.values.value.unit_price).toBe(2.1);
   });

   it("preselects the product's newest spec sheet and picks again for another product", async () => {
      const wrapper = await mountLine();

      await pick(wrapper, mop);
      expect(api.values.value.spec_document_id).toBe(SPEC_MOP_V3);

      await pick(wrapper, tips);
      expect(api.values.value.spec_document_id).toBe(SPEC_TIPS_V1);
   });

   it('puts a new line after the last one, and first on an order without lines', async () => {
      const wrapper = await mountLine();
      await pick(wrapper, mop);
      api.values.value.quantity = 100;
      expect(submitted().position).toBe(4);

      api.order = order([]);
      const first = await mountLine();
      await pick(first, mop);
      api.values.value.quantity = 100;
      expect(submitted().position).toBe(1);
   });

   it("submits a new line on the route's order with its product, quantity, price and spec", async () => {
      const wrapper = await mountLine();
      await pick(wrapper, mop);
      api.values.value.quantity = 100;

      expect(submitted()).toEqual({
         purchase_order_id: ORDER,
         product_id: MOP,
         quantity: 100,
         unit_price: 1.9,
         pi_line_total: null,
         spec_document_id: SPEC_MOP_V3,
         position: 4,
         notes: null
      });
   });

   it("moves a draft left from another order to the route's order, dropping its product", async () => {
      await mountLine({
         purchase_order_id: OTHER_ORDER,
         product_id: TIPS,
         spec_document_id: SPEC_TIPS_V1,
         unit_price: 0.5,
         quantity: 40
      });

      expect(api.values.value).toMatchObject({
         purchase_order_id: ORDER,
         product_id: null,
         spec_document_id: null,
         unit_price: null,
         quantity: 40
      });
   });

   it("keeps a draft of the route's own order as it is", async () => {
      await mountLine({
         product_id: MOP,
         spec_document_id: SPEC_MOP_V2,
         unit_price: 1.8
      });

      expect(api.values.value).toMatchObject({
         purchase_order_id: ORDER,
         product_id: MOP,
         spec_document_id: SPEC_MOP_V2,
         unit_price: 1.8
      });
   });

   it("submits the route's order even when the form still holds another", async () => {
      const wrapper = await mountLine();
      await pick(wrapper, mop);
      api.values.value.quantity = 100;
      api.values.value.purchase_order_id = OTHER_ORDER;

      expect(submitted().purchase_order_id).toBe(ORDER);
   });
});
