import '../setup/mockMain';
import {
   toPurchaseOrderFormValues,
   type PurchaseOrderCard,
   type PurchaseOrderCardLine,
   type PurchaseOrderOverviewRow,
   type PurchaseOrderStatus
} from '@/api/purchaseOrder';
import { ability } from '@/plugins/casl';
import FormField from '@/components/ui/form/form-field/FormField.vue';
import en from '@/plugins/i18n/locales/en/index.json';
import General from '@/views/pages/ops/purchase-order/tabs/General.vue';
import Lines from '@/views/pages/ops/purchase-order/tabs/Lines.vue';
import {
   PURCHASE_ORDER_FORM,
   PURCHASE_ORDER_OVERVIEW,
   tabForField,
   usePurchaseOrderForm
} from '@/views/pages/ops/purchase-order/usePurchaseOrderForm';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { abilitiesPlugin } from '@casl/vue';
import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import PrimeVue from 'primevue/config';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, nextTick, ref } from 'vue';

const api = vi.hoisted(() => ({
   query: {} as Record<string, string>,
   options: undefined as
      | undefined
      | {
           prefill: () => Record<string, unknown>;
           toPayload: (data: Record<string, unknown>) => Record<string, unknown>;
           onSaved?: (row: { id: string }) => void;
        },
   row: { value: null as unknown },
   values: { value: {} as Record<string, unknown> },
   linked: { status: 'pending' } as { status: string; clientTenantId?: string | null },
   linkedProjectIds: [] as unknown[]
}));

vi.mock('@/composables/useSharedRow', async (importOriginal) => ({
   ...(await importOriginal<typeof import('@/composables/useSharedRow')>()),
   useSharedRow: () => ({ isShared: () => false, providerName: () => null })
}));
vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ query: api.query }),
   useRouter: () => ({ push: vi.fn() })
}));
// The card's form is useUpsertForm; what usePurchaseOrderForm adds is checked against a stand-in.
vi.mock('@/composables/useUpsertForm', () => ({
   useUpsertForm: (given: NonNullable<typeof api.options>) => {
      api.options = given;
      return {
         discardDraft: vi.fn(),
         row: api.row,
         values: api.values,
         tenantId: { value: 'provider' }
      };
   }
}));
vi.mock('@/api/relationship', async (importOriginal) => {
   const { computed, toValue } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/relationship')>()),
      useLinkedClient: (projectId: () => unknown) =>
         computed(() => {
            api.linkedProjectIds.push(toValue(projectId));
            return api.linked;
         })
   };
});
vi.mock('@/api/purchaseOrder', async (importOriginal) => {
   const { computed } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/purchaseOrder')>()),
      useEntityDocumentOptions: () => computed(() => [])
   };
});

const Slot = defineComponent({
   setup:
      (_, { slots }) =>
      () =>
         h('div', slots.default?.({}))
});
const SelectSupplier = defineComponent({
   name: 'SelectSupplier',
   props: ['modelValue'],
   emits: ['update:modelValue', 'pick'],
   setup: () => () => h('span', { 'data-select': 'supplier' })
});
const Stub = (name: string) =>
   defineComponent({ name, props: ['modelValue'], setup: () => () => h('span') });
const CustomLink = defineComponent({
   props: ['to'],
   setup:
      (props, { slots }) =>
      () =>
         h('span', { 'data-link': props.to.name }, slots.default?.({ navigate: () => {} }))
});

const SUPPLIER = '00000000-0000-4000-8000-000000000002';

const line = (id: string, position: number): PurchaseOrderCardLine =>
   ({
      id,
      position,
      quantity: 100,
      unit_price: 1.9,
      line_total: 190,
      product: { id: `p-${id}`, sku: `SKU-${id}`, display_name: `Product ${id}` },
      spec_document: null
   }) as unknown as PurchaseOrderCardLine;

const order = (status: PurchaseOrderStatus, lines: PurchaseOrderCardLine[] = []) =>
   ({
      id: 'o1',
      code: 'PO-THO-2026-001',
      status,
      currency: 'USD',
      supplier_id: SUPPLIER,
      incoterm: 'EXW',
      deposit_rate: 30,
      supplier: { code: 'TR1' },
      purchase_order_line: lines,
      purchase_order_payment: []
   }) as unknown as PurchaseOrderCard;

/** The card's form as the tabs inject it: values from the row, or a new order's empty ones. */
const standInForm = (row: PurchaseOrderCard | null) => ({
   values: ref(toPurchaseOrderFormValues(row)),
   errors: ref({}),
   isDirty: ref(false),
   isSubmitting: ref(false),
   readonly: ref(false),
   shared: ref(false),
   reset: vi.fn(),
   submit: vi.fn(),
   draft: {},
   row: ref(row),
   linkError: ref<string | null>(null)
});

