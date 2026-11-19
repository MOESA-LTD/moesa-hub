import { assert, assertEquals } from 'jsr:@std/assert@1';
import { handler } from '../create-account/index.ts';
import { authorizedRequest, CALLER, jsonResponse, stubFetch } from './helpers.ts';

// Verify-first self-signup (Task 11, task-5-review I1): the sign-up proves the inbox before an
// account can be used. POST takes no password, invites the address and keeps the company in
// app_metadata; POST /complete creates it once the link was followed.

Deno.env.set('SITE_URL', 'http://localhost:6161');

const EXISTING = '00000000-0000-4000-8000-0000000000bb';
const NEW_USER = '00000000-0000-4000-8000-0000000000cc';
const PLAN = '00000000-0000-4000-8000-0000000000d1';
const OTHER_PLAN = '00000000-0000-4000-8000-0000000000d2';

const company = { display_name: 'New Company', email: 'company@example.test', city: 'Bursa' };
const body = { account: { email: 'New@Example.test ' }, company };

type Seen = { method: string; path: string; search: string; body: string };

type Opts = {
   /** open_signup_enabled. */
   open?: boolean;
   /** The address already has an account: confirmed or not. */
   account?: 'confirmed' | 'unconfirmed';
   /** The existing account owns a company. */
   ownsTenant?: boolean;
   /** signup_throttle's answer. */
   throttled?: boolean;
   /** The invite mail fails. */
   mailFails?: boolean;
   /** For /complete: the caller's account as GoTrue's admin API returns it. */
   caller?: { email_confirmed_at: string | null; app_metadata?: Record<string, unknown> };
   /** For /complete: complete_signup raises this key. */
   completeRaises?: string;
};

const backend = (opts: Opts = {}) => {
   const seen: Seen[] = [];
   const restore = stubFetch((url, init) => {
      const method = init?.method ?? 'GET';
      seen.push({ method, path: url.pathname, search: url.search, body: init?.body ? String(init.body) : '' });
      switch (url.pathname) {
         case '/rest/v1/rpc/open_signup_enabled':
            return jsonResponse(opts.open ?? true);
         case '/rest/v1/rpc/signup_throttle':
            return jsonResponse(!opts.throttled);
         case '/rest/v1/user':
            return jsonResponse(opts.account ? [{ id: EXISTING }] : []);
         case '/rest/v1/tenant_owner':
            return jsonResponse(opts.ownsTenant ? [{ tenant_id: 'T' }] : []);
         case '/rest/v1/rpc/complete_signup':
            if (opts.completeRaises) return jsonResponse({ code: 'P0001', message: opts.completeRaises }, 400);
            return jsonResponse({ id: 'NEW-TENANT', display_name: 'New Company', email: 'company@example.test' });
         case '/auth/v1/admin/users':
            return jsonResponse({ id: NEW_USER, email: 'new@example.test' });
         case '/auth/v1/invite':
            if (opts.mailFails) return jsonResponse({ code: 'unexpected_failure', msg: 'smtp down' }, 500);
            return jsonResponse({ id: NEW_USER, email: 'new@example.test' });
         case `/auth/v1/admin/users/${EXISTING}`:
            if (method === 'GET')
               return jsonResponse({
                  id: EXISTING,
                  email: 'new@example.test',
                  email_confirmed_at: opts.account === 'confirmed' ? '2026-01-01T00:00:00Z' : null
               });
            return jsonResponse({ id: EXISTING });
         case `/auth/v1/admin/users/${CALLER}`:
            if (method === 'GET')
               return jsonResponse({
                  id: CALLER,
                  email: 'new@example.test',
                  app_metadata: { provider: 'email' },
                  user_metadata: {},
                  ...opts.caller
               });
            return jsonResponse({ id: CALLER });
         default:
            return jsonResponse({}, 404);
      }
   });
   return { seen, restore };
};

const post = (payload: unknown = body, headers: Record<string, string> = {}) =>
   new Request('http://localhost/create-account', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-forwarded-for': '203.0.113.9, 10.0.0.1', ...headers },
      body: JSON.stringify(payload)
   });

