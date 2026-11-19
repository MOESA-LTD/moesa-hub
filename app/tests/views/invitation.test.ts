import '../setup/mockMain';
import en from '@/plugins/i18n/locales/en/index.json';
import Index from '@/views/pages/auth/invitation/Index.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { reactive } from 'vue';

const api = vi.hoisted(() => ({
   rpc: vi.fn(),
   invoke: vi.fn(),
   updateUser: vi.fn(),
   replace: vi.fn(),
   toast: vi.fn(),
   errorHandler: vi.fn(),
   logout: vi.fn(),
   refreshAccess: vi.fn(),
   changeCurrentTenant: vi.fn()
}));

const auth = reactive({
   isSignedIn: true,
   user: { email: 'invitee@client.test' },
   branches: [{ id: 'tenant-1', display_name: 'Client Ltd' }],
   refreshAccess: api.refreshAccess,
   changeCurrentTenant: api.changeCurrentTenant,
   logout: api.logout
});

vi.mock('@/lib/supabase', () => ({
   supabase: { functions: { invoke: api.invoke }, auth: { updateUser: api.updateUser } },
   publicSchema: { rpc: api.rpc }
}));
vi.mock('@/lib/appErrorHandler', () => ({ appErrorHandler: api.errorHandler }));
vi.mock('@/store/auth', () => ({ useAuthStore: () => auth }));
vi.mock('@/api/subscription', async (importOriginal) => ({
   ...(await importOriginal<typeof import('@/api/subscription')>()),
   useModules: () => ({
      data: { value: [{ id: 'product', is_core: true }] }
   })
}));
vi.mock('primevue', async (importOriginal) => ({
   ...(await importOriginal<typeof import('primevue')>()),
   useToast: () => ({ add: api.toast })
}));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ params: { token: 'secret-token' } }),
   useRouter: () => ({ replace: api.replace })
}));

const TOKEN = 'secret-token';

const preview = (over: Record<string, unknown> = {}) => ({
   company_name: 'Client Ltd',
   email: 'invitee@client.test',
   provider_name: 'MOESA LTD',
   procurement_model: 'provider',
   recommended_plan_id: 'pro',
   expires_at: null,
   seats: 1,
   needs_password: false,
   plans: [
      {
         id: 'basic',
         display_name: 'Basic',
         description: null,
         audience: 'Small teams',
         price: 0,
         currency: 'EUR',
         billing_period: 'month',
         trial_days: 0,
         position: 1,
         modules: ['product'],
         limits: { max_users: 5 }
      },
      {
         id: 'pro',
         display_name: 'Pro',
         description: null,
         audience: null,
         price: 20,
         currency: 'EUR',
         billing_period: 'month',
         trial_days: 14,
         position: 2,
         modules: ['product', 'audit_log'],
         limits: {}
      }
   ],
   ...over
});

const stubs = { PhoneInput: true, SelectCountry: true, FormBox: false };

const mountPage = async () => {
   const wrapper = mount(Index, {
      global: { plugins: [i18NPlugin, PrimeVue], stubs, directives: { focustrap: {}, tooltip: {} } }
   });
   await flushPromises();
   return wrapper;
};

const toPlanStep = async (wrapper: Awaited<ReturnType<typeof mountPage>>) => {
   // A password is already set: the page starts on the company step.
   await wrapper.findAll('[data-step="company"] button').at(-1)!.trigger('click');
   await flushPromises();
};

/** Through the company step to the plan step, then accepts. */
const accept = async (wrapper: Awaited<ReturnType<typeof mountPage>>) => {
   await toPlanStep(wrapper);
   await wrapper.get('[data-accept]').trigger('click');
   await flushPromises();
};

