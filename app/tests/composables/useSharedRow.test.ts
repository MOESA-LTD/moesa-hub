import { clientVisibleColumns, useSharedRow } from '@/composables/useSharedRow';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

// A provider's row shared with a client tenant (its client_tenant_id) is read-only there, under a
// "From <provider>" tag; a row of a tenant in scope is the user's own, whatever its client.
const state = vi.hoisted(() => ({ scope: [] as string[] }));

vi.mock('@/store/auth', () => ({
   useAuthStore: () => ({ scopeTenants: state.scope.map((id) => ({ id })) })
}));
vi.mock('@/api/relationship', () => ({
   useProviderNames: () => ({
      data: ref([{ tenant_id: 'moe', client_tenant_id: 'tho', provider_name: 'MOESA LTD' }])
   })
}));

describe('useSharedRow', () => {
   beforeEach(() => (state.scope = ['tho']));

   it('a provider row whose client is my tenant is shared', () => {
      const { isShared, providerName } = useSharedRow();
      const row = { tenant_id: 'moe', client_tenant_id: 'tho' };
      expect(isShared(row)).toBe(true);
      expect(providerName(row)).toBe('MOESA LTD');
   });

   it('my own row is not shared', () => {
      const { isShared, providerName } = useSharedRow();
      expect(isShared({ tenant_id: 'tho', client_tenant_id: null })).toBe(false);
      expect(isShared({ tenant_id: 'tho' })).toBe(false);
      expect(providerName({ tenant_id: 'tho' })).toBeNull();
   });

   it('a row of a tenant I belong to is not shared even with a client_tenant_id', () => {
      state.scope = ['tho', 'moe'];
      const { isShared } = useSharedRow();
      expect(isShared({ tenant_id: 'moe', client_tenant_id: 'tho' })).toBe(false);
   });

   it('a row shared with a tenant outside my scope is not mine to read as a client', () => {
      expect(useSharedRow().isShared({ tenant_id: 'moe', client_tenant_id: 'other' })).toBe(false);
   });
});

describe('clientVisibleColumns', () => {
   it('keeps the client-visible fields and the named derived columns', () => {
      const columns = [
         { field: 'code' },
         { field: 'pi_total' },
         { field: 'client_status' },
         { field: 'line_count' },
         { header: 'no field' }
      ];
      expect(clientVisibleColumns('purchase_order', columns, ['line_count'])).toEqual([
         { field: 'code' },
         { field: 'client_status' },
         { field: 'line_count' },
         { header: 'no field' }
      ]);
   });
});