/** POST /create-account/complete as CALLER (or without a token). */
const complete = (payload: unknown = { plan_id: PLAN }, auth = true) => {
   const headers = new Headers({ 'Content-Type': 'application/json' });
   if (auth) headers.set('Authorization', authorizedRequest().headers.get('Authorization')!);
   return new Request('http://localhost/create-account/complete', {
      method: 'POST',
      headers,
      body: JSON.stringify(payload)
   });
};

/** Runs the handler like serve() would: thrown errors become their response. */
const respond = async (run: () => Promise<Response>) => {
   const { errorResponse } = await import('../_shared/http.ts');
   try {
      return await run();
   } catch (error) {
      return errorResponse(error);
   }
};

const authWrites = (seen: Seen[]) =>
   seen.filter((s) => s.path.startsWith('/auth/v1/') && s.method !== 'GET');
const tenantWrites = (seen: Seen[]) =>
   seen.filter((s) => /register_tenant|complete_signup|create_company|\/rest\/v1\/tenant\b/.test(s.path) && s.method !== 'GET');

const pendingOf = (s: Seen) => JSON.parse(s.body).app_metadata?.pending_company;

// --- GET and the closed setting ---------------------------------------------------------------

Deno.test('POST is refused with signup_closed when the setting is off', async () => {
   const { seen, restore } = backend({ open: false });
   try {
      const response = await respond(() => handler(post()));
      assertEquals(response.status, 403);
      assertEquals((await response.json()).message, 'signup_closed');
      assertEquals(
         seen.map((s) => s.path),
         ['/rest/v1/rpc/open_signup_enabled'],
         'nothing else is called'
      );
   } finally {
      restore();
   }
});

Deno.test('GET reports the setting', async () => {
   for (const open of [false, true]) {
      const { restore } = backend({ open });
      try {
         const response = await handler(new Request('http://localhost/create-account'));
         assertEquals(response.status, 200);
         assertEquals(await response.json(), { open });
      } finally {
         restore();
      }
   }
});

// --- POST: no password, no tenant, one answer ----------------------------------------------------

Deno.test('POST never accepts a password', async () => {
   for (const payload of [
      { ...body, account: { ...body.account, password: 'attacker-pass-1' } },
      { ...body, password: 'attacker-pass-1' },
      { ...body, account: { ...body.account, user_metadata: { x: 1 } } },
      { ...body, company: { ...company, tenant_id: 'T' } },
      { account: body.account }
   ]) {
      const { seen, restore } = backend();
      try {
         const response = await respond(() => handler(post(payload)));
         assertEquals(response.status, 400, JSON.stringify(payload));
         assertEquals((await response.json()).message, 'signup_payload_invalid');
         assertEquals(authWrites(seen), [], 'no account is created or mailed');
      } finally {
         restore();
      }
   }
});

Deno.test('the answer is identical for a new, an unconfirmed and a confirmed address', async () => {
   const answers: string[] = [];
   for (const account of [undefined, 'unconfirmed', 'confirmed'] as const) {
      const { seen, restore } = backend({ account });
      try {
         const response = await handler(post());
         answers.push(`${response.status} ${response.headers.get('content-type')} ${await response.text()}`);
         assertEquals(tenantWrites(seen), [], `no tenant before completion (${account ?? 'new'})`);
      } finally {
         restore();
      }
   }
   assertEquals(answers[0], `202 application/json ${JSON.stringify({ status: 'check_email' })}`);
   assertEquals(new Set(answers).size, 1, answers.join(' | '));
});

