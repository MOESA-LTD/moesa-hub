import '../setup/mockMain';
import en from '@/plugins/i18n/locales/en/index.json';
import Complete from '@/views/pages/auth/register/Complete.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { FunctionsHttpError } from '@supabase/supabase-js';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { reactive } from 'vue';

const api = vi.hoisted(() => ({
   invoke: vi.fn(),
   updateUser: vi.fn(),
   plans: vi.fn(),
   replace: vi.fn(),
   push: vi.fn(),
   toast: vi.fn(),
   errorHandler: vi.fn(),
   refreshAccess: vi.fn(),
   changeCurrentTenant: vi.fn(),
   logout: vi.fn()
}));
const routeState = vi.hoisted(() => ({ hash: '' }));

const PENDING = {
   company: { display_name: 'Leafline GmbH', email: 'owner@leafline.test', city: 'Bursa' },
   plan_id: 'pro'
};

const auth = reactive({
   isSignedIn: true,
   user: {
      email: 'owner@leafline.test',
      app_metadata: { provider: 'email' } as Record<string, unknown>,
      user_metadata: {} as Record<string, unknown>
   },
   branches: [{ id: 'tenant-1', display_name: 'Leafline GmbH' }],
   refreshAccess: api.refreshAccess,
   changeCurrentTenant: api.changeCurrentTenant,
   logout: api.logout
});

vi.mock('@/lib/supabase', () => ({
   supabase: { functions: { invoke: api.invoke }, auth: { updateUser: api.updateUser } },
   publicSchema: { rpc: vi.fn() }
}));
vi.mock('@/api/auth/signup', async (importOriginal) => ({
   ...(await importOriginal<typeof import('@/api/auth/signup')>()),
   fetchSignupPlans: api.plans
}));
vi.mock('@/lib/appErrorHandler', () => ({ appErrorHandler: api.errorHandler }));
vi.mock('@/store/auth', () => ({ useAuthStore: () => auth }));
vi.mock('@/api/subscription', async (importOriginal) => ({
   ...(await importOriginal<typeof import('@/api/subscription')>()),
   useModules: () => ({ data: { value: [{ id: 'product', is_core: true }] } })
}));
vi.mock('primevue', async (importOriginal) => ({
   ...(await importOriginal<typeof import('primevue')>()),
   useToast: () => ({ add: api.toast })
}));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ params: {}, fullPath: '/register/complete', hash: routeState.hash }),
   useRouter: () => ({ replace: api.replace, push: api.push, go: vi.fn() })
}));

const plan = (id: string, display_name: string, over: object = {}) => ({
   id,
   display_name,
   description: null,
   audience: null,
   price: 10,
   currency: 'EUR',
   billing_period: 'month',
   trial_days: 0,
   position: 1,
   modules: ['product'],
   limits: {},
   ...over
});

const refusal = (status: number, body: Record<string, unknown>) => ({
   data: null,
   error: new FunctionsHttpError(new Response(JSON.stringify(body), { status }))
});

/** GET answers the pending sign-up; POST (complete) answers `completion`. */
let completion: unknown;
const routeInvoke = (pending: unknown = { data: PENDING, error: null }) =>
   api.invoke.mockImplementation((_path: string, options: { method: string }) =>
      Promise.resolve(options.method === 'GET' ? pending : completion)
   );
const completeCalls = () =>
   api.invoke.mock.calls.filter(([, options]) => options.method === 'POST');

const mounted: { unmount: () => void }[] = [];
const mountPage = async () => {
   const wrapper = mount(Complete, {
      global: {
         plugins: [i18NPlugin, PrimeVue],
         stubs: { FormBox: false, PhoneInput: true, SelectCountry: true },
         directives: { focustrap: {}, tooltip: {} }
      }
   });
   mounted.push(wrapper);
   await flushPromises();
   return wrapper;
};

