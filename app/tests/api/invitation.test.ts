import {
   createInvitation,
   invitationSchema,
   invitationState,
   resendInvitation,
   revokeInvitation,
   toInvitationBody,
   toStaffOptions,
   toInvitationFormValues
} from '@/api/invitation';
import { mapPostgrestError } from '@/lib/form/postgrestErrors';
import { FunctionsHttpError } from '@supabase/supabase-js';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mock = vi.hoisted(() => ({
   invoke: vi.fn(),
   rpc: vi.fn(),
   throwOnError: vi.fn()
}));

vi.mock('@/lib/supabase', () => ({
   supabase: { functions: { invoke: mock.invoke } },
   publicSchema: {
      rpc: (...args: unknown[]) => {
         mock.rpc(...args);
         return { throwOnError: () => mock.throwOnError() };
      }
   }
}));

const USER = '00000000-0000-4000-8000-000000000001';
const PLAN = '00000000-0000-4000-8000-000000000002';

const form = (overrides: object = {}) => ({
   ...toInvitationFormValues(),
   email: ' Buyer@Example.COM ',
   company_name: 'Leafline GmbH',
   client_code: 'lea',
   ...overrides
});

const parse = (overrides: object = {}) => invitationSchema.safeParse(form(overrides));

const refusal = (status: number, body: object) =>
   new FunctionsHttpError(
      new Response(JSON.stringify(body), {
         status,
         headers: { 'Content-Type': 'application/json' }
      })
   );

beforeEach(() => {
   mock.invoke.mockReset();
   mock.rpc.mockReset();
   mock.throwOnError.mockReset().mockResolvedValue({});
});

describe('invitationState', () => {
   const now = new Date('2026-11-19T12:00:00Z');

   it('reports expired from expires_at', () => {
      expect(invitationState({ status: 'pending', expires_at: '2026-11-18T12:00:00Z' }, now)).toBe(
         'expired'
      );
      expect(invitationState({ status: 'pending', expires_at: '2026-11-20T12:00:00Z' }, now)).toBe(
         'pending'
      );
   });

   it('keeps the settled states whatever the expiry', () => {
      const past = '2026-01-01T00:00:00Z';
      expect(invitationState({ status: 'accepted', expires_at: past }, now)).toBe('accepted');
      expect(invitationState({ status: 'revoked', expires_at: past }, now)).toBe('revoked');
   });
});

describe('the invitation form', () => {
   it('lower-cases the e-mail and upper-cases the client code', () => {
      const result = parse();
      expect(result.success).toBe(true);
      expect(result.data).toMatchObject({ email: 'buyer@example.com', client_code: 'LEA' });
   });

   it('refuses a short company name and a client code that is not three letters', () => {
      expect(parse({ company_name: 'ab' }).success).toBe(false);
      expect(parse({ client_code: 'LE' }).success).toBe(false);
      expect(parse({ client_code: 'LEA1' }).success).toBe(false);
   });

   it('limits staff entries to the three roles', () => {
      for (const role_name of ['management', 'coordinator', 'viewer'])
         expect(parse({ staff: [{ user_id: USER, role_name }] }).success).toBe(true);
      expect(parse({ staff: [{ user_id: USER, role_name: 'owner' }] }).success).toBe(false);
      expect(parse({ staff: [{ user_id: 'nobody', role_name: 'viewer' }] }).success).toBe(false);
   });

   it('takes at most 20 staff entries', () => {
      const entry = (i: number) => ({
         user_id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
         role_name: 'viewer'
      });
      expect(parse({ staff: Array.from({ length: 20 }, (_, i) => entry(i)) }).success).toBe(true);
      expect(parse({ staff: Array.from({ length: 21 }, (_, i) => entry(i)) }).success).toBe(false);
   });
});

