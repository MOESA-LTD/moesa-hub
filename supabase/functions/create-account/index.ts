// Open self-signup (decision 17), verify-first (Task 11, task-5-review I1).
//
//   GET  /create-account            public                      -> 200 { open }
//   POST /create-account            { account: { email }, company, plan_id? }
//                                   open signup only            -> 202 { status: 'check_email' }
//   POST /create-account/complete   { plan_id? }  signed in, the inbox proven -> 201 { tenant }
//
// No password is ever accepted here and no account is confirmed without its inbox: the address is
// invited (GoTrue mails a link to SITE_URL/register/complete; the account has no password) and the
// company it asked for waits in app_metadata.pending_company, which only the service role writes.
// Following the link proves the inbox; the page then sets the password and completes, and only then
// is the company created. So nobody can pre-register someone else's address with a password they
// know and wait for that customer to be invited into it.
//
// POST answers the same 202 for a new address, an unconfirmed one and a confirmed one (no
// enumeration):
//   - new: an unconfirmed account (no password) is created with the pending company, then invited;
//   - unconfirmed and owning no company: the pending company is replaced and the address re-invited;
//   - confirmed, or owning a company: nothing is done and nothing is mailed. The owner of that
//     address already has an account and signs in (the page says so); a mail would only let a third
//     party mail-bomb a known address.
// Mail and Auth failures are logged (status and code) and not told, for the same reason. The
// endpoint is throttled per address and per client address before anything is written
// (signup_throttle: 5 and 30 an hour). GoTrue's own mail rate limit is project-wide, so it would
// let one caller starve every other mail (provider invitations included): it is not relied on.
//
// /complete refuses while signup is closed, also for a signup started while it was open (decision
// 17: the switch closes the door for everyone), refuses an account whose e-mail is not confirmed
// (read from Auth's admin API, not the token) and one with nothing pending, and creates at most one
// company per account (complete_signup, serialised per user; a second call is 409).
import { authenticate } from '../_shared/auth.ts';
import { z } from '../_shared/deps.ts';
import { HttpError, json, serve } from '../_shared/http.ts';
import type { Json } from '../_shared/database.types.ts';
import { supabaseAdmin } from '../_shared/supabaseClient.ts';

type Service = ReturnType<typeof supabaseAdmin>;

const UUID = z.string().uuid();
const text = (max = 300) => z.string().trim().max(max);

/** The company keys private.create_company takes, and no others. */
const companySchema = z
   .object({
      display_name: text(200).min(3),
      email: text(320).toLowerCase().email(),
      legal_name: text().optional(),
      phone: text(40).nullish(),
      website: text().optional(),
      country: text(100).optional(),
      city: text(100).optional(),
      district: text(100).optional(),
      address: text(1000).optional(),
      tax_office: text(200).optional(),
      tax_number: text(50).optional()
   })
   .strict()
   // Empty values are left out (create_company stores them as NULL anyway).
   .transform((company) =>
      Object.fromEntries(Object.entries(company).filter(([, value]) => typeof value === 'string' && value !== ''))
   );

const signupSchema = z
   .object({
      account: z.object({ email: text(320).toLowerCase().email() }).strict(),
      company: companySchema,
      plan_id: UUID.nullish()
   })
   .strict();

const completeSchema = z.object({ plan_id: UUID.nullable().optional() }).strict();

/** What waits in app_metadata until the inbox is proven. */
const pendingSchema = z.object({
   company: z.record(z.string()),
   plan_id: UUID.nullable().optional()
});

const COMPANY_CONFLICTS: Record<string, string> = {
   tenant_email_key: 'company_email_exists',
   tenant_phone_key: 'company_phone_exists'
};

/** The body, parsed by `schema`; anything else is 400 signup_payload_invalid (no issue list). */
const readBody = async <T extends z.ZodTypeAny>(req: Request, schema: T): Promise<z.infer<T>> => {
   let body: unknown;
   try {
      body = await req.json();
   } catch {
      throw new HttpError(400, 'signup_payload_invalid');
   }
   const parsed = schema.safeParse(body);
   if (!parsed.success) throw new HttpError(400, 'signup_payload_invalid');
   return parsed.data;
};

/** The panel's base URL the link points at (config site_url). */
const siteUrl = () => {
   const value = Deno.env.get('SITE_URL')?.trim().replace(/\/+$/, '');
   if (!value || !/^https?:\/\/[^/]+/.test(value)) throw new HttpError(500, 'signup_unconfigured');
   return value;
};

/** The client's address as the platform's proxy reports it (first x-forwarded-for entry). */
const clientIp = (req: Request) =>
   (req.headers.get('x-forwarded-for') ?? req.headers.get('x-real-ip') ?? '').split(',')[0].trim().slice(0, 64);

/** Self-signup is a platform setting, off by default (decision 17); the service role alone reads it. */
const openSignup = async (service: Service) => {
   const { data } = await service.rpc('open_signup_enabled').throwOnError();
   return data === true;
};

const SIGNUP_CLOSED = () => json({ message: 'signup_closed', code: 'signup_closed' }, 403);

/** Logs an Auth or database failure by status and code only: its text may quote the input. */
const logFailure = (what: string, error: unknown) => {
   const { status, code } = (error ?? {}) as { status?: number; code?: string };
   console.error(`create-account: ${what}`, status, code);
};

