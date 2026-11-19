import { readRefusal } from '@/api/invitation/refusal';
import type { PlanSummary } from '@/lib/planDiff';
import { supabase } from '@/lib/supabase';

// Verify-first self-signup (supabase/functions/create-account, Task 11). The register page sends
// the e-mail and the company; the mailed link opens /register/complete signed in, where the new
// owner sets a password, confirms or edits the company, chooses a plan and completes: only then is
// the company created. The sign-up waits server side (private.pending_signup), never in the token.

/** A refusal of create-account named by its code (signup_closed, signup_throttled, ...). */
export class SignupError extends Error {
   constructor(public readonly code: string) {
      super(code);
      this.name = 'SignupError';
   }
}

/** The function's refusal as a SignupError; any other error as it is. */
export const named = async (error: unknown) => {
   const refusal = await readRefusal(error);
   return refusal ? new SignupError(refusal.code) : error;
};

/** What the sign-up asked for: the completion page's defaults. */
export type PendingSignup = {
   company: Record<string, string>;
   plan_id: string | null;
};

/**
 * The company and plan waiting for the signed-in account. Refusals (signup_not_pending,
 * signup_unconfirmed, signup_closed) are thrown as a SignupError.
 */
export async function fetchPendingSignup(): Promise<PendingSignup> {
   const { data, error } = await supabase.functions.invoke<PendingSignup>(
      'create-account/complete',
      { method: 'GET' }
   );
   if (error) throw await named(error);
   return { company: data?.company ?? {}, plan_id: data?.plan_id ?? null };
}

/**
 * Creates the company waiting for the signed-in account, as the owner confirmed or edited it
 * (`company`, the allowlisted keys), on `planId` (null: the default plan).
 */
export async function completeSignup(planId: string | null, company: Record<string, string>) {
   const { data, error } = await supabase.functions.invoke<{
      tenant: { id: string; display_name: string };
   }>('create-account/complete', { method: 'POST', body: { company, plan_id: planId } });
   if (error) throw await named(error);
   return data as { tenant: { id: string; display_name: string } };
}

const PLAN_SELECT =
   'id, display_name, description, audience, price, currency, billing_period, trial_days, position, plan_module(module_id), plan_limit(limit_key, value)';

type PlanRow = Omit<PlanSummary, 'modules' | 'limits'> & {
   plan_module: { module_id: string }[] | null;
   plan_limit: { limit_key: string; value: number | null }[] | null;
};

/** The plans a client may choose (decision 21): their targets. */
export const CLIENT_PLAN_TARGETS = ['client', 'all'] as const;

/**
 * The active plans offered to clients, in the shape the invitation preview gives them
 * (PlanCompare's input).
 */
export async function fetchSignupPlans(): Promise<PlanSummary[]> {
   const { data } = await supabase
      .from('plan')
      .select(PLAN_SELECT)
      .eq('is_active', true)
      .in('target', [...CLIENT_PLAN_TARGETS])
      .order('position')
      .order('display_name')
      .throwOnError();
   return ((data ?? []) as unknown as PlanRow[]).map(({ plan_module, plan_limit, ...plan }) => ({
      ...plan,
      modules: (plan_module ?? []).map(({ module_id }) => module_id).sort(),
      limits: Object.fromEntries(
         (plan_limit ?? []).map(({ limit_key, value }) => [limit_key, value])
      )
   }));
}
