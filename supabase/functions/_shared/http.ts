import { corsHeaders } from './cors.ts';
import { z } from './deps.ts';

export class HttpError extends Error {
   constructor(
      public status: number,
      message: string,
      public details?: unknown
   ) {
      super(message);
   }
}

export const json = (body: unknown, status = 200) =>
   new Response(body === null ? null : JSON.stringify(body), {
      status,
      headers: body === null ? {} : { 'Content-Type': 'application/json' }
   });

const PG_ERROR_STATUS: Record<string, number> = {
   '23505': 409, // unique_violation
   '23503': 409, // foreign_key_violation
   '42501': 403 // insufficient_privilege (RLS)
};

/** The form of the app's error keys (errors.* in the locales), e.g. subscription_read_only. */
const ERROR_KEY = /^[a-z0-9_]+$/;

/**
 * The database's named refusals whose status is not the SQLSTATE's (P0001 is 403 otherwise, 23514
 * has none). The invitation functions raise them or, before their first write, return them as
 * `{"error": key}` (Plan 3 F2); both are answered alike.
 */
export const NAMED_ERROR_STATUS: Record<string, number> = {
   invitation_throttled: 429,
   invitation_invalid: 404,
   invitation_email_mismatch: 403,
   invitation_forbidden: 403,
   invitation_payload_invalid: 400,
   invitation_staff_invalid: 400,
   plan_inactive: 400,
   company_email_exists: 409,
   company_phone_exists: 409,
   client_code_taken: 409,
   invitation_pending_exists: 409
};

/** An error for a refusal the database returned as `{"error": key}`, named by its key alone. */
export const namedRefusal = (key: unknown) =>
   typeof key === 'string' && ERROR_KEY.test(key)
      ? new HttpError(NAMED_ERROR_STATUS[key] ?? 403, key)
      : new HttpError(403, 'request_rejected');

/** Maps an error to a response without leaking internals; unknown errors are logged and returned as 500. */
export const errorResponse = (error: unknown) => {
   if (error instanceof HttpError) {
      return json({ message: error.message, details: error.details }, error.status);
   }

   if (error instanceof z.ZodError) {
      return json(
         {
            message: 'invalid_request',
            issues: error.issues.map(({ path, code, message }) => ({ path, code, message }))
         },
         422
      );
   }

   const { code, status } = (error ?? {}) as { code?: string; status?: number };

   // A named database refusal (a SQLSTATE and a known key): its own status, its key and no more.
   const named = (error as { message?: unknown } | null)?.message;
   if (
      typeof code === 'string' &&
      /^[0-9A-Z]{5}$/.test(code) &&
      typeof named === 'string' &&
      Object.hasOwn(NAMED_ERROR_STATUS, named)
   ) {
      return json({ message: named, code }, NAMED_ERROR_STATUS[named]);
   }

   // Raised on purpose by the database. Only the app's own reasons (keys such as plan_limit_users)
   // are passed on; any other message may carry internals, so it is logged instead.
   if (code === 'P0001') {
      const { message } = error as Error;
      if (ERROR_KEY.test(message)) return json({ message, code }, 403);
      console.error(error);
      return json({ message: 'request_rejected', code }, 403);
   }

   if (code && PG_ERROR_STATUS[code]) {
      return json({ message: 'request_rejected', code }, PG_ERROR_STATUS[code]);
   }

   // Supabase Auth errors carry a public error code (e.g. email_exists) and a 4xx status.
   if (typeof status === 'number' && status >= 400 && status < 500 && code) {
      return json({ message: code, code }, status);
   }

   console.error(error);
   return json({ message: 'internal_error' }, 500);
};

/** Deno.serve wrapper: handles CORS preflight, attaches CORS headers and maps thrown errors. */
export const serve = (handler: (req: Request) => Promise<Response>) =>
   Deno.serve(async (req) => {
      const cors = corsHeaders(req);

      if (req.method === 'OPTIONS') {
         return new Response('ok', { headers: cors });
      }

      let response: Response;
      try {
         response = await handler(req);
      } catch (error) {
         response = errorResponse(error);
      }

      for (const [key, value] of Object.entries(cors)) response.headers.set(key, value);
      return response;
   });