/**
 * Invites `email` and leaves the company waiting in its app_metadata, unless the address belongs to
 * a confirmed account or to one that owns a company. Never throws: the caller answers the same in
 * every case.
 */
const inviteSignup = async (service: Service, email: string, pending: Record<string, unknown>, redirectTo: string) => {
   try {
      const { data: found, error: lookup } = await service
         .from('user')
         .select('id')
         .eq('email', email)
         .maybeSingle();
      if (lookup) throw lookup;

      if (found) {
         const { data, error } = await service.auth.admin.getUserById(found.id);
         if (error) throw error;
         if (data.user?.email_confirmed_at) return;

         const { data: owned, error: owner } = await service
            .from('tenant_owner')
            .select('tenant_id')
            .eq('user_id', found.id)
            .limit(1);
         if (owner) throw owner;
         if (owned?.length) return;

         const { error: update } = await service.auth.admin.updateUserById(found.id, {
            app_metadata: { pending_company: pending }
         });
         if (update) throw update;
      } else {
         // The account exists before the mail, with the company already in place: no password, not
         // confirmed. app_metadata is the service role's alone (the user cannot write it).
         const { error } = await service.auth.admin.createUser({
            email,
            email_confirm: false,
            app_metadata: { pending_company: pending }
         });
         // An Auth account public.user does not list (confirmed or not): left alone.
         if (error?.code === 'email_exists') return;
         if (error) throw error;
      }

      // An unconfirmed account is (re-)invited: Auth mails the link, which proves the inbox.
      const { error } = await service.auth.admin.inviteUserByEmail(email, { redirectTo });
      if (error) throw error;
   } catch (error) {
      logFailure('the sign-up was not mailed', error);
   }
};

export const signup = async (req: Request, service: Service) => {
   if (!(await openSignup(service))) return SIGNUP_CLOSED();
   const site = siteUrl();
   const { account, company, plan_id } = await readBody(req, signupSchema);

   const { data: allowed } = await service
      .rpc('signup_throttle', { p_email: account.email, p_ip: clientIp(req) })
      .throwOnError();
   if (allowed !== true) throw new HttpError(429, 'signup_throttled');

   const pending = { company, plan_id: plan_id ?? null, requested_at: new Date().toISOString() };
   await inviteSignup(service, account.email, pending, `${site}/register/complete`);

   return json({ status: 'check_email' }, 202);
};

export const completeSignup = async (req: Request, service: Service) => {
   // Signed in, verified by Supabase Auth: the account is the token's subject.
   const { sub: userId } = await authenticate(req);
   if (!(await openSignup(service))) return SIGNUP_CLOSED();
   const { plan_id } = await readBody(req, completeSchema);

   // The proof and the pending company come from Auth itself, not from the token's claims.
   const { data, error } = await service.auth.admin.getUserById(userId);
   if (error || !data.user) throw new HttpError(401, 'unauthorized');
   if (!data.user.email_confirmed_at) throw new HttpError(403, 'signup_unconfirmed');
   const pending = pendingSchema.safeParse(data.user.app_metadata?.pending_company);
   if (!pending.success) throw new HttpError(409, 'signup_not_pending');

   let tenant: { id: string; display_name: string };
   try {
      // Refused when closed, unproven or completed already (supabase/migrations/070, section 3).
      const { data: created } = await service
         .rpc('complete_signup', {
            p_user: userId,
            p_company: pending.data.company as Json,
            p_plan_id: (plan_id === undefined ? pending.data.plan_id ?? null : plan_id) as string
         })
         .throwOnError();
      tenant = created as unknown as { id: string; display_name: string };
   } catch (error) {
      const { code, message } = (error ?? {}) as { code?: string; message?: string };
      const constraint = /constraint "([^"]+)"/.exec(message ?? '')?.[1] ?? '';
      if (code === '23505' && COMPANY_CONFLICTS[constraint]) {
         throw new HttpError(409, COMPANY_CONFLICTS[constraint], { code: COMPANY_CONFLICTS[constraint] });
      }
      throw error;
   }

   // Done: nothing waits any more. A failure here is harmless (the account owns a company now, so a
   // second completion is refused) and only logged.
   const { error: clear } = await service.auth.admin.updateUserById(userId, {
      app_metadata: { pending_company: null }
   });
   if (clear) logFailure('the pending company was not cleared', clear);

   return json({ tenant: { id: tenant.id, display_name: tenant.display_name } }, 201);
};

const rootPattern = new URLPattern({ pathname: '/create-account' });
const completePattern = new URLPattern({ pathname: '/create-account/complete' });

export const handler = async (req: Request): Promise<Response> => {
   const service = supabaseAdmin();

   if (rootPattern.test(req.url)) {
      if (req.method === 'GET') return json({ open: await openSignup(service) });
      if (req.method === 'POST') return await signup(req, service);
      throw new HttpError(405, 'method_not_allowed');
   }
   if (completePattern.test(req.url)) {
      if (req.method !== 'POST') throw new HttpError(405, 'method_not_allowed');
      return await completeSignup(req, service);
   }
   throw new HttpError(404, 'not_found');
};

if (import.meta.main) serve(handler);
