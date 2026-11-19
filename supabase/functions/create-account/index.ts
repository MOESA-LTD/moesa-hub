// Open self-signup (decision 17), verify-first (Task 11, task-5-review I1).
//
//   GET  /create-account            public                      -> 200 { open }
//   POST /create-account            { account: { email }, company, plan_id? }
//                                   open signup only            -> 202 { status: 'check_email' }
//   GET  /create-account/complete   signed in                   -> 200 { company, plan_id }
//   POST /create-account/complete   { company?, plan_id? }  signed in, the inbox proven
//                                                               -> 201 { tenant }
//
// No password is ever accepted here and no account is confirmed without its inbox: the address is
// invited (GoTrue mails a link to SITE_URL/register/complete; the account has no password) and the
// company it asked for waits in private.pending_signup (server side only: no API role reads it and
// it is in no token). Following the link proves the inbox; the page then sets the password, shows
// the company for the owner to confirm or edit, and completes: only then is the company created.
// So nobody can pre-register someone else's address with a password they know.
//
// POST answers the same 202 whatever the address (no enumeration):
//   - new: an unconfirmed account (no password) is created, its pending sign-up saved, then invited;
//   - unconfirmed, with a pending sign-up and owning no company (an earlier self-signup): the
//     pending sign-up is replaced and the address re-invited;
//   - anything else (confirmed, owning a company, or an unconfirmed account a provider or a company
//     invited, which has no pending sign-up): nothing is done and nothing is mailed, so a sign-up can
//     never disturb someone else's invitation. The owner of a confirmed address signs in (the page
//     says so).
// Mail and Auth failures are logged (status and code) and not told, for the same reason. The
// endpoint is throttled before anything is written (signup_throttle): 5 an hour per address, 30 per
// client address and 200 in all, the last protecting the project's mail quota (GoTrue's own limit is
// project-wide, so one caller could otherwise starve every other mail, provider invitations
// included).
//
// /complete refuses while signup is closed, also for a signup started while it was open (decision
// 17), refuses an account whose e-mail is not confirmed (read from Auth's admin API, not the token)
// and one with nothing pending, and creates at most one company per account (complete_signup,
// serialised per user, removes the pending sign-up in the same transaction).
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
   .transform(
      (company) =>
         Object.fromEntries(
            Object.entries(company).filter(([, value]) => typeof value === 'string' && value !== '')
         ) as Record<string, string>
   );

const signupSchema = z
   .object({
      account: z.object({ email: text(320).toLowerCase().email() }).strict(),
      company: companySchema,
      plan_id: UUID.nullish()
   })
   .strict();

/** The company as the owner confirmed or edited it (the pending one when left out), and the plan. */
const completeSchema = z
   .object({ company: companySchema.optional(), plan_id: UUID.nullable().optional() })
   .strict();

/** What public.pending_signup returns. */
type Pending = { company: Record<string, string>; plan_id: string | null };

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

/**
 * The client's address from x-forwarded-for, counted from the right: entry `hops` from the end, the
 * one the nearest trusted proxy appended for the connection it received (SIGNUP_TRUSTED_PROXY_HOPS,
 * default 1: the rightmost). Entries further left come from the client and can be anything, so they
 * are never used. If the header has fewer entries the address is unknown (one shared bucket, which
 * the per-address and global limits still back up). See supabase/functions/.env.example for how to
 * verify the value on the hosted project.
 */
export const clientIp = (req: Request) => {
   const configured = Number(Deno.env.get('SIGNUP_TRUSTED_PROXY_HOPS') ?? '1');
   const hops = Number.isInteger(configured) && configured >= 1 ? configured : 1;
   const entries = (req.headers.get('x-forwarded-for') ?? '')
      .split(',')
      .map((entry) => entry.trim())
      .filter(Boolean);
   return entries.at(-hops)?.slice(0, 64) ?? '';
};

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

const readPending = async (service: Service, userId: string) => {
   const { data } = await service.rpc('pending_signup', { p_user: userId }).throwOnError();
   return (data ?? null) as Pending | null;
};

