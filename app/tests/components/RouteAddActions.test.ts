import '../setup/mockMain';
import RouteAddActions from '@/components/ui/route-add-actions/RouteAddActions.vue';
import { ability } from '@/plugins/casl';
import en from '@/plugins/i18n/locales/en/index.json';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { defineComponent } from 'vue';
import { createMemoryHistory, createRouter, useRouter, type RouteLocationRaw } from 'vue-router';

// A module's side-menu add actions shown as buttons on its list page.
const router = createRouter({
   history: createMemoryHistory(),
   routes: [
      { path: '/', component: { template: '<div />' } },
      {
         path: '/incidents',
         name: 'ops-incident',
         meta: {
            contextMenuItems: [
               {
                  label: 'action.add',
                  route: { name: 'ops-incident-manage', query: { showDialog: 'center' } }
               }
            ]
         },
         component: { template: '<div />' }
      },
      {
         path: '/incidents/manage',
         name: 'ops-incident-manage',
         meta: { requiredPermissions: [{ action: 'select', subject: 'incident' }] },
         component: { template: '<div />' }
      },
      {
         path: '/orders',
         name: 'ops-purchase-order',
         meta: { contextMenuItems: () => [] },
         component: { template: '<div />' }
      }
   ]
});

// Like CustomLink, the stub navigates only through the navigate slot prop.
const CustomLink = defineComponent({
   props: ['to'],
   setup(props, { slots }) {
      const linkRouter = useRouter();
      return () =>
         slots.default?.({ navigate: () => linkRouter.push(props.to as RouteLocationRaw) });
   }
});

const mountActions = (name: string) =>
   mount(RouteAddActions, {
      props: { name },
      global: { plugins: [router, i18NPlugin, PrimeVue] as never, stubs: { CustomLink } }
   });

describe('RouteAddActions', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   beforeEach(() => ability.update([{ action: 'manage', subject: 'all' }]));

   it("shows the menu's Add as a button that opens the new-record dialog", async () => {
      const wrapper = mountActions('ops-incident');
      const button = wrapper.get('[data-route-add-actions] button');
      expect(button.text()).toBe(en.action.add);

      await button.trigger('click');
      await flushPromises();
      expect(router.currentRoute.value.name).toBe('ops-incident-manage');
      expect(router.currentRoute.value.query.showDialog).toBe('center');
   });

   it('shows nothing to a user who may read but not create, or when the menu offers no add', () => {
      ability.update([{ action: 'select', subject: 'incident' }]);
      expect(mountActions('ops-incident').find('[data-route-add-actions]').exists()).toBe(false);

      ability.update([{ action: 'manage', subject: 'all' }]);
      expect(mountActions('ops-purchase-order').find('[data-route-add-actions]').exists()).toBe(
         false
      );
   });
});
