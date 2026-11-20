import '../setup/mockMain';
import { ability } from '@/plugins/casl';
import en from '@/plugins/i18n/locales/en/index.json';
import Incidents from '@/views/pages/ops/product/tabs/Incidents.vue';
import { PRODUCT_CARD_TABS } from '@/views/pages/ops/product/useProductForm';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { abilitiesPlugin } from '@casl/vue';
import { mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { defineComponent, h } from 'vue';

// The product card's incidents: those linked to the product, and a new one with it filled in.
const IncidentTable = defineComponent({
   name: 'IncidentTable',
   props: ['filters'],
   setup: () => () => h('div')
});
const CustomLink = defineComponent({
   name: 'CustomLink',
   props: ['to'],
   setup:
      (_, { slots }) =>
      () =>
         slots.default?.({ navigate: () => {} })
});

const mountTab = () =>
   mount(Incidents, {
      props: { id: 'p1' },
      global: {
         plugins: [i18NPlugin, PrimeVue, [abilitiesPlugin, ability, { useGlobalProperties: true }]],
         stubs: { IncidentTable, CustomLink }
      }
   });

describe('product incidents tab', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   beforeEach(() => ability.update([{ action: 'manage', subject: 'all' }]));

   it('is a tab of the product card', () => {
      expect(PRODUCT_CARD_TABS).toContain('incidents');
   });

   it("lists the product's incidents and opens a new one linked to it", () => {
      const wrapper = mountTab();
      expect(wrapper.getComponent(IncidentTable).props('filters')).toEqual({
         entityType: 'product',
         entityId: 'p1'
      });
      expect(wrapper.getComponent(CustomLink).props('to')).toMatchObject({
         name: 'ops-incident-manage',
         query: { entity_type: 'product', entity_id: 'p1' }
      });
   });

   it('offers no new incident without the right', () => {
      ability.update([{ action: 'read', subject: 'incident' }]);
      expect(mountTab().find('[data-test="new-incident"]').exists()).toBe(false);
   });
});
