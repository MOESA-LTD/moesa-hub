import { readRefusal } from '@/api/invitation/refusal';
import type { PlanSummary } from '@/lib/planDiff';
import { supabase } from '@/lib/supabase';

// Verify-first self-signup (supabase/functions/create-account, Task 11). The register page sends
// the e-mail and the company; the mailed link opens /register/complete signed in, where the new
// owner sets a password, chooses a plan and completes: only then is the company created.

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

/** What waits in the account's app_metadata until the sign-up is completed. */
export type PendingSignup = {
   company: Record<string, string>;
   plan_id?: string | null;
};

/**
 * The company the account asked for at sign-up, from app_metadata (which only the server writes),
 * never from user_metadata; null when nothing waits.
 */
export function pendingSignup(
   user:
      | { app_metadata?: Record<string, unknown> | null; user_metadata?: unknown }
      | null
      | undefined
): PendingSignup | null {
   const pending = user?.app_metadata?.pending_company as PendingSignup | null | undefined;
   return pending && typeof pending === 'object' && pending.company ? pending : null;
}

/** Creates the company that waits for the signed-in account, on `planId` (null: the default). */
export async function completeSignup(planId: string | null) {
   const { data, error } = await supabase.functions.invoke<{
      tenant: { id: string; display_name: string };
   }>('create-account/complete', { method: 'POST', body: { plan_id: planId } });
   if (error) throw await named(error);
   return data as { tenant: { id: string; display_name: string } };
}

const PLAN_SELECT =
   'id, display_name, description, audience, price, currency, billing_period, trial_days, position, plan_module(module_id), plan_limit(limit_key, value)';

type PlanRow = Omit<PlanSummary, 'modules' | 'limits'> & {
   plan_module: { module_id: string }[] | null;
   plan_limit: { limit_key: string; value: number | null }[] | null;
};

/** The active plans, in the shape the invitation preview gives them (PlanCompare's input). */
export async function fetchSignupPlans(): Promise<PlanSummary[]> {
   const { data } = await supabase
      .from('plan')
      .select(PLAN_SELECT)
      .eq('is_active', true)
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
