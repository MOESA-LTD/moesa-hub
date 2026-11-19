// Verify-first self-signup over real HTTP (Plan 3, Task 11; task-5-review I1). The open sign-up no
// longer creates a confirmed account with the caller's password: create-account invites the address
// and keeps the company in app_metadata; the company is created by create-account/complete once the
// mailed link has proven the inbox. The last test replays the takeover chain of I1 and shows it is
// closed: an attacker who registers a customer's address learns no password, and the customer, later
// invited by a provider, owns an account nobody else can sign in to.
//
// Opens self-signup for its run (as the seeded super admin; set_platform_setting checks auth.uid(),
// so the service role cannot) and restores the setting at the end. Needs the Edge Functions served
// and SITE_URL/register/complete among the Auth redirect URLs (config.toml; restart the stack after
// changing it). Tokens, keys and sessions are never printed.
//
// Run: eval "$(supabase status -o env | sed 's/^/export /')" && cd supabase/functions && deno task test:http
import { assert, assertEquals } from 'jsr:@std/assert@1';
import {
   admin,
   authUser,
   authUsersWithEmail,
   edge,
   followVerifyLink,
   invEmail,
   type InvitationFixture,
   invitationSetup,
   invitationTeardown,
   mailCount,
   mailedInvitation,
   mailedLink,
   nextClientCode,
   passwordSignIn,
   refreshSession,
   rest,
   setOpenSignup,
   setPassword,
   userIdByEmail,
} from './helpers.ts';

let f: InvitationFixture;
let openBefore = false;
const t = (name: string, fn: () => Promise<void>) => Deno.test({ name, fn, sanitizeResources: false, sanitizeOps: false });

const CHECK_EMAIL = { status: 'check_email' };
const signup = (email: string, company: Record<string, unknown>, extra: Record<string, unknown> = {}) =>
   edge(null, 'create-account', { body: { account: { email, ...extra }, company } });
const complete = (token: string | null, plan_id: string | null) => edge(token, 'create-account/complete', { body: { plan_id } });

const tenantsNamed = async (name: string) =>
   ((await admin(`tenant?display_name=eq.${encodeURIComponent(name)}&select=id`)).body as { id: string }[]).length;
const ownedTenants = async (userId: string) =>
   ((await admin(`tenant_owner?user_id=eq.${userId}&select=tenant_id`)).body as { tenant_id: string }[]).map((o) => o.tenant_id);
const planOf = async (tenantId: string) =>
   ((await admin(`subscription?tenant_id=eq.${tenantId}&select=plan_id`)).body as { plan_id: string }[])[0]?.plan_id;
const settle = () => new Promise((resolve) => setTimeout(resolve, 1500));

/** The sign-up link of the newest mail to `email`, followed: the session it opens. */
const followSignupMail = async (email: string, after: number) => {
   const { verifyUrl, redirectTo } = await mailedLink(email, after);
   assert(
      redirectTo.endsWith('/register/complete'),
      `the sign-up mail links to ${redirectTo} (is SITE_URL/register/complete an Auth redirect URL? restart the stack)`,
   );
   return await followVerifyLink(verifyUrl);
};

t('setup', async () => {
   f = await invitationSetup();
   const served = await edge(null, 'create-account', { method: 'GET' });
   assertEquals(served.status, 200, 'create-account must be served (supabase start)');
   openBefore = await setOpenSignup(true);
   assertEquals((await edge(null, 'create-account', { method: 'GET' })).body, { open: true });
});

