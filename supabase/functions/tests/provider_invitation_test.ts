import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { errorResponse } from '../_shared/http.ts';
import { handler } from '../provider-invitation/index.ts';
import { authorizedRequest, CALLER, jsonResponse, stubFetch, TENANT } from './helpers.ts';

Deno.env.set('SITE_URL', 'http://localhost:6161');

/** The stubbed token, distinctive enough to be searched for in every body and log line. */
const SECRET = 'tok_SECRET-4f9a_zz';
const INVITATION = '00000000-0000-4000-8000-0000000000c1';
const EXISTING = '00000000-0000-4000-8000-0000000000bb';

type Seen = {
   method: string;
   path: string;
   search: string;
   headers: Headers;
   body: string;
};

type Opts = {
   /** The token the create / rotate RPC hands out. */
   token?: string;
   /** Whether public.user has an account with the address. */
   existingUser?: boolean;
   /** The existing account was invited but never confirmed its e-mail (default: confirmed). */
   unconfirmed?: boolean;
   /** The mail call (OTP or invite) fails. */
   mailFails?: boolean;
   /** A PostgREST error the create / rotate RPC answers with. */
   rpcError?: { status: number; code: string; message: string };
   /** What accept_provider_invitation returns. */
   accept?: unknown;
};

/** Answers what the provider-invitation function reads and writes. */
const backend = (opts: Opts = {}) => {
   const seen: Seen[] = [];
   const token = opts.token ?? SECRET;
   const restore = stubFetch((url, init) => {
      const method = init?.method ?? 'GET';
      seen.push({
         method,
         path: url.pathname,
         search: url.search,
         headers: new Headers(init?.headers),
         body: init?.body ? String(init.body) : ''
      });
      const fail = opts.rpcError;
      switch (url.pathname) {
         case '/rest/v1/rpc/create_provider_invitation':
            if (fail) return jsonResponse({ code: fail.code, message: fail.message }, fail.status);
            return jsonResponse({ id: 'I', token });
         case '/rest/v1/rpc/rotate_provider_invitation_token':
            if (fail) return jsonResponse({ code: fail.code, message: fail.message }, fail.status);
            return jsonResponse(token);
         case '/rest/v1/rpc/revoke_unsent_provider_invitation':
            return new Response(null, { status: 204 });
         case '/rest/v1/rpc/accept_provider_invitation':
            return jsonResponse(opts.accept ?? { tenant_id: 'NEW-TENANT', skipped_staff: [] });
         case '/rest/v1/provider_invitation':
            return jsonResponse([{ email: 'new@client.test' }]);
         case '/rest/v1/user':
            return jsonResponse(opts.existingUser ? [{ id: EXISTING }] : []);
         case '/auth/v1/otp':
         case '/auth/v1/invite':
            if (opts.mailFails)
               return jsonResponse({ code: 'unexpected_failure', msg: `smtp down ${url.search}` }, 500);
            return jsonResponse(
               url.pathname === '/auth/v1/otp' ? {} : { id: EXISTING, email: 'new@client.test' }
            );
         case `/auth/v1/admin/users/${EXISTING}`:
            return jsonResponse({
               id: EXISTING,
               email: 'new@client.test',
               email_confirmed_at: opts.unconfirmed ? null : '2026-01-01T00:00:00Z'
            });
         default:
            return jsonResponse({}, 404);
      }
   });
   return { seen, restore };
};

/** A request to `path` with the caller's token (holding `permissions`) and a JSON body. */
const request = (
   path: string,
   body: unknown,
   permissions: [string, string][] = [],
   init: { method?: string; auth?: boolean } = {}
) => {
   const authorized = authorizedRequest(...permissions);
   const headers = new Headers({ 'Content-Type': 'application/json' });
   if (init.auth !== false) headers.set('Authorization', authorized.headers.get('Authorization')!);
   return new Request(`http://localhost${path}`, {
      method: init.method ?? 'POST',
      headers,
      body: init.method === 'GET' ? undefined : JSON.stringify(body)
   });
};

