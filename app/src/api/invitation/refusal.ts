import { FunctionsHttpError } from '@supabase/supabase-js';

/**
 * The refusal an Edge function answered with: its JSON body, read from the failed response
 * (`functions.invoke` resolves a non-2xx as `{ error: FunctionsHttpError }`). The code is the body's
 * `message` (as in a database error), else its `error`; null when the error is not such a response.
 */
export async function readRefusal(error: unknown) {
   if (!(error instanceof FunctionsHttpError)) return null;
   const body = await error.context
      .clone()
      .json()
      .catch(() => null);
   const code = typeof body?.message === 'string' ? body.message : body?.error;
   if (typeof code !== 'string') return null;
   return { code, bodyCode: typeof body?.code === 'string' ? (body.code as string) : null };
}
