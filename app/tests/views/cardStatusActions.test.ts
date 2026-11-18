import '../setup/mockMain';
import type { PurchaseOrderCard as PurchaseOrderRow } from '@/api/purchaseOrder';
import type { ShipmentCard as ShipmentRow } from '@/api/shipment';
import { ability } from '@/plugins/casl';
import en from '@/plugins/i18n/locales/en/index.json';
import PurchaseOrderCard from '@/views/pages/ops/purchase-order/PurchaseOrderCard.vue';
import ShipmentCard from '@/views/pages/ops/shipment/ShipmentCard.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { abilitiesPlugin } from '@casl/vue';
import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import PrimeVue from 'primevue/config';
import ConfirmationService from 'primevue/confirmationservice';
import ToastService from 'primevue/toastservice';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { h, ref, Suspense, type Component } from 'vue';

// The cards' status actions against unsaved edits: a move refetches the row, and a dirty form would
// then save its stale values over what the database set (e.g. the dispute deadline on delivery).
// The forms are stand-ins; what is checked is that the card disables its moves while dirty.
const api = vi.hoisted(() => ({
   dirty: null as unknown as { value: boolean },
   shared: null as unknown as { value: boolean },
   row: null as unknown
}));

const stand = vi.hoisted(() => ({
   /** The card's form: clean or dirty as api.dirty says, on api.row. */
   form: async () => {
      const { ref } = await import('vue');
      return () => ({
         values: ref({}),
         errors: ref({}),
         isDirty: api.dirty,
         isSubmitting: ref(false),
         readonly: ref(false),
         shared: api.shared,
         reset: () => {},
         save: () => Promise.resolve(),
         ready: Promise.resolve(),
         draft: {},
         row: ref(api.row),
         warehouses: ref([])
      });
   },
   /** A tab: not under test. */
   tab: async () => {
      const { defineComponent, h } = await import('vue');
      return { default: defineComponent({ setup: () => () => h('span') }) };
   }
}));

vi.mock('@/composables/useSharedRow', async (importOriginal) => ({
   ...(await importOriginal<typeof import('@/composables/useSharedRow')>()),
   useSharedRow: () => ({ isShared: () => false, providerName: () => 'MOESA LTD' })
}));
vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ query: {} }),
   useRouter: () => ({ push: vi.fn() })
}));
vi.mock('@/views/pages/ops/shipment/useShipmentForm', async (importOriginal) => {
   const { ref } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/views/pages/ops/shipment/useShipmentForm')>()),
      useShipmentForm: await stand.form(),
      useShipmentDocuments: () => ref([])
   };
});
vi.mock('@/views/pages/ops/purchase-order/usePurchaseOrderForm', async (importOriginal) => ({
   ...(await importOriginal<
      typeof import('@/views/pages/ops/purchase-order/usePurchaseOrderForm')
   >()),
   usePurchaseOrderForm: await stand.form()
}));
vi.mock('@/api/shipment', async (importOriginal) => {
   const { ref } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/shipment')>()),
      useShipmentOverview: () => ({ data: ref(null) }),
      useSetShipmentStatus: () => ({ mutateAsync: vi.fn() })
   };
});
vi.mock('@/api/purchaseOrder', async (importOriginal) => {
   const { ref } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/purchaseOrder')>()),
      usePurchaseOrderOverview: () => ({ data: ref(null) }),
      useSetPurchaseOrderStatus: () => ({ mutateAsync: vi.fn() })
   };
});
vi.mock('@/views/pages/ops/shipment/tabs/Acceptance.vue', () => stand.tab());
vi.mock('@/views/pages/ops/shipment/tabs/Dates.vue', () => stand.tab());
vi.mock('@/views/pages/ops/shipment/tabs/Documents.vue', () => stand.tab());
vi.mock('@/views/pages/ops/shipment/tabs/Events.vue', () => stand.tab());
vi.mock('@/views/pages/ops/shipment/tabs/General.vue', () => stand.tab());
vi.mock('@/views/pages/ops/shipment/tabs/Media.vue', () => stand.tab());
vi.mock('@/views/pages/ops/shipment/tabs/Orders.vue', () => stand.tab());
vi.mock('@/views/pages/ops/purchase-order/tabs/Documents.vue', () => stand.tab());
vi.mock('@/views/pages/ops/purchase-order/tabs/General.vue', () => stand.tab());
vi.mock('@/views/pages/ops/purchase-order/tabs/Lines.vue', () => stand.tab());
vi.mock('@/views/pages/ops/purchase-order/tabs/Media.vue', () => stand.tab());
vi.mock('@/views/pages/ops/purchase-order/tabs/Payments.vue', () => stand.tab());
vi.mock('@/views/pages/ops/purchase-order/tabs/Pi.vue', () => stand.tab());
vi.mock('@/views/pages/ops/purchase-order/tabs/Production.vue', () => stand.tab());

