import { publicSchema, supabase } from '@/lib/supabase';
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query';
import { computed } from 'vue';

// Platform switches (supabase/migrations/070): the super admin reads and changes them; anyone may
// ask whether self-signup is open (decision 17, off by default), through the create-account
// function, since no API role reads the setting itself.

/** The settings by key, as `platform_settings` returns them. */
export type PlatformSettings = { open_signup?: boolean } & Record<string, unknown>;

const SIGNUP_OPEN_KEY = ['platform-setting', 'signup-open'] as const;
const SETTINGS_KEY = ['platform-setting', 'all'] as const;

/** Whether self-signup is open. Anything but an explicit `open: true` counts as closed. */
export async function fetchSignupOpen(): Promise<boolean> {
   const { data, error } = await supabase.functions.invoke<{ open?: unknown }>('create-account', {
      method: 'GET'
   });
   return !error && data?.open === true;
}

/** `open`: whether the sign-up page and links are offered (false until known). */
export function useSignupOpen() {
   const query = useQuery({
      queryKey: SIGNUP_OPEN_KEY,
      queryFn: fetchSignupOpen,
      staleTime: 60_000
   });
   return { ...query, open: computed(() => query.data.value === true) };
}

/** Every platform setting (super admin only: 42501 super_admin_required otherwise). */
export async function fetchPlatformSettings(): Promise<PlatformSettings> {
   const { data } = await publicSchema.rpc('platform_settings').throwOnError();
   return (data ?? {}) as PlatformSettings;
}

/** Changes one existing setting; returns all settings as they are now. */
export async function setPlatformSetting(key: string, value: unknown): Promise<PlatformSettings> {
   const { data } = await publicSchema
      .rpc('set_platform_setting', { key, value: value as never })
      .throwOnError();
   return (data ?? {}) as PlatformSettings;
}

export const usePlatformSettings = () =>
   useQuery({ queryKey: SETTINGS_KEY, queryFn: fetchPlatformSettings });

export function useSetPlatformSetting() {
   const queryClient = useQueryClient();
   return useMutation({
      mutationFn: ({ key, value }: { key: string; value: unknown }) =>
         setPlatformSetting(key, value),
      onSuccess: async (settings) => {
         queryClient.setQueryData(SETTINGS_KEY, settings);
         await queryClient.invalidateQueries({ queryKey: SIGNUP_OPEN_KEY });
      }
   });
}