const INSERT: [string, string] = ['insert', 'provider_invitation'];
const UPDATE: [string, string] = ['update', 'provider_invitation'];

const createBody = {
   invitation: {
      email: 'New@Client.test ',
      company_name: 'New Ltd',
      client_code: 'NEW',
      procurement_model: 'provider'
   },
   staff: []
};

// What the serve wrapper does with a thrown error.
const respond = (response: Promise<Response>) => response.catch(errorResponse);

/** Runs `fn` with every console channel captured; returns what was written. */
const captureLogs = async (fn: () => Promise<void>) => {
   const written: string[] = [];
   const channels = ['log', 'error', 'warn', 'info', 'debug'] as const;
   const saved = channels.map((c) => console[c]);
   for (const c of channels)
      console[c] = (...args: unknown[]) => {
         written.push(args.map((a) => (a instanceof Error ? `${a.message} ${a.stack}` : Deno.inspect(a, { depth: 10 }))).join(' '));
      };
   try {
      await fn();
   } finally {
      channels.forEach((c, i) => (console[c] = saved[i]));
   }
   return written.join('\n');
};

const rpcCalls = (seen: Seen[]) => seen.filter((s) => s.path.startsWith('/rest/v1/rpc/'));
const mailCalls = (seen: Seen[]) => seen.filter((s) => s.path.startsWith('/auth/v1/'));

// ------------------------------------------------------------------------------------------
// The brief's tests.

Deno.test('create never returns the token', async () => {
   const { restore } = backend({ token: 'T' });
   let body: unknown;
   try {
      const res = await handler(request('/provider-invitation', createBody, [INSERT]));
      assertEquals(res.status, 201);
      body = await res.json();
   } finally {
      restore();
   }
   assertEquals(body, { id: 'I' });
   assert(!JSON.stringify(body).includes('T'));
});

Deno.test('an existing address gets a magic link, not an invite', async () => {
   const { seen, restore } = backend({ token: 'T', existingUser: true });
   try {
      assertEquals((await handler(request('/provider-invitation', createBody, [INSERT]))).status, 201);
   } finally {
      restore();
   }
   const otp = seen.find((s) => s.path === '/auth/v1/otp');
   assert(otp, 'signInWithOtp was called');
   const sent = JSON.parse(otp.body);
   assertEquals(sent.email, 'new@client.test');
   assertEquals(sent.create_user, false);
   const redirect = new URLSearchParams(otp.search).get('redirect_to') ?? '';
   assert(redirect.endsWith('/invitation/T'), redirect);
   assertEquals(redirect, 'http://localhost:6161/invitation/T');
   assert(!seen.some((s) => s.path === '/auth/v1/invite'), 'inviteUserByEmail not called');
   // The address is looked up by the service, normalised as the database stores it.
   const lookup = seen.find((s) => s.path === '/rest/v1/user');
   assertEquals(new URLSearchParams(lookup?.search).get('email'), 'eq.new@client.test');
});

Deno.test('a new address gets an invite e-mail', async () => {
   const { seen, restore } = backend({ token: 'T' });
   try {
      assertEquals((await handler(request('/provider-invitation', createBody, [INSERT]))).status, 201);
   } finally {
      restore();
   }
   const invite = seen.find((s) => s.path === '/auth/v1/invite');
   assert(invite, 'inviteUserByEmail was called');
   assertEquals(JSON.parse(invite.body).email, 'new@client.test');
   assertEquals(
      new URLSearchParams(invite.search).get('redirect_to'),
      'http://localhost:6161/invitation/T'
   );
   assert(!seen.some((s) => s.path === '/auth/v1/otp'), 'no magic link');
});

Deno.test('an invited account that never confirmed is invited again, not sent a magic link', async () => {
   // Supabase Auth refuses a magic link to an unconfirmed account while sign-ups are off; it
   // re-sends an invitation to one instead.
   const { seen, restore } = backend({ existingUser: true, unconfirmed: true });
   try {
      assertEquals((await handler(request('/provider-invitation', createBody, [INSERT]))).status, 201);
   } finally {
      restore();
   }
   assert(seen.some((s) => s.path === '/auth/v1/invite'), 'inviteUserByEmail was called');
   assert(!seen.some((s) => s.path === '/auth/v1/otp'), 'no magic link');
});

