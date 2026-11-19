import '../setup/mockMain';
import PlanCompare from '@/components/service-components/plan-compare/PlanCompare.vue';
import type { PlanSummary } from '@/lib/planDiff';
import en from '@/plugins/i18n/locales/en/index.json';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { beforeAll, describe, expect, it } from 'vitest';

const plan = (id: string, over: Partial<PlanSummary> = {}): PlanSummary => ({
   id,
   display_name: id.toUpperCase(),
   description: null,
   audience: null,
   price: 10,
   currency: 'EUR',
   billing_period: 'month',
   trial_days: 14,
   position: 1,
   modules: ['product', 'audit_log'],
   limits: { max_users: 10 },
   ...over
});

const mountCompare = (props: Record<string, unknown> = {}) =>
   mount(PlanCompare, {
      props: {
         plans: [
            plan('basic', { modules: ['product'], limits: { max_users: 2 }, position: 1 }),
            plan('pro', { audience: 'Growing teams', position: 2 })
         ],
         recommendedId: 'pro',
         seats: 1,
         modelValue: 'pro',
         providerName: 'MOESA LTD',
         coreModules: ['product'],
         ...props
      },
      global: { plugins: [i18NPlugin, PrimeVue] }
   });

describe('PlanCompare', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));

   it('marks the recommended plan', () => {
      const wrapper = mountCompare();
      const badges = wrapper.findAll('[data-recommended]');
      expect(badges).toHaveLength(1);
      expect(badges[0]!.text()).toContain('Recommended by MOESA LTD');
      expect(wrapper.get('[data-plan="pro"]').find('[data-recommended]').exists()).toBe(true);
   });

   it("disables a plan whose user limit is below the invitation's seats", () => {
      const wrapper = mountCompare({ seats: 3 });
      const basic = wrapper.get('[data-plan="basic"]');
      expect(basic.get('button').attributes('disabled')).toBeDefined();
      expect(basic.get('[data-too-small]').text()).toContain('3');
      expect(wrapper.get('[data-plan="pro"] button').attributes('disabled')).toBeUndefined();
   });

   it('explains a downgrade', () => {
      const wrapper = mountCompare();
      const text = wrapper.get('[data-change="downgrade"]').text();
      expect(text).toContain('Downgrading to BASIC');
      expect(text).toContain('removes');
      expect(text).toContain('users to 2');
   });

   it('explains an upgrade', () => {
      const wrapper = mountCompare({ modelValue: 'basic' });
      const text = wrapper.get('[data-change="upgrade"]').text();
      expect(text).toContain('Upgrading to PRO');
      expect(text).toContain('adds');
   });

   it('shows unlimited for a missing limit and no changes without a choice', () => {
      const wrapper = mountCompare({
         plans: [plan('a', { limits: {} })],
         modelValue: null,
         recommendedId: null
      });
      expect(wrapper.text()).toContain('Unlimited');
      expect(wrapper.find('[data-plan-changes]').exists()).toBe(false);
   });

   it('emits the plan the customer chooses', async () => {
      const wrapper = mountCompare({ modelValue: null });
      await wrapper.get('[data-plan="pro"] button').trigger('click');
      expect(wrapper.emitted('update:modelValue')?.[0]).toEqual(['pro']);
   });
});
