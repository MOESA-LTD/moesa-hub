import { linkedClient, toClientOptions } from '@/api/relationship';
import { describe, expect, it } from 'vitest';

const row = (overrides: object) => ({
   tenant_id: 'provider',
   client_tenant_id: 'tho',
   client_code: 'THO',
   client_name: 'Thor GmbH',
   procurement_model: 'provider' as const,
   status: 'active' as const,
   ...overrides
});

describe('toClientOptions', () => {
   it("lists the active tenant's active provider-procures relationships", () => {
      const rows = [
         row({}),
         row({ client_tenant_id: 'self', client_code: 'SLF', procurement_model: 'client' }),
         row({ client_tenant_id: 'old', client_code: 'OLD', status: 'ended' }),
         row({ tenant_id: 'other', client_tenant_id: 'x', client_code: 'XXX' })
      ];
      expect(toClientOptions(rows, 'provider')).toEqual([
         {
            value: 'tho',
            label: 'THO · Thor GmbH',
            procurement_model: 'provider',
            status: 'active'
         }
      ]);
   });

   it('keeps the client a saved record names, even once its relationship ended', () => {
      const rows = [row({ client_tenant_id: 'old', client_code: 'OLD', status: 'ended' })];
      expect(toClientOptions(rows, 'provider', 'old').map(({ value }) => value)).toEqual(['old']);
   });

   it('sorts by client code', () => {
      const rows = [
         row({ client_tenant_id: 'b', client_code: 'BBB' }),
         row({ client_code: 'AAA' })
      ];
      expect(toClientOptions(rows, 'provider').map(({ label }) => label.slice(0, 3))).toEqual([
         'AAA',
         'BBB'
      ]);
   });
});

describe('linkedClient', () => {
   const rows = [row({}), row({ client_tenant_id: 'self', procurement_model: 'client' })];

   it("names the project's tenant when it is an active provider-procures client", () => {
      expect(linkedClient('tho', 'provider', rows)).toEqual({
         status: 'client',
         clientTenantId: 'tho'
      });
   });

   it("names no client for the tenant's own project", () => {
      expect(linkedClient('provider', 'provider', rows)).toEqual({ status: 'own' });
   });

   it('refuses a project of a tenant with no such relationship, or not found', () => {
      expect(linkedClient('self', 'provider', rows)).toEqual({ status: 'forbidden' });
      expect(linkedClient(null, 'provider', rows)).toEqual({ status: 'forbidden' });
   });

   it('waits for the project and the relationships', () => {
      expect(linkedClient(undefined, 'provider', rows)).toEqual({ status: 'pending' });
      expect(linkedClient('tho', 'provider', undefined)).toEqual({ status: 'pending' });
      expect(linkedClient('provider', 'provider', undefined)).toEqual({ status: 'own' });
   });
});
