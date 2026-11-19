import { fetchPlatformSettings, fetchSignupOpen, setPlatformSetting } from '@/api/platformSetting';
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

beforeEach(() => {
   mock.invoke.mockReset();
   mock.rpc.mockReset();
   mock.throwOnError.mockReset();
});

describe('platform settings', () => {
   it('setPlatformSetting calls the RPC with key and value', async () => {
      mock.throwOnError.mockResolvedValue({ data: { open_signup: true } });
      await expect(setPlatformSetting('open_signup', true)).resolves.toEqual({ open_signup: true });
      expect(mock.rpc).toHaveBeenCalledWith('set_platform_setting', {
         key: 'open_signup',
         value: true
      });
   });

   it('reads the settings through platform_settings (super admin only)', async () => {
      mock.throwOnError.mockResolvedValue({ data: { open_signup: false } });
      await expect(fetchPlatformSettings()).resolves.toEqual({ open_signup: false });
      expect(mock.rpc).toHaveBeenCalledWith('platform_settings');
   });

   it('a refusal of the RPC is passed on', async () => {
      mock.throwOnError.mockRejectedValue(
         Object.assign(new Error('super_admin_required'), { code: '42501' })
      );
      await expect(setPlatformSetting('open_signup', true)).rejects.toThrow('super_admin_required');
   });
});

describe('fetchSignupOpen', () => {
   it('asks create-account with GET', async () => {
      mock.invoke.mockResolvedValue({ data: { open: true }, error: null });
      await expect(fetchSignupOpen()).resolves.toBe(true);
      expect(mock.invoke).toHaveBeenCalledWith('create-account', { method: 'GET' });
   });

   it('is closed unless the answer says open', async () => {
      for (const data of [{ open: false }, { open: 'true' }, {}, null]) {
         mock.invoke.mockResolvedValue({ data, error: null });
         await expect(fetchSignupOpen()).resolves.toBe(false);
      }
   });

   it('is closed when the function cannot be reached', async () => {
      mock.invoke.mockResolvedValue({ data: null, error: new Error('network') });
      await expect(fetchSignupOpen()).resolves.toBe(false);
   });
});