Deno.test('a new address: an unconfirmed account with no password, the company in app_metadata, then the invite', async () => {
   const { seen, restore } = backend();
   try {
      assertEquals((await handler(post({ ...body, plan_id: PLAN }))).status, 202);
   } finally {
      restore();
   }
   const writes = authWrites(seen);
   assertEquals(writes.map((s) => `${s.method} ${s.path}`), ['POST /auth/v1/admin/users', 'POST /auth/v1/invite']);

   const created = JSON.parse(writes[0].body);
   assertEquals(created.email, 'new@example.test', 'trimmed and lower-cased');
   assertEquals(created.email_confirm, false);
   assert(!('password' in created), 'no password');
   assert(!('user_metadata' in created) && !('data' in created), 'nothing in user_metadata');
   assertEquals(pendingOf(writes[0]).company, company);
   assertEquals(pendingOf(writes[0]).plan_id, PLAN);

   const invite = writes[1];
   assertEquals(JSON.parse(invite.body).email, 'new@example.test');
   assert(!JSON.parse(invite.body).data, 'the invite carries no user_metadata');
   assertEquals(new URLSearchParams(invite.search).get('redirect_to'), 'http://localhost:6161/register/complete');
});

Deno.test('an unconfirmed account that owns nothing: the pending company is replaced and the address re-invited', async () => {
   const { seen, restore } = backend({ account: 'unconfirmed' });
   try {
      assertEquals((await handler(post())).status, 202);
   } finally {
      restore();
   }
   const writes = authWrites(seen);
   assertEquals(writes.map((s) => `${s.method} ${s.path}`), [`PUT /auth/v1/admin/users/${EXISTING}`, 'POST /auth/v1/invite']);
   const update = JSON.parse(writes[0].body);
   assertEquals(Object.keys(update), ['app_metadata'], 'app_metadata only: no password, no user_metadata');
   assertEquals(update.app_metadata.pending_company.company, company);
   assertEquals(update.app_metadata.pending_company.plan_id, null);
});

Deno.test('a confirmed account, or an unconfirmed one that owns a company, is left alone (no mail)', async () => {
   for (const opts of [{ account: 'confirmed' as const }, { account: 'unconfirmed' as const, ownsTenant: true }]) {
      const { seen, restore } = backend(opts);
      try {
         const response = await handler(post());
         assertEquals(response.status, 202);
         assertEquals(await response.json(), { status: 'check_email' });
         assertEquals(authWrites(seen), [], JSON.stringify(opts));
      } finally {
         restore();
      }
   }
});

Deno.test('a failed mail is logged, not told: the answer stays the same', async () => {
   const { restore } = backend({ mailFails: true });
   const errors: unknown[][] = [];
   const original = console.error;
   console.error = (...args: unknown[]) => errors.push(args);
   try {
      const response = await handler(post());
      assertEquals(response.status, 202);
      assertEquals(await response.json(), { status: 'check_email' });
   } finally {
      console.error = original;
      restore();
   }
   assert(errors.length > 0, 'the failure is logged');
   assert(!JSON.stringify(errors).includes('company@example.test'), 'without the input');
});

Deno.test('the endpoint is throttled per address and client before anything is created', async () => {
   const { seen, restore } = backend({ throttled: true });
   try {
      const response = await respond(() => handler(post()));
      assertEquals(response.status, 429);
      assertEquals((await response.json()).message, 'signup_throttled');
   } finally {
      restore();
   }
   const throttle = seen.find((s) => s.path === '/rest/v1/rpc/signup_throttle')!;
   assertEquals(JSON.parse(throttle.body), { p_email: 'new@example.test', p_ip: '203.0.113.9' });
   assertEquals(authWrites(seen), []);
});

// --- POST /complete ------------------------------------------------------------------------------

const PENDING = { pending_company: { company, plan_id: OTHER_PLAN, requested_at: '2026-11-19T00:00:00Z' } };
const proven = { email_confirmed_at: '2026-11-19T00:01:00Z', app_metadata: { provider: 'email', ...PENDING } };