const mountTab = (
   component: typeof General | typeof Lines,
   form: ReturnType<typeof standInForm>,
   overview: Partial<PurchaseOrderOverviewRow> | null = null
) =>
   mount(component, {
      global: {
         plugins: [i18NPlugin, PrimeVue, [abilitiesPlugin, ability, { useGlobalProperties: true }]],
         provide: {
            [PURCHASE_ORDER_FORM as symbol]: form,
            [PURCHASE_ORDER_OVERVIEW as symbol]: ref(overview)
         },
         directives: { focustrap: {}, tooltip: {} },
         stubs: {
            FormBox: Slot,
            FormField: Slot,
            SelectSupplier,
            ProjectSelect: Stub('ProjectSelect'),
            SelectClient: Stub('SelectClient'),
            CustomLink
         }
      }
   });

beforeAll(() => i18n.setLocaleMessage('en', en));

beforeEach(() => {
   setActivePinia(createPinia());
   ability.update([{ action: 'manage', subject: 'all' }]);
   api.query = {};
   api.row.value = null;
   api.values.value = { client_tenant_id: null, project_id: null };
   api.linked = { status: 'pending' };
   api.linkedProjectIds = [];
});

describe('tabForField', () => {
   it('opens the PI tab for a PI field and the general tab for the rest', () => {
      expect(tabForField('pi_total')).toBe('pi');
      expect(tabForField('pi_check')).toBe('pi');
      expect(tabForField('incoterm')).toBe('general');
      expect(tabForField('currency')).toBe('general');
   });
});

describe('usePurchaseOrderForm', () => {
   it('starts a new order empty', () => {
      usePurchaseOrderForm(() => null);
      expect(api.options!.prefill()).toEqual({});
   });

   it("takes the project from the link's props", () => {
      usePurchaseOrderForm(() => null, undefined, { projectId: 'pr1' });
      expect(api.options!.prefill()).toEqual({ project_id: 'pr1' });
   });

   it("names the client of a client project's link", async () => {
      api.values.value = { client_tenant_id: null, project_id: 'pr1' };
      api.linked = { status: 'client', clientTenantId: 'tho' };
      const form = usePurchaseOrderForm(() => null, undefined, { projectId: 'pr1' });
      await nextTick();

      expect(api.linkedProjectIds).toContain('pr1');
      expect(api.values.value).toEqual({ client_tenant_id: 'tho', project_id: 'pr1' });
      expect(form.linkError.value).toBeNull();
   });

   it("leaves an own project's link without a client", async () => {
      api.values.value = { client_tenant_id: null, project_id: 'pr1' };
      api.linked = { status: 'own' };
      const form = usePurchaseOrderForm(() => null, undefined, { projectId: 'pr1' });
      await nextTick();

      expect(api.values.value).toEqual({ client_tenant_id: null, project_id: 'pr1' });
      expect(form.linkError.value).toBeNull();
   });

   it('refuses the link of a project outside an active provider-procures relationship', async () => {
      api.values.value = { client_tenant_id: null, project_id: 'pr1' };
      api.linked = { status: 'forbidden' };
      const form = usePurchaseOrderForm(() => null, undefined, { projectId: 'pr1' });
      await nextTick();

      expect(form.linkError.value).toBe('relationship_inactive');
      expect(api.values.value.project_id).toBeNull();
   });

   it('looks up no project for a saved order', () => {
      usePurchaseOrderForm(() => 'o1', undefined, { projectId: 'pr1' });
      expect(api.linkedProjectIds.every((id) => id === undefined)).toBe(true);
   });

   it('shows the refusal instead of the form', () => {
      const form = { ...standInForm(null), linkError: ref('relationship_inactive') };
      const wrapper = mountTab(General, form as never);
      expect(wrapper.get('[data-link-error]').text()).toBe(i18n.t('errors.relationship_inactive'));
      expect(wrapper.findComponent({ name: 'SelectSupplier' }).exists()).toBe(false);
   });

   it('ignores the query of the page under a route dialog', () => {
      api.query = { project_id: 'pr-under' };
      usePurchaseOrderForm(() => null);
      expect(api.options!.prefill()).toEqual({});
   });

   it('leaves the locked terms out of the payload of an approved order', () => {
      api.row.value = order('pi_approved');
      usePurchaseOrderForm(() => 'o1');
      const payload = api.options!.toPayload({
         ...toPurchaseOrderFormValues(order('pi_approved')),
         id: 'o1',
         ready_on: null,
         notes: 'late'
      });
      expect(payload).toMatchObject({ id: 'o1', notes: 'late' });
      expect(payload).not.toHaveProperty('currency');
      expect(payload).not.toHaveProperty('incoterm');
   });
});