Deno.test('a mail failure revokes the invitation', async () => {
   const { seen, restore } = backend({ mailFails: true });
   let res!: Response;
   try {
      res = await respond(handler(request('/provider-invitation', createBody, [INSERT])));
   } finally {
      restore();
   }
   assertEquals(res.status, 502);
   assertEquals((await res.json()).message, 'invitation_mail_failed');
   const revoke = seen.find((s) => s.path === '/rest/v1/rpc/revoke_unsent_provider_invitation');
   assert(revoke, 'the invitation was revoked');
   assertEquals(JSON.parse(revoke.body), { p_invitation: 'I', p_actor: CALLER });
   assertEquals(revoke.headers.get('x-audit-actor'), CALLER);
});

Deno.test('a caller without insert is refused 403 before any RPC', async () => {
   const { seen, restore } = backend();
   let res!: Response;
   try {
      res = await respond(handler(request('/provider-invitation', createBody, [UPDATE])));
   } finally {
      restore();
   }
   assertEquals(res.status, 403);
   assertEquals(rpcCalls(seen), []);
   assertEquals(mailCalls(seen), []);
});

// ------------------------------------------------------------------------------------------
// Create and resend: who acts, and the audit label (F27).

Deno.test('create acts for the caller in the active tenant, and the audit names the caller', async () => {
   const { seen, restore } = backend();
   try {
      await handler(request('/provider-invitation', createBody, [INSERT]));
   } finally {
      restore();
   }
   const create = seen.find((s) => s.path === '/rest/v1/rpc/create_provider_invitation')!;
   const args = JSON.parse(create.body);
   assertEquals(args.p_tenant, TENANT);
   assertEquals(args.p_actor, CALLER);
   // The address the link is mailed to is the one stored: trimmed and lower-cased.
   assertEquals(args.p_invitation, { ...createBody.invitation, email: 'new@client.test' });
   assertEquals(args.p_staff, []);
   assertEquals(create.headers.get('x-audit-role'), 'provider-invitation');
   assertEquals(create.headers.get('x-audit-actor'), CALLER);
   assertEquals(create.headers.get('x-audit-actor'), args.p_actor);
   // The service key, never the caller's token, carries the RPC (it is service-only).
   assertEquals(create.headers.get('Authorization'), 'Bearer service');
});

Deno.test('create refuses unknown body keys with 400 before any RPC', async () => {
   for (const body of [
      { ...createBody, p_actor: 'x' },
      { ...createBody, tenant_id: TENANT },
      { staff: [] },
      'not an object'
   ]) {
      const { seen, restore } = backend();
      let res!: Response;
      try {
         res = await respond(handler(request('/provider-invitation', body, [INSERT])));
      } finally {
         restore();
      }
      assertEquals(res.status, 400, JSON.stringify(body));
      assertEquals((await res.json()).message, 'invitation_payload_invalid');
      assertEquals(rpcCalls(seen), []);
   }
});

Deno.test('resend needs update', async () => {
   const { seen, restore } = backend();
   let res!: Response;
   try {
      res = await respond(
         handler(request(`/provider-invitation/${INVITATION}/resend`, {}, [INSERT, ['select', 'provider_invitation']]))
      );
   } finally {
      restore();
   }
   assertEquals(res.status, 403);
   assertEquals(rpcCalls(seen), []);
   assertEquals(mailCalls(seen), []);
});

