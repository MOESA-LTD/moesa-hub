import '../setup/mockMain';
import { useAuthUi } from '@/composables/useAuthUi';
import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, reactive, ref } from 'vue';
import { createMemoryHistory, createRouter, RouterView } from 'vue-router';

// Signing in moves the user off the pages for signed-out users (the login page) into the app; the
// pages an e-mail link signs in to (the invitation, the sign-up completion) serve the signed-in
// user and keep them (walk, Task 17: a restored or link session bounced the invitee off).
const signedIn = ref(false);

vi.mock('@/store/auth', () => ({
   useAuthStore: () => reactive({ isSignedIn: signedIn, initialized: Promise.resolve() })
}));
vi.mock('primevue/usetoast', () => ({ useToast: () => ({ add: vi.fn() }) }));

const Page = defineComponent({ render: () => h('div') });

const mountAt = async (path: string) => {
   const router = createRouter({
      history: createMemoryHistory(),
      routes: [
         { path: '/', name: 'dashboard', component: Page },
         { path: '/login', name: 'auth-login', component: Page },
         { path: '/invitation/:token', name: 'auth-invitation', component: Page },
         { path: '/register/complete', name: 'auth-register-complete', component: Page }
      ]
   });
   await router.push(path);
   await router.isReady();
   const App = defineComponent({
      setup: () => {
         useAuthUi();
         return () => h(RouterView);
      }
   });
   mount(App, { global: { plugins: [router] } });
   await flushPromises();
   return router;
};

describe('useAuthUi on signing in', () => {
   beforeEach(() => {
      signedIn.value = false;
   });

   it('moves a user who signed in on the login page into the app', async () => {
      const router = await mountAt('/login');
      signedIn.value = true;
      await flushPromises();
      expect(router.currentRoute.value.name).toBe('dashboard');
   });

   it.each(['/invitation/tok', '/register/complete'])(
      'keeps a user signed in on %s, the page the e-mail link opens',
      async (path) => {
         const router = await mountAt(path);
         signedIn.value = true;
         await flushPromises();
         expect(router.currentRoute.value.fullPath).toBe(path);
      }
   );
});