describe('general tab', () => {
   it('disables the locked terms from pi_approved on', () => {
      const wrapper = mountTab(General, standInForm(order('pi_approved')));
      expect(wrapper.get('[data-field="currency"]').classes()).toContain('p-disabled');
      expect(wrapper.get('[data-field="ready_on"] input').attributes()).not.toHaveProperty(
         'disabled'
      );
   });

   it('offers the client on a new order only, and its projects', () => {
      const CLIENT = '00000000-0000-4000-8000-000000000099';
      const form = standInForm(null);
      form.values.value.project_id = 'pr1';
      const wrapper = mountTab(General, form);
      const client = wrapper.getComponent({ name: 'SelectClient' });
      expect(client.attributes('disabled')).toBe('false');

      form.values.value.client_tenant_id = CLIENT;
      client.vm.$emit('change', CLIENT);
      expect(form.values.value.project_id).toBeNull();

      const saved = mountTab(General, standInForm(order('draft')));
      expect(saved.getComponent({ name: 'SelectClient' }).attributes('disabled')).toBe('true');
   });

   it('names the client tenant to the project picker', async () => {
      const CLIENT = '00000000-0000-4000-8000-000000000099';
      const form = standInForm(null);
      form.values.value.client_tenant_id = CLIENT;
      const wrapper = mountTab(General, form);
      expect(wrapper.getComponent({ name: 'ProjectSelect' }).attributes('tenantid')).toBe(CLIENT);
   });

   it('keeps the project of an order past its draft (po_project_locked)', () => {
      const draft = mountTab(General, standInForm(order('draft')));
      expect(draft.getComponent({ name: 'ProjectSelect' }).attributes('disabled')).toBe('false');
      const sent = mountTab(General, standInForm(order('sent')));
      expect(sent.getComponent({ name: 'ProjectSelect' }).attributes('disabled')).toBe('true');
   });

   it('keeps the terms of a sent order editable', () => {
      const wrapper = mountTab(General, standInForm(order('sent')));
      expect(wrapper.get('[data-field="currency"]').classes()).not.toContain('p-disabled');
   });

   it("fills an empty incoterm and deposit from the picked supplier's defaults", async () => {
      const form = standInForm(null);
      const wrapper = mountTab(General, form);

      wrapper.getComponent(SelectSupplier).vm.$emit('pick', {
         default_incoterm: 'FOB',
         deposit_rate: 30
      });

      expect(form.values.value.incoterm).toBe('FOB');
      expect(form.values.value.deposit_rate).toBe(30);
   });

   it('keeps an incoterm already set', async () => {
      const form = standInForm(null);
      form.values.value.incoterm = 'EXW';
      const wrapper = mountTab(General, form);

      wrapper.getComponent(SelectSupplier).vm.$emit('pick', {
         default_incoterm: 'FOB',
         deposit_rate: 30
      });

      expect(form.values.value.incoterm).toBe('EXW');
      expect(form.values.value.deposit_rate).toBe(30);
   });
});

describe('general tab for a coordinator', () => {
   // Reads the supplier terms but may not write them (supplier_terms read-only).
   beforeEach(() =>
      ability.update([
         { action: 'manage', subject: 'all' },
         ...['incoterm', 'deposit_rate'].flatMap((field) =>
            ['insert', 'update'].map((action) => ({
               action,
               subject: 'purchase_order',
               fields: [field],
               inverted: true
            }))
         )
      ])
   );

   it('shows the incoterm and the deposit read-only', () => {
      const wrapper = mount(General, {
         global: {
            plugins: [
               createPinia(),
               i18NPlugin,
               PrimeVue,
               [abilitiesPlugin, ability, { useGlobalProperties: true }]
            ],
            provide: {
               [PURCHASE_ORDER_FORM as symbol]: standInForm(order('sent')),
               [PURCHASE_ORDER_OVERVIEW as symbol]: ref(null)
            },
            directives: { focustrap: {}, tooltip: {} },
            stubs: {
               FormBox: Slot,
               BlockUI: Slot,
               SelectSupplier,
               ProjectSelect: Stub('ProjectSelect'),
               SelectClient: Stub('SelectClient'),
               CustomLink
            }
         }
      });
      const blocked = (field: string) =>
         (
            wrapper.findAllComponents(FormField).find((f) => f.props('field') === field)?.vm as
               | { blocked?: boolean }
               | undefined
         )?.blocked;
      expect(blocked('deposit_rate')).toBe(true);
      expect(blocked('incoterm')).toBe(true);
      expect(blocked('incoterm_place')).toBe(false);
   });

   it("does not fill the terms from the picked supplier's defaults", () => {
      const form = standInForm(null);
      const wrapper = mountTab(General, form);

      wrapper.getComponent(SelectSupplier).vm.$emit('pick', {
         default_incoterm: 'FOB',
         deposit_rate: 30
      });

      expect(form.values.value.incoterm).toBeFalsy();
      expect(form.values.value.deposit_rate ?? null).toBeNull();
   });
});

