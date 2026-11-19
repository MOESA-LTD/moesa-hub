import '../setup/mockMain';
import { ability } from '@/plugins/casl';
import en from '@/plugins/i18n/locales/en/index.json';
import Manage from '@/views/pages/ops/client/Manage.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { abilitiesPlugin } from '@casl/vue';
import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import ConfirmationService from 'primevue/confirmationservice';
import FocusTrap from 'primevue/focustrap';
import ToastService from 'primevue/toastservice';
import Tooltip from 'primevue/tooltip';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, Suspense } from 'vue';

// The form is useUpsertForm: a stand-in holds the relationship it would load, so what the page
// adds (the side, the locks, the procurement choices) is what is checked.
const api = vi.hoisted(() => ({ row: null as unknown, active: 'provider' }));

vi.mock('@/lib/supabase', () => ({ supabase: {}, publicSchema: {} }));
vi.mock('@/store/auth', () => ({
   useAuthStore: () => ({ currentTenant: { id: api.active }, scopeTenants: [{ id: api.active }] })
}));
vi.mock('@/composables/useUpsertForm', async () => {
   const { toRelationshipFormValues } = await import('@/api/relationship');
   const { ref } = await import('vue');
   return {
      useUpsertForm: () => ({
         values: ref(toRelationshipFormValues(api.row as never)),
         errors: ref({}),
         isDirty: ref(false),
         isSubmitting: ref(false),
         readonly: ref(false),
         reset: () => {},
         save: () => Promise.resolve(),
         ready: Promise.resolve(),
         draft: {},
         row: ref(api.row)
      })
   };
});

const relationship = (overrides: object = {}) => ({
   id: 'r1',
   tenant_id: 'provider',
   client_tenant_id: 'tho',
   client_code: 'THO',
   client_name: 'Thor GmbH',
   provider_name: 'Moesa Ltd',
   procurement_model: 'provider',
   commercial_model: 'trading_partner',
   packages: ['A1'],
   contract_status: 'active',
   start_on: null,
   deposit_rate: 30,
   extra_cost_rule: 'rule',
   eu_responsible_person: 'EU rep',
   notes: 'secret note',
   restricted_drive_url: null,
   status: 'active',
   ...overrides
});

const mountManage = async () => {
   const wrapper = mount(
      defineComponent({
         setup: () => () => h(Suspense, null, { default: () => h(Manage, { id: 'r1' }) })
      }),
      {
         attachTo: document.body,
         global: {
            plugins: [
               i18NPlugin,
               PrimeVue,
               ConfirmationService,
               ToastService,
               [abilitiesPlugin, ability, { useGlobalProperties: true }]
            ] as never,
            directives: { tooltip: Tooltip, focustrap: FocusTrap }
         }
      }
   );
   await flushPromises();
   return wrapper;
};

enableAutoUnmount(afterEach);

describe('relationship Manage page', () => {
   beforeAll(() => {
      i18n.setLocaleMessage('en', en);
      ability.update([{ action: ['read', 'update', 'insert'], subject: 'all' }]);
   });
   beforeEach(() => {
      api.active = 'provider';
      api.row = relationship();
   });

   it('the client side offers no edit of contract terms', async () => {
      api.active = 'tho';
      const wrapper = await mountManage();
      const inputs = wrapper.findAll('input, textarea');
      expect(inputs.length).toBeGreaterThan(0);
      expect(inputs.every((input) => input.attributes('disabled') !== undefined)).toBe(true);
      // Provider-internal notes are not shown to the client at all.
      expect(wrapper.text()).not.toContain(en.ops.client.fields.notes);
      expect(wrapper.text()).toContain('Moesa Ltd');
   });

   it('offers no way to save on the client side, nor for an ended relationship', async () => {
      api.active = 'tho';
      expect((await mountManage()).find('button[type="submit"]').exists()).toBe(false);
      api.active = 'provider';
      api.row = relationship({ status: 'ended' });
      const ended = await mountManage();
      expect(ended.find('button[type="submit"]').exists()).toBe(false);
      expect(ended.findAll('input').every((i) => i.attributes('disabled') !== undefined)).toBe(
         true
      );
   });

   it('starts locked as the client when no row is loaded', async () => {
      api.row = null;
      const wrapper = await mountManage();
      expect(wrapper.find('button[type="submit"]').exists()).toBe(false);
      expect(wrapper.text()).not.toContain(en.ops.client.fields.notes);
   });

   it('the provider side edits the terms', async () => {
      const wrapper = await mountManage();
      const deposit = wrapper.findAll('input').find((input) => input.element.value.includes('30'));
      expect(deposit?.attributes('disabled')).toBeUndefined();
      expect(wrapper.text()).toContain('THO');
   });

   it('offers provider to client only, never client to provider', async () => {
      const options = async (model: string) => {
         api.row = relationship({ procurement_model: model });
         const wrapper = await mountManage();
         const select = wrapper.findAllComponents({ name: 'SelectEnum' })[0];
         return select.props('values');
      };
      expect(await options('provider')).toEqual(['provider', 'client']);
      expect(await options('client')).toEqual(['client']);
   });
});
