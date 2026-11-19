// Tenant-to-tenant product transfer over real HTTP (Plan 3, Task 14): real PostgREST and Storage
// requests against the local stack. The rights gate, the masked report, the header bypass, a real
// copy and move with their files, and the Storage rules around files in flight (rulings R1, R2).
// A failing case is a defect in 072/073/074.
//
// Run: eval "$(supabase status -o env | sed 's/^/export /')" && cd supabase/functions && deno task test:http
import { assert, assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import {
   admin,
   adminSetup,
   adminTeardown,
   ANON_KEY,
   API_URL,
   DEMO_PASSWORD,
   type Fixture,
   rest,
   type RestResult,
   SECRET_PI_TEXT,
   signIn,
} from './helpers.ts';

// The suite's state is shared (copied, moved): without the key the first admin call would fail and
// every later test with it, so stop here instead.
const SERVICE_KEY: string = (() => {
   const key = Deno.env.get('SERVICE_ROLE_KEY');
   if (!key) throw new Error('SERVICE_ROLE_KEY is not set: export the env of `supabase status -o env`');
   return key;
})();
const PREFIX = 'http-tr-';
const email = (tag: string) => `${PREFIX}${tag}@moesa-panel.test`;
const ROLE_PREFIX = 'http_tr_';
const SKU_COPY = 'HTTP-TR-COPY';
const SKU_MOVE = 'HTTP-TR-MOVE';
const PRICE = 31415.92;
const PRICE_TEXT = '31415.92';
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);

let f: Fixture;
const t = (name: string, fn: () => Promise<void>) => Deno.test({ name, fn, sanitizeResources: false, sanitizeOps: false });

type Person = { id: string; email: string; token: string };
const people: Record<string, Person> = {};
/** Every refused answer of the suite, checked at the end for another tenant's name, a price or a SKU. */
const failures: { what: string; body: unknown }[] = [];
/** Every Storage object the suite put somewhere, removed at the end. */
const objects: string[] = [];

const refused = (r: RestResult, what: string) => {
   failures.push({ what, body: r.body });
   return r;
};
const code = (r: RestResult): string => (typeof r.body === 'object' && r.body ? (r.body as { message?: string }).message ?? '' : String(r.body));

/** A refused transfer RPC: one of the statuses, with the code in the body. */
const assertRefusal = (r: RestResult, expected: string, statuses: number[], what: string) => {
   refused(r, what);
   assert(statuses.includes(r.status), `${what}: status ${r.status} ${JSON.stringify(r.body).slice(0, 300)}`);
   assertEquals(code(r), expected, `${what}: ${JSON.stringify(r.body).slice(0, 300)}`);
};

const transfer = (
   who: string,
   source: string,
   target: string,
   productIds: string[],
   mode: 'copy' | 'move',
   decisions: unknown = null,
   rehearse = true,
) =>
   rest(people[who].token, 'rpc/transfer_products', {
      method: 'POST',
      profile: 'public',
      body: { source_tenant: source, target_tenant: target, product_ids: productIds, mode, decisions, rehearse },
   });
const checkFiles = (who: string, id: string) =>
   rest(people[who].token, 'rpc/transfer_check_files', { method: 'POST', profile: 'public', body: { transfer_id: id } });

// ---------------------------------------------------------------------------------------------
// Admin helpers (service key).

const authAdmin = (path: string, method: string, body?: unknown) =>
   fetch(`${API_URL}/auth/v1/admin/${path}`, {
      method,
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
   });