describe('lines tab', () => {
   const lines = [line('l1', 1), line('l2', 2)];

   it('marks the spec sheet missing only for the lines the overview lists', () => {
      const wrapper = mountTab(Lines, standInForm(order('draft', lines)), {
         spec_missing_line_ids: ['l1'],
         system_subtotal: 380,
         currency: 'USD'
      });

      const missing = wrapper.findAll('[data-test="spec-missing"]');
      expect(missing).toHaveLength(1);
      expect(missing[0]!.attributes('data-line')).toBe('l1');
      expect(missing[0]!.text()).toBe(i18n.t('ops.purchase_order.spec_missing'));
      expect(wrapper.text()).toContain('380.00 USD');
   });

   it('shows the version of a line with a spec sheet', () => {
      const withSpec = {
         ...line('l3', 3),
         spec_document: { id: 'd1', version: 3, status: 'signed' }
      } as PurchaseOrderCardLine;
      const wrapper = mountTab(Lines, standInForm(order('draft', [withSpec])), {
         spec_missing_line_ids: []
      });
      expect(wrapper.get('[data-test="spec-version"]').text()).toBe('v03');
      expect(wrapper.find('[data-test="spec-missing"]').exists()).toBe(false);
   });

   it('shows a shared order its sell prices, read-only, without cost or spec sheets', () => {
      const shared = [
         { ...line('l1', 1), unit_price: null, line_total: null, sell_price_eur: 9.9 }
      ];
      const form = {
         ...standInForm(order('sent', shared as PurchaseOrderCardLine[])),
         shared: ref(true)
      };
      const wrapper = mountTab(Lines, form, { spec_missing_line_ids: null, system_subtotal: null });

      const headers = wrapper.findAll('th').map((th) => th.text());
      expect(headers).toContain(i18n.t('ops.product.fields.sell_price_eur'));
      for (const key of ['unit_price', 'line_total', 'spec_document'])
         expect(headers).not.toContain(i18n.t(`ops.purchase_order.fields.${key}`));
      expect(wrapper.text()).toContain('9.90 EUR');
      expect(wrapper.find('[data-link="ops-purchase-order-line-add"]').exists()).toBe(false);
      expect(wrapper.find('[data-link="ops-purchase-order-line-edit"]').exists()).toBe(false);
      expect(wrapper.find('[data-test="subtotal"]').exists()).toBe(false);
   });

   it('offers adding and editing lines while the order is open', () => {
      const wrapper = mountTab(Lines, standInForm(order('sent', lines)));
      expect(wrapper.find('[data-link="ops-purchase-order-line-add"]').exists()).toBe(true);
      expect(wrapper.findAll('[data-link="ops-purchase-order-line-edit"]')).toHaveLength(2);
   });

   it('offers no new line to a user who may not write the unit price (NOT NULL)', () => {
      ability.update([
         { action: 'manage', subject: 'all' },
         ...['insert', 'update'].map((action) => ({
            action,
            subject: 'purchase_order_line',
            fields: ['unit_price'],
            inverted: true
         }))
      ]);
      const wrapper = mountTab(Lines, standInForm(order('sent', lines)));
      expect(wrapper.find('[data-link="ops-purchase-order-line-add"]').exists()).toBe(false);
      expect(wrapper.findAll('[data-link="ops-purchase-order-line-edit"]')).toHaveLength(2);
   });

   it('hides adding and editing once the order is locked', () => {
      const wrapper = mountTab(Lines, standInForm(order('pi_approved', lines)));
      expect(wrapper.find('[data-link="ops-purchase-order-line-add"]').exists()).toBe(false);
      expect(wrapper.find('[data-link="ops-purchase-order-line-edit"]').exists()).toBe(false);
   });
});