Deno.test('complete creates the company of a proven account with the chosen plan, then forgets the pending one', async () => {
   const { seen, restore } = backend({ caller: proven });
   let response!: Response;
   try {
      response = await handler(complete());
   } finally {
      restore();
   }
   assertEquals(response.status, 201);
   assertEquals(await response.json(), { tenant: { id: 'NEW-TENANT', display_name: 'New Company' } });

   const rpc = seen.filter((s) => s.path === '/rest/v1/rpc/complete_signup');
   assertEquals(rpc.length, 1, 'exactly once');
   assertEquals(JSON.parse(rpc[0].body), { p_user: CALLER, p_company: company, p_plan_id: PLAN });

   const clear = seen.filter((s) => s.path === `/auth/v1/admin/users/${CALLER}` && s.method === 'PUT');
   assertEquals(clear.map((s) => JSON.parse(s.body)), [{ app_metadata: { pending_company: null } }]);
   // The proof is read from Auth's admin API, never from the token's claims.
   assert(seen.some((s) => s.path === `/auth/v1/admin/users/${CALLER}` && s.method === 'GET'));
});

Deno.test('complete without a plan in the body takes the one asked for at sign-up', async () => {
   const { seen, restore } = backend({ caller: proven });
   try {
      assertEquals((await handler(complete({}))).status, 201);
   } finally {
      restore();
   }
   const rpc = seen.find((s) => s.path === '/rest/v1/rpc/complete_signup')!;
   assertEquals(JSON.parse(rpc.body).p_plan_id, OTHER_PLAN);
});

Deno.test('complete refuses an unconfirmed account, one with nothing pending, closed signup and no token', async () => {
   const cases: [string, Opts, Request, number, string][] = [
      ['unconfirmed', { caller: { ...proven, email_confirmed_at: null } }, complete(), 403, 'signup_unconfirmed'],
      ['nothing pending', { caller: { ...proven, app_metadata: { provider: 'email' } } }, complete(), 409, 'signup_not_pending'],
      ['cleared pending', { caller: { ...proven, app_metadata: { pending_company: null } } }, complete(), 409, 'signup_not_pending'],
      ['pending in user_metadata only', { caller: { email_confirmed_at: proven.email_confirmed_at, app_metadata: {}, user_metadata: PENDING } as Opts['caller'] }, complete(), 409, 'signup_not_pending'],
      ['closed since', { open: false, caller: proven }, complete(), 403, 'signup_closed'],
      ['no token', { caller: proven }, complete({ plan_id: PLAN }, false), 401, 'unauthorized'],
      ['company in the body', { caller: proven }, complete({ plan_id: PLAN, company }), 400, 'signup_payload_invalid'],
      ['bad plan id', { caller: proven }, complete({ plan_id: 'x' }), 400, 'signup_payload_invalid']
   ];
   for (const [what, opts, request, status, message] of cases) {
      const { seen, restore } = backend(opts);
      try {
         const response = await respond(() => handler(request));
         assertEquals([response.status, (await response.json()).message], [status, message], what);
         assertEquals(tenantWrites(seen), [], `${what}: no company`);
         assertEquals(authWrites(seen), [], `${what}: the account is untouched`);
      } finally {
         restore();
      }
   }
});

Deno.test('the database refusals of complete keep their meaning', async () => {
   for (const [key, status] of [
      ['signup_completed', 409],
      ['signup_closed', 403],
      ['signup_unconfirmed', 403],
      ['plan_inactive', 400],
      ['company_payload_invalid', 400]
   ] as const) {
      const { seen, restore } = backend({ caller: proven, completeRaises: key });
      try {
         const response = await respond(() => handler(complete()));
         assertEquals([response.status, (await response.json()).message], [status, key]);
         assertEquals(authWrites(seen), [], `${key}: the pending company is kept`);
      } finally {
         restore();
      }
   }
});

Deno.test('unknown routes and methods are refused', async () => {
   const { restore } = backend();
   try {
      for (const [method, path, status] of [
         ['GET', '/create-account/complete', 405],
         ['POST', '/create-account/other', 404],
         ['DELETE', '/create-account', 405]
      ] as const) {
         const response = await respond(() => handler(new Request(`http://localhost${path}`, { method })));
         assertEquals(response.status, status, `${method} ${path}`);
         await response.body?.cancel();
      }
   } finally {
      restore();
   }
});