Deno.test('resend rotates as the caller, mails the new link and returns only the id', async () => {
   const { seen, restore } = backend({ existingUser: true });
   let res!: Response;
   try {
      res = await handler(request(`/provider-invitation/${INVITATION}/resend`, {}, [UPDATE]));
   } finally {
      restore();
   }
   assertEquals(res.status, 200);
   const text = await res.text();
   assertEquals(JSON.parse(text), { id: INVITATION });
   assert(!text.includes(SECRET));
   const rotate = seen.find((s) => s.path === '/rest/v1/rpc/rotate_provider_invitation_token')!;
   assertEquals(JSON.parse(rotate.body), { p_invitation: INVITATION, p_actor: CALLER });
   assertEquals(rotate.headers.get('x-audit-role'), 'provider-invitation');
   assertEquals(rotate.headers.get('x-audit-actor'), CALLER);
   // The invitation's address is read in the caller's active tenant only.
   const read = seen.find((s) => s.path === '/rest/v1/provider_invitation')!;
   const params = new URLSearchParams(read.search);
   assertEquals(params.get('id'), `eq.${INVITATION}`);
   assertEquals(params.get('tenant_id'), `eq.${TENANT}`);
   const otp = seen.find((s) => s.path === '/auth/v1/otp')!;
   assertEquals(
      new URLSearchParams(otp.search).get('redirect_to'),
      `http://localhost:6161/invitation/${SECRET}`
   );
});

Deno.test('a resend whose mail fails answers 502 and leaves the invitation pending', async () => {
   const { seen, restore } = backend({ mailFails: true });
   let res!: Response;
   try {
      res = await respond(handler(request(`/provider-invitation/${INVITATION}/resend`, {}, [UPDATE])));
   } finally {
      restore();
   }
   assertEquals(res.status, 502);
   assertEquals((await res.json()).message, 'invitation_mail_failed');
   assert(!seen.some((s) => s.path.includes('revoke')), 'a failed resend does not revoke');
});

Deno.test('resend refuses a malformed id and a body with keys', async () => {
   for (const [path, body] of [
      ['/provider-invitation/not-a-uuid/resend', {}],
      [`/provider-invitation/${INVITATION}/resend`, { token: 'x' }]
   ] as const) {
      const { seen, restore } = backend();
      let res!: Response;
      try {
         res = await respond(handler(request(path, body, [UPDATE])));
      } finally {
         restore();
      }
      assertEquals(res.status, path.includes('not-a-uuid') ? 404 : 400, path);
      assertEquals(rpcCalls(seen), []);
   }
});

Deno.test('the link encodes the token as one path segment', async () => {
   const { seen, restore } = backend({ token: 'a/b?c#d' });
   try {
      await handler(request('/provider-invitation', createBody, [INSERT]));
   } finally {
      restore();
   }
   const invite = seen.find((s) => s.path === '/auth/v1/invite')!;
   assertEquals(
      new URLSearchParams(invite.search).get('redirect_to'),
      'http://localhost:6161/invitation/a%2Fb%3Fc%23d'
   );
});

Deno.test('without SITE_URL nothing is created', async () => {
   const site = Deno.env.get('SITE_URL')!;
   Deno.env.delete('SITE_URL');
   const { seen, restore } = backend();
   let res!: Response;
   try {
      res = await respond(handler(request('/provider-invitation', createBody, [INSERT])));
   } finally {
      restore();
      Deno.env.set('SITE_URL', site);
   }
   assertEquals(res.status, 500);
   assertEquals(rpcCalls(seen), []);
});

// ------------------------------------------------------------------------------------------
// Acceptance (F1).

const acceptBody = { token: SECRET, company: { display_name: 'New Ltd' }, plan_id: null };

Deno.test('accept takes the user from the verified token', async () => {
   const { seen, restore } = backend();
   let res!: Response;
   try {
      res = await handler(request('/provider-invitation/accept', acceptBody));
   } finally {
      restore();
   }
   assertEquals(res.status, 200);
   assertEquals(await res.json(), { tenant_id: 'NEW-TENANT' });
   // The token was verified with Supabase Auth.
   assert(seen.length > 0);
   const accept = seen.find((s) => s.path === '/rest/v1/rpc/accept_provider_invitation')!;
   assertEquals(JSON.parse(accept.body), {
      p_user: CALLER,
      p_token: SECRET,
      p_company: { display_name: 'New Ltd' },
      p_plan_id: null
   });
   assertEquals(accept.headers.get('x-audit-role'), 'provider-invitation');
   assertEquals(accept.headers.get('x-audit-actor'), CALLER);
});

