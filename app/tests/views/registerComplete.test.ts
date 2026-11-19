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
   changeCurrentTenant: vi.fn()
}));

const PENDING = {
   company: { display_name: 'Leafline GmbH', email: 'owner@leafline.test' },
   plan_id: 'pro'
};

const auth = reactive({
   isSignedIn: true,
   user: {
      email: 'owner@leafline.test',
      app_metadata: { provider: 'email', pending_company: PENDING } as Record<string, unknown>,
      user_metadata: {} as Record<string, unknown>
   },
   branches: [{ id: 'tenant-1', display_name: 'Leafline GmbH' }],
   refreshAccess: api.refreshAccess,
   changeCurrentTenant: api.changeCurrentTenant
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
   useRoute: () => ({ params: {}, fullPath: '/register/complete' }),
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

const mounted: { unmount: () => void }[] = [];
const mountPage = async () => {
   const wrapper = mount(Complete, {
      global: {
         plugins: [i18NPlugin, PrimeVue],
         stubs: { FormBox: false },
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

describe('sign-up completion page', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   afterEach(() => mounted.splice(0).forEach((wrapper) => wrapper.unmount()));
   beforeEach(() => {
      Object.values(api).forEach((fn) => fn.mockReset());
      auth.isSignedIn = true;
      auth.user.app_metadata = { provider: 'email', pending_company: PENDING };
      auth.user.user_metadata = {};
      api.plans.mockResolvedValue([plan('basic', 'Basic'), plan('pro', 'Pro', { position: 2 })]);
      api.updateUser.mockResolvedValue({ error: null });
      api.invoke.mockResolvedValue({
         data: { tenant: { id: 'tenant-1', display_name: 'Leafline GmbH' } },
         error: null
      });
      api.refreshAccess.mockResolvedValue(undefined);
      api.changeCurrentTenant.mockResolvedValue(undefined);
      api.errorHandler.mockResolvedValue(undefined);
   });

   it('explains that the e-mail link must be opened when there is no session', async () => {
      auth.isSignedIn = false;
      const wrapper = await mountPage();
      expect(wrapper.find('[data-no-session]').exists()).toBe(true);
      expect(api.plans).not.toHaveBeenCalled();
   });

   it('says so when nothing waits for the account', async () => {
      auth.user.app_metadata = { provider: 'email' };
      const wrapper = await mountPage();
      expect(wrapper.get('[data-nothing-pending]').text()).toContain('no sign-up waiting');
   });

   it('ignores a pending company in user_metadata (the user could write it)', async () => {
      auth.user.app_metadata = { provider: 'email' };
      auth.user.user_metadata = { pending_company: PENDING };
      const wrapper = await mountPage();
      expect(wrapper.find('[data-nothing-pending]').exists()).toBe(true);
   });

   it('names the company and starts with the password, set with the password_set mark', async () => {
      const wrapper = await mountPage();
      expect(wrapper.text()).toContain('Leafline GmbH');
      await setPassword(wrapper);

      expect(api.updateUser).toHaveBeenCalledWith({
         password: 'Secret123!',
         data: { password_set: true }
      });
      expect(wrapper.find('[data-step="plan"]').exists()).toBe(true);
   });

   it('skips the password when one was set already', async () => {
      auth.user.user_metadata = { password_set: true };
      const wrapper = await mountPage();
      expect(wrapper.find('[data-step="plan"]').exists()).toBe(true);
   });

   it('compares the plans, starting from the one asked for at sign-up, and completes with the chosen one', async () => {
      auth.user.user_metadata = { password_set: true };
      const wrapper = await mountPage();
      expect(wrapper.findAll('[data-plan]')).toHaveLength(2);
      expect(wrapper.get('[data-plan="pro"] button').attributes('aria-pressed')).toBe('true');

      await wrapper.get('[data-plan="basic"] button').trigger('click');
      await wrapper.get('[data-complete]').trigger('click');
      await flushPromises();

      expect(api.invoke).toHaveBeenCalledWith('create-account/complete', {
         method: 'POST',
         body: { plan_id: 'basic' }
      });
      expect(api.refreshAccess).toHaveBeenCalled();
      expect(api.changeCurrentTenant).toHaveBeenCalledWith(auth.branches[0]);
      expect(api.replace).toHaveBeenCalledWith({ name: 'dashboard' });
   });

   it('stops with the reason when signup was closed meanwhile', async () => {
      auth.user.user_metadata = { password_set: true };
      api.invoke.mockResolvedValue(
         refusal(403, { message: 'signup_closed', code: 'signup_closed' })
      );
      const wrapper = await mountPage();
      await wrapper.get('[data-complete]').trigger('click');
      await flushPromises();

      expect(wrapper.get('[data-fatal]').text()).toContain('Sign-up is closed');
      expect(api.replace).not.toHaveBeenCalled();
      expect(api.errorHandler).not.toHaveBeenCalled();
   });

   it('reloads the plans when the chosen one was withdrawn', async () => {
      auth.user.user_metadata = { password_set: true };
      api.invoke.mockResolvedValue(refusal(400, { message: 'plan_inactive', code: 'P0001' }));
      const wrapper = await mountPage();
      api.plans.mockResolvedValue([plan('basic', 'Basic')]);
      await wrapper.get('[data-complete]').trigger('click');
      await flushPromises();

      expect(wrapper.get('[data-notice]').text()).toContain('no longer offered');
      expect(wrapper.findAll('[data-plan]')).toHaveLength(1);
      expect(wrapper.get('[data-complete]').attributes('disabled')).toBeDefined();
   });
});