t('sign-up takes no password, creates no company and answers alike for every address', async () => {
   const email = invEmail('su-new');
   const company = { display_name: 'HTTP Inv Signup New', email: invEmail('su-new-co') };

   for (const extra of [{ password: 'Chosen1234!' }, { password: 'Chosen1234!', email_confirm: true }]) {
      const r = await signup(email, company, extra);
      assertEquals([r.status, r.body?.message], [400, 'signup_payload_invalid'], JSON.stringify(extra));
   }
   assertEquals(await authUsersWithEmail(email), 0, 'a password in the body creates nothing');

   // A new address: an unconfirmed account with nothing but the pending company, and a mail.
   const first = await signup(email, company);
   assertEquals([first.status, first.body], [202, CHECK_EMAIL]);
   const { redirectTo } = await mailedLink(email, 0);
   assert(redirectTo.endsWith('/register/complete'), redirectTo);

   const id = (await userIdByEmail(email))!;
   const account = await authUser(id);
   assertEquals(account.email_confirmed_at ?? null, null, 'not confirmed');
   assertEquals(account.app_metadata?.pending_company?.company?.display_name, 'HTTP Inv Signup New');
   assertEquals(account.user_metadata?.pending_company, undefined, 'never in user_metadata (the user could write it)');
   assertEquals(await ownedTenants(id), [], 'no company before the inbox is proven');
   assertEquals(await tenantsNamed('HTTP Inv Signup New'), 0);
   assertEquals((await passwordSignIn(email, 'Chosen1234!')).session, false, 'no password exists');

   // The same address again (unconfirmed): the same answer, the request replaced, a new mail.
   const again = await signup(email, { ...company, display_name: 'HTTP Inv Signup Again' });
   assertEquals([again.status, again.body], [first.status, first.body]);
   await mailedLink(email, 1);
   assertEquals((await authUser(id)).app_metadata?.pending_company?.company?.display_name, 'HTTP Inv Signup Again');
   assertEquals(await authUsersWithEmail(email), 1);

   // A confirmed address: the same answer, and nothing happens (no mail, nothing pending).
   const before = await mailCount(f.stranger.email);
   const confirmed = await signup(f.stranger.email, { display_name: 'HTTP Inv Signup Taken', email: invEmail('su-taken-co') });
   assertEquals([confirmed.status, confirmed.body], [first.status, first.body]);
   await settle();
   assertEquals(await mailCount(f.stranger.email), before, 'no mail to a confirmed account');
   assertEquals((await authUser(f.stranger.id)).app_metadata?.pending_company, undefined);
   assertEquals(await tenantsNamed('HTTP Inv Signup Taken'), 0);
});

t('a proven inbox completes the sign-up once, on the chosen plan', async () => {
   const email = invEmail('su-done');
   assertEquals((await signup(email, { display_name: 'HTTP Inv Signup Done', email: invEmail('su-done-co'), city: 'Bursa' })).status, 202);
   const session = await followSignupMail(email, 0);
   const id = (await userIdByEmail(email))!;
   assert((await authUser(id)).email_confirmed_at, 'the link proved the inbox');

   assertEquals(await setPassword(session.access, 'Own-Pass-4821!'), 200);
   const done = await complete(session.access, f.proPlan);
   assertEquals(done.status, 201, JSON.stringify(done.body));
   assertEquals(done.body.tenant.display_name, 'HTTP Inv Signup Done');

   const owned = await ownedTenants(id);
   assertEquals(owned, [done.body.tenant.id]);
   assertEquals(await planOf(owned[0]), f.proPlan);
   assertEquals((await authUser(id)).app_metadata?.pending_company ?? null, null, 'nothing waits any more');

   const second = await complete(session.access, f.proPlan);
   assertEquals([second.status, second.body?.message], [409, 'signup_not_pending']);
   assertEquals(await tenantsNamed('HTTP Inv Signup Done'), 1, 'exactly one company');

   // The new owner signs in with the password they set and reads their company.
   assertEquals((await passwordSignIn(email, 'Own-Pass-4821!')).session, true);
   const access = await refreshSession(session.refresh);
   const read = await rest(access, `tenant?id=eq.${owned[0]}&select=id,city`, { headers: { 'x-tenant-id': owned[0] } });
   assertEquals(read.body, [{ id: owned[0], city: 'Bursa' }]);
});