Deno.test('accept refuses a body naming the user', async () => {
   for (const extra of [{ p_user: 'x' }, { user_id: 'x' }, { staff: [] }]) {
      const { seen, restore } = backend();
      let res!: Response;
      try {
         res = await respond(handler(request('/provider-invitation/accept', { ...acceptBody, ...extra })));
      } finally {
         restore();
      }
      assertEquals(res.status, 400, JSON.stringify(extra));
      assertEquals((await res.json()).message, 'invitation_payload_invalid');
      assertEquals(rpcCalls(seen), []);
   }
});

Deno.test('accept without a JWT is 401', async () => {
   const { seen, restore } = backend();
   let res!: Response;
   try {
      res = await respond(handler(request('/provider-invitation/accept', acceptBody, [], { auth: false })));
   } finally {
      restore();
   }
   assertEquals(res.status, 401);
   assertEquals(rpcCalls(seen), []);
});

Deno.test('accept needs no tenant right: a signed-in non-member is served', async () => {
   // No permission at all in any tenant (my_access answers an empty list).
   const { seen, restore } = backend();
   try {
      assertEquals((await handler(request('/provider-invitation/accept', acceptBody, []))).status, 200);
   } finally {
      restore();
   }
   assert(seen.some((s) => s.path === '/rest/v1/rpc/accept_provider_invitation'));
});

// ------------------------------------------------------------------------------------------
// Error mapping (F2).

const ACCEPT_REFUSALS: [string, number][] = [
   ['invitation_throttled', 429],
   ['invitation_invalid', 404],
   ['invitation_email_mismatch', 403],
   ['invitation_payload_invalid', 400],
   ['company_email_exists', 409],
   ['company_phone_exists', 409],
   ['client_code_taken', 409],
   ['invitation_pending_exists', 409],
   ['plan_inactive', 400]
];

Deno.test('accept maps each refusal to its status', async () => {
   for (const [code, status] of ACCEPT_REFUSALS) {
      const { restore } = backend({ accept: { error: code } });
      let res!: Response;
      try {
         res = await respond(handler(request('/provider-invitation/accept', acceptBody)));
      } finally {
         restore();
      }
      assertEquals(res.status, status, code);
      const text = await res.text();
      assertEquals(JSON.parse(text).message, code);
      assert(!text.includes(SECRET));
   }
});

/** The raised errors of create, rotate and accept, as PostgREST answers them. */
const RAISED: [{ status: number; code: string; message: string }, number][] = [
   [{ status: 400, code: 'P0001', message: 'invitation_throttled' }, 429],
   [{ status: 400, code: 'P0001', message: 'invitation_invalid' }, 404],
   [{ status: 400, code: '23514', message: 'invitation_payload_invalid' }, 400],
   [{ status: 400, code: '23514', message: 'invitation_staff_invalid' }, 400],
   [{ status: 400, code: '23514', message: 'plan_inactive' }, 400],
   [{ status: 409, code: '23505', message: 'client_code_taken' }, 409],
   [{ status: 409, code: '23505', message: 'invitation_pending_exists' }, 409],
   [{ status: 409, code: '23505', message: 'company_email_exists' }, 409],
   [{ status: 409, code: '23505', message: 'company_phone_exists' }, 409],
   [{ status: 403, code: '42501', message: 'invitation_forbidden' }, 403],
   [{ status: 400, code: 'P0001', message: 'plan_limit_users' }, 403]
];

Deno.test('create and resend map each raised error to its status, naming only the code', async () => {
   for (const [error, status] of RAISED) {
      for (const [path, right] of [
         ['/provider-invitation', INSERT],
         [`/provider-invitation/${INVITATION}/resend`, UPDATE]
      ] as const) {
         const { seen, restore } = backend({ rpcError: error });
         let res!: Response;
         try {
            res = await respond(handler(request(path, path.endsWith('resend') ? {} : createBody, [right])));
         } finally {
            restore();
         }
         assertEquals(res.status, status, `${path} ${error.message}`);
         assertEquals((await res.json()).message, error.message);
         assertEquals(mailCalls(seen), [], 'nothing is mailed after a refusal');
      }
   }
});

