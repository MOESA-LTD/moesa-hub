import { createAccount, registerSchema } from '@/api/auth';
import { completeSignup, fetchSignupPlans, pendingSignup, SignupError } from '@/api/auth/signup';
import { FunctionsHttpError } from '@supabase/supabase-js';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mock = vi.hoisted(() => ({
   invoke: vi.fn(),
   from: vi.fn(),
   select: vi.fn(),
   eq: vi.fn(),
   order: vi.fn(),
   result: vi.fn()
}));

vi.mock('@/lib/supabase', () => ({
   supabase: {
      functions: { invoke: mock.invoke },
      from: (...args: unknown[]) => {
         mock.from(...args);
         const chain = {
            select: (...a: unknown[]) => (mock.select(...a), chain),
            eq: (...a: unknown[]) => (mock.eq(...a), chain),
            order: (...a: unknown[]) => (mock.order(...a), chain),
            throwOnError: () => mock.result()
         };
         return chain;
      }
   },
   publicSchema: { rpc: vi.fn() }
}));

const refusal = (status: number, body: object) => ({
   data: null,
   error: new FunctionsHttpError(new Response(JSON.stringify(body), { status }))
});

const company = { display_name: 'Leafline GmbH', email: 'info@leafline.test', city: '', phone: '' };

beforeEach(() => Object.values(mock).forEach((fn) => fn.mockReset()));

describe('createAccount', () => {
   it('sends the e-mail and the company, never a password', async () => {
      mock.invoke.mockResolvedValue({ data: { status: 'check_email' }, error: null });
      const parsed = registerSchema.parse({
         account: { email: ' Owner@Leafline.test ' },
         company
      });
      await createAccount(parsed);

      const [path, options] = mock.invoke.mock.calls[0]!;
      expect(path).toBe('create-account');
      expect(options.body).toEqual({
         account: { email: 'Owner@Leafline.test' },
         company: { display_name: 'Leafline GmbH', email: 'info@leafline.test' }
      });
      expect(JSON.stringify(options.body)).not.toContain('password');
   });

   it('names the refusal', async () => {
      mock.invoke.mockResolvedValue(refusal(429, { message: 'signup_throttled' }));
      const parsed = registerSchema.parse({ account: { email: 'a@b.test' }, company });
      await expect(createAccount(parsed)).rejects.toEqual(new SignupError('signup_throttled'));
   });
});

describe('completeSignup', () => {
   it('posts the chosen plan only', async () => {
      mock.invoke.mockResolvedValue({
         data: { tenant: { id: 't1', display_name: 'Leafline GmbH' } },
         error: null
      });
      await expect(completeSignup('plan-1')).resolves.toEqual({
         tenant: { id: 't1', display_name: 'Leafline GmbH' }
      });
      expect(mock.invoke).toHaveBeenCalledWith('create-account/complete', {
         method: 'POST',
         body: { plan_id: 'plan-1' }
      });
   });

   it('turns a refusal body into a SignupError', async () => {
      mock.invoke.mockResolvedValue(
         refusal(403, { message: 'signup_closed', code: 'signup_closed' })
      );
      await expect(completeSignup(null)).rejects.toEqual(new SignupError('signup_closed'));
   });
});

describe('fetchSignupPlans', () => {
   it('reads the active plans in the shape of the invitation preview', async () => {
      mock.result.mockResolvedValue({
         data: [
            {
               id: 'p1',
               display_name: 'Pro',
               description: null,
               audience: 'Growing teams',
               price: 20,
               currency: 'EUR',
               billing_period: 'month',
               trial_days: 14,
               position: 2,
               plan_module: [{ module_id: 'shipment' }, { module_id: 'audit_log' }],
               plan_limit: [{ limit_key: 'max_users', value: 10 }]
            }
         ]
      });
      const plans = await fetchSignupPlans();
      expect(mock.from).toHaveBeenCalledWith('plan');
      expect(mock.eq).toHaveBeenCalledWith('is_active', true);
      expect(plans).toEqual([
         {
            id: 'p1',
            display_name: 'Pro',
            description: null,
            audience: 'Growing teams',
            price: 20,
            currency: 'EUR',
            billing_period: 'month',
            trial_days: 14,
            position: 2,
            modules: ['audit_log', 'shipment'],
            limits: { max_users: 10 }
         }
      ]);
   });
});

describe('pendingSignup', () => {
   it('reads the company waiting in app_metadata only', () => {
      const pending = { company: { display_name: 'Leafline GmbH' }, plan_id: 'p1' };
      expect(pendingSignup({ app_metadata: { pending_company: pending } })).toEqual(pending);
      expect(
         pendingSignup({ app_metadata: {}, user_metadata: { pending_company: pending } })
      ).toBeNull();
      expect(pendingSignup({ app_metadata: { pending_company: null } })).toBeNull();
      expect(pendingSignup(null)).toBeNull();
   });
});
