import type { Database } from './database.types.ts';
import type { SupabaseClient } from './deps.ts';

/** A service-role client (the caller's own: create-account's, user's or provider-invitation's). */
type Service = SupabaseClient<Database>;

/**
 * Releases an address squatted by an abandoned self-signup (Task 11 M4): an account that never
 * proved its inbox, owns no company, belongs to none and whose pending sign-up is older than a day
 * (public.abandoned_signup). The account is deleted (its pending sign-up goes with it, cascade), so
 * a staff or provider invitation can proceed as for a new address. Returns whether it was released.
 */
export const releaseAbandonedSignup = async (service: Service, userId: string): Promise<boolean> => {
   const { data, error } = await service.rpc('abandoned_signup', { p_user: userId });
   if (error) throw error;
   if (data !== true) return false;
   const { error: removal } = await service.auth.admin.deleteUser(userId);
   if (removal) throw removal;
   return true;
};
