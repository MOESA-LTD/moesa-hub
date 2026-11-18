import '../setup/mockMain';
import { useUpsertForm } from '@/composables/useUpsertForm';
import { ability } from '@/plugins/casl';
import { mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import ConfirmationService from 'primevue/confirmationservice';
import ToastService from 'primevue/toastservice';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, ref } from 'vue';
import * as z from 'zod';

// A provider's row shared with a tenant in scope opens read-only, whatever the user's rights, and
// its lookups read the client tenant (the provider's is not in scope).
const state = vi.hoisted(() => ({ scope: ['tho'] as string[] }));

vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ query: {} }),
   useRouter: () => ({ push: vi.fn() }),
   onBeforeRouteLeave: () => {}
}));
vi.mock('@/store/auth', () => ({
   useAuthStore: () => ({
      currentTenant: { id: state.scope[0] },
      scopeTenants: state.scope.map((id) => ({ id })),
      canIn: () => true
   })
}));

type Row = { id: string; tenant_id: string; client_tenant_id: string | null; name: string };

const useFormOf = (row: Row) => {
   let form!: {
      shared: { value: boolean };
      readonly: { value: boolean };
      tenantId: { value: string | null };
   };
   mount(
      defineComponent({
         setup() {
            form = useUpsertForm({
               id: row.id,
               useRow: () => ({ data: ref(row), suspense: () => Promise.resolve() }) as never,
               useSaveRow: () => ({ mutateAsync: vi.fn() }) as never,
               subject: 'purchase_order',
               schema: z.object({ name: z.string() }),
               toFormValues: (value) => ({ name: (value as Partial<Row> | null)?.name ?? '' }),
               toPayload: (data) => data as Row
            });
            return () => h('div');
         }
      }),
      { global: { plugins: [PrimeVue, ConfirmationService, ToastService] } }
   );
   return form;
};

describe('useUpsertForm on a shared row', () => {
   beforeEach(() => {
      state.scope = ['tho'];
      ability.update([{ action: 'manage', subject: 'all' }]);
   });

   it('is read-only and reads through the client tenant', () => {
      const form = useFormOf({ id: 'o1', tenant_id: 'moe', client_tenant_id: 'tho', name: 'x' });
      expect(form.shared.value).toBe(true);
      expect(form.readonly.value).toBe(true);
      expect(form.tenantId.value).toBe('tho');
   });

   it('stays editable for provider staff with both tenants in scope', () => {
      state.scope = ['moe', 'tho'];
      const form = useFormOf({ id: 'o1', tenant_id: 'moe', client_tenant_id: 'tho', name: 'x' });
      expect(form.shared.value).toBe(false);
      expect(form.readonly.value).toBe(false);
      expect(form.tenantId.value).toBe('moe');
   });
});
