import {
   endRelationship,
   linkedClient,
   procurementModelChoices,
   relationshipSchema,
   relationshipSide,
   toClientOptions,
   toRelationshipFormValues,
   toRelationshipPayload
} from '@/api/relationship';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mock = vi.hoisted(() => ({ rpc: vi.fn(), throwOnError: vi.fn() }));

vi.mock('@/lib/supabase', () => ({
   supabase: {},
   publicSchema: {
      rpc: (...args: unknown[]) => {
         mock.rpc(...args);
         return { throwOnError: () => mock.throwOnError() };
      }
   }
}));

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

describe('relationshipSide', () => {
   it('is provider when the row tenant is in scope', () => {
      expect(relationshipSide(row({}), new Set(['provider']))).toBe('provider');
      // A branch the user reads is theirs too, though it is not the active tenant.
      expect(relationshipSide(row({}), new Set(['other', 'provider']))).toBe('provider');
   });

   it('is client when the row tenant is outside the scope', () => {
      expect(relationshipSide(row({}), new Set(['tho']))).toBe('client');
      expect(relationshipSide(row({}), new Set())).toBe('client');
   });
});

describe('endRelationship', () => {
   beforeEach(() => {
      mock.rpc.mockReset();
      mock.throwOnError.mockReset().mockResolvedValue({});
   });

   it('calls end_provider_relationship with the relationship id', async () => {
      await endRelationship('r1');
      expect(mock.rpc).toHaveBeenCalledWith('end_provider_relationship', {
         relationship_id: 'r1'
      });
   });

   it('passes on a refusal', async () => {
      mock.throwOnError.mockRejectedValue(new Error('relationship_end_forbidden'));
      await expect(endRelationship('r1')).rejects.toThrow('relationship_end_forbidden');
   });
});

describe('the relationship form', () => {
   it('offers provider to client, never client to provider', () => {
      expect(procurementModelChoices('provider')).toEqual(['provider', 'client']);
      expect(procurementModelChoices('client')).toEqual(['client']);
   });

   it('keeps the saved terms in the form and sends only what a provider may change', () => {
      const saved = {
         id: 'r1',
         tenant_id: 'provider',
         client_tenant_id: 'tho',
         client_code: 'THO',
         client_name: 'Thor GmbH',
         procurement_model: 'provider',
         commercial_model: 'trading_partner',
         packages: ['A1'],
         contract_status: 'active',
         start_on: '2026-01-31',
         deposit_rate: 30,
         extra_cost_rule: null,
         eu_responsible_person: null,
         notes: 'n',
         restricted_drive_url: null
      } as never;
      const parsed = relationshipSchema.parse(toRelationshipFormValues(saved));
      const payload = toRelationshipPayload(parsed);
      expect(payload).toMatchObject({
         id: 'r1',
         procurement_model: 'provider',
         commercial_model: 'trading_partner',
         start_on: '2026-01-31',
         deposit_rate: 30,
         extra_cost_rule: null,
         notes: 'n'
      });
      for (const key of ['tenant_id', 'client_tenant_id', 'client_code', 'status', 'accepted_at'])
         expect(payload).not.toHaveProperty(key);
   });
});