const storage = (token: string, method: string, path: string, init: { body?: BodyInit; type?: string } = {}) =>
   fetch(`${API_URL}/storage/v1/${path}`, {
      method,
      headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}`, ...(init.type ? { 'Content-Type': init.type } : {}) },
      body: init.body,
   });
const upload = async (token: string, path: string, body: Uint8Array<ArrayBuffer> = PNG, type = 'image/png') => {
   const r = await storage(token, 'POST', `object/media/${path}`, { body, type });
   const text = await r.text();
   if (r.ok) objects.push(path);
   return { status: r.status, text };
};
const exists = async (path: string): Promise<boolean> => {
   const r = await storage(SERVICE_KEY, 'GET', `object/authenticated/media/${path}`);
   await r.body?.cancel();
   return r.ok;
};

const one = <T>(r: RestResult, what: string): T => {
   if (!Array.isArray(r.body) || r.body.length !== 1) throw new Error(`expected one ${what}, got ${r.status} ${JSON.stringify(r.body).slice(0, 300)}`);
   return r.body[0] as T;
};

async function person(tag: string): Promise<Person> {
   const addr = email(tag);
   const r = await authAdmin('users', 'POST', { email: addr, password: DEMO_PASSWORD, email_confirm: true });
   if (r.status >= 400) throw new Error(`creating ${addr}: ${r.status}`);
   const id = (await r.json()).id as string;
   return (people[tag] = { id, email: addr, token: await signIn(addr) });
}

async function roleWith(tenant: string, name: string, grants: [string, string][]): Promise<string> {
   const id = one<{ id: string }>(
      await admin('role', { method: 'POST', body: { tenant_id: tenant, display_name: ROLE_PREFIX + name }, headers: { Prefer: 'return=representation' } }),
      'role',
   ).id;
   const permissions = (await admin('permission?select=id,resource_name,command')).body as { id: string; resource_name: string; command: string }[];
   const rows = grants.map(([resource, command]) => {
      const p = permissions.find((x) => x.resource_name === resource && x.command === command);
      if (!p) throw new Error(`permission ${resource}.${command} missing`);
      return { role_id: id, permission_id: p.id };
   });
   await admin('role_permission', { method: 'POST', body: rows });
   return id;
}

async function join(user: string, tenant: string, role: string): Promise<void> {
   await admin('tenant_user', { method: 'POST', body: { tenant_id: tenant, user_id: people[user].id } });
   await admin('user_role', { method: 'POST', body: { user_id: people[user].id, role_id: role } });
}

async function cleanupTransfer(): Promise<void> {
   const users = (await admin(`user?email=like.${PREFIX}*&select=id`)).body as { id: string }[];
   const paths = new Set<string>(objects);
   for (const { id } of users) {
      const runs = (await admin(`transfer?started_by=eq.${id}&select=id,files`)).body as {
         id: string;
         files: { from: string; to: string }[];
      }[];
      for (const run of runs) {
         for (const file of run.files) [file.from, file.to].forEach((p) => paths.add(p));
         await admin(`transfer?id=eq.${run.id}`, { method: 'DELETE' });
      }
   }
   await admin(`sourcing?product_sku=like.HTTP-TR-*`, { method: 'DELETE' });
   const media = (await admin(`media?file_name=like.httptr-*&select=id,storage_path`)).body as { id: string; storage_path: string }[];
   for (const m of media) {
      paths.add(m.storage_path);
      await admin(`media_link?media_id=eq.${m.id}`, { method: 'DELETE' });
   }
   for (const m of media) await admin(`media?id=eq.${m.id}`, { method: 'DELETE' });
   await admin(`product?sku=like.HTTP-TR-*`, { method: 'DELETE' });
   for (const path of paths) {
      const r = await storage(SERVICE_KEY, 'DELETE', `object/media/${path}`);
      await r.body?.cancel();
   }
   for (const { id } of users) {
      await admin(`user_role?user_id=eq.${id}`, { method: 'DELETE' });
      await admin(`tenant_owner?user_id=eq.${id}`, { method: 'DELETE' });
      await admin(`tenant_user?user_id=eq.${id}`, { method: 'DELETE' });
      const r = await authAdmin(`users/${id}`, 'DELETE');
      await r.body?.cancel();
   }
   const roles = (await admin(`role?display_name=like.${ROLE_PREFIX}*&select=id`)).body as { id: string }[];
   for (const { id } of roles) {
      await admin(`user_role?role_id=eq.${id}`, { method: 'DELETE' });
      await admin(`role_field_permission?role_id=eq.${id}`, { method: 'DELETE' });
      await admin(`role_permission?role_id=eq.${id}`, { method: 'DELETE' });
      await admin(`role?id=eq.${id}`, { method: 'DELETE' });
   }
}

const count = async (path: string): Promise<number> => ((await admin(`${path}&select=id`)).body as unknown[]).length;
const productsIn = (tenant: string, sku: string) => count(`product?tenant_id=eq.${tenant}&sku=eq.${sku}`);

/** A product with a priced sourcing row, a gallery file and its Storage object, in the LTD tenant. */
async function productWithFile(sku: string, name: string): Promise<{ id: string; mediaId: string; path: string }> {
   const id = one<{ id: string }>(
      await admin('product', {
         method: 'POST',
         headers: { 'x-tenant-id': f.moesa, Prefer: 'return=representation' },
         body: { tenant_id: f.moesa, sku, display_name: `HTTP TR ${name}` },
      }),
      'product',
   ).id;
   await admin('sourcing', {
      method: 'POST',
      headers: { 'x-tenant-id': f.moesa },
      body: { tenant_id: f.moesa, product_id: id, purchase_price: PRICE, purchase_currency: 'EUR', notes: 'tr secret note' },
   });
   const mediaId = crypto.randomUUID();
   const path = `${f.moesa}/${mediaId}/httptr-${name}.png`;
   const put = await upload(people.copier.token, path);
   assertEquals(put.status, 200, `uploading the source file: ${put.text}`);
   const media = await rest(people.copier.token, 'media', {
      method: 'POST',
      headers: { 'x-tenant-id': f.moesa, Prefer: 'return=representation' },
      body: {
         id: mediaId,
         tenant_id: f.moesa,
         storage_path: path,
         file_name: `httptr-${name}.png`,
         mime_type: 'image/png',
         size_bytes: PNG.length,
      },
   });
   assertEquals(media.status, 201, JSON.stringify(media.body));
   const link = await rest(people.copier.token, 'media_link', {
      method: 'POST',
      headers: { 'x-tenant-id': f.moesa },
      body: { tenant_id: f.moesa, media_id: mediaId, entity_type: 'product', entity_id: id, role: 'gallery' },
   });
   assertEquals(link.status, 201, JSON.stringify(link.body));
   return { id, mediaId, path };
}

type Run = {
   id: string;
   files_status: string;
   missing_files: string[];
   files: { media_id: string; from: string; to: string; keep_source: boolean }[] | null;
   report: unknown;
   product_ids: string[] | null;
   decisions: unknown;
   id_map: unknown;
};
const copied: { run?: Run; product?: string; source?: { id: string; mediaId: string; path: string } } = {};
const moved: { run?: Run; source?: { id: string; mediaId: string; path: string } } = {};

// ---------------------------------------------------------------------------------------------

t('setup', async () => {
   f = await adminSetup();
   await cleanupTransfer();
   const ltdManagement = one<{ id: string }>(await admin(`role?tenant_id=eq.${f.moesa}&display_name=eq.management&select=id`), 'LTD management').id;
   const europeManagement = one<{ id: string }>(await admin(`role?tenant_id=eq.${f.europe}&display_name=eq.management&select=id`), 'Europe management').id;

   // The copier: management (every right, cost fields included) in both tenants.
   await person('copier');
   await join('copier', f.moesa, ltdManagement);
   await join('copier', f.europe, europeManagement);

   // A source user with media rights only, in LTD (a planter that is not part of any transfer).
   await person('source');
   await join('source', f.moesa, await roleWith(f.moesa, 'media_src', [['public.media', 'select'], ['public.media', 'insert']]));

   // A target user with media rights only, in Europe.
   await person('target');
   await join('target', f.europe, await roleWith(f.europe, 'media_tgt', [['public.media', 'select'], ['public.media', 'insert']]));

   // A target-only reader of the transfer record.
   await person('reader');
   await join('reader', f.europe, await roleWith(f.europe, 'reader', [['public.transfer', 'select']]));
});

// ---------------------------------------------------------------------------------------------
// The brief's four.

t('a transfer needs field rights in both tenants', async () => {
   const product = one<{ id: string }>(await admin(`product?tenant_id=eq.${f.moesa}&sku=eq.HTTP-NEW&select=id`), 'HTTP-NEW').id;
   const before = { products: await count(`product?tenant_id=eq.${f.europe}`), transfers: await count('transfer?id=not.is.null') };
   // http-mixed: management in LTD (every right) and http_no_cost in Europe (every table right, no cost group).
   for (const rehearse of [true, false]) {
      const r = await rest(f.mixed, 'rpc/transfer_products', {
         method: 'POST',
         profile: 'public',
         body: { source_tenant: f.moesa, target_tenant: f.europe, product_ids: [product], mode: 'copy', decisions: null, rehearse },
      });
      assertRefusal(r, 'transfer_field_rights_required', [400, 403, 409], `no cost write in the target (rehearse ${rehearse})`);
   }
   assertEquals(await count(`product?tenant_id=eq.${f.europe}`), before.products, 'nothing is written');
   assertEquals(await count('transfer?id=not.is.null'), before.transfers, 'no transfer row');
});

t('a transfer into a tenant the caller is not in is refused without detail', async () => {
   const product = one<{ id: string }>(await admin(`product?tenant_id=eq.${f.moesa}&sku=eq.HTTP-NEW&select=id`), 'HTTP-NEW').id;
   // http-restricted is a member of LTD only.
   for (const [source, target, what] of [
      [f.moesa, f.europe, 'into Europe'],
      [f.moesa, f.nova, 'into Nova'],
      [f.europe, f.moesa, 'out of Europe'],
   ] as const) {
      const r = await rest(f.restricted, 'rpc/transfer_products', {
         method: 'POST',
         profile: 'public',
         body: { source_tenant: source, target_tenant: target, product_ids: [product], mode: 'copy', decisions: null, rehearse: true },
      });
      assertRefusal(r, 'transfer_forbidden', [403], what);
      assertEquals({ ...r.body, code: undefined }, { message: 'transfer_forbidden', details: null, hint: null, code: undefined }, `${what}: nothing but the code`);
      for (const name of ['MOESA Europe', 'Nova', 'THOMETZKI', 'MOESA LTD']) assert(!JSON.stringify(r.body).includes(name), `${what}: ${name} in the body`);
   }
   // The same refusal for a tenant id that does not exist: no way to tell the two apart.
   const ghost = await rest(f.restricted, 'rpc/transfer_products', {
      method: 'POST',
      profile: 'public',
      body: { source_tenant: f.moesa, target_tenant: crypto.randomUUID(), product_ids: [product], mode: 'copy', decisions: null, rehearse: true },
   });
   assertRefusal(ghost, 'transfer_forbidden', [403], 'unknown tenant');
   const options = await rest(f.restricted, 'rpc/transfer_options', { method: 'POST', profile: 'public', body: { source_tenant: f.europe } });
   assertEquals(options.status, 200);
   // Not a member of the source: the same answer as for any tenant it is not in, nothing more.
   assertEquals(options.body, { source_writable: false, targets: [] });
   for (const name of ['MOESA Europe', 'Nova', 'THOMETZKI']) assert(!JSON.stringify(options.body).includes(name), `options leak ${name}`);
});

t('the report shows masked values only', async () => {
   const eu = one<{ product_id: string }>(await admin(`sourcing?id=eq.${f.euId}&select=product_id`), 'HTTP-EU sourcing').product_id;
   // http-mixed has no cost read in Europe, so a rehearsal out of Europe is refused (F18): there is no
   // report at all, and nothing of the sourcing row is in the answer.
   const r = await rest(f.mixed, 'rpc/transfer_products', {
      method: 'POST',
      profile: 'public',
      body: { source_tenant: f.europe, target_tenant: f.moesa, product_ids: [eu], mode: 'copy', decisions: null, rehearse: true },
   });
   assertRefusal(r, 'transfer_field_rights_required', [403], 'no cost read in the source');
   const text = JSON.stringify(r.body);
   for (const secret of ['77.7', SECRET_PI_TEXT, 'HTTP-EU', 'HTTP EU']) assert(!text.includes(secret), `${secret} in the answer`);
   // And with the rights, the report holds counts and ids only.
   const p = await productWithFile(SKU_COPY, 'copy');
   copied.source = p;
   const ok = await transfer('copier', f.moesa, f.europe, [p.id], 'copy');
   assertEquals(ok.status, 200, JSON.stringify(ok.body).slice(0, 400));
   const body = JSON.stringify(ok.body);
   for (const secret of [PRICE_TEXT, SECRET_PI_TEXT, SKU_COPY, 'HTTP TR copy', 'tr secret note', 'httptr-copy.png', 'HTTP-SECRET']) {
      assert(!body.includes(secret), `${secret} in the rehearsal report`);
   }
   assert(typeof ok.body.report_hash === 'string' && ok.body.report_hash.length > 0);
   assertEquals(await productsIn(f.europe, SKU_COPY), 0, 'a rehearsal writes nothing');
});

t('a client owner cannot transfer a provider sourcing row', async () => {
   const product = one<{ id: string }>(await admin('product?sku=eq.HTTP-SECRET&select=id'), 'HTTP-SECRET').id;
   const before = await count(`sourcing?tenant_id=eq.${f.client}`);
   // thomas owns the client THO; the sourcing row belongs to the provider LTD.
   for (const [source, target, what] of [
      [f.moesa, f.client, 'provider to client'],
      [f.client, f.moesa, 'client to provider'],
      [f.moesa, f.europe, 'provider to its branch'],
   ] as const) {
      for (const rehearse of [true, false]) {
         const r = await rest(f.clientOwner, 'rpc/transfer_products', {
            method: 'POST',
            profile: 'public',
            body: { source_tenant: source, target_tenant: target, product_ids: [product], mode: 'copy', decisions: null, rehearse },
         });
         assertRefusal(r, 'transfer_forbidden', [403], `${what} (rehearse ${rehearse})`);
         for (const name of ['MOESA', 'Europe', 'HTTP-SECRET', '12.5', 'THOMETZKI']) assert(!JSON.stringify(r.body).includes(name), `${what}: ${name}`);
      }
   }
   assertEquals(await count(`sourcing?tenant_id=eq.${f.client}`), before);
   assertEquals(await count(`sourcing?tenant_id=eq.${f.europe}&product_sku=eq.HTTP-SECRET`), 0);
});

// ---------------------------------------------------------------------------------------------

t('custom headers do not bypass a guard', async () => {
   const tricks = {
      'x-moesa-transfer-id': crypto.randomUUID(),
      'moesa.transfer_id': crypto.randomUUID(),
      'x-transferring': '1',
      'x-moesa-rules-bypass': '1',
      'moesa.rules_bypass': '1',
      Prefer: 'tx=commit, params=single-object',
   };
   const attempts: [string, string, string, unknown, string][] = [
      // The base field write guard: a restricted user writes a cost field.
      ['PATCH', `sourcing?id=eq.${f.secretId}`, 'api', { purchase_price: 1 }, 'restricted'],
      // The media guard: a row with no Storage object.
      ['POST', 'media', 'api', {
         id: crypto.randomUUID(),
         tenant_id: f.moesa,
         storage_path: 'nope',
         file_name: 'httptr-bypass.png',
         mime_type: 'image/png',
         size_bytes: 12,
      }, 'mixed'],
      // The transfer record itself, through both profiles.
      ['POST', 'transfer', 'api', { tenant_id: f.europe, source_tenant_id: f.moesa, mode: 'copy', started_by: people.copier.id }, 'mixed'],
      ['POST', 'transfer', 'public', { tenant_id: f.europe, source_tenant_id: f.moesa, mode: 'copy', started_by: people.copier.id }, 'mixed'],
   ];
   const sessions: Record<string, string> = { restricted: f.restricted, mixed: f.mixed };
   const transfersBefore = await count('transfer?id=not.is.null');
   const priceBefore = (await admin(`sourcing?id=eq.${f.secretId}&select=purchase_price`)).body;
   for (const [method, path, profile, body, who] of attempts) {
      const base = { 'x-tenant-id': f.moesa };
      const plain = await rest(sessions[who], path, { method, profile, body, headers: base });
      const tricked = await rest(sessions[who], path, { method, profile, body, headers: { ...base, ...tricks } });
      refused(tricked, `bypass ${method} ${path}`);
      assert(tricked.status >= 400, `${method} ${path} went through: ${tricked.status} ${JSON.stringify(tricked.body).slice(0, 200)}`);
      assertEquals(tricked.status, plain.status, `${method} ${path}: the headers changed the answer`);
      assertEquals(code(tricked), code(plain), `${method} ${path}: the headers changed the answer`);
   }
   assertEquals(await count('transfer?id=not.is.null'), transfersBefore);
   assertEquals(await count('media?file_name=eq.httptr-bypass.png'), 0);
   assertEquals((await admin(`sourcing?id=eq.${f.secretId}&select=purchase_price`)).body, priceBefore);
   // The RPC with the headers is gated like without them. `params=single-object` is left out here:
   // it changes which function PostgREST looks up (one json parameter), so the call would miss the
   // function (PGRST202) instead of reaching the guard.
   const { Prefer: _prefer, ...rpcTricks } = tricks;
   const r = await rest(f.restricted, 'rpc/transfer_products', {
      method: 'POST',
      profile: 'public',
      headers: { ...rpcTricks, Prefer: 'tx=commit' },
      body: { source_tenant: f.moesa, target_tenant: f.europe, product_ids: [f.newProductId], mode: 'copy', decisions: null, rehearse: false },
   });
   assertRefusal(r, 'transfer_forbidden', [403], 'rpc with bypass headers');
});

// ---------------------------------------------------------------------------------------------
// A real copy.

t('a stale report_hash is refused', async () => {
   const p = copied.source!;
   const rehearsal = await transfer('copier', f.moesa, f.europe, [p.id], 'copy');
   assertEquals(rehearsal.status, 200);
   const hash = rehearsal.body.report_hash as string;
   for (const decisions of [null, {}, { report_hash: 'deadbeef' }, { report_hash: hash.split('').reverse().join('') }]) {
      const r = await transfer('copier', f.moesa, f.europe, [p.id], 'copy', decisions, false);
      assertRefusal(r, 'transfer_report_stale', [409], `stale ${JSON.stringify(decisions)?.slice(0, 40)}`);
   }
   // A real stale hash: the rehearsal's own hash, after the data changed. The source product gains a
   // variant, which the package carries, so the approved report no longer describes the run.
   const fresh = await transfer('copier', f.moesa, f.europe, [p.id], 'copy');
   assertEquals(fresh.status, 200);
   const approved = fresh.body.report_hash as string;
   const variant = one<{ id: string }>(
      await admin('product', {
         method: 'POST',
         headers: { 'x-tenant-id': f.moesa, Prefer: 'return=representation' },
         body: { tenant_id: f.moesa, parent_id: p.id, sku: `${SKU_COPY}-V`, display_name: 'HTTP TR copy variant' },
      }),
      'variant',
   ).id;
   const stale = await transfer('copier', f.moesa, f.europe, [p.id], 'copy', { report_hash: approved }, false);
   assertRefusal(stale, 'transfer_report_stale', [409], 'hash of a rehearsal the data has moved past');
   await admin(`product?id=eq.${variant}`, { method: 'DELETE' });
   assertEquals(await productsIn(f.europe, SKU_COPY), 0, 'nothing is written');
   assertEquals(await count(`transfer?started_by=eq.${people.copier.id}`), 0);
   // Back as it was, the same hash applies again (the test below does).
   const again = await transfer('copier', f.moesa, f.europe, [p.id], 'copy');
   assertEquals(again.body.report_hash, approved, 'the report is the approved one again');
});

t('a copy over HTTP: rehearse, apply, read the target rows, the masked record', async () => {
   const p = copied.source!;
   const rehearsal = await transfer('copier', f.moesa, f.europe, [p.id], 'copy');
   assertEquals(rehearsal.status, 200);
   const hash = rehearsal.body.report_hash as string;
   const applied = await transfer('copier', f.moesa, f.europe, [p.id], 'copy', { report_hash: hash }, false);
   assertEquals(applied.status, 200, JSON.stringify(applied.body).slice(0, 400));
   const run = applied.body as Run & { tenant_id: string; source_tenant_id: string; mode: string };
   assertEquals(run.tenant_id, f.europe);
   assertEquals(run.source_tenant_id, f.moesa);
   assertEquals(run.mode, 'copy');
   assertEquals(run.files_status, 'pending');
   assertEquals(run.files!.length, 1);
   assertEquals(run.files![0].keep_source, true);
   assertEquals(run.files![0].from, p.path);
   assert(run.files![0].to.startsWith(`${f.europe}/`), run.files![0].to);
   copied.run = run;

   // The target rows over REST, as the copier in Europe.
   const inEurope = { 'x-tenant-id': f.europe };
   const product = one<{ id: string; tenant_id: string }>(
      await rest(people.copier.token, `product?sku=eq.${SKU_COPY}&select=id,tenant_id`, { headers: inEurope }),
      'copied product',
   );
   assertEquals(product.tenant_id, f.europe);
   assertNotEquals(product.id, p.id);
   copied.product = product.id;
   const cost = one<{ purchase_price: number; tenant_id: string; client_tenant_id: string | null }>(
      await rest(people.copier.token, `sourcing?product_id=eq.${product.id}&select=purchase_price,tenant_id,client_tenant_id`, { headers: inEurope }),
      'copied sourcing',
   );
   assertEquals(cost.purchase_price, PRICE);
   assertEquals(cost.tenant_id, f.europe);
   assertEquals(cost.client_tenant_id, null);
   const media = one<{ id: string; storage_path: string }>(
      await rest(people.copier.token, `media?file_name=eq.httptr-copy.png&select=id,storage_path`, { headers: inEurope }),
      'copied media',
   );
   assertEquals(media.storage_path, run.files![0].to);
   assertEquals(
      (await rest(people.copier.token, `media_link?media_id=eq.${media.id}&select=entity_id`, { headers: inEurope })).body,
      [{ entity_id: product.id }],
   );
   // The source is untouched.
   assertEquals(await productsIn(f.moesa, SKU_COPY), 1);
   assertEquals(await count(`sourcing?product_id=eq.${p.id}`), 1);
   assert(await exists(p.path), 'the source file stays');

   // The record: the copier in both tenants sees it whole, a target-only reader sees the masked fields as null.
   const full = one<Run>(
      await rest(people.copier.token, `transfer?id=eq.${run.id}&select=*`, { headers: { ...inEurope, 'x-tenant-ids': `${f.europe},${f.moesa}` } }),
      'transfer row',
   );
   assert(full.report !== null && full.product_ids !== null && full.files !== null && full.id_map !== null && full.decisions !== null);
   const seen = one<Run>(await rest(people.reader.token, `transfer?id=eq.${run.id}&select=*`, { headers: inEurope }), 'reader transfer row');
   assertEquals(seen.id, run.id);
   for (const field of ['report', 'product_ids', 'decisions', 'id_map', 'files'] as const) assertEquals(seen[field], null, `${field} is masked`);
   // Asking for the source tenant too widens nothing for someone who is not in it.
   const forged = one<Run>(
      await rest(people.reader.token, `transfer?id=eq.${run.id}&select=*`, { headers: { ...inEurope, 'x-tenant-ids': `${f.europe},${f.moesa}` } }),
      'reader transfer row (forged scope)',
   );
   for (const field of ['report', 'product_ids', 'decisions', 'id_map', 'files'] as const) assertEquals(forged[field], null, `${field} stays masked`);
   // The audit log shows the same masked snapshot.
   assertEquals(JSON.stringify(seen).includes(PRICE_TEXT), false);
});

t('files in flight: nobody plants an object into a copied folder (R2)', async () => {
   const run = copied.run!;
   const to = run.files![0].to;
   const folder = to.split('/').slice(0, 2).join('/');
   // A target user with media insert, not part of the transfer.
   for (const path of [to, `${folder}/other.png`, `${folder}/httptr-copy.png`]) {
      const r = await upload(people.target.token, path);
      assert(r.status >= 400, `planted ${path}: ${r.status} ${r.text}`);
      assert(!(await exists(path)), `${path} exists`);
   }
   // The source user (LTD only) is not in the target at all: refused for want of media insert in the
   // target, not by R2. The control shows it: a fresh target folder, with no media row, is refused
   // to it with the same row-level-security answer.
   const r = await upload(people.source.token, to);
   assert(r.status >= 400, `${r.status} ${r.text}`);
   assert(/row-level security/i.test(r.text), `not the policy's refusal: ${r.text}`);
   assert(!(await exists(to)));
   const outside = await upload(people.source.token, `${f.europe}/${crypto.randomUUID()}/httptr-outside.png`);
   assert(outside.status >= 400 && /row-level security/i.test(outside.text), `${outside.status} ${outside.text}`);
   // A folder without a media row is an ordinary upload for the same user: the refusal is the row's.
   const fresh = `${f.europe}/${crypto.randomUUID()}/httptr-fresh.png`;
   assertEquals((await upload(people.target.token, fresh)).status, 200);
   // Nothing there yet: the check reports the file missing and the transfer still pending.
   const check = await checkFiles('copier', run.id);
   assertEquals(check.status, 200, JSON.stringify(check.body));
   assertEquals(check.body.files_status, 'partial');
   assertEquals(check.body.missing_files, [to]);
   // The target user cannot ask for the check at all.
   refused(await checkFiles('target', run.id), 'check by an outsider');
   assertEquals((await checkFiles('target', run.id)).status, 404);
});

