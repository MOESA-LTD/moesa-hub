import { assert, assertEquals } from 'jsr:@std/assert@1';
import { clientIp, handler } from '../create-account/index.ts';
import { authorizedRequest, CALLER, jsonResponse, stubFetch } from './helpers.ts';

// Verify-first self-signup (Task 11, task-5-review I1): the sign-up proves the inbox before an
// account can be used. POST takes no password, invites the address and keeps the company in
// private.pending_signup (through service-only RPCs); POST /complete creates it, as the owner
// confirmed or edited it, once the link was followed.

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
   /** The pending sign-up public.pending_signup returns (any user). */
   pending?: unknown;
   /** The existing account owns a company. */
   ownsTenant?: boolean;
   /** signup_throttle's answer. */
   throttled?: boolean;
   /** The invite mail fails. */
   mailFails?: boolean;
   /** save_pending_signup fails. */
   saveFails?: boolean;
   /** For /complete: whether the caller's e-mail is confirmed. */
   callerConfirmed?: boolean;
   /** For /complete: complete_signup raises this key (or a unique violation on this constraint). */
   completeRaises?: string;
   uniqueViolation?: string;
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
         case '/rest/v1/rpc/pending_signup':
            return jsonResponse(opts.pending ?? null);
         case '/rest/v1/rpc/save_pending_signup':
            if (opts.saveFails) return jsonResponse({ code: '57014', message: 'canceling statement' }, 500);
            return new Response(null, { status: 204 });
         case '/rest/v1/user':
            return jsonResponse(opts.account ? [{ id: EXISTING }] : []);
         case '/rest/v1/tenant_owner':
            return jsonResponse(opts.ownsTenant ? [{ tenant_id: 'T' }] : []);
         case '/rest/v1/rpc/complete_signup':
            if (opts.completeRaises) return jsonResponse({ code: 'P0001', message: opts.completeRaises }, 400);
            if (opts.uniqueViolation)
               return jsonResponse(
                  { code: '23505', message: `duplicate key value violates unique constraint "${opts.uniqueViolation}"` },
                  409
               );
            return jsonResponse({ id: 'NEW-TENANT', display_name: 'New Company', email: 'company@example.test' });
         case '/auth/v1/admin/users':
            return jsonResponse({ id: NEW_USER, email: 'new@example.test' });
         case `/auth/v1/admin/users/${NEW_USER}`:
            return jsonResponse({});
         case '/auth/v1/invite':
            if (opts.mailFails) return jsonResponse({ code: 'unexpected_failure', msg: 'smtp down' }, 500);
            return jsonResponse({ id: NEW_USER, email: 'new@example.test' });
         case `/auth/v1/admin/users/${EXISTING}`:
            return jsonResponse({
               id: EXISTING,
               email: 'new@example.test',
               email_confirmed_at: opts.account === 'confirmed' ? '2026-01-01T00:00:00Z' : null
            });
         case `/auth/v1/admin/users/${CALLER}`:
            return jsonResponse({
               id: CALLER,
               email: 'new@example.test',
               app_metadata: { provider: 'email' },
               user_metadata: {},
               email_confirmed_at: opts.callerConfirmed === false ? null : '2026-11-19T00:01:00Z'
            });
         default:
            return jsonResponse({}, 404);
      }
   });
   return { seen, restore };
};

const post = (payload: unknown = body, headers: Record<string, string> = {}) =>
   new Request('http://localhost/create-account', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-forwarded-for': '6.6.6.6, 203.0.113.9', ...headers },
      body: JSON.stringify(payload)
   });