const setPassword = async (wrapper: Awaited<ReturnType<typeof mountPage>>) => {
   const [password, confirmation] = wrapper.findAll('[data-step="account"] input');
   await password!.setValue('Secret123!');
   await confirmation!.setValue('Secret123!');
   await wrapper.get('[data-step="account"] form').trigger('submit');
   await flushPromises();
};

/** From the company step to the plan step. */
const toPlan = async (wrapper: Awaited<ReturnType<typeof mountPage>>) => {
   await wrapper.findAll('[data-step="company"] button').at(-1)!.trigger('click');
   await flushPromises();
};

const completeNow = async (wrapper: Awaited<ReturnType<typeof mountPage>>) => {
   await toPlan(wrapper);
   await wrapper.get('[data-complete]').trigger('click');
   await flushPromises();
};

describe('sign-up completion page', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   afterEach(() => mounted.splice(0).forEach((wrapper) => wrapper.unmount()));
   beforeEach(() => {
      Object.values(api).forEach((fn) => fn.mockReset());
      auth.isSignedIn = true;
      auth.user.user_metadata = {};
      routeState.hash = '';
      completion = {
         data: { tenant: { id: 'tenant-1', display_name: 'Leafline GmbH' } },
         error: null
      };
      routeInvoke();
      api.plans.mockResolvedValue([plan('basic', 'Basic'), plan('pro', 'Pro', { position: 2 })]);
      api.updateUser.mockResolvedValue({ error: null });
      api.refreshAccess.mockResolvedValue(undefined);
      api.changeCurrentTenant.mockResolvedValue(undefined);
      api.errorHandler.mockResolvedValue(undefined);
      api.logout.mockResolvedValue(undefined);
   });

   it('explains that the e-mail link must be opened when there is no session', async () => {
      auth.isSignedIn = false;
      const wrapper = await mountPage();
      expect(wrapper.find('[data-no-session]').exists()).toBe(true);
      expect(api.invoke).not.toHaveBeenCalled();
   });

   it('L4: names an expired or used link and offers a new sign-up', async () => {
      auth.isSignedIn = false;
      routeState.hash = '#error=access_denied&error_code=otp_expired&error_description=x';
      const wrapper = await mountPage();
      expect(wrapper.get('[data-link-expired]').text()).toContain(
         'This link has expired — sign up again to get a new one.'
      );
      await wrapper.get('[data-link-expired] button').trigger('click');
      expect(api.push).toHaveBeenCalledWith({ name: 'auth-register' });
   });

   it('says so when nothing waits for the account', async () => {
      routeInvoke(refusal(409, { message: 'signup_not_pending' }));
      const wrapper = await mountPage();
      expect(wrapper.get('[data-nothing-pending]').text()).toContain('no sign-up waiting');
   });

   it('reads the pending sign-up from the server, not from the token', async () => {
      auth.user.app_metadata = {
         provider: 'email',
         pending_company: { company: { display_name: 'Token Co' } }
      };
      await mountPage();
      expect(api.invoke).toHaveBeenCalledWith('create-account/complete', { method: 'GET' });
   });

   it('M3: shows the signed-in address on every step, with a way out', async () => {
      const wrapper = await mountPage();
      const shown = () => wrapper.get('[data-signed-in-as]').text();
      expect(wrapper.find('[data-step="account"]').exists()).toBe(true);
      expect(shown()).toContain('owner@leafline.test');
      await setPassword(wrapper);
      expect(wrapper.find('[data-step="company"]').exists()).toBe(true);
      expect(shown()).toContain('owner@leafline.test');
      await toPlan(wrapper);
      expect(wrapper.find('[data-step="plan"]').exists()).toBe(true);
      expect(shown()).toContain('owner@leafline.test');

      await wrapper.get('[data-signed-in-as] [data-sign-out]').trigger('click');
      expect(api.logout).toHaveBeenCalled();
   });

   it('sets the password with the password_set mark, then shows the company prefilled', async () => {
      const wrapper = await mountPage();
      await setPassword(wrapper);
      expect(api.updateUser).toHaveBeenCalledWith({
         password: 'Secret123!',
         data: { password_set: true }
      });
      const inputs = wrapper.findAll('[data-step="company"] input');
      expect((inputs[0]!.element as HTMLInputElement).value).toBe('Leafline GmbH');
   });

   it('I1: completes with the company as edited and the chosen plan', async () => {
      auth.user.user_metadata = { password_set: true };
      const wrapper = await mountPage();
      await wrapper.findAll('[data-step="company"] input')[0]!.setValue('Leafline Trading GmbH');
      await toPlan(wrapper);
      expect(wrapper.get('[data-plan="pro"] button').attributes('aria-pressed')).toBe('true');
      await wrapper.get('[data-plan="basic"] button').trigger('click');
      await wrapper.get('[data-complete]').trigger('click');
      await flushPromises();

      expect(completeCalls()).toHaveLength(1);
      expect(completeCalls()[0]![1]).toEqual({
         method: 'POST',
         body: {
            company: {
               display_name: 'Leafline Trading GmbH',
               email: 'owner@leafline.test',
               city: 'Bursa'
            },
            plan_id: 'basic'
         }
      });
      expect(api.changeCurrentTenant).toHaveBeenCalledWith(auth.branches[0]);
      expect(api.replace).toHaveBeenCalledWith({ name: 'dashboard' });
   });

   it('I1: a taken company e-mail keeps the owner on the form, who changes it and retries', async () => {
      auth.user.user_metadata = { password_set: true };
      completion = refusal(409, { message: 'company_email_exists' });
      const wrapper = await mountPage();
      await completeNow(wrapper);

      expect(wrapper.find('[data-step="company"]').exists()).toBe(true);
      // The refusal is on the e-mail field (FormField shows it as an error badge).
      const emailInput = wrapper.get('[data-step="company"] input[type="email"]');
      expect(emailInput.attributes('aria-invalid')).toBe('true');
      expect(wrapper.find('[data-fatal]').exists()).toBe(false);
      expect(api.replace).not.toHaveBeenCalled();

      completion = {
         data: { tenant: { id: 'tenant-1', display_name: 'Leafline GmbH' } },
         error: null
      };
      const email = wrapper
         .findAll('[data-step="company"] input')
         .find((input) => (input.element as HTMLInputElement).value === 'owner@leafline.test')!;
      await email.setValue('sales@leafline.test');
      await completeNow(wrapper);

      expect(completeCalls()).toHaveLength(2);
      expect(completeCalls()[1]![1].body.company.email).toBe('sales@leafline.test');
      expect(api.replace).toHaveBeenCalledWith({ name: 'dashboard' });
   });

   it('stops with the reason when signup was closed meanwhile', async () => {
      auth.user.user_metadata = { password_set: true };
      completion = refusal(403, { message: 'signup_closed', code: 'signup_closed' });
      const wrapper = await mountPage();
      await completeNow(wrapper);

      expect(wrapper.get('[data-fatal]').text()).toContain('Sign-up is closed');
      expect(wrapper.find('[data-signed-in-as]').exists()).toBe(true);
      expect(api.replace).not.toHaveBeenCalled();
      expect(api.errorHandler).not.toHaveBeenCalled();
   });

   it('reloads the plans when the chosen one was withdrawn', async () => {
      auth.user.user_metadata = { password_set: true };
      completion = refusal(400, { message: 'plan_inactive', code: 'P0001' });
      const wrapper = await mountPage();
      api.plans.mockResolvedValue([plan('basic', 'Basic')]);
      await completeNow(wrapper);

      expect(wrapper.get('[data-notice]').text()).toContain('no longer offered');
      expect(wrapper.findAll('[data-plan]')).toHaveLength(1);
      expect(wrapper.get('[data-complete]').attributes('disabled')).toBeDefined();
   });
});