t('files in flight: a caller with transfer insert in both tenants uploads the copy, then the check is done', async () => {
   const run = copied.run!;
   const to = run.files![0].to;
   // The wrong type and the wrong size are uploaded by the copier first, as a mismatch the check refuses.
   const wrong = await upload(people.copier.token, to, new Uint8Array(PNG.length + 5), 'image/png');
   assertEquals(wrong.status, 200, wrong.text);
   const mismatch = await checkFiles('copier', run.id);
   assertEquals(mismatch.status, 200);
   assertEquals(mismatch.body.files_status, 'partial');
   assertEquals(mismatch.body.missing_files, [`mismatch:${to}`]);
   // The copier cannot replace or remove it: the row exists, the transfer holds it. The service role removes it.
   const del = await storage(people.copier.token, 'DELETE', `object/media/${to}`);
   await del.body?.cancel();
   assert(await exists(to), 'a user cannot remove a held target object');
   const removed = await storage(SERVICE_KEY, 'DELETE', `object/media/${to}`);
   await removed.body?.cancel();
   assert(!(await exists(to)));
   // The right object.
   const good = await upload(people.copier.token, to);
   assertEquals(good.status, 200, good.text);
   const done = await checkFiles('copier', run.id);
   assertEquals(done.status, 200, JSON.stringify(done.body));
   assertEquals(done.body.files_status, 'done');
   assertEquals(done.body.missing_files, []);
   // Done is final: the folder takes nothing else, from anyone.
   const late = await upload(people.copier.token, `${to.split('/').slice(0, 2).join('/')}/late.png`);
   assert(late.status >= 400, `${late.status} ${late.text}`);
   // Not even the copied path itself, by the copier the pending transfer let in: with the object
   // gone (the service removes it), only the transfer's 'not done' clause stood for that upload.
   const gone = await storage(SERVICE_KEY, 'DELETE', `object/media/${to}`);
   await gone.body?.cancel();
   assert(!(await exists(to)));
   const replant = await upload(people.copier.token, to);
   assert(replant.status >= 400 && /row-level security/i.test(replant.text), `${replant.status} ${replant.text}`);
   assert(!(await exists(to)), 'a done transfer let its target path be uploaded again');
   // The service puts the copy back for the rest of the suite.
   assertEquals((await upload(SERVICE_KEY, to)).status, 200);
});

