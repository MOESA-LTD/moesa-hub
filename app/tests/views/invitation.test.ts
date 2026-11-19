import '../setup/mockMain';
import en from '@/plugins/i18n/locales/en/index.json';
import Index from '@/views/pages/auth/invitation/Index.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { FunctionsHttpError } from '@supabase/supabase-js';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { reactive } from 'vue';

const api = vi.hoisted(() => ({
   rpc: vi.fn(),
   invoke: vi.fn(),
   updateUser: vi.fn(),
   replace: vi.fn(),
   push: vi.fn(),
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
   useRoute: () => ({ params: { token: 'secret-token' }, fullPath: '/invitation/secret-token' }),
   useRouter: () => ({ replace: api.replace, push: api.push, go: vi.fn() })
}));

const TOKEN = 'secret-token';

/** How `functions.invoke` really reports a refusal: it resolves with the error, whose context is the response. */
const refusal = (status: number, body: Record<string, unknown>) => ({
   data: null,
   error: new FunctionsHttpError(new Response(JSON.stringify(body), { status }))
});

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

const mounted: { unmount: () => void }[] = [];

const mountPage = async () => {
   const wrapper = mount(Index, {
      global: { plugins: [i18NPlugin, PrimeVue], stubs, directives: { focustrap: {}, tooltip: {} } }
   });
   mounted.push(wrapper);
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
   afterEach(() => mounted.splice(0).forEach((wrapper) => wrapper.unmount()));
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

   it('accept sends only company and plan, never model or staff roles (F1)', async () => {
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

   it('I2: names each provider staff member and role, and sends only the staff kept', async () => {
      api.rpc.mockResolvedValue({
         data: preview({
            seats: 3,
            staff: [
               { index: 0, display_name: 'Koordinatör', role_name: 'coordinator' },
               { index: 1, display_name: null, role_name: 'management' }
            ]
         }),
         error: null
      });
      const wrapper = await mountPage();
      await toPlanStep(wrapper);

      const list = wrapper.get('[data-staff]');
      expect(list.text()).toContain('Koordinatör');
      expect(list.text()).toContain(en.invitation.staff.role.coordinator);
      expect(list.text()).toContain(en.invitation.staff.unnamed);
      expect(list.text()).toContain(en.invitation.staff.role.management);
      expect(wrapper.get('[data-step="plan"]').text()).toContain('brings 3 users');

      await wrapper.get('[data-staff-member="1"] input').setValue(false);
      await flushPromises();
      expect(wrapper.get('[data-step="plan"]').text()).toContain('brings 2 users');

      await wrapper.get('[data-accept]').trigger('click');
      await flushPromises();
      const [, options] = api.invoke.mock.calls[0]!;
      expect(Object.keys(options.body)).toEqual(['token', 'company', 'plan_id', 'staff']);
      expect(options.body.staff).toEqual([0]);
   });

   it('I2: the plans follow the staff kept', async () => {
      const small = { ...preview().plans[0]!, limits: { max_users: 2 } };
      api.rpc.mockResolvedValue({
         data: preview({
            seats: 3,
            recommended_plan_id: 'basic',
            plans: [small, preview().plans[1]],
            staff: [
               { index: 0, display_name: 'Koordinatör', role_name: 'coordinator' },
               { index: 1, display_name: 'Akif', role_name: 'viewer' }
            ]
         }),
         error: null
      });
      const wrapper = await mountPage();
      await toPlanStep(wrapper);
      // Three seats: the two-user plan is not offered, so nothing is chosen.
      expect(wrapper.get('[data-accept]').attributes('disabled')).toBeDefined();
      expect(wrapper.get('[data-plan="basic"]').text()).toContain('this invitation brings 3');

      await wrapper.get('[data-staff-member="0"] input').setValue(false);
      await flushPromises();
      expect(wrapper.get('[data-plan="basic"]').text()).not.toContain('this invitation brings');
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

   it('M3: shows the signed-in address on every step, with a way out', async () => {
      api.rpc.mockResolvedValue({ data: preview({ needs_password: true }), error: null });
      const wrapper = await mountPage();
      const shown = () => wrapper.get('[data-signed-in-as]').text();
      expect(wrapper.find('[data-step="account"]').exists()).toBe(true);
      expect(shown()).toContain('invitee@client.test');

      const [password, confirmation] = wrapper.findAll('input');
      await password!.setValue('Secret123!');
      await confirmation!.setValue('Secret123!');
      await wrapper.get('form').trigger('submit');
      await flushPromises();
      expect(wrapper.find('[data-step="company"]').exists()).toBe(true);
      expect(shown()).toContain('invitee@client.test');

      await toPlanStep(wrapper);
      expect(wrapper.find('[data-step="plan"]').exists()).toBe(true);
      expect(shown()).toContain('invitee@client.test');

      await wrapper.get('[data-signed-in-as] [data-sign-out]').trigger('click');
      expect(api.logout).toHaveBeenCalled();
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

   // Cleanup item 11: the customer's throttle is about their own attempts, not the provider's
   // daily invitation cap (errors.invitation_throttled).
   it('words a throttled preview for the customer, not as the provider cap', async () => {
      api.rpc.mockResolvedValue({ data: { error: 'invitation_throttled' }, error: null });
      const wrapper = await mountPage();
      const text = wrapper.get('[data-fatal]').text();
      expect(text).toContain('Too many attempts');
      expect(text).not.toContain('invitations were sent');
   });

   it('words a throttled acceptance for the customer, not as the provider cap', async () => {
      api.invoke.mockResolvedValue(refusal(429, { message: 'invitation_throttled' }));
      const wrapper = await mountPage();
      await accept(wrapper);
      const text = wrapper.get('[data-notice]').text();
      expect(text).toContain('Too many attempts');
      expect(text).not.toContain('invitations were sent');
   });

   it('shows plan_limit_users from a 403 body and stays on the plan step', async () => {
      api.invoke.mockResolvedValue(refusal(403, { message: 'plan_limit_users', code: 'P0001' }));
      const wrapper = await mountPage();
      await accept(wrapper);

      expect(wrapper.get('[data-notice]').text()).toContain('fewer users');
      expect(api.replace).not.toHaveBeenCalled();
      expect(api.errorHandler).not.toHaveBeenCalled();
   });

   it('ends on the dead-link card for invitation_invalid (404)', async () => {
      api.invoke.mockResolvedValue(refusal(404, { message: 'invitation_invalid' }));
      const wrapper = await mountPage();
      await accept(wrapper);

      expect(wrapper.get('[data-fatal]').text()).toContain('no longer valid');
   });

   it('names the signed-in address for invitation_email_mismatch (403)', async () => {
      api.invoke.mockResolvedValue(refusal(403, { message: 'invitation_email_mismatch' }));
      const wrapper = await mountPage();
      await accept(wrapper);

      expect(wrapper.get('[data-fatal]').text()).toContain('invitee@client.test');
      expect(wrapper.find('[data-sign-out]').exists()).toBe(true);
   });

   // Decision 19: the invited account is a member of the provider's company.
   it('ends on a fatal card for invitation_self_invite at preview', async () => {
      api.rpc.mockResolvedValue({ data: { error: 'invitation_self_invite' }, error: null });
      const wrapper = await mountPage();
      expect(wrapper.get('[data-fatal]').text()).toContain('member of the inviting company');
   });

   it('ends on a fatal card for invitation_self_invite (409) at acceptance', async () => {
      api.invoke.mockResolvedValue(refusal(409, { message: 'invitation_self_invite' }));
      const wrapper = await mountPage();
      await accept(wrapper);

      expect(wrapper.get('[data-fatal]').text()).toContain('member of the inviting company');
      expect(api.errorHandler).not.toHaveBeenCalled();
   });

   it('puts a taken company e-mail (409) on the e-mail field', async () => {
      api.invoke.mockResolvedValue(refusal(409, { message: 'company_email_exists' }));
      const wrapper = await mountPage();
      await accept(wrapper);

      expect(wrapper.find('[data-step="company"]').exists()).toBe(true);
      expect(wrapper.text()).toContain('already registered');
   });

   it('offers a retry when the preview fails for another reason', async () => {
      api.rpc.mockResolvedValueOnce({ data: null, error: new Error('network') });
      const wrapper = await mountPage();
      expect(wrapper.find('[data-load-failed]').exists()).toBe(true);
      expect(api.errorHandler).toHaveBeenCalled();

      await wrapper.get('[data-retry]').trigger('click');
      await flushPromises();
      expect(api.rpc).toHaveBeenCalledTimes(2);
      expect(wrapper.find('[data-step="company"]').exists()).toBe(true);
   });

   it('offers to sign in, back to this link, when there is no session', async () => {
      auth.isSignedIn = false;
      const wrapper = await mountPage();
      await wrapper.get('[data-sign-in]').trigger('click');
      expect(api.push).toHaveBeenCalledWith({
         name: 'auth-login',
         query: { redirect: '/invitation/secret-token' }
      });
      expect(wrapper.text()).toContain('ask your provider to send it again');
   });

   it('restores the referrer policy it found when it goes', async () => {
      const existing = document.createElement('meta');
      existing.name = 'referrer';
      existing.content = 'origin';
      document.head.appendChild(existing);
      const wrapper = await mountPage();
      expect(existing.content).toBe('no-referrer');
      wrapper.unmount();
      expect(existing.content).toBe('origin');
      existing.remove();
   });

   it('removes the referrer tag it added', async () => {
      const wrapper = await mountPage();
      expect(document.head.querySelector('meta[name="referrer"]')?.getAttribute('content')).toBe(
         'no-referrer'
      );
      wrapper.unmount();
      expect(document.head.querySelector('meta[name="referrer"]')).toBeNull();
   });

   it('says to reload when the new tenant never shows in the list', async () => {
      vi.useFakeTimers({ toFake: ['setTimeout'] });
      try {
         auth.branches = [];
         const wrapper = await mountPage();
         const done = accept(wrapper);
         for (let i = 0; i < 6; i++) {
            await flushPromises();
            await vi.advanceTimersByTimeAsync(2000);
         }
         await done;
         await flushPromises();

         expect(wrapper.find('[data-accepted]').exists()).toBe(true);
         expect(api.replace).not.toHaveBeenCalled();
         expect(api.refreshAccess.mock.calls.length).toBeGreaterThan(1);
      } finally {
         vi.useRealTimers();
         auth.branches = [{ id: 'tenant-1', display_name: 'Client Ltd' }];
      }
   });
});