const savePending = (service: Service, userId: string, company: Record<string, string>, planId: string | null) =>
   service
      .rpc('save_pending_signup', { p_user: userId, p_company: company as Json, p_plan_id: planId as string })
      .throwOnError();

/**
 * Invites `email` and keeps the company waiting, unless the address belongs to an account a
 * sign-up must leave alone (see the header). Never throws: the caller answers the same in every
 * case.
 */
const inviteSignup = async (
   service: Service,
   email: string,
   company: Record<string, string>,
   planId: string | null,
   redirectTo: string
) => {
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
         // Only an earlier self-signup is re-invited: a provider's or a company's invitee is not.
         if (!(await readPending(service, found.id))) return;

         const { data: owned, error: owner } = await service
            .from('tenant_owner')
            .select('tenant_id')
            .eq('user_id', found.id)
            .limit(1);
         if (owner) throw owner;
         if (owned?.length) return;

         await savePending(service, found.id, company, planId);
      } else {
         // The account exists before the mail, with the company already waiting: no password, not
         // confirmed.
         const { data, error } = await service.auth.admin.createUser({ email, email_confirm: false });
         // An Auth account public.user does not list (confirmed or not): left alone.
         if (error?.code === 'email_exists') return;
         if (error) throw error;
         try {
            await savePending(service, data.user.id, company, planId);
         } catch (saving) {
            // No account may stay behind without its pending sign-up: nothing could ever complete
            // or release it.
            await service.auth.admin.deleteUser(data.user.id);
            throw saving;
         }
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

   await inviteSignup(service, account.email, company, plan_id ?? null, `${site}/register/complete`);

   return json({ status: 'check_email' }, 202);
};

/** The signed-in account, its inbox proven, and its pending sign-up (refusals otherwise). */
const provenPending = async (req: Request, service: Service) => {
   // Signed in, verified by Supabase Auth: the account is the token's subject.
   const { sub: userId } = await authenticate(req);
   if (!(await openSignup(service))) return { closed: true as const };

   // The proof comes from Auth itself, not from the token's claims.
   const { data, error } = await service.auth.admin.getUserById(userId);
   if (error || !data.user) throw new HttpError(401, 'unauthorized');
   if (!data.user.email_confirmed_at) throw new HttpError(403, 'signup_unconfirmed');
   const pending = await readPending(service, userId);
   if (!pending) throw new HttpError(409, 'signup_not_pending');
   return { closed: false as const, userId, pending };
};

/** The company and plan the sign-up asked for: the completion page's defaults. */
export const readSignup = async (req: Request, service: Service) => {
   const found = await provenPending(req, service);
   if (found.closed) return SIGNUP_CLOSED();
   return json({ company: found.pending.company, plan_id: found.pending.plan_id ?? null });
};

export const completeSignup = async (req: Request, service: Service) => {
   const found = await provenPending(req, service);
   if (found.closed) return SIGNUP_CLOSED();
   const { company, plan_id } = await readBody(req, completeSchema);
   const { userId, pending } = found;

   try {
      // Refused when closed, unproven, completed already or no longer pending (070, section 3);
      // create_company checks the company's allowlist again.
      const { data: created } = await service
         .rpc('complete_signup', {
            p_user: userId,
            p_company: (company ?? pending.company) as Json,
            p_plan_id: (plan_id === undefined ? pending.plan_id ?? null : plan_id) as string
         })
         .throwOnError();
      const tenant = created as unknown as { id: string; display_name: string };
      return json({ tenant: { id: tenant.id, display_name: tenant.display_name } }, 201);
   } catch (error) {
      const { code, message } = (error ?? {}) as { code?: string; message?: string };
      const constraint = /constraint "([^"]+)"/.exec(message ?? '')?.[1] ?? '';
      if (code === '23505' && COMPANY_CONFLICTS[constraint]) {
         throw new HttpError(409, COMPANY_CONFLICTS[constraint], { code: COMPANY_CONFLICTS[constraint] });
      }
      throw error;
   }
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
      if (req.method === 'GET') return await readSignup(req, service);
      if (req.method === 'POST') return await completeSignup(req, service);
      throw new HttpError(405, 'method_not_allowed');
   }
   throw new HttpError(404, 'not_found');
};

if (import.meta.main) serve(handler);