t('completion is refused without a pending sign-up, and once signup is closed', async () => {
   const nothing = await complete(f.stranger.token, null);
   assertEquals([nothing.status, nothing.body?.message], [409, 'signup_not_pending']);
   assertEquals(await ownedTenants(f.stranger.id), []);

   const anon = await complete(null, null);
   assertEquals(anon.status, 401);

   const email = invEmail('su-closed');
   assertEquals((await signup(email, { display_name: 'HTTP Inv Signup Closed', email: invEmail('su-closed-co') })).status, 202);
   const session = await followSignupMail(email, 0);
   await setOpenSignup(false);
   try {
      const closed = await complete(session.access, null);
      assertEquals([closed.status, closed.body?.message], [403, 'signup_closed']);
   } finally {
      await setOpenSignup(true);
   }
   assertEquals(await tenantsNamed('HTTP Inv Signup Closed'), 0);
});

t('the takeover chain of task-5-review I1 is closed', async () => {
   const victim = invEmail('su-victim');
   const attackerPasswords = ['Attacker1234!', 'password-123', 'Demo1234!'];

   // 1. The attacker registers the victim's address. A password is refused; without one the
   //    account exists but nobody knows a password for it, and its link went to the victim's inbox.
   const withPassword = await signup(victim, { display_name: 'HTTP Inv Attacker Co', email: invEmail('su-attacker-co') }, { password: attackerPasswords[0] });
   assertEquals([withPassword.status, withPassword.body?.message], [400, 'signup_payload_invalid']);
   const registered = await signup(victim, { display_name: 'HTTP Inv Attacker Co', email: invEmail('su-attacker-co') });
   assertEquals([registered.status, registered.body], [202, CHECK_EMAIL]);
   const victimId = (await userIdByEmail(victim))!;
   assert(victimId, 'the pending account exists');
   for (const password of attackerPasswords) {
      assertEquals((await passwordSignIn(victim, password)).session, false, 'the attacker cannot sign in');
   }

   // 2. The provider invites the victim. The account is unconfirmed, so it is invited (not sent a
   //    magic link into an account someone else could already use).
   const before = await mailCount(victim);
   const created = await edge(f.owner.token, 'provider-invitation', {
      headers: { 'x-tenant-id': f.provider },
      body: { invitation: { email: victim, company_name: 'HTTP Inv Victim Co', client_code: nextClientCode(), procurement_model: 'provider' } },
   });
   assertEquals(created.status, 201, JSON.stringify(created.body));
   const mailed = await mailedInvitation(victim, before);

   // 3. The victim follows the link, is asked for a password, sets one and accepts.
   const session = await followVerifyLink(mailed.verifyUrl);
   const preview = await rest(session.access, 'rpc/invitation_preview', { method: 'POST', body: { token: mailed.token }, profile: 'public' });
   assertEquals(preview.body?.needs_password, true, JSON.stringify(preview.body?.error ?? ''));
   assertEquals(await setPassword(session.access, 'Victim-Own-7731!'), 200);
   const accepted = await edge(session.access, 'provider-invitation/accept', {
      body: { token: mailed.token, company: { display_name: 'HTTP Inv Victim Co' }, plan_id: f.proPlan },
   });
   assertEquals(accepted.status, 200, JSON.stringify(accepted.body));

   // 4. The account is the victim's alone: no password the attacker chose works, the attacker's
   //    pending company is gone and can no longer be completed, the victim's own password works.
   for (const password of attackerPasswords) {
      const attempt = await passwordSignIn(victim, password);
      assertEquals(attempt.session, false, 'the attacker cannot sign in');
      assertEquals(attempt.status, 400);
   }
   assertEquals((await passwordSignIn(victim, 'Victim-Own-7731!')).session, true);
   assertEquals((await authUser(victimId)).app_metadata?.pending_company ?? null, null, 'acceptance cleared the pending sign-up');
   const late = await complete(session.access, null);
   assertEquals([late.status, late.body?.message], [409, 'signup_not_pending']);
   assertEquals(await ownedTenants(victimId), [accepted.body.tenant_id]);
   assertEquals(await tenantsNamed('HTTP Inv Attacker Co'), 0);
});

t('teardown', async () => {
   try {
      await setOpenSignup(openBefore);
      assertEquals((await edge(null, 'create-account', { method: 'GET' })).body, { open: openBefore });
   } finally {
      await invitationTeardown();
   }
});
