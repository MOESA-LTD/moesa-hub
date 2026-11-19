// Provider invitations (Plan 3, decision 16).
//
//   POST /provider-invitation              { invitation, staff }   insert right   -> 201 { id }
//   POST /provider-invitation/:id/resend   {}                      update right   -> 200 { id }
//   POST /provider-invitation/accept       { token, company, plan_id }  signed in -> 200 { tenant_id }
//                                          (drops a pending self-signup of the account, Task 11)
//
// The token is the invitation's only credential: it is minted by the database, mailed as a link
// through Supabase Auth and then forgotten. It is never returned, logged or passed to an error.
// Create and resend act for the caller (p_actor = the caller, the audit actor too, F27). Accept
// serves a customer who is not a member of any tenant yet: no tenant or right is checked, but the
// user is the verified token's, never the body's (F1).
import { releaseAbandonedSignup } from '../_shared/abandonedSignup.ts';
import { authenticate, withAuthorization } from '../_shared/auth.ts';
import { z } from '../_shared/deps.ts';
import { HttpError, json, namedRefusal, serve } from '../_shared/http.ts';
import type { Json } from '../_shared/database.types.ts';
import { supabaseService } from '../_shared/supabaseClient.ts';

const UUID = z.string().uuid();

const createSchema = z
   .object({
      // The database checks every other key and value (create_provider_invitation's allowlist).
      invitation: z
         .object({ email: z.string().trim().toLowerCase().email().max(320) })
         .passthrough(),
      staff: z.array(z.unknown()).max(20).default([])
   })
   .strict();

const resendSchema = z.object({}).strict();

const acceptSchema = z
   .object({
      token: z.string().min(1).max(256),
      // The database checks the company keys (accept_provider_invitation's allowlist).
      company: z.record(z.unknown()),
      plan_id: UUID.nullable()
   })
   .strict();

/** The body, parsed by `schema`; anything else is the invitation's payload refusal (400). */
const readBody = async <T extends z.ZodTypeAny>(req: Request, schema: T): Promise<z.infer<T>> => {
   let body: unknown;
   try {
      body = await req.json();
   } catch {
      throw new HttpError(400, 'invitation_payload_invalid');
   }
   const parsed = schema.safeParse(body);
   // No issue list: it could quote what was sent.
   if (!parsed.success) throw new HttpError(400, 'invitation_payload_invalid');
   return parsed.data;
};

/** The panel's base URL the link points at (config site_url). Without it nothing is created. */
const siteUrl = () => {
   const value = Deno.env.get('SITE_URL')?.trim().replace(/\/+$/, '');
   if (!value || !/^https?:\/\/[^/]+/.test(value)) throw new HttpError(500, 'invitation_unconfigured');
   return value;
};

/** The link in the e-mail: the panel's acceptance page, the token as one path segment (F21). */
const invitationLink = (site: string, token: string) =>
   `${site}/invitation/${encodeURIComponent(token)}`;

/**
 * The service-role client of this function: service-only RPCs (the token is minted and checked
 * where no API role reaches it) and the Auth mail. Its writes are audited as provider-invitation
 * acting for `actorId`, the verified caller (F27).
 */
const invitationService = (actorId: string) => {
   const db = supabaseService({ role: 'provider-invitation', actorId });

   /** Whether the address belongs to an account that has confirmed its e-mail (it can sign in). */
   const confirmedAccount = async (email: string) => {
      const { data: account, error: lookup } = await db
         .from('user')
         .select('id')
         .eq('email', email)
         .maybeSingle();
      if (lookup) throw lookup;
      if (!account) return false;

      const { data, error } = await db.auth.admin.getUserById(account.id);
      if (error) throw error;
      if (data.user?.email_confirmed_at) return true;

      // An abandoned self-signup squatting the address (Task 11 M4) is released first, so the
      // invitation creates the account afresh; a younger one is simply re-invited (its pending
      // sign-up is dropped on acceptance). A failed release changes nothing: the re-invite works.
      try {
         await releaseAbandonedSignup(db, account.id);
      } catch (release) {
         const { status, code } = (release ?? {}) as { status?: number; code?: string };
         console.error('provider-invitation: releasing an abandoned sign-up failed', status, code);
      }
      return false;
   };

   /**
    * Mails the link: an account that can sign in gets a magic link (no account is created); a new
    * address, or an account invited before that never confirmed (Auth sends it no magic link while
    * sign-ups are off), an invitation. The caller learns only whether it was sent, never which
    * way, and no Auth error is passed on or logged: its text may quote the link.
    */
   const mail = async (email: string, link: string) => {
      let confirmed: boolean;
      try {
         confirmed = await confirmedAccount(email);
      } catch (error) {
         const { status, code } = (error ?? {}) as { status?: number; code?: string };
         console.error('provider-invitation: account lookup failed', status, code);
         return false;
      }

      const otp = () =>
         db.auth.signInWithOtp({
            email,
            options: { shouldCreateUser: false, emailRedirectTo: link }
         });

      let { error } = confirmed
         ? await otp()
         : await db.auth.admin.inviteUserByEmail(email, { redirectTo: link });
      // A confirmed Auth account public.user does not list: it is sent the magic link instead.
      if (error && !confirmed && error.code === 'email_exists') ({ error } = await otp());
      if (error) {
         console.error('provider-invitation: the e-mail was not sent', error.status, error.code);
         return false;
      }
      return true;
   };

   return { db, mail };
};