describe('the create payload', () => {
   const body = () =>
      toInvitationBody(parse({ staff: [{ user_id: USER, role_name: 'viewer' }] }).data!);

   it('splits into the invitation and its staff, the shape the function expects', () => {
      expect(Object.keys(body()).sort()).toEqual(['invitation', 'staff']);
      expect(body().staff).toEqual([{ user_id: USER, role_name: 'viewer' }]);
   });

   it('never carries a token, a tenant or an id', () => {
      const invitation = body().invitation as Record<string, unknown>;
      for (const key of ['token', 'token_hash', 'tenant_id', 'id', 'staff', 'status'])
         expect(invitation).not.toHaveProperty(key);
   });

   it('names only keys the database allows, and leaves empty terms out', () => {
      const allowed = [
         'email',
         'company_name',
         'client_code',
         'procurement_model',
         'commercial_model',
         'packages',
         'contract_status',
         'start_on',
         'deposit_rate',
         'extra_cost_rule',
         'eu_responsible_person',
         'recommended_plan_id'
      ];
      const keys = Object.keys(body().invitation);
      expect(keys.filter((key) => !allowed.includes(key))).toEqual([]);
      expect(keys).toEqual(
         expect.arrayContaining(['email', 'company_name', 'client_code', 'procurement_model'])
      );
      expect(body().invitation).not.toHaveProperty('recommended_plan_id');
   });

   it('sends the recommended plan when one is chosen', () => {
      const data = parse({ recommended_plan_id: PLAN }).data!;
      expect(toInvitationBody(data).invitation).toMatchObject({ recommended_plan_id: PLAN });
   });
});

describe('the invitation calls', () => {
   it('creates through the provider-invitation function and returns the id', async () => {
      mock.invoke.mockResolvedValue({ data: { id: 'i1' }, error: null });
      const values = parse().data!;
      expect(await createInvitation(values)).toEqual({ id: 'i1' });
      expect(mock.invoke).toHaveBeenCalledWith('provider-invitation', {
         method: 'POST',
         body: toInvitationBody(values)
      });
   });

   it('resends through the id route with an empty JSON body', async () => {
      mock.invoke.mockResolvedValue({ data: { id: 'i1' }, error: null });
      await resendInvitation('i1');
      expect(mock.invoke).toHaveBeenCalledWith('provider-invitation/i1/resend', {
         method: 'POST',
         body: {}
      });
   });

   it('revokes through the revoke_provider_invitation function', async () => {
      await revokeInvitation('i1');
      expect(mock.rpc).toHaveBeenCalledWith('revoke_provider_invitation', {
         invitation_id: 'i1'
      });
   });

   it('shows a function refusal as its named code, on its field when it has one', async () => {
      mock.invoke.mockResolvedValue({
         data: null,
         error: refusal(409, { message: 'client_code_taken', code: '23505' })
      });
      const error = await createInvitation(parse().data!).catch((e) => e);
      expect(error.message).toBe('client_code_taken');
      expect(mapPostgrestError(error, ['client_code', 'email'])).toEqual({
         client_code: expect.any(String)
      });
   });

   it('maps the pending-invitation refusal to the e-mail field', async () => {
      mock.invoke.mockResolvedValue({
         data: null,
         error: refusal(409, { message: 'invitation_pending_exists', code: '23505' })
      });
      const error = await createInvitation(parse().data!).catch((e) => e);
      expect(mapPostgrestError(error, ['client_code', 'email'])).toEqual({
         email: expect.any(String)
      });
   });

   it('leaves a toast-level refusal to the error handler', async () => {
      mock.invoke.mockResolvedValue({
         data: null,
         error: refusal(502, { message: 'invitation_mail_failed' })
      });
      const error = await createInvitation(parse().data!).catch((e) => e);
      expect(error.message).toBe('invitation_mail_failed');
      expect(error.code).toBeTruthy();
      expect(mapPostgrestError(error, ['client_code', 'email'])).toBeNull();
   });
});

describe('toStaffOptions', () => {
   const member = (id: string, tenant_id: string | null, name?: string) => ({
      id,
      tenant_id,
      email: `${id}@x.test`,
      user_metadata: name ? { display_name: name } : null
   });

   it('lists only members of the active tenant, once each, by name or e-mail', () => {
      const options = toStaffOptions(
         [
            member('b', 't1'),
            member('a', 't1', 'Ann'),
            member('a', 't1', 'Ann'),
            member('o', null),
            member('x', 't2')
         ],
         't1'
      );
      expect(options).toEqual([
         { value: 'a', label: 'Ann' },
         { value: 'b', label: 'b@x.test' }
      ]);
   });
});
