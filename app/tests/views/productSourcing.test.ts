import '../setup/mockMain';
import { ability } from '@/plugins/casl';
import en from '@/plugins/i18n/locales/en/index.json';
import Sourcing from '@/views/pages/ops/product/tabs/Sourcing.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { abilitiesPlugin } from '@casl/vue';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, Suspense } from 'vue';

// The product's sourcing tab: the active tenant's row in a form, the other tenants' rows beside it,
// and the provider's spec sheets on its row for a client's product.
const api = vi.hoisted(() => ({
   product: null as unknown,
   rows: [] as unknown[],
   clients: [] as { value: string }[],
   providerProcures: false
}));

vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('@/store/auth', () => ({
   useAuthStore: () => ({
      currentTenant: { id: 'provider' },
      scopeTenants: [
         { id: 'provider', display_name: 'Provider Ltd' },
         { id: 'client', display_name: 'Thor GmbH' }
      ]
   })
}));
vi.mock('@/api/product', async (importOriginal) => {
   const { ref } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/product')>()),
      productResource: { useOne: () => ({ data: ref(api.product) }) }
   };
});
vi.mock('@/api/sourcing', async (importOriginal) => {
   const { ref } = await import('vue');
   return {
      ...(await importOriginal<typeof import('@/api/sourcing')>()),
      useSourcing: () => ({ data: ref(api.rows), isPending: ref(false) })
   };
});
vi.mock('@/api/relationship', async () => {
   const { computed } = await import('vue');
   return {
      useClientOptions: () => computed(() => api.clients),
      useProviderProcures: () => computed(() => api.providerProcures)
   };
});

const SourcingForm = defineComponent({
   name: 'SourcingForm',
   props: ['id', 'productId', 'clientTenantId'],
   setup: () => () => h('form')
});
const EntityDocuments = defineComponent({
   name: 'EntityDocuments',
   props: ['entityType', 'entityId', 'code'],
   setup: () => () => h('div')
});

const mountTab = async () => {
   const wrapper = mount(
      defineComponent({
         render: () => h(Suspense, null, { default: () => h(Sourcing, { id: 'p1' }) })
      }),
      {
         global: {
            plugins: [
               i18NPlugin,
               PrimeVue,
               [abilitiesPlugin, ability, { useGlobalProperties: true }]
            ],
            stubs: { SourcingForm, EntityDocuments }
         }
      }
   );
   await flushPromises();
   return wrapper;
};

const clientProduct = { id: 'p1', tenant_id: 'client', sku: 'THO-MOP' };

describe('product sourcing tab', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));

   beforeEach(() => {
      ability.update([{ action: 'manage', subject: 'all' }]);
      api.product = clientProduct;
      api.rows = [];
      api.clients = [{ value: 'client' }];
      api.providerProcures = false;
   });

   it("edits the active tenant's row and shows the client's own row beside it", async () => {
      api.rows = [
         { id: 'own', tenant_id: 'provider', client_tenant_id: 'client', purchase_price: 1.9 },
         { id: 'theirs', tenant_id: 'client', client_tenant_id: null, sell_price_eur: 4.5 }
      ];
      const wrapper = await mountTab();

      const form = wrapper.getComponent(SourcingForm);
      expect(form.props()).toMatchObject({ id: 'own', productId: 'p1', clientTenantId: 'client' });
      expect(wrapper.get('[data-sourcing-others]').text()).toContain('Thor GmbH');
      expect(wrapper.get('[data-sourcing-others]').text()).toContain('4.5');
   });

   it("lets the provider attach its spec sheet to its row of a client's product", async () => {
      api.rows = [{ id: 'own', tenant_id: 'provider', client_tenant_id: 'client' }];
      const wrapper = await mountTab();
      expect(wrapper.getComponent(EntityDocuments).props()).toEqual({
         entityType: 'sourcing',
         entityId: 'own',
         code: 'THO-MOP'
      });
   });

   it("adds a row for a client's product under a relationship, naming the client", async () => {
      const wrapper = await mountTab();
      expect(wrapper.findComponent(SourcingForm).exists()).toBe(false);
      expect(wrapper.find('[data-sourcing-documents]').exists()).toBe(false);

      await wrapper.get('[data-sourcing-add]').trigger('click');
      expect(wrapper.getComponent(SourcingForm).props()).toMatchObject({
         id: null,
         clientTenantId: 'client'
      });
   });

   it('offers no add without a relationship to the product owner, or without the right', async () => {
      api.clients = [];
      const wrapper = await mountTab();
      expect(wrapper.find('[data-sourcing-add]').exists()).toBe(false);
      expect(wrapper.text()).toContain(i18n.t('ops.product.sourcing.no_relationship'));

      api.clients = [{ value: 'client' }];
      ability.update([{ action: 'read', subject: 'sourcing' }]);
      expect((await mountTab()).find('[data-sourcing-add]').exists()).toBe(false);
   });

   it('adds a row for an own product without a client', async () => {
      api.product = { id: 'p1', tenant_id: 'provider', sku: 'OWN-1' };
      api.clients = [];
      const wrapper = await mountTab();
      await wrapper.get('[data-sourcing-add]').trigger('click');
      expect(wrapper.getComponent(SourcingForm).props('clientTenantId')).toBeNull();
   });

   it('keeps procurement out of a company its provider procures for', async () => {
      api.product = { id: 'p1', tenant_id: 'provider', sku: 'OWN-1' };
      api.providerProcures = true;
      const wrapper = await mountTab();
      expect(wrapper.find('[data-sourcing-add]').exists()).toBe(false);
      expect(wrapper.get('[data-sourcing-provider-procures]').text()).toBe(
         en.ops.product.sourcing.kept_by_provider
      );
   });

   it('hides the sourcing fields the user may not read', async () => {
      ability.update([
         { action: 'read', subject: 'sourcing' },
         { action: 'read', subject: 'sourcing', fields: ['sell_price_eur'], inverted: true }
      ]);
      api.rows = [
         { id: 'theirs', tenant_id: 'client', client_tenant_id: null, sell_price_eur: 4.5 }
      ];
      const wrapper = await mountTab();
      expect(wrapper.get('[data-sourcing-others]').text()).not.toContain(
         en.ops.product.fields.sell_price_eur
      );
   });
});
