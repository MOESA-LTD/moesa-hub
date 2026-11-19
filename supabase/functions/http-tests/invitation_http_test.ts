// Invitation onboarding over real HTTP (Plan 3, Task 7): the attack surface of the provider
// invitation. The token is minted by the database (service role only), mailed through Supabase Auth
// and accepted through the provider-invitation Edge Function (F1); the preview is an authenticated
// RPC answering refusals as 200 {"error": code} (F2). A failing case is a defect in Tasks 3-6.
//
// Needs the Edge Functions served (supabase start serves them, with supabase/functions/.env's
// SITE_URL) and the Auth redirect URL SITE_URL/invitation/** (config.toml; restart the stack after
// changing it). Tokens, keys and sessions are never printed.
//
// Run: eval "$(supabase status -o env | sed 's/^/export /')" && cd supabase/functions && deno task test:http
import { assert, assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import { encodeBase64 } from 'jsr:@std/encoding@1/base64';
import {
   admin,
   ANON_KEY,
   authUserMetadata,
   authUsersWithEmail,
   edge,
   followVerifyLink,
   invEmail,
   type InvitationFixture,
   invitationSetup,
   invitationTeardown,
   invitee,
   issueInvitation,
   mailCount,
   mailedInvitation,
   nextClientCode,
   refreshSession,
   signIn,
   rest,
   type RestResult,
} from './helpers.ts';

let f: InvitationFixture;
const t = (name: string, fn: () => Promise<void>) => Deno.test({ name, fn, sanitizeResources: false, sanitizeOps: false });

/** Every failing answer of the suite, checked at the end for a token, a hash or a staff e-mail. */
const failures: { what: string; body: unknown }[] = [];
/** Every token the suite held. */
const tokens: string[] = [];
const refused = (r: RestResult, what: string) => {
   failures.push({ what, body: r.body });
   return r;
};

/** A token nobody was ever issued: the same form as a real one (32 random bytes, base64url). */
const randomToken = () =>
   encodeBase64(crypto.getRandomValues(new Uint8Array(32))).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');

const preview = (token: string | null, invitationToken: string) =>
   rest(token ?? ANON_KEY, 'rpc/invitation_preview', { method: 'POST', body: { token: invitationToken }, profile: 'public' });
const accept = (token: string | null, body: unknown) => edge(token, 'provider-invitation/accept', { body });
const acceptCompany = (token: string, invitationToken: string, display_name: string, plan_id: string | null = null) =>
   accept(token, { token: invitationToken, company: { display_name }, plan_id });
/** A request of the provider owner in the provider tenant. */
const asProvider = { 'x-tenant-id': '' };

const invitationRow = async (id: string) =>
   ((await admin(`provider_invitation?id=eq.${id}&select=status,failed_attempts,client_tenant_id`)).body as {
      status: string;
      failed_attempts: number;
      client_tenant_id: string | null;
   }[])[0];
const tenantsNamed = async (name: string) =>
   ((await admin(`tenant?display_name=eq.${encodeURIComponent(name)}&select=id`)).body as { id: string }[]).length;

/** The PostgREST answer of a refused RPC: refused before it runs (no grant, or not exposed). */
const notCallable = (r: RestResult, what: string) => {
   refused(r, what);
   assert([401, 403, 404].includes(r.status), `${what}: ${r.status} ${JSON.stringify(r.body).slice(0, 200)}`);
};

/** The main invitation, accepted through the real mail path (test 4), reused by later tests. */
const main = { id: '', token: '', email: invEmail('main'), verifyUrl: '', client: '', session: { access: '', refresh: '' } };

t('setup', async () => {
   f = await invitationSetup();
   asProvider['x-tenant-id'] = f.provider;
   // The suite needs the function: a missing one is a failure, not a skip.
   const probe = await accept(null, {});
   assertEquals(probe.status, 401, `provider-invitation is not served (${probe.status}): run supabase start / functions serve`);
});

t('anon cannot call preview, accept, revoke, create, rotate or discard', async () => {
   const { token, id } = await issueInvitation(f, invEmail('anon-target'));
   tokens.push(token);
   const calls: [string, unknown][] = [
      ['invitation_preview', { token }],
      ['accept_provider_invitation', { p_user: f.stranger.id, p_token: token, p_company: { display_name: 'HTTP Inv Anon' }, p_plan_id: null }],
      ['revoke_provider_invitation', { invitation_id: id }],
      ['create_provider_invitation', { p_tenant: f.provider, p_actor: f.owner.id, p_invitation: { email: invEmail('anon-x') } }],
      ['rotate_provider_invitation_token', { p_invitation: id, p_actor: f.owner.id }],
      ['revoke_unsent_provider_invitation', { p_invitation: id, p_actor: f.owner.id }],
   ];
   for (const [fn, body] of calls) {
      notCallable(await rest(ANON_KEY, `rpc/${fn}`, { method: 'POST', body, profile: 'public' }), `anon ${fn}`);
      notCallable(await rest(ANON_KEY, `rpc/${fn}`, { method: 'POST', body, profile: 'api' }), `anon api.${fn}`);
   }
   // Unauthenticated, the Edge route refuses before reading anything.
   assertEquals(refused(await accept(null, { token, company: { display_name: 'HTTP Inv Anon' }, plan_id: null }), 'anon accept').status, 401);
   assertEquals(refused(await edge(null, 'provider-invitation', { body: { invitation: { email: invEmail('anon-y') } } }), 'anon create').status, 401);
   assertEquals((await invitationRow(id)).status, 'pending');
   assertEquals(await tenantsNamed('HTTP Inv Anon'), 0);
});

t('authenticated users cannot mint, rotate, accept or discard through PostgREST', async () => {
   const target = await invitee('rpc-target');
   const { token, id } = await issueInvitation(f, target.email);
   tokens.push(token);
   // The provider owner holds every invitation right; the invitee holds the token. Neither reaches
   // the service-only functions.
   for (const [who, jwt, self] of [
      ['provider owner', f.owner.token, f.owner.id],
      ['invitee', target.token, target.id],
   ] as const) {
      const calls: [string, unknown][] = [
         ['create_provider_invitation', { p_tenant: f.provider, p_actor: self, p_invitation: { email: invEmail('rpc-x'), company_name: 'HTTP Inv X', client_code: nextClientCode(), procurement_model: 'provider' } }],
         ['rotate_provider_invitation_token', { p_invitation: id, p_actor: self }],
         ['accept_provider_invitation', { p_user: target.id, p_token: token, p_company: { display_name: 'HTTP Inv RPC' }, p_plan_id: null }],
         ['revoke_unsent_provider_invitation', { p_invitation: id, p_actor: self }],
         ['is_provider_staff', { p_client: f.provider, p_user: self }],
      ];
      for (const [fn, body] of calls) {
         for (const profile of ['public', 'api']) {
            notCallable(await rest(jwt, `rpc/${fn}`, { method: 'POST', body, profile, headers: asProvider }), `${who} ${profile}.${fn}`);
         }
      }
   }
   const row = await invitationRow(id);
   assertEquals([row.status, row.failed_attempts], ['pending', 0]);
   assertEquals(await tenantsNamed('HTTP Inv RPC'), 0);
   assertEquals(((await admin(`provider_invitation?email=eq.${encodeURIComponent(invEmail('rpc-x'))}&select=id`)).body as unknown[]).length, 0);
   // The token still works for its invitee: nothing above touched it.
   assertEquals((await preview(target.token, token)).body?.company_name, 'HTTP Inv Company');
});

t('the provider app never sees a token', async () => {
   const before = await mailCount(main.email);
   const r = await edge(f.owner.token, 'provider-invitation', {
      headers: asProvider,
      body: {
         invitation: {
            email: main.email,
            company_name: 'HTTP Inv Main Co',
            client_code: nextClientCode(),
            procurement_model: 'client',
            commercial_model: 'operations_partner',
         },
         staff: [
            { user_id: f.staff[0].id, role_name: 'management' },
            { user_id: f.staff[1].id, role_name: 'coordinator' },
         ],
      },
   });
   assertEquals(r.status, 201, JSON.stringify(r.body));
   assertEquals(Object.keys(r.body), ['id']);
   main.id = r.body.id;

   // The mail carries the token (the only copy); the response did not.
   const mailed = await mailedInvitation(main.email, before);
   main.token = mailed.token;
   main.verifyUrl = mailed.verifyUrl;
   tokens.push(main.token);
   assertEquals(main.token.length, 43);
   assert(!JSON.stringify(r.body).includes(main.token));

   // api.provider_invitation has no token or hash column, and no view or schema leads to the hash.
   const listed = await rest(f.owner.token, `provider_invitation?id=eq.${main.id}&select=*`, { headers: asProvider });
   assertEquals(listed.status, 200, JSON.stringify(listed.body));
   assertEquals(listed.body.length, 1);
   for (const key of Object.keys(listed.body[0])) assert(!/token|hash/i.test(key), `api.provider_invitation.${key}`);
   for (const select of ['token_hash', 'token', 'hash']) {
      const r2 = await rest(f.owner.token, `provider_invitation?select=${select}`, { headers: asProvider });
      assertNotEquals(r2.status, 200, `select=${select}`);
      refused(r2, `select=${select}`);
   }
   for (const [path, profile] of [
      ['provider_invitation_token?select=*', 'private'],
      ['provider_invitation_token?select=*', 'api'],
      ['provider_invitation_token?select=*', 'public'],
      ['provider_invitation?select=token_hash', 'public'],
   ]) {
      const r3 = await rest(f.owner.token, path, { profile, headers: asProvider });
      assertNotEquals(r3.status, 200, `${profile}.${path}`);
      refused(r3, `${profile}.${path}`);
   }
   // Even the service role's REST access does not reach the private table.
   const svc = await admin('provider_invitation_token?select=*', { profile: 'private', allowError: true });
   assertNotEquals(svc.status, 200);
});

t('the provider never invites an account of its own company, nor may one accept (decision 19)', async () => {
   // At creation: the owner's own address and a staff member's, in another case.
   for (const email of [f.owner.email, f.staff[0].email.toUpperCase()]) {
      const r = refused(
         await edge(f.owner.token, 'provider-invitation', {
            headers: asProvider,
            body: { invitation: { email, company_name: 'HTTP Inv Self Co', client_code: nextClientCode(), procurement_model: 'provider' } },
         }),
         'self invite',
      );
      assertEquals([r.status, r.body?.message], [409, 'invitation_self_invite'], JSON.stringify(r.body));
   }
   assertEquals(((await admin(`provider_invitation?company_name=eq.${encodeURIComponent('HTTP Inv Self Co')}&select=id`)).body as unknown[]).length, 0);

   // At preview and acceptance: the invited account joined the provider meanwhile.
   const joiner = await invitee('self-joiner');
   const { token, id } = await issueInvitation(f, joiner.email);
   tokens.push(token);
   await admin('tenant_user', { method: 'POST', body: { tenant_id: f.provider, user_id: joiner.id } });
   const p = refused(await preview(joiner.token, token), 'self preview');
   assertEquals([p.status, p.body], [200, { error: 'invitation_self_invite' }]);
   const r = refused(await acceptCompany(joiner.token, token, 'HTTP Inv Self Joiner'), 'self accept');
   assertEquals([r.status, r.body?.message], [409, 'invitation_self_invite'], JSON.stringify(r.body));
   const row = await invitationRow(id);
   assertEquals([row.status, row.failed_attempts], ['pending', 0]);
   assertEquals(await tenantsNamed('HTTP Inv Self Joiner'), 0);
});

t('a plan for providers only cannot be recommended (decision 21)', async () => {
   const providerPlans = ((await admin('plan?target=eq.provider&is_active=is.true&select=id')).body as { id: string }[]).map((x) => x.id);
   assert(providerPlans.length > 0, 'the seed has an active plan for providers only');
   const r = refused(
      await edge(f.owner.token, 'provider-invitation', {
         headers: asProvider,
         body: {
            invitation: {
               email: invEmail('provider-plan'),
               company_name: 'HTTP Inv Provider Plan Co',
               client_code: nextClientCode(),
               procurement_model: 'provider',
               recommended_plan_id: providerPlans[0],
            },
         },
      }),
      'recommended provider plan',
   );
   assertEquals([r.status, r.body?.message], [400, 'plan_not_for_clients'], JSON.stringify(r.body));
});

t('acceptance through the mailed link creates tenant, accepted relationship and stored staff roles', async () => {
   // The invited address had no account: the mail was an Auth invitation. Following it signs the
   // new user in (e-mail confirmed by the link), as the browser would.
   main.session = await followVerifyLink(main.verifyUrl);

   const p = await preview(main.session.access, main.token);
   assertEquals(p.status, 200, JSON.stringify(p.body));
   assertEquals(p.body.company_name, 'HTTP Inv Main Co');
   assertEquals(p.body.procurement_model, 'client');
   assertEquals(p.body.provider_name, f.providerName);
   assertEquals(p.body.seats, 3);
   assertEquals(p.body.needs_password, true);
   // Final review I2: the staff who would join, by display name and role; never an e-mail or an id.
   const listed = p.body.staff as { index: number; display_name: string | null; role_name: string }[];
   assertEquals(listed.map((s) => s.role_name).sort(), ['coordinator', 'management']);
   for (const s of listed) assertEquals(Object.keys(s).sort(), ['display_name', 'index', 'role_name']);
   const text = JSON.stringify(p.body);
   for (const s of f.staff) assert(!text.includes(s.email) && !text.includes(s.id), 'the preview names a staff e-mail or id');
   assert(!text.includes(main.token));
   // Decision 21: the plans offered are the active ones for clients; a plan for providers only is
   // neither offered nor accepted.
   const providerPlans = ((await admin('plan?target=eq.provider&is_active=is.true&select=id')).body as { id: string }[]).map((x) => x.id);
   assert(providerPlans.length > 0, 'the seed has an active plan for providers only');
   const offered = (p.body.plans as { id: string }[]).map((x) => x.id);
   assert(offered.includes(f.proPlan) && !offered.some((id) => providerPlans.includes(id)), JSON.stringify(offered));
   const forProviders = refused(await acceptCompany(main.session.access, main.token, 'HTTP Inv Client Main', providerPlans[0]), 'provider plan');
   assertEquals([forProviders.status, forProviders.body?.message], [400, 'plan_not_for_clients'], JSON.stringify(forProviders.body));
   assertEquals(await tenantsNamed('HTTP Inv Client Main'), 0);

   const r = await acceptCompany(main.session.access, main.token, 'HTTP Inv Client Main', f.proPlan);
   assertEquals(r.status, 200, JSON.stringify(r.body));
   assertEquals(Object.keys(r.body), ['tenant_id']);
   main.client = r.body.tenant_id;
   main.session.access = await refreshSession(main.session.refresh);

   // The new owner sees its one relationship, with the model the provider invited it with.
   const rel = await rest(main.session.access, 'provider_relationship?select=tenant_id,client_tenant_id,procurement_model,status', {
      headers: { 'x-tenant-id': main.client },
   });
   assertEquals(rel.status, 200, JSON.stringify(rel.body));
   assertEquals(rel.body, [{ tenant_id: f.provider, client_tenant_id: main.client, procurement_model: 'client', status: 'active' }]);
   const owned = await admin(`tenant_owner?tenant_id=eq.${main.client}&select=user_id`);
   assertEquals(owned.body.length, 1);
   const sub = await admin(`subscription?tenant_id=eq.${main.client}&select=plan_id`);
   assertEquals(sub.body, [{ plan_id: f.proPlan }]);

   // The staff joined in the roles the invitation stored, and work in the new tenant.
   for (const [s, role] of [[f.staff[0], 'management'], [f.staff[1], 'coordinator']] as const) {
      const roles = (await admin(`user_role?user_id=eq.${s.id}&select=role!inner(tenant_id,display_name)&role.tenant_id=eq.${main.client}`)).body as {
         role: { display_name: string };
      }[];
      assertEquals(roles.map((x) => x.role.display_name), [role]);
      const staffToken = await signIn(s.email);
      const seen = await rest(staffToken, `tenant?id=eq.${main.client}&select=id`, {
         headers: { 'x-tenant-id': main.client, 'x-tenant-ids': `${main.client},${f.provider}` },
      });
      assertEquals(seen.status, 200, JSON.stringify(seen.body));
      assertEquals(seen.body, [{ id: main.client }]);
   }
   const row = await invitationRow(main.id);
   assertEquals([row.status, row.client_tenant_id], ['accepted', main.client]);

   // Single use: the same user, the same token, again.
   const again = refused(await acceptCompany(main.session.access, main.token, 'HTTP Inv Client Main 2'), 'replay');
   assertEquals(again.status, 404);
   assertEquals(again.body?.message, 'invitation_invalid');
});

t('preview answers refusals as JSON and never counts a wrong account', async () => {
   const target = await invitee('preview-target');
   const { token, id } = await issueInvitation(f, target.email);
   tokens.push(token);

   const wrong = refused(await preview(f.stranger.token, token), 'preview mismatch');
   assertEquals([wrong.status, wrong.body], [200, { error: 'invitation_email_mismatch' }]);
   const unknown = refused(await preview(f.stranger.token, randomToken()), 'preview unknown');
   assertEquals([unknown.status, unknown.body], [200, { error: 'invitation_invalid' }]);
   const anon = refused(await preview(null, token), 'preview anon');
   assert([401, 403, 404].includes(anon.status), String(anon.status));

   for (let i = 0; i < 3; i++) await preview(f.stranger.token, token);
   assertEquals((await invitationRow(id)).failed_attempts, 0);
   const right = await preview(target.token, token);
   assertEquals(right.status, 200);
   assertEquals(right.body.company_name, 'HTTP Inv Company');
});

t('a wrong account cannot accept and is counted', async () => {
   const target = await invitee('mismatch-target');
   const intruder = await invitee('mismatch-intruder');
   const { token, id } = await issueInvitation(f, target.email);
   tokens.push(token);

   const r = refused(await acceptCompany(intruder.token, token, 'HTTP Inv Client Intruder'), 'accept mismatch');
   assertEquals(r.status, 403, JSON.stringify(r.body));
   assertEquals(r.body?.message, 'invitation_email_mismatch');
   const row = await invitationRow(id);
   assertEquals([row.status, row.failed_attempts], ['pending', 1]);
   assertEquals(await tenantsNamed('HTTP Inv Client Intruder'), 0);
});

t('used, revoked, expired and unknown tokens are indistinguishable', async () => {
   const user = await invitee('states');

   const used = await issueInvitation(f, user.email);
   const ok = await acceptCompany(user.token, used.token, 'HTTP Inv Client Used');
   assertEquals(ok.status, 200, JSON.stringify(ok.body));

   const revoked = await issueInvitation(f, user.email);
   const rv = await rest(f.owner.token, 'rpc/revoke_provider_invitation', {
      method: 'POST',
      body: { invitation_id: revoked.id },
      profile: 'public',
      headers: asProvider,
   });
   assertEquals(rv.status, 204, JSON.stringify(rv.body));

   const expired = await issueInvitation(f, user.email);
   await admin(`provider_invitation?id=eq.${expired.id}`, { method: 'PATCH', body: { expires_at: new Date(Date.now() - 60_000).toISOString() } });

   const states: [string, string][] = [
      ['used', used.token],
      ['revoked', revoked.token],
      ['expired', expired.token],
      ['unknown', randomToken()],
   ];
   tokens.push(...states.map(([, token]) => token));
   const accepts: RestResult[] = [];
   const previews: RestResult[] = [];
   for (const [state, token] of states) {
      accepts.push(refused(await acceptCompany(user.token, token, `HTTP Inv Client ${state}`), `accept ${state}`));
      previews.push(refused(await preview(user.token, token), `preview ${state}`));
   }
   for (const [i, [state]] of states.entries()) {
      assertEquals(accepts[i].status, 404, `${state}: ${JSON.stringify(accepts[i].body)}`);
      assertEquals(JSON.stringify(accepts[i].body), JSON.stringify(accepts[0].body), state);
      assertEquals([previews[i].status, previews[i].body], [200, { error: 'invitation_invalid' }], state);
   }
   assertEquals(accepts[0].body, { message: 'invitation_invalid' });
   for (const [state] of states.slice(1)) assertEquals(await tenantsNamed(`HTTP Inv Client ${state}`), 0);
   // A failed accept of an expired invitation is not a mismatch: nothing is counted.
   assertEquals((await invitationRow(expired.id)).failed_attempts, 0);
});

t('the accepting user cannot choose model, staff, roles, tenant or owner', async () => {
   const user = await invitee('forge');
   const { token, id } = await issueInvitation(f, user.email, {}, [{ user_id: f.staff[1].id, role_name: 'viewer' }]);
   tokens.push(token);
   const name = 'HTTP Inv Client Forged';

   // Inside the company: the database's allowlist (a JSON refusal, mapped to 400).
   const forged: Record<string, unknown> = {
      procurement_model: 'client',
      staff: JSON.stringify([{ user_id: f.stranger.id, role_name: 'management' }]),
      roles: 'management',
      tenant_id: f.provider,
      owner_id: f.stranger.id,
      client_code: 'ZZZ',
   };
   for (const [key, value] of Object.entries(forged)) {
      const r = refused(await accept(user.token, { token, company: { display_name: name, [key]: value }, plan_id: null }), `company.${key}`);
      assertEquals([r.status, r.body?.message], [400, 'invitation_payload_invalid'], `company.${key}: ${JSON.stringify(r.body)}`);
   }
   // Beside the company: the function's strict body, before any call.
   for (const key of ['procurement_model', 'staff', 'roles', 'tenant_id', 'owner_id', 'client_code', 'p_user', 'user_id']) {
      const r = refused(await accept(user.token, { token, company: { display_name: name }, plan_id: null, [key]: forged[key] ?? f.stranger.id }), key);
      assertEquals([r.status, r.body?.message], [400, 'invitation_payload_invalid'], `${key}: ${JSON.stringify(r.body)}`);
   }
   // A non-text value in the company.
   const nested = refused(await accept(user.token, { token, company: { display_name: name, phone: { x: 1 } }, plan_id: null }), 'nested');
   assertEquals(nested.status, 400);

   assertEquals(await tenantsNamed(name), 0);
   const row = await invitationRow(id);
   assertEquals([row.status, row.failed_attempts], ['pending', 0]);
});

t('the customer keeps only the staff it chooses (I2)', async () => {
   const user = await invitee('choose');
   const { token } = await issueInvitation(f, user.email, {}, [
      { user_id: f.staff[0].id, role_name: 'management' },
      { user_id: f.staff[1].id, role_name: 'coordinator' },
   ]);
   tokens.push(token);
   const p = await preview(user.token, token);
   assertEquals(p.status, 200, JSON.stringify(p.body));
   const listed = p.body.staff as { index: number; role_name: string }[];
   const coordinator = listed.find((s) => s.role_name === 'coordinator')!;

   // An index the preview did not give is the payload refusal, before anything is written.
   const name = 'HTTP Inv Client Chosen';
   const wrong = refused(await accept(user.token, { token, company: { display_name: name }, plan_id: null, staff: [9] }), 'staff index');
   assertEquals([wrong.status, wrong.body?.message], [400, 'invitation_payload_invalid']);

   const r = await accept(user.token, { token, company: { display_name: name }, plan_id: null, staff: [coordinator.index] });
   assertEquals(r.status, 200, JSON.stringify(r.body));
   const members = (await admin(`tenant_user?tenant_id=eq.${r.body.tenant_id}&select=user_id`)).body as { user_id: string }[];
   assertEquals(members.map((m) => m.user_id).sort(), [user.id, f.staff[1].id].sort());
});

t('concurrent acceptance creates one tenant', async () => {
   const user = await invitee('race');
   const { token } = await issueInvitation(f, user.email);
   tokens.push(token);
   const name = 'HTTP Inv Client Race';
   const answers = await Promise.all([acceptCompany(user.token, token, name), acceptCompany(user.token, token, name)]);
   answers.forEach((a, i) => a.status !== 200 && refused(a, `race ${i}`));
   assertEquals(answers.map((a) => a.status).sort(), [200, 404], JSON.stringify(answers.map((a) => a.body)));
   assertEquals(await tenantsNamed(name), 1);
});

t('brute force is throttled', async () => {
   // Preview: 30 per 10 minutes per user, refusals as JSON.
   const guesser = await invitee('guesser');
   for (let i = 1; i <= 30; i++) {
      const r = await preview(guesser.token, randomToken());
      assertEquals([r.status, r.body], [200, { error: 'invitation_invalid' }], `preview ${i}`);
   }
   const p31 = refused(await preview(guesser.token, randomToken()), 'preview 31');
   assertEquals([p31.status, p31.body], [200, { error: 'invitation_throttled' }]);

   // Accept: 10 per hour per user, 429 from the 11th, even with the user's own valid token.
   const own = await issueInvitation(f, guesser.email);
   tokens.push(own.token);
   for (let i = 1; i <= 10; i++) {
      const r = refused(await acceptCompany(guesser.token, randomToken(), 'HTTP Inv Client Guess'), `accept ${i}`);
      assertEquals(r.status, 404, `accept ${i}: ${JSON.stringify(r.body)}`);
   }
   const a11 = refused(await acceptCompany(guesser.token, own.token, 'HTTP Inv Client Guess'), 'accept 11');
   assertEquals([a11.status, a11.body?.message], [429, 'invitation_throttled']);
   assertEquals(await tenantsNamed('HTTP Inv Client Guess'), 0);
   const row = await invitationRow(own.id);
   assertEquals([row.status, row.failed_attempts], ['pending', 0]);

   // The throttle is the guesser's: another user is served.
   const other = await preview(f.stranger.token, randomToken());
   assertEquals(other.body, { error: 'invitation_invalid' });
});

t('ten failed attempts lock the invitation until it is resent', async () => {
   const user = await invitee('locked');
   const intruder = await invitee('lock-intruder');

   // Created through the function, as the provider would: an existing account gets a magic link.
   const before = await mailCount(user.email);
   const created = await edge(f.owner.token, 'provider-invitation', {
      headers: asProvider,
      body: { invitation: { email: user.email, company_name: 'HTTP Inv Locked Co', client_code: nextClientCode(), procurement_model: 'provider' } },
   });
   assertEquals(created.status, 201, JSON.stringify(created.body));
   const id = created.body.id as string;
   const first = await mailedInvitation(user.email, before);
   tokens.push(first.token);

   for (let i = 1; i <= 10; i++) {
      const r = refused(await acceptCompany(intruder.token, first.token, 'HTTP Inv Client Locked'), `intruder ${i}`);
      assertEquals([r.status, r.body?.message], [403, 'invitation_email_mismatch'], `intruder ${i}`);
   }
   assertEquals((await invitationRow(id)).failed_attempts, 10);

   // Locked: even the invited user is refused, like any dead token.
   const locked = refused(await acceptCompany(user.token, first.token, 'HTTP Inv Client Locked'), 'locked accept');
   assertEquals([locked.status, locked.body], [404, { message: 'invitation_invalid' }]);
   assertEquals((await preview(user.token, first.token)).body, { error: 'invitation_invalid' });

   // The provider resends: a new token by mail, the count forgotten, the old link dead.
   const mails = await mailCount(user.email);
   await new Promise((resolve) => setTimeout(resolve, 1100)); // Auth's per-address mail frequency (1 s)
   const resent = await edge(f.owner.token, `provider-invitation/${id}/resend`, { headers: asProvider, body: {} });
   assertEquals([resent.status, resent.body], [200, { id }]);
   const second = await mailedInvitation(user.email, mails);
   tokens.push(second.token);
   assertNotEquals(second.token, first.token);
   const row = await invitationRow(id);
   assertEquals([row.status, row.failed_attempts], ['pending', 0]);

   const old = refused(await acceptCompany(user.token, first.token, 'HTTP Inv Client Locked'), 'old token');
   assertEquals(old.status, 404);
   const ok = await acceptCompany(user.token, second.token, 'HTTP Inv Client Locked');
   assertEquals(ok.status, 200, JSON.stringify(ok.body));
   assertEquals(await tenantsNamed('HTTP Inv Client Locked'), 1);
});

t('open signup is closed by default', async () => {
   const email = invEmail('signup');
   const r = refused(
      await edge(null, 'create-account', {
         body: { account: { email, password: 'Demo1234!signup' }, company: { display_name: 'HTTP Inv Signup', email: invEmail('signup-co') } },
      }),
      'signup',
   );
   assertEquals([r.status, r.body?.message], [403, 'signup_closed'], JSON.stringify(r.body));
   assertEquals(await authUsersWithEmail(email), 0);
   assertEquals((await admin(`user?email=eq.${encodeURIComponent(email)}&select=id`)).body, []);
   assertEquals(await tenantsNamed('HTTP Inv Signup'), 0);
});

t('a client owner adds provider staff, not strangers, and cannot edit a shared profile', async () => {
   // The main client's owner (test 4), in its own tenant: the provider's staff member who was not
   // on the invitation is linked (Task 6); an account of nobody's company is not.
   const inClient = { 'x-tenant-id': main.client };
   const access = await refreshSession(main.session.refresh);
   const linked = await edge(access, 'user', { headers: inClient, body: { email: f.extraStaff.email } });
   assertEquals(linked.status, 201, JSON.stringify(linked.body));
   assertEquals(linked.body.user.id, f.extraStaff.id);
   const member = await admin(`tenant_user?tenant_id=eq.${main.client}&user_id=eq.${f.extraStaff.id}&select=user_id`);
   assertEquals(member.body.length, 1);
   assertEquals((await admin(`user_role?user_id=eq.${f.extraStaff.id}&select=role!inner(tenant_id)&role.tenant_id=eq.${main.client}`)).body, []);

   const stranger = refused(await edge(access, 'user', { headers: inClient, body: { email: f.stranger.email } }), 'link stranger');
   assertEquals([stranger.status, stranger.body?.message], [409, 'user_exists_elsewhere'], JSON.stringify(stranger.body));
   assertEquals((await admin(`tenant_user?tenant_id=eq.${main.client}&user_id=eq.${f.stranger.id}&select=user_id`)).body, []);

   const before = await authUserMetadata(f.extraStaff.id);
   const edit = refused(
      await edge(access, `user/${f.extraStaff.id}`, { method: 'PUT', headers: inClient, body: { user_metadata: { display_name: 'HTTP Inv pwned' } } }),
      'shared profile edit',
   );
   assertEquals([edit.status, edit.body?.message], [403, 'user_profile_shared'], JSON.stringify(edit.body));
   assertEquals(await authUserMetadata(f.extraStaff.id), before);
});

t('error bodies carry no token, hash or staff identity', async () => {
   assert(failures.length >= 60, `only ${failures.length} failing answers were collected`);
   const secrets: string[] = [];
   for (const token of new Set(tokens)) {
      const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token)));
      const hex = Array.from(hash, (b) => b.toString(16).padStart(2, '0')).join('');
      secrets.push(token, encodeURIComponent(token), hex, `\\\\x${hex}`, encodeBase64(hash));
   }
   const staff = [...f.staff, f.extraStaff];
   for (const s of staff) secrets.push(s.email, s.id);
   for (const { what, body } of failures) {
      const text = JSON.stringify(body) ?? '';
      for (const s of secrets) assert(!text.includes(s), `${what}: the error body carries a secret: ${text.slice(0, 200)}`);
   }
});

t('teardown', async () => {
   await invitationTeardown();
});