/** /create-account/complete as CALLER (or without a token). */
const complete = (payload: unknown = { plan_id: PLAN }, auth = true, method = 'POST') => {
   const headers = new Headers({ 'Content-Type': 'application/json' });
   if (auth) headers.set('Authorization', authorizedRequest().headers.get('Authorization')!);
   return new Request('http://localhost/create-account/complete', {
      method,
      headers,
      body: method === 'GET' ? undefined : JSON.stringify(payload)
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

const authWrites = (seen: Seen[]) => seen.filter((s) => s.path.startsWith('/auth/v1/') && s.method !== 'GET');
const pendingWrites = (seen: Seen[]) => seen.filter((s) => s.path === '/rest/v1/rpc/save_pending_signup');
const tenantWrites = (seen: Seen[]) =>
   seen.filter((s) => /register_tenant|complete_signup|create_company|\/rest\/v1\/tenant\b/.test(s.path) && s.method !== 'GET');

const PENDING = { company, plan_id: OTHER_PLAN, created_at: '2026-11-19T00:00:00Z' };

// --- GET and the closed setting ---------------------------------------------------------------

Deno.test('POST is refused with signup_closed when the setting is off', async () => {
   const { seen, restore } = backend({ open: false });
   try {
      const response = await respond(() => handler(post()));
      assertEquals(response.status, 403);
      assertEquals((await response.json()).message, 'signup_closed');
      assertEquals(seen.map((s) => s.path), ['/rest/v1/rpc/open_signup_enabled'], 'nothing else is called');
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
         assertEquals(pendingWrites(seen), []);
      } finally {
         restore();
      }
   }
});

Deno.test('the answer is identical for every kind of address', async () => {
   const answers: string[] = [];
   for (const opts of [
      {},
      { account: 'unconfirmed' as const, pending: PENDING },
      { account: 'unconfirmed' as const },
      { account: 'confirmed' as const }
   ]) {
      const { seen, restore } = backend(opts);
      try {
         const response = await handler(post());
         answers.push(`${response.status} ${response.headers.get('content-type')} ${await response.text()}`);
         assertEquals(tenantWrites(seen), [], `no tenant before completion (${JSON.stringify(opts)})`);
      } finally {
         restore();
      }
   }
   assertEquals(answers[0], `202 application/json ${JSON.stringify({ status: 'check_email' })}`);
   assertEquals(new Set(answers).size, 1, answers.join(' | '));
});

Deno.test('a new address: an unconfirmed account with no password, its pending sign-up saved server side, then the invite', async () => {
   const { seen, restore } = backend();
   try {
      assertEquals((await handler(post({ ...body, plan_id: PLAN }))).status, 202);
   } finally {
      restore();
   }
   const writes = seen.filter((s) => s.method !== 'GET' && !s.path.includes('open_signup') && !s.path.includes('throttle'));
   assertEquals(writes.map((s) => `${s.method} ${s.path}`), [
      'POST /auth/v1/admin/users',
      'POST /rest/v1/rpc/save_pending_signup',
      'POST /auth/v1/invite'
   ]);

   const created = JSON.parse(writes[0].body);
   assertEquals(created, { email: 'new@example.test', email_confirm: false }, 'no password, nothing in any metadata');
   assertEquals(JSON.parse(writes[1].body), { p_user: NEW_USER, p_company: company, p_plan_id: PLAN });

   const invite = writes[2];
   assertEquals(JSON.parse(invite.body).email, 'new@example.test');
   assert(!JSON.parse(invite.body).data, 'the invite carries no user_metadata');
   assertEquals(new URLSearchParams(invite.search).get('redirect_to'), 'http://localhost:6161/register/complete');
});

Deno.test('an account left without its pending sign-up is removed again', async () => {
   const { seen, restore } = backend({ saveFails: true });
   const original = console.error;
   console.error = () => {};
   try {
      assertEquals((await handler(post())).status, 202);
   } finally {
      console.error = original;
      restore();
   }
   assertEquals(authWrites(seen).map((s) => `${s.method} ${s.path}`), [
      'POST /auth/v1/admin/users',
      `DELETE /auth/v1/admin/users/${NEW_USER}`
   ]);
});

Deno.test('an earlier self-signup (unconfirmed, pending, owning nothing): replaced and re-invited', async () => {
   const { seen, restore } = backend({ account: 'unconfirmed', pending: PENDING });
   try {
      assertEquals((await handler(post())).status, 202);
   } finally {
      restore();
   }
   assertEquals(pendingWrites(seen).map((s) => JSON.parse(s.body)), [{ p_user: EXISTING, p_company: company, p_plan_id: null }]);
   assertEquals(authWrites(seen).map((s) => `${s.method} ${s.path}`), ['POST /auth/v1/invite']);
});

Deno.test('M1: an unconfirmed account a provider or a company invited (no pending sign-up) is left alone', async () => {
   const { seen, restore } = backend({ account: 'unconfirmed' });
   try {
      const response = await handler(post());
      assertEquals([response.status, await response.json()], [202, { status: 'check_email' }]);
   } finally {
      restore();
   }
   assertEquals(authWrites(seen), [], 'no re-invite: their invitation link keeps working');
   assertEquals(pendingWrites(seen), [], 'no sign-up is attached to them');
});

Deno.test('a confirmed account, or a pending one that owns a company, is left alone (no mail)', async () => {
   for (const opts of [{ account: 'confirmed' as const }, { account: 'unconfirmed' as const, pending: PENDING, ownsTenant: true }]) {
      const { seen, restore } = backend(opts);
      try {
         const response = await handler(post());
         assertEquals([response.status, await response.json()], [202, { status: 'check_email' }]);
         assertEquals(authWrites(seen), [], JSON.stringify(opts));
         assertEquals(pendingWrites(seen), [], JSON.stringify(opts));
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

Deno.test('the endpoint is throttled before anything is created, keyed on the address the proxy appended', async () => {
   const { seen, restore } = backend({ throttled: true });
   try {
      const response = await respond(() => handler(post()));
      assertEquals(response.status, 429);
      assertEquals((await response.json()).message, 'signup_throttled');
   } finally {
      restore();
   }
   const throttle = seen.find((s) => s.path === '/rest/v1/rpc/signup_throttle')!;
   // The client's own entry (6.6.6.6) is never trusted: the rightmost one is the proxy's.
   assertEquals(JSON.parse(throttle.body), { p_email: 'new@example.test', p_ip: '203.0.113.9' });
   assertEquals(authWrites(seen), []);
   assertEquals(pendingWrites(seen), []);
});

Deno.test('clientIp takes the rightmost x-forwarded-for entry', () => {
   const ip = (value?: string) =>
      clientIp(new Request('http://localhost', { headers: value === undefined ? {} : { 'x-forwarded-for': value } }));
   assertEquals(ip('1.1.1.1, 2.2.2.2 , 3.3.3.3'), '3.3.3.3');
   assertEquals(ip('9.9.9.9'), '9.9.9.9');
   assertEquals(ip('spoofed, '), 'spoofed');
   assertEquals(ip(''), '');
   assertEquals(ip(), '');
});

// --- /complete ------------------------------------------------------------------------------------

Deno.test('GET complete gives the pending company and plan, for the signed-in proven account only', async () => {
   const { seen, restore } = backend({ pending: PENDING });
   try {
      const response = await respond(() => handler(complete(undefined, true, 'GET')));
      assertEquals(response.status, 200);
      assertEquals(await response.json(), { company, plan_id: OTHER_PLAN });
   } finally {
      restore();
   }
   const read = seen.find((s) => s.path === '/rest/v1/rpc/pending_signup')!;
   assertEquals(JSON.parse(read.body), { p_user: CALLER });

   for (const [opts, auth, status, message] of [
      [{}, true, 409, 'signup_not_pending'],
      [{ pending: PENDING, callerConfirmed: false }, true, 403, 'signup_unconfirmed'],
      [{ pending: PENDING, open: false }, true, 403, 'signup_closed'],
      [{ pending: PENDING }, false, 401, 'unauthorized']
   ] as const) {
      const { restore } = backend(opts);
      try {
         const response = await respond(() => handler(complete(undefined, auth, 'GET')));
         assertEquals([response.status, (await response.json()).message], [status, message], JSON.stringify(opts));
      } finally {
         restore();
      }
   }
});

Deno.test('complete creates the pending company of a proven account with the chosen plan', async () => {
   const { seen, restore } = backend({ pending: PENDING });
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
   assertEquals(authWrites(seen), [], 'the account itself is not written');
   // The proof is read from Auth's admin API, never from the token's claims.
   assert(seen.some((s) => s.path === `/auth/v1/admin/users/${CALLER}` && s.method === 'GET'));
});

Deno.test('I1: complete uses the company as the owner edited it; the pending one is only the default', async () => {
   const edited = { display_name: 'Edited Company ', email: 'Other@Example.test', phone: '', tax_number: 'TR-1' };
   const { seen, restore } = backend({ pending: PENDING });
   try {
      assertEquals((await handler(complete({ company: edited, plan_id: null }))).status, 201);
   } finally {
      restore();
   }
   const rpc = seen.find((s) => s.path === '/rest/v1/rpc/complete_signup')!;
   assertEquals(JSON.parse(rpc.body), {
      p_user: CALLER,
      p_company: { display_name: 'Edited Company', email: 'other@example.test', tax_number: 'TR-1' },
      p_plan_id: null
   });
});

Deno.test('an edited company passes the same allowlist', async () => {
   for (const edited of [
      { ...company, tenant_id: 'T' },
      { ...company, owner_id: CALLER },
      { display_name: 'ab', email: 'x@y.test' },
      { display_name: 'Fine Name', email: 'not-an-email' },
      { display_name: 'Fine Name', email: 'x@y.test', city: 7 }
   ]) {
      const { seen, restore } = backend({ pending: PENDING });
      try {
         const response = await respond(() => handler(complete({ company: edited, plan_id: PLAN })));
         assertEquals([response.status, (await response.json()).message], [400, 'signup_payload_invalid'], JSON.stringify(edited));
         assertEquals(tenantWrites(seen), []);
      } finally {
         restore();
      }
   }
});

Deno.test('complete without a plan in the body takes the one asked for at sign-up', async () => {
   const { seen, restore } = backend({ pending: PENDING });
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
      ['unconfirmed', { pending: PENDING, callerConfirmed: false }, complete(), 403, 'signup_unconfirmed'],
      ['nothing pending', {}, complete(), 409, 'signup_not_pending'],
      ['closed since', { open: false, pending: PENDING }, complete(), 403, 'signup_closed'],
      ['no token', { pending: PENDING }, complete({ plan_id: PLAN }, false), 401, 'unauthorized'],
      ['unknown key', { pending: PENDING }, complete({ plan_id: PLAN, user_id: CALLER }), 400, 'signup_payload_invalid'],
      ['bad plan id', { pending: PENDING }, complete({ plan_id: 'x' }), 400, 'signup_payload_invalid']
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

Deno.test('the refusals of complete_signup keep their meaning', async () => {
   for (const [opts, status, key] of [
      [{ completeRaises: 'signup_completed' }, 409, 'signup_completed'],
      [{ completeRaises: 'signup_not_pending' }, 409, 'signup_not_pending'],
      [{ completeRaises: 'signup_closed' }, 403, 'signup_closed'],
      [{ completeRaises: 'signup_unconfirmed' }, 403, 'signup_unconfirmed'],
      [{ completeRaises: 'plan_inactive' }, 400, 'plan_inactive'],
      [{ completeRaises: 'company_payload_invalid' }, 400, 'company_payload_invalid'],
      [{ uniqueViolation: 'tenant_email_key' }, 409, 'company_email_exists'],
      [{ uniqueViolation: 'tenant_phone_key' }, 409, 'company_phone_exists']
   ] as const) {
      const { restore } = backend({ pending: PENDING, ...opts });
      try {
         const response = await respond(() => handler(complete()));
         assertEquals([response.status, (await response.json()).message], [status, key]);
      } finally {
         restore();
      }
   }
});

Deno.test('unknown routes and methods are refused', async () => {
   const { restore } = backend();
   try {
      for (const [method, path, status] of [
         ['PUT', '/create-account/complete', 405],
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
