import '../setup/mockMain';
import { toChangeRequestFormValues, type ChangeRequestCard } from '@/api/changeRequest';
import { provideFormTenant } from '@/api/formTenant';
import { toIncidentFormValues, type IncidentCard as IncidentRow } from '@/api/incident';
import { ability } from '@/plugins/casl';
import en from '@/plugins/i18n/locales/en/index.json';
import CrGeneral from '@/views/pages/ops/change-request/tabs/General.vue';
import { CHANGE_REQUEST_FORM } from '@/views/pages/ops/change-request/useChangeRequestForm';
import IncGeneral from '@/views/pages/ops/incident/tabs/General.vue';
import { INCIDENT_FORM, INCIDENT_OVERVIEW } from '@/views/pages/ops/incident/useIncidentForm';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { abilitiesPlugin } from '@casl/vue';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { enableAutoUnmount, mount, type VueWrapper } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import PrimeVue from 'primevue/config';
import ConfirmationService from 'primevue/confirmationservice';
import ToastService from 'primevue/toastservice';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, ref } from 'vue';

// O_OWN belongs to the form tenant T; O_SHARED is a provider's order shared to it.
const T = 't-client';
const PROVIDER = 't-provider';
const OPTIONS = [
   { value: 'O_OWN', label: 'Own order', tenantId: T },
   { value: 'O_SHARED', label: 'Shared order', tenantId: PROVIDER }
];

vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ query: {} }),
   useRouter: () => ({ push: vi.fn() })
}));
vi.mock('@/api/useLookup', async () => {
   const { computed } = await import('vue');
   return { useLookup: () => ({ data: computed(() => undefined) }) };
});
vi.mock('@/api/project', async (importOriginal) => {
   const { computed } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/project')>()),
      useMemberOptions: () => computed(() => [])
   };
});
vi.mock('@/api/purchaseOrder', async (importOriginal) => {
   const { computed } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/purchaseOrder')>()),
      useEntityDocumentOptions: () => computed(() => [])
   };
});
vi.mock('@/api/changeRequest', async (importOriginal) => {
   const { computed } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/changeRequest')>()),
      useNewerDocumentOptions: () => computed(() => [])
   };
});
vi.mock('@/api/incident', async (importOriginal) => {
   const { computed } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/incident')>()),
      useIncidentEntityOptions: () => computed(() => OPTIONS)
   };
});

const Slot = defineComponent({
   setup:
      (_, { slots }) =>
      () =>
         h('div', slots.default?.({}))
});

const standInForm = (values: Record<string, unknown>, row: unknown) => ({
   values: ref(values),
   errors: ref({}),
   isDirty: ref(false),
   isSubmitting: ref(false),
   readonly: ref(false),
   reset: vi.fn(),
   submit: vi.fn(),
   draft: {},
   row: ref(row)
});

const mountTab = (component: unknown, key: symbol, form: unknown) => {
   const Host = defineComponent({
      setup() {
         provideFormTenant(T);
         return () => h(component as never);
      }
   });
   return mount(Host, {
      global: {
         plugins: [
            i18NPlugin,
            PrimeVue,
            ConfirmationService,
            ToastService,
            VueQueryPlugin,
            [abilitiesPlugin, ability, { useGlobalProperties: true }] as const
         ] as never,
         provide: { [key]: form, [INCIDENT_OVERVIEW as symbol]: ref(null) },
         directives: { focustrap: {}, tooltip: {} },
         stubs: { FormBox: Slot, FormField: Slot, ProductMultiSelect: true, teleport: true }
      }
   });
};

const selectOf = (wrapper: VueWrapper, field: string) =>
   wrapper
      .findAllComponents({ name: 'Select' })
      .find((select) => select.attributes('data-field') === field)!;

enableAutoUnmount(afterEach);
beforeAll(() => i18n.setLocaleMessage('en', en));
beforeEach(() => {
   setActivePinia(createPinia());
   ability.update([{ action: 'manage', subject: 'all' }]);
});

describe('incident order and shipment picker', () => {
   const mountIncident = (row: IncidentRow | null) => {
      const form = standInForm(
         { ...toIncidentFormValues(row), entity_type: 'purchase_order' },
         row
      );
      return { form, wrapper: mountTab(IncGeneral, INCIDENT_FORM as symbol, form) };
   };

   it("sets the link from a shared row's tenant", () => {
      const { form, wrapper } = mountIncident(null);
      selectOf(wrapper, 'entity_id').vm.$emit('update:modelValue', 'O_SHARED');
      expect(form.values.value.entity_id).toBe('O_SHARED');
      expect(form.values.value.entity_tenant_id).toBe(PROVIDER);
   });

   it('leaves the link null for an own pick', () => {
      const { form, wrapper } = mountIncident(null);
      selectOf(wrapper, 'entity_id').vm.$emit('update:modelValue', 'O_OWN');
      expect(form.values.value.entity_tenant_id).toBeNull();
   });

   it('does not let a saved link change', () => {
      const row = {
         id: 'I1',
         tenant_id: T,
         family: 'ol',
         entity_type: 'purchase_order',
         entity_id: 'O_SHARED',
         entity_tenant_id: PROVIDER,
         affected_parties: [],
         incident_log: [],
         incident_deadline: [],
         project_gate: []
      } as unknown as IncidentRow;
      const { wrapper } = mountIncident(row);
      expect(selectOf(wrapper, 'entity_id').props('disabled')).toBe(true);
      expect(selectOf(wrapper, 'entity_type').props('disabled')).toBe(true);
   });
});

describe('change request order picker', () => {
   const card = (values: Record<string, unknown> = {}) =>
      ({
         id: 'CR1',
         tenant_id: T,
         project_id: null,
         project: null,
         change_kinds: [],
         change_request_product: [],
         ...values
      }) as unknown as ChangeRequestCard;
   const mountCr = (row: ChangeRequestCard | null) => {
      const form = standInForm(toChangeRequestFormValues(row), row);
      return { form, wrapper: mountTab(CrGeneral, CHANGE_REQUEST_FORM as symbol, form) };
   };

   it("sets the link from a shared order's tenant", () => {
      const { form, wrapper } = mountCr(null);
      selectOf(wrapper, 'purchase_order_id').vm.$emit('update:modelValue', 'O_SHARED');
      expect(form.values.value.purchase_order_id).toBe('O_SHARED');
      expect(form.values.value.order_tenant_id).toBe(PROVIDER);
   });

   it('leaves the link null for an own pick', () => {
      const { form, wrapper } = mountCr(null);
      selectOf(wrapper, 'purchase_order_id').vm.$emit('update:modelValue', 'O_OWN');
      expect(form.values.value.order_tenant_id).toBeNull();
   });

   it('does not let a saved link change', () => {
      const { wrapper } = mountCr(
         card({ purchase_order_id: 'O_SHARED', order_tenant_id: PROVIDER })
      );
      expect(selectOf(wrapper, 'purchase_order_id').props('disabled')).toBe(true);
   });

   it('keeps an own saved order editable', () => {
      const { wrapper } = mountCr(card({ purchase_order_id: 'O_OWN', order_tenant_id: T }));
      expect(selectOf(wrapper, 'purchase_order_id').props('disabled')).toBe(false);
   });
});