const MAIL_FAILED = () => new HttpError(502, 'invitation_mail_failed');

export const createInvitation = (req: Request) =>
   withAuthorization(req, [['insert', 'provider_invitation']], async ({ userId, tenantId }) => {
      const site = siteUrl();
      const { invitation, staff } = await readBody(req, createSchema);
      const { db, mail } = invitationService(userId);

      const { data, error } = await db
         .rpc('create_provider_invitation', {
            p_tenant: tenantId,
            p_actor: userId,
            p_invitation: invitation as Json,
            p_staff: staff as Json
         })
         .single();
      if (error) throw error;
      const { id, token } = data as { id: string; token: string };

      if (!(await mail(invitation.email, invitationLink(site, token)))) {
         // Nobody holds the token: the invitation goes, so the address and code are free again.
         const { error: undo } = await db.rpc('revoke_unsent_provider_invitation', {
            p_invitation: id,
            p_actor: userId
         });
         if (undo) console.error('provider-invitation: revoking the unsent invitation failed', id, undo.code);
         throw MAIL_FAILED();
      }

      return json({ id }, 201);
   });

export const resendInvitation = (req: Request, id: string) =>
   withAuthorization(req, [['update', 'provider_invitation']], async ({ userId, tenantId }) => {
      const site = siteUrl();
      await readBody(req, resendSchema);
      const { db, mail } = invitationService(userId);

      // The address of an invitation of the caller's active tenant (the service role reads past
      // RLS, so the tenant is named here); any other id is refused like an unknown one.
      const { data: found, error: read } = await db
         .from('provider_invitation')
         .select('email')
         .eq('id', id)
         .eq('tenant_id', tenantId)
         .maybeSingle();
      if (read) throw read;
      if (!found) throw new HttpError(404, 'invitation_invalid');

      const { data: token, error } = await db.rpc('rotate_provider_invitation_token', {
         p_invitation: id,
         p_actor: userId
      });
      if (error) throw error;

      // The old link is dead and the new token reached nobody: the invitation stays pending (no
      // secret is out, and the provider's invitation is not lost to a mail outage); the provider
      // resends again or revokes.
      if (!(await mail(found.email, invitationLink(site, token as string)))) throw MAIL_FAILED();

      return json({ id });
   });

export const acceptInvitation = async (req: Request) => {
   // Signed in, verified by Supabase Auth: the user who accepts is the token's subject.
   const { sub: userId } = await authenticate(req);
   const { token, company, plan_id } = await readBody(req, acceptSchema);
   const { db } = invitationService(userId);

   // accept_provider_invitation labels its own writes with p_user and restores the headers (Task 4).
   const { data, error } = await db.rpc('accept_provider_invitation', {
      p_user: userId,
      p_token: token,
      p_company: company as Json,
      p_plan_id: plan_id as string
   });
   if (error) throw error;

   const result = (data ?? {}) as { error?: string; tenant_id?: string };
   if (result.error !== undefined) throw namedRefusal(result.error);
   // Neither a refusal nor a tenant: the function broke its contract. A plain 500 (errorResponse
   // logs this message, which names no input).
   if (!result.tenant_id) throw new Error('accept_provider_invitation returned no tenant');

   return json({ tenant_id: result.tenant_id });
};

const createPattern = new URLPattern({ pathname: '/provider-invitation' });
const acceptPattern = new URLPattern({ pathname: '/provider-invitation/accept' });
const resendPattern = new URLPattern({ pathname: '/provider-invitation/:id/resend' });

export const handler = async (req: Request): Promise<Response> => {
   const route = (method: string, run: () => Promise<Response>) => {
      if (req.method !== method) throw new HttpError(405, 'method_not_allowed');
      return run();
   };

   if (createPattern.test(req.url)) return await route('POST', () => createInvitation(req));
   if (acceptPattern.test(req.url)) return await route('POST', () => acceptInvitation(req));

   const id = resendPattern.exec(req.url)?.pathname.groups.id;
   if (id !== undefined) {
      if (!UUID.safeParse(id).success) throw new HttpError(404, 'not_found');
      return await route('POST', () => resendInvitation(req, id));
   }

   throw new HttpError(404, 'not_found');
};

if (import.meta.main) serve(handler);
