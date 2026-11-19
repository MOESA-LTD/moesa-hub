import '../setup/mockMain';
import en from '@/plugins/i18n/locales/en/index.json';
import InvitationsIndex from '@/views/pages/ops/client/invitations/Index.vue';
import RelationshipsIndex from '@/views/pages/ops/client/Index.vue';
import { ability } from '@/plugins/casl';
import { abilitiesPlugin } from '@casl/vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import ToastService from 'primevue/toastservice';
import Tooltip from 'primevue/tooltip';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, nextTick } from 'vue';

const api = vi.hoisted(() => ({
   scope: [{ id: 'provider' }] as { id: string }[],
   confirm: vi.fn(),
   end: vi.fn()
}));

vi.mock('@/lib/supabase', () => ({ supabase: {}, publicSchema: {} }));
vi.mock('@/store/auth', () => ({
   useAuthStore: () => ({
      get currentTenant() {
         return api.scope[0];
      },
      get scopeTenants() {
         return api.scope;
      }
   })
}));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRouter: () => ({ push: vi.fn() })
}));
vi.mock('@/composables/useConfirmAction', () => ({ useConfirmAction: () => api.confirm }));
vi.mock('@/api/relationship', async (importOriginal) => ({
   ...(await importOriginal<typeof import('@/api/relationship')>()),
   useEndRelationship: () => ({ mutateAsync: api.end })
}));
vi.mock('@/api/invitation', async (importOriginal) => ({
   ...(await importOriginal<typeof import('@/api/invitation')>()),
   useResendInvitation: () => ({ mutateAsync: vi.fn() }),
   useRevokeInvitation: () => ({ mutateAsync: vi.fn() })
}));

type Captured = { from: string; fixedFilters?: unknown[]; rowActions?: any[] };
const tables: (Captured & { rows?: unknown[] })[] = [];

// Stands in for ResourceTable: records what it is given and renders each row's slots.
const ResourceTable = defineComponent({
   name: 'ResourceTable',
   inheritAttrs: false,
   props: ['from', 'fixedFilters', 'rowActions', 'columns'],
   setup(props, { slots, attrs }) {
      tables.push(props as never);
      return () =>
         h('div', { 'data-table': attrs.stateKey }, [
            slots.header?.(),
            ...((attrs['data-rows'] as unknown[] | undefined) ?? []).map((data) =>
               h('div', { class: 'row' }, [
                  slots.email_body?.({ data }),
                  slots.status_body?.({ data })
               ])
            )
         ]);
   }
});

const mountPage = (component: object, rows: unknown[] = []) =>
   mount(
      defineComponent({
         setup: () => () => h(component, { 'data-rows': rows })
      }),
      {
         global: {
            plugins: [
               i18NPlugin,
               PrimeVue,
               ToastService,
               [abilitiesPlugin, ability, { useGlobalProperties: true }]
            ] as never,
            directives: { tooltip: Tooltip },
            stubs: { ResourceTable, Teleport: true, KeywordSearchInput: true, CustomLink: true }
         }
      }
   );

enableAutoUnmount(afterEach);

describe('relationships page', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   beforeEach(() => {
      tables.length = 0;
      api.scope = [{ id: 'provider' }];
      api.confirm.mockReset().mockResolvedValue(true);
      api.end.mockReset();
   });

   it('splits clients and providers by the tenants in scope, and follows a tenant switch', async () => {
      const wrapper = mountPage(RelationshipsIndex);
      await flushPromises();
      const [clients, providers] = tables;
      expect(clients.fixedFilters).toEqual([{ column: 'tenant_id', in: ['provider'] }]);
      expect(providers.fixedFilters).toEqual([
         { column: 'client_tenant_id', in: ['provider'] },
         { column: 'tenant_id', notIn: ['provider'] }
      ]);

      // Switching tenant (the scope is read live, nothing is stored) gives other filters.
      api.scope = [{ id: 'tho' }, { id: 'tho-branch' }];
      wrapper.unmount();
      tables.length = 0;
      mountPage(RelationshipsIndex);
      await nextTick();
      expect(tables[0].fixedFilters).toEqual([{ column: 'tenant_id', in: ['tho', 'tho-branch'] }]);
      expect(tables[1].fixedFilters).toEqual([
         { column: 'client_tenant_id', in: ['tho', 'tho-branch'] },
         { column: 'tenant_id', notIn: ['tho', 'tho-branch'] }
      ]);
   });

   it('End says what ending does, then ends the relationship', async () => {
      mountPage(RelationshipsIndex);
      const end = tables[0].rowActions!.find((a) => a.icon === 'pi pi-ban');
      const data = { id: 'r1', client_name: 'Thor GmbH', status: 'active' };
      expect(end.visible({ data })).toBe(true);
      expect(end.visible({ data: { ...data, status: 'ended' } })).toBe(false);
      await end.command({ data })();
      const options = api.confirm.mock.calls[0][0];
      expect(options.message).toBe(en.ops.client.end.message);
      expect(options.message).toMatch(/shared orders/);
      expect(options.header).toBe('End the relationship with Thor GmbH?');
      await options.accept();
      expect(api.end).toHaveBeenCalledWith('r1');
   });
});

describe('invitations page', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   beforeEach(() => (tables.length = 0));

   it('shows a dash for an e-mail the role may not read', () => {
      const wrapper = mountPage(InvitationsIndex, [
         { id: 'i1', email: null, status: 'pending', expires_at: '2999-01-01T00:00:00Z' },
         { id: 'i2', email: 'a@b.test', status: 'pending', expires_at: '2999-01-01T00:00:00Z' }
      ]);
      const cells = wrapper.findAll('.row').map((row) => row.find('span').text());
      expect(cells).toEqual(['—', 'a@b.test']);
   });

   it('offers resend and revoke on pending and expired rows only', () => {
      mountPage(InvitationsIndex);
      const actions = tables[0].rowActions!;
      expect(actions).toHaveLength(2);
      const visible = (status: string, expires_at: string) =>
         actions.map((a) => a.visible({ data: { status, expires_at } }));
      expect(visible('pending', '2999-01-01T00:00:00Z')).toEqual([true, true]);
      expect(visible('pending', '2000-01-01T00:00:00Z')).toEqual([true, true]);
      expect(visible('accepted', '2999-01-01T00:00:00Z')).toEqual([false, false]);
      expect(visible('revoked', '2999-01-01T00:00:00Z')).toEqual([false, false]);
   });
});