// ---------------------------------------------------------------------------------------------
// A move: the source file is deleted by the service only (R1).

t('files in flight: nobody removes a source object a move left behind (R1)', async () => {
   const p = await productWithFile(SKU_MOVE, 'move');
   moved.source = p;
   const rehearsal = await transfer('copier', f.moesa, f.europe, [p.id], 'move');
   assertEquals(rehearsal.status, 200, JSON.stringify(rehearsal.body).slice(0, 400));
   const r = await transfer('copier', f.moesa, f.europe, [p.id], 'move', { report_hash: rehearsal.body.report_hash }, false);
   assertEquals(r.status, 200, JSON.stringify(r.body).slice(0, 400));
   const run = r.body as Run;
   moved.run = run;
   assertEquals(run.files_status, 'pending');
   assertEquals(run.files!.length, 1);
   assertEquals(run.files![0].keep_source, false);
   assertEquals(run.files![0].from, p.path);
   assertEquals(await productsIn(f.moesa, SKU_MOVE), 0, 'the product left the source');
   assertEquals(await productsIn(f.europe, SKU_MOVE), 1);
   assertEquals(await count(`media?id=eq.${p.mediaId}`), 0, 'the source media row is gone');

   // The source user: media insert in LTD, nothing else. The control: an object of its own it may remove.
   const own = `${f.moesa}/${crypto.randomUUID()}/httptr-own.png`;
   assertEquals((await upload(people.source.token, own)).status, 200);
   const ownDelete = await storage(people.source.token, 'DELETE', `object/media/${own}`);
   await ownDelete.body?.cancel();
   assert(ownDelete.ok && !(await exists(own)), 'the source user can remove an object of its own');
   // ... and the object a move left is not one of them: single and bulk delete.
   const single = await storage(people.source.token, 'DELETE', `object/media/${p.path}`);
   await single.body?.cancel();
   const bulk = await storage(people.source.token, 'DELETE', 'object/media', {
      body: JSON.stringify({ prefixes: [p.path] }),
      type: 'application/json',
   });
   const bulkBody = await bulk.text();
   assert(await exists(p.path), `the held source object was removed (${single.status} ${bulk.status} ${bulkBody})`);
   // The copier (transfer insert in both tenants) uploads the target copy; the transfer is done.
   const to = run.files![0].to;
   assertEquals((await upload(people.copier.token, to)).status, 200);
   const done = await checkFiles('copier', run.id);
   assertEquals(done.status, 200, JSON.stringify(done.body));
   assertEquals(done.body.files_status, 'done');
   // Done, a keep_source:false object still holds against a caller who cannot check the transfer.
   const after = await storage(people.source.token, 'DELETE', `object/media/${p.path}`);
   await after.body?.cancel();
   assert(await exists(p.path), 'a done transfer still holds the source object against a user who cannot check it');
   // The service role removes it, as the app's service does once the check says done.
   const service = await storage(SERVICE_KEY, 'DELETE', `object/media/${p.path}`);
   await service.body?.cancel();
   assert(!(await exists(p.path)));
});

// ---------------------------------------------------------------------------------------------

t('no failing body names another tenant, a price or a SKU', async () => {
   assert(failures.length >= 10, `only ${failures.length} refusals collected`);
   const tenants = ((await admin('tenant?select=display_name')).body as { display_name: string }[]).map((x) => x.display_name);
   const skus = ((await admin('product?select=sku&sku=like.HTTP-*')).body as { sku: string }[]).map((x) => x.sku);
   const forbidden = [...tenants, ...skus, 'HTTP-SECRET', 'HTTP-EU', 'HTTP-NEW', SKU_COPY, SKU_MOVE, PRICE_TEXT, SECRET_PI_TEXT, '77.7', 'tr secret note'];
   const leaks: string[] = [];
   for (const { what, body } of failures) {
      const text = JSON.stringify(body);
      for (const word of forbidden) if (word && text.includes(word)) leaks.push(`${what}: ${word}`);
   }
   assertEquals(leaks, []);
});

t('teardown', async () => {
   await cleanupTransfer();
   assertEquals(await count(`product?sku=like.HTTP-TR-*`), 0);
   assertEquals(await count(`transfer?tenant_id=eq.${f.europe}&files_status=neq.done`), 0);
   await adminTeardown(f);
});
