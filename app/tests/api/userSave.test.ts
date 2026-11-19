import { userRepository } from '@/api/user';
import { FunctionsHttpError } from '@supabase/supabase-js';
import ToastEventBus from 'primevue/toasteventbus';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mock = vi.hoisted(() => ({
   invoke: vi.fn(),
   rpc: vi.fn(),
   throwOnError: vi.fn()
}));

vi.mock('@/lib/supabase', () => {
   const query = {
      setHeader() {
         return query;
      },
      throwOnError: () => mock.throwOnError()
   };
   return {
      supabase: { functions: { invoke: mock.invoke } },
      publicSchema: {
         rpc: (...args: unknown[]) => {
            mock.rpc(...args);
            return query;
         }
      }
   };
});

const refusal = (status: number, message: string) =>
   new FunctionsHttpError(
      new Response(JSON.stringify({ message }), {
         status,
         headers: { 'Content-Type': 'application/json' }
      })
   );

const input = { id: 'u1', tenantId: 't1', attributes: {}, roleIds: ['r1'] };

describe('userRepository.save for a member', () => {
   const toasts: unknown[] = [];
   const collect = (message: unknown) => toasts.push(message);

   beforeEach(() => {
      toasts.length = 0;
      mock.invoke.mockReset();
      mock.rpc.mockReset();
      mock.throwOnError.mockReset().mockResolvedValue({});
      vi.spyOn(userRepository, 'get').mockResolvedValue(null);
      ToastEventBus.on('add', collect);
   });

   afterEach(() => ToastEventBus.off('add', collect));

   it('saves the roles and tells the user when another company manages the profile', async () => {
      mock.invoke.mockResolvedValue({ data: null, error: refusal(403, 'user_profile_shared') });
      await userRepository.save(input as never);

      expect(mock.rpc).toHaveBeenCalledWith('set_user_roles', { user_id: 'u1', role_ids: ['r1'] });
      expect(toasts).toHaveLength(1);
      expect(toasts[0]).toMatchObject({ severity: 'info' });
   });

   it('rethrows an owner or super admin refusal and saves no roles', async () => {
      const error = refusal(403, 'user_not_allowed');
      mock.invoke.mockResolvedValue({ data: null, error });

      await expect(userRepository.save(input as never)).rejects.toBe(error);
      expect(mock.rpc).not.toHaveBeenCalled();
      expect(toasts).toHaveLength(0);
   });

   it('shows no notice when the profile was saved', async () => {
      mock.invoke.mockResolvedValue({ data: { user: { id: 'u1' } }, error: null });
      await userRepository.save(input as never);

      expect(mock.rpc).toHaveBeenCalled();
      expect(toasts).toHaveLength(0);
   });
});