Deno.test('an unexpected database error is 500 without its text', async () => {
   const { restore } = backend({
      rpcError: { status: 400, code: '22P02', message: 'invalid input syntax near secret detail' }
   });
   let res!: Response;
   const logs = await captureLogs(async () => {
      try {
         res = await respond(handler(request('/provider-invitation', createBody, [INSERT])));
      } finally {
         restore();
      }
   });
   assertEquals(res.status, 500);
   const text = await res.text();
   assert(!text.includes('secret detail'), text);
   assertStringIncludes(logs, '22P02');
});

// ------------------------------------------------------------------------------------------
// The token never leaves the server: no body, no log line.

Deno.test('the token never appears in any response body or log output', async () => {
   const scenarios: [string, Opts, () => Request][] = [
      ['create', {}, () => request('/provider-invitation', createBody, [INSERT])],
      ['create, existing', { existingUser: true }, () => request('/provider-invitation', createBody, [INSERT])],
      ['create, mail fails', { mailFails: true }, () => request('/provider-invitation', createBody, [INSERT])],
      ['resend', {}, () => request(`/provider-invitation/${INVITATION}/resend`, {}, [UPDATE])],
      ['resend, mail fails', { mailFails: true }, () => request(`/provider-invitation/${INVITATION}/resend`, {}, [UPDATE])],
      ['accept', {}, () => request('/provider-invitation/accept', acceptBody)],
      ['accept refused', { accept: { error: 'invitation_invalid' } }, () => request('/provider-invitation/accept', acceptBody)],
      ['accept bad body', {}, () => request('/provider-invitation/accept', { ...acceptBody, user_id: 'x' })],
      ['accept no jwt', {}, () => request('/provider-invitation/accept', acceptBody, [], { auth: false })]
   ];
   for (const [name, opts, make] of scenarios) {
      const { restore } = backend(opts);
      let text = '';
      const logs = await captureLogs(async () => {
         try {
            const res = await respond(handler(make()));
            text = await res.text();
         } finally {
            restore();
         }
      });
      assert(!text.includes(SECRET), `${name}: body ${text}`);
      assert(!logs.includes(SECRET), `${name}: logs ${logs}`);
      assert(!logs.includes(encodeURIComponent(SECRET)), `${name}: logs`);
   }
});

Deno.test('the answer does not reveal whether the address has an account', async () => {
   const answers: string[] = [];
   for (const existingUser of [true, false]) {
      for (const mailFails of [false, true]) {
         const { restore } = backend({ existingUser, mailFails });
         try {
            const res = await respond(handler(request('/provider-invitation', createBody, [INSERT])));
            answers.push(`${existingUser}:${res.status} ${await res.text()}`);
         } finally {
            restore();
         }
      }
   }
   const strip = (a: string) => a.replace(/^(true|false):/, '');
   assertEquals(strip(answers[0]), strip(answers[2]));
   assertEquals(strip(answers[1]), strip(answers[3]));
});

// ------------------------------------------------------------------------------------------
// Routing.

Deno.test('only POST on the three routes', async () => {
   const cases: [string, string, number][] = [
      ['GET', '/provider-invitation', 405],
      ['PUT', '/provider-invitation', 405],
      ['DELETE', `/provider-invitation/${INVITATION}`, 404],
      ['GET', '/provider-invitation/accept', 405],
      ['POST', '/provider-invitation/nope', 404],
      ['POST', `/provider-invitation/${INVITATION}`, 404],
      ['POST', `/provider-invitation/${INVITATION}/resend/x`, 404],
      ['POST', '/elsewhere', 404]
   ];
   for (const [method, path, status] of cases) {
      const { seen, restore } = backend();
      let res!: Response;
      try {
         res = await respond(handler(request(path, {}, [INSERT, UPDATE], { method })));
      } finally {
         restore();
      }
      assertEquals(res.status, status, `${method} ${path}`);
      assertEquals(rpcCalls(seen), []);
   }
});