describe('invitation page', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   beforeEach(() => {
      Object.values(api).forEach((fn) => fn.mockReset());
      auth.isSignedIn = true;
      api.rpc.mockResolvedValue({ data: preview(), error: null });
      api.invoke.mockResolvedValue({ data: { tenant_id: 'tenant-1' }, error: null });
      api.updateUser.mockResolvedValue({ error: null });
      api.refreshAccess.mockResolvedValue(undefined);
      api.changeCurrentTenant.mockResolvedValue(undefined);
      api.errorHandler.mockResolvedValue(undefined);
   });

   it('accept sends only company and plan, never model or staff', async () => {
      const wrapper = await mountPage();
      expect(api.rpc).toHaveBeenCalledWith('invitation_preview', { token: TOKEN });
      await accept(wrapper);

      expect(api.invoke).toHaveBeenCalledTimes(1);
      const [path, options] = api.invoke.mock.calls[0]!;
      expect(path).toBe('provider-invitation/accept');
      expect(Object.keys(options.body)).toEqual(['token', 'company', 'plan_id']);
      expect(options.body.token).toBe(TOKEN);
      expect(options.body.plan_id).toBe('pro');
      // The company carries only the allowlisted keys; the e-mail defaults to the invitation's.
      expect(Object.keys(options.body.company)).toEqual(['display_name', 'email']);
      expect(options.body.company.email).toBe('invitee@client.test');
   });

   it('switches to the new tenant after reloading the tenants, then opens the dashboard', async () => {
      const wrapper = await mountPage();
      await accept(wrapper);

      expect(api.refreshAccess).toHaveBeenCalled();
      expect(api.changeCurrentTenant).toHaveBeenCalledWith(auth.branches[0]);
      expect(api.replace).toHaveBeenCalledWith({ name: 'dashboard' });
   });

   it('starts from the provider-recommended plan', async () => {
      const wrapper = await mountPage();
      await toPlanStep(wrapper);
      expect(wrapper.get('[data-plan="pro"] button').attributes('aria-pressed')).toBe('true');
   });

   it('explains that the e-mail link must be opened when there is no session', async () => {
      auth.isSignedIn = false;
      const wrapper = await mountPage();
      expect(wrapper.find('[data-no-session]').exists()).toBe(true);
      expect(api.rpc).not.toHaveBeenCalled();
   });

   it('sets the password with the mark the preview depends on', async () => {
      api.rpc.mockResolvedValue({ data: preview({ needs_password: true }), error: null });
      const wrapper = await mountPage();
      const [password, confirmation] = wrapper.findAll('input');
      await password!.setValue('Secret123!');
      await confirmation!.setValue('Secret123!');
      await wrapper.get('form').trigger('submit');
      await flushPromises();

      expect(api.updateUser).toHaveBeenCalledWith({
         password: 'Secret123!',
         data: { password_set: true }
      });
      expect(wrapper.find('[data-step="company"]').exists()).toBe(true);
   });

   it('handles a refusal returned as a 200 body', async () => {
      api.rpc.mockResolvedValue({ data: { error: 'invitation_invalid' }, error: null });
      const wrapper = await mountPage();
      expect(wrapper.get('[data-fatal]').text()).toContain('no longer valid');
   });

   it('names the signed-in address on a mismatch and offers to sign out', async () => {
      api.rpc.mockResolvedValue({ data: { error: 'invitation_email_mismatch' }, error: null });
      const wrapper = await mountPage();
      expect(wrapper.get('[data-fatal]').text()).toContain('invitee@client.test');
      await wrapper.get('[data-sign-out]').trigger('click');
      expect(api.logout).toHaveBeenCalled();
   });

   it('shows a refusal of the accept call and stays on the plan step', async () => {
      const { InvitationError } = await import('@/api/invitation/accept');
      api.invoke.mockRejectedValue(new InvitationError('plan_limit_users'));
      const wrapper = await mountPage();
      await accept(wrapper);

      expect(wrapper.get('[data-notice]').text()).toContain('fewer users');
      expect(api.replace).not.toHaveBeenCalled();
   });

   it('puts a taken company e-mail on the e-mail field', async () => {
      const { InvitationError } = await import('@/api/invitation/accept');
      api.invoke.mockRejectedValue(new InvitationError('company_email_exists'));
      const wrapper = await mountPage();
      await accept(wrapper);

      expect(wrapper.find('[data-step="company"]').exists()).toBe(true);
      expect(wrapper.text()).toContain('already registered');
   });
});
