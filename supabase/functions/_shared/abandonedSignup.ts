import type { supabaseAdmin } from './supabaseClient.ts';

/** The caller's own service client: user's (allow-listed) or provider-invitation's (labelled). */
type Service = ReturnType<typeof supabaseAdmin>;

/**
 * Releases an address squatted by an abandoned self-signup (Task 11 M4): an account that never
 * proved its inbox, was created over a day ago, owns no company, belongs to none and has a pending
 * sign-up. public.release_abandoned_signup deletes it in one statement, the conditions re-checked
 * under the row's lock (its identities and pending sign-up go with it), so the staff or provider
 * invitation can proceed as for a new address. No Auth admin call. Returns whether it was released.
 */
export const releaseAbandonedSignup = async (service: Service, userId: string): Promise<boolean> => {
   const { data, error } = await service.rpc('release_abandoned_signup', { p_user: userId });
   if (error) throw error;
   return data === true;
};
