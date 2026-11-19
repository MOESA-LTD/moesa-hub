import '../setup/mockMain';
import { authBeforeEach } from '@/router/middlewares/before-each/auth';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { RouteLocationNormalized } from 'vue-router';

const api = vi.hoisted(() => ({ setSession: vi.fn(), toast: vi.fn() }));

vi.mock('@/lib/supabase', () => ({ supabase: { auth: { setSession: api.setSession } } }));
vi.mock('primevue', () => ({ useToast: () => ({ add: api.toast }) }));
vi.mock('@plugins/casl', () => ({ ability: { can: () => true, cannot: () => false } }));
vi.mock('@/store/auth', () => ({
   useAuthStore: () => ({
      initialized: Promise.resolve(),
      accessReady: () => Promise.resolve(),
      isSignedIn: true,
      isSuperAdmin: false,
      lockedModule: () => null
   })
}));

const run = (to: Partial<RouteLocationNormalized>) =>
   (authBeforeEach as (...args: unknown[]) => unknown).call(
      undefined,
      { meta: {}, matched: [], ...to } as RouteLocationNormalized,
      {} as RouteLocationNormalized,
      () => {}
   );

describe('authBeforeEach with the tokens of an e-mail link', () => {
   beforeEach(() => {
      api.setSession.mockReset().mockResolvedValue({ error: null });
      api.toast.mockReset();
      window.location.hash = '#access_token=a&refresh_token=r';
   });

   it('sends an invited user to the security page to set a password', async () => {
      expect(await run({ name: 'dashboard', path: '/dashboard' })).toEqual({
         name: 'account-security'
      });
      expect(api.setSession).toHaveBeenCalledWith({ access_token: 'a', refresh_token: 'r' });
   });

   it('keeps the invitation page: it sets the password itself', async () => {
      const to = { name: 'auth-invitation', path: '/invitation/tok' };
      expect(await run(to)).toBeUndefined();
      expect(api.setSession).toHaveBeenCalledWith({ access_token: 'a', refresh_token: 'r' });
      expect(api.toast).not.toHaveBeenCalled();
      // The tokens leave the address bar; the invitation token stays in the path.
      expect(window.location.hash).toBe('');
   });
});