const shipment = {
   id: 's1',
   code: 'SHP-THO-2026-001',
   status: 'booked',
   shipment_purchase_order: [],
   shipment_line: []
} as unknown as ShipmentRow;

const order = {
   id: 'o1',
   code: 'PO-THO-2026-001',
   status: 'draft',
   deposit_rate: 30,
   supplier: { code: 'TR1' },
   purchase_order_line: [],
   purchase_order_payment: [],
   pi_check: {}
} as unknown as PurchaseOrderRow;

const mountCard = async (card: Component) => {
   const wrapper = mount(
      { render: () => h(Suspense, null, { default: () => h(card, { id: 'x' }) }) },
      {
         global: {
            plugins: [
               i18NPlugin,
               PrimeVue,
               ConfirmationService,
               ToastService,
               [abilitiesPlugin, ability, { useGlobalProperties: true }]
            ],
            stubs: { teleport: true }
         }
      }
   );
   await flushPromises();
   return wrapper;
};

const moves = (wrapper: Awaited<ReturnType<typeof mountCard>>) => wrapper.findAll('[data-status]');

enableAutoUnmount(afterEach);
beforeAll(() => i18n.setLocaleMessage('en', en));
beforeEach(() => {
   setActivePinia(createPinia());
   ability.update([{ action: 'manage', subject: 'all' }]);
   api.dirty = ref(false);
   api.shared = ref(false);
});

describe.each([
   ['shipment', ShipmentCard, shipment],
   ['purchase order', PurchaseOrderCard, order]
] as const)('%s card status actions', (_, card, row) => {
   beforeEach(() => {
      api.row = row;
   });

   it('offers the moves while the form is clean', async () => {
      const wrapper = await mountCard(card);

      expect(moves(wrapper).length).toBeGreaterThan(0);
      for (const button of moves(wrapper)) expect(button.attributes('disabled')).toBeUndefined();
      expect(wrapper.find('[data-test="status-dirty-hint"]').exists()).toBe(false);
   });

   it('disables them, saying why, while there are unsaved edits', async () => {
      const wrapper = await mountCard(card);
      api.dirty.value = true;
      await flushPromises();

      expect(moves(wrapper).length).toBeGreaterThan(0);
      for (const button of moves(wrapper)) expect(button.attributes('disabled')).toBeDefined();
      expect(wrapper.get('[data-test="status-dirty-hint"]').text()).toBe(
         i18n.t('ops.status_actions.dirty_hint')
      );
   });
});

// A provider's row shared with the client side: read-only, tagged with its provider, and only the
// tabs of what the client reads.
describe.each([
   ['shipment', ShipmentCard, shipment, 'shipment', ['general', 'dates', 'orders', 'events']],
   ['purchase order', PurchaseOrderCard, order, 'purchase_order', ['general', 'lines']]
] as const)('shared %s card', (_, card, row, prefix, tabs) => {
   beforeEach(() => {
      api.row = row;
      api.shared.value = true;
   });

   it('offers no move, names its provider and shows the client tabs only', async () => {
      const wrapper = await mountCard(card);

      expect(moves(wrapper)).toHaveLength(0);
      expect(wrapper.get('[data-test="shared-tag"]').text()).toBe('From MOESA LTD');
      expect(wrapper.get('[data-test="shared-hint"]').text()).toBe(i18n.t('ops.shared.read_only'));
      const shown = wrapper.findAll('[role="tab"]').map((tab) => tab.text());
      expect(shown).toEqual(tabs.map((key) => i18n.t(`ops.${prefix}.tabs.${key}`)));
   });
});
