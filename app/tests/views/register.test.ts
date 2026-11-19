import '../setup/mockMain';
import en from '@/plugins/i18n/locales/en/index.json';
import AuthIndex from '@/views/pages/auth/Index.vue';
import Register from '@/views/pages/auth/register/Index.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { FunctionsHttpError } from '@supabase/supabase-js';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

const api = vi.hoisted(() => ({
   invoke: vi.fn(),
   replace: vi.fn(),
   push: vi.fn(),
   errorHandler: vi.fn()
}));

const signup = vi.hoisted(() => ({
   open: null as unknown as { value: boolean },
   isPending: null as unknown as { value: boolean }
}));
signup.open = ref(true);
signup.isPending = ref(false);

vi.mock('@/lib/supabase', () => ({
   supabase: { functions: { invoke: api.invoke } },
   publicSchema: { rpc: vi.fn() }
}));
vi.mock('@/api/platformSetting', () => ({
   useSignupOpen: () => ({ open: signup.open, isPending: signup.isPending })
}));
vi.mock('@/lib/appErrorHandler', () => ({ appErrorHandler: api.errorHandler }));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ name: 'auth-login', params: {}, query: {} }),
   useRouter: () => ({ replace: api.replace, push: api.push })
}));

const stubs = {
   PhoneInput: true,
   SelectCountry: true,
   FormBox: false,
   RouterLink: { template: '<a data-router-link><slot :href="\'#\'" :navigate="() => {}" /></a>' },
   CustomRouteView: true,
   Teleport: true
};

const mounted: { unmount: () => void }[] = [];
const mountPage = async (component: object = Register) => {
   const wrapper = mount(component, {
      global: {
         plugins: [i18NPlugin, PrimeVue],
         stubs,
         directives: { focustrap: {}, tooltip: {} },
         mocks: { $route: { name: 'auth-login' } }
      }
   });
   mounted.push(wrapper);
   await flushPromises();
   return wrapper;
};

/** Fills the e-mail, goes on, names the company and sends. */
const register = async (wrapper: Awaited<ReturnType<typeof mountPage>>) => {
   await wrapper.get('[data-step="email"] input').setValue('owner@leafline.test');
   await wrapper.get('[data-next]').trigger('click');
   await flushPromises();
   const inputs = wrapper.findAll('[data-step="company"] input');
   await inputs[0]!.setValue('Leafline GmbH');
   await wrapper.findAll('[data-step="company"] button').at(-1)!.trigger('click');
   await flushPromises();
};

describe('register page', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   afterEach(() => mounted.splice(0).forEach((wrapper) => wrapper.unmount()));
   beforeEach(() => {
      Object.values(api).forEach((fn) => fn.mockReset());
      signup.open.value = true;
      signup.isPending.value = false;
      api.invoke.mockResolvedValue({ data: { status: 'check_email' }, error: null });
      api.errorHandler.mockResolvedValue(undefined);
   });

   it('register shows the invitation notice when signup is closed', async () => {
      signup.open.value = false;
      const wrapper = await mountPage();
      expect(wrapper.get('[data-signup-closed]').text()).toContain('Sign-up is by invitation');
      expect(wrapper.find('[data-step="email"]').exists()).toBe(false);
      expect(wrapper.find('input').exists()).toBe(false);
   });

   it('opens the company step without errors', async () => {
      const wrapper = await mountPage();
      await wrapper.get('[data-step="email"] input').setValue('owner@leafline.test');
      await wrapper.get('[data-next]').trigger('click');
      await flushPromises();
      expect(wrapper.find('[data-step="company"]').exists()).toBe(true);
      // Copying the owner's e-mail into the company is not an edit of the company.
      expect(wrapper.find('[data-step="company"] .form_field__error').exists()).toBe(false);
   });

   it('asks for no password', async () => {
      const wrapper = await mountPage();
      expect(wrapper.find('input[type="password"]').exists()).toBe(false);
   });

   it('sends the e-mail and the company, then says to check the e-mail', async () => {
      const wrapper = await mountPage();
      await register(wrapper);

      expect(api.invoke).toHaveBeenCalledTimes(1);
      const [path, options] = api.invoke.mock.calls[0]!;
      expect(path).toBe('create-account');
      expect(options.body.account).toEqual({ email: 'owner@leafline.test' });
      // The company e-mail starts as the owner's.
      expect(options.body.company).toEqual({
         display_name: 'Leafline GmbH',
         email: 'owner@leafline.test'
      });
      expect(JSON.stringify(options.body)).not.toContain('password');

      const check = wrapper.get('[data-check-email]');
      expect(check.text()).toContain('Check your e-mail');
      expect(check.text()).toContain('owner@leafline.test');
      expect(wrapper.find('[data-step="company"]').exists()).toBe(false);
   });

   it('names a throttled sign-up and stays on the form', async () => {
      api.invoke.mockResolvedValue({
         data: null,
         error: new FunctionsHttpError(
            new Response(JSON.stringify({ message: 'signup_throttled' }), { status: 429 })
         )
      });
      const wrapper = await mountPage();
      await register(wrapper);

      expect(wrapper.get('[data-notice]').text()).toContain('Too many');
      expect(wrapper.find('[data-check-email]').exists()).toBe(false);
      expect(api.errorHandler).not.toHaveBeenCalled();
   });

   it('shows the notice when signup was closed meanwhile', async () => {
      api.invoke.mockResolvedValue({
         data: null,
         error: new FunctionsHttpError(
            new Response(JSON.stringify({ message: 'signup_closed', code: 'signup_closed' }), {
               status: 403
            })
         )
      });
      const wrapper = await mountPage();
      await register(wrapper);
      expect(wrapper.find('[data-signup-closed]').exists()).toBe(true);
   });
});

describe('sign-in page banner', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   afterEach(() => mounted.splice(0).forEach((wrapper) => wrapper.unmount()));

   it('hides the sign-up link when signup is closed', async () => {
      signup.open.value = false;
      const wrapper = await mountPage(AuthIndex);
      expect(wrapper.find('[data-signup-link]').exists()).toBe(false);
   });

   it('offers the sign-up link when signup is open', async () => {
      signup.open.value = true;
      const wrapper = await mountPage(AuthIndex);
      expect(wrapper.find('[data-signup-link]').exists()).toBe(true);
   });
});
