// Field-level permissions over real HTTP (Task 20, spec R12): the attack checklist against the local
// PostgREST, GoTrue, Storage and (when served) the Edge runtime. A failing case is a leak.
//
// Run: eval "$(supabase status -o env | sed 's/^/export /')" && cd supabase/functions && deno task test:http
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { adminSetup, adminTeardown, ANON_KEY, API_URL, APP_SELECTS, type Fixture, JWT_SECRET, rest, signJwt } from './helpers.ts';

let f: Fixture;
const h = () => ({ 'x-tenant-id': f.moesa });
const t = (name: string, fn: () => Promise<void>) => Deno.test({ name, fn, sanitizeResources: false, sanitizeOps: false });

t('setup', async () => {
   f = await adminSetup();
});

t('masked read returns null', async () => {
   const r = await rest(f.restricted, `sourcing?id=eq.${f.secretId}&select=purchase_price,notes`, { headers: h() });
   assertEquals(r.status, 200);
   assertEquals(r.body, [{ purchase_price: null, notes: null }]);
});

t('filter oracle returns nothing', async () => {
   const r = await rest(f.restricted, `sourcing?id=eq.${f.secretId}&purchase_price=gt.0`, { headers: h() });
   assertEquals(r.body, []);
   const n = await rest(f.restricted, `sourcing?id=eq.${f.secretId}&notes=like.secret*&select=id`, { headers: h() });
   assertEquals(n.body, []);
   const isNull = await rest(f.restricted, `sourcing?id=eq.${f.secretId}&purchase_price=is.null&select=id`, { headers: h() });
   assertEquals(isNull.body, [{ id: f.secretId }], 'IS NULL sees the masked value, not the stored one');
});

t('order by a masked field does not reorder', async () => {
   const a = await rest(f.restricted, 'sourcing?select=id&order=purchase_price.desc,id', { headers: h() });
   const b = await rest(f.restricted, 'sourcing?select=id&order=id', { headers: h() });
   assertEquals(a.status, 200);
   assertEquals(a.body, b.body);
});

t('count with a masked filter is zero', async () => {
   const r = await rest(f.restricted, 'sourcing?purchase_price=gt.0&select=id', { headers: { ...h(), Prefer: 'count=exact' } });
   assertEquals(r.headers.get('content-range'), '*/0');
});

t('R4 supplier embed is null', async () => {
   const r = await rest(f.restricted, `sourcing?id=eq.${f.secretId}&select=product_sku,supplier_id,supplier(code)`, { headers: h() });
   assertEquals(r.body, [{ product_sku: 'HTTP-SECRET', supplier_id: null, supplier: null }]);
});

t('every app select string resolves', async () => {
   const failures: string[] = [];
   for (const [path, select] of APP_SELECTS) {
      const r = await rest(f.restricted, `${path}?select=${encodeURIComponent(select)}&limit=1`, { headers: h() });
      if (r.status !== 200) failures.push(`${r.status} ${path} ${select}: ${JSON.stringify(r.body).slice(0, 200)}`);
   }
   assertEquals(failures, []);
});

t('write to a masked field is refused (wrong and correct guess)', async () => {
   for (const v of [1, 12.5]) {
      const r = await rest(f.restricted, `sourcing?id=eq.${f.secretId}`, { method: 'PATCH', body: { purchase_price: v }, headers: h() });
      assertEquals(r.status, 403);
      assertEquals(r.body.code, '42501');
      assertEquals(r.body.message, 'field_write_forbidden');
   }
});

t('return=representation is masked', async () => {
   const r = await rest(f.restricted, `sourcing?id=eq.${f.secretId}`, {
      method: 'PATCH',
      body: { product_name: 'y' },
      headers: { ...h(), Prefer: 'return=representation' },
   });
   assertEquals(r.status, 200);
   assertEquals(r.body[0].purchase_price, null);
   assertEquals(r.body[0].notes, null);
});

t('PATCH filtered on a masked field affects nothing', async () => {
   const r = await rest(f.restricted, 'sourcing?purchase_price=lt.100', {
      method: 'PATCH',
      body: { product_name: 'z' },
      headers: { ...h(), Prefer: 'return=representation' },
   });
   assertEquals(r.body, []);
});

t('POST and DELETE with representation are masked', async () => {
   // The app's fetch adds tenant_id to every write (customFetch). The cost lives on a sourcing row.
   const p = await rest(f.restricted, 'sourcing', {
      method: 'POST',
      body: { tenant_id: f.moesa, product_id: f.newProductId },
      headers: { ...h(), Prefer: 'return=representation' },
   });
   assertEquals(p.status, 201, JSON.stringify(p.body));
   assertEquals(p.body[0].product_sku, 'HTTP-NEW');
   assertEquals(p.body[0].purchase_price, null);
   // Sourcing rows can be deleted, order lines too; the masked DELETE runs on an order line (cost: unit_price).
   // unit_price is required and a cost field: the restricted user cannot add a line at all.
   const l = await rest(f.restricted, 'purchase_order_line', {
      method: 'POST',
      body: { tenant_id: f.moesa, purchase_order_id: f.poId, product_id: f.newProductId, quantity: 1, unit_price: 1 },
      headers: { ...h(), Prefer: 'return=representation' },
   });
   assertEquals(l.status, 403, JSON.stringify(l.body));
   assertEquals(l.body.message, 'field_write_forbidden');
   const d = await rest(f.restricted, `purchase_order_line?id=eq.${f.lineId}`, {
      method: 'DELETE',
      headers: { ...h(), Prefer: 'return=representation' },
   });
   assertEquals(d.status, 200, JSON.stringify(d.body));
   assertEquals(d.body.length, 1);
   assertEquals(d.body[0].id, f.lineId);
   assertEquals(d.body[0].quantity, 10);
   assertEquals(d.body[0].unit_price, null);
   assert(!JSON.stringify(d.body).includes('12.5'));
});

t('the base table is closed', async () => {
   for (const token of [f.restricted, f.koordinator, ANON_KEY]) {
      for (const table of ['product', 'sourcing']) {
         const r = await rest(token, `${table}?select=id&limit=1`, { profile: 'public', headers: h() });
         assertEquals(r.body.code, '42501', table);
         const w = await rest(token, `${table}?id=eq.${f.secretId}`, { method: 'PATCH', body: { notes: 'w' }, profile: 'public', headers: h() });
         assertEquals(w.body.code, '42501', table);
      }
   }
});

t('private and graphql_public profiles are refused', async () => {
   for (const profile of ['private', 'pg_catalog', 'auth', 'storage', 'vault']) {
      const r = await rest(f.restricted, 'product?select=id&limit=1', { profile, headers: h() });
      assertEquals(r.status, 406, `${profile}: ${JSON.stringify(r.body)}`);
      assertEquals(r.body.code, 'PGRST106');
   }
   // The CLI always adds graphql_public to PostgREST's schemas; after 063 it holds only the
   // extension's stub function, so no relation resolves there.
   for (const table of ['product', 'sourcing', 'user', 'audit_log']) {
      const r = await rest(f.restricted, `${table}?select=*&limit=1`, { profile: 'graphql_public', headers: h() });
      assert([404, 406].includes(r.status), `graphql_public ${table}: ${r.status} ${JSON.stringify(r.body)}`);
   }
   for (const fn of ['field_read_tenants', 'impersonate_scope', 'save_role_field_rights']) {
      const r = await rest(f.restricted, `rpc/${fn}`, { method: 'POST', body: {}, profile: 'private', headers: h() });
      assertEquals(r.status, 406, `private.${fn}: ${r.status}`);
   }
});

t('graphql is gone', async () => {
   const r = await fetch(`${API_URL}/graphql/v1`, {
      method: 'POST',
      headers: { apikey: ANON_KEY, Authorization: `Bearer ${f.restricted}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: '{ productCollection { edges { node { purchasePrice } } } }' }),
   });
   const text = await r.text();
   // Either no route, or graphql_public's stub answering that pg_graphql is not enabled: never data.
   assert(
      [404, 406].includes(r.status) || text.includes('pg_graphql extension is not enabled'),
      `graphql answered ${r.status}: ${text.slice(0, 200)}`,
   );
   assert(!text.includes('"data"'), text.slice(0, 200));
});

for (const role of ['api_owner', 'rfp_writer', 'postgres', 'supabase_admin', 'authenticator']) {
   t(`a JWT whose role claim is ${role} is refused`, async () => {
      const token = await signJwt({ sub: f.restrictedUserId, role }, JWT_SECRET);
      const r = await rest(token, `sourcing?id=eq.${f.secretId}&select=id,purchase_price`, { headers: h() });
      assert([401, 403].includes(r.status), `${role}: ${r.status} ${JSON.stringify(r.body)}`);
      assert(!JSON.stringify(r.body).includes('12.5'));
   });
}

t('a forged service_role JWT with a wrong secret is refused', async () => {
   const token = await signJwt({ role: 'service_role', iss: 'supabase-demo' }, 'not-the-secret-not-the-secret-not-the-secret');
   const r = await rest(token, `sourcing?id=eq.${f.secretId}&select=purchase_price`, { profile: 'public', headers: h() });
   assertEquals(r.status, 401);
   const a = await rest(token, `sourcing?id=eq.${f.secretId}&select=purchase_price`, { headers: h() });
   assertEquals(a.status, 401);
});

t('mixed-rights user over x-tenant-ids', async () => {
   const r = await rest(f.mixed, `sourcing?id=in.(${f.secretId},${f.euId})&select=product_sku,purchase_price&order=product_sku`, {
      headers: { 'x-tenant-id': f.moesa, 'x-tenant-ids': `${f.moesa},${f.europe}` },
   });
   assertEquals(r.body, [
      { product_sku: 'HTTP-EU', purchase_price: null },
      { product_sku: 'HTTP-SECRET', purchase_price: 12.5 },
   ]);
   const filtered = await rest(f.mixed, `sourcing?id=in.(${f.secretId},${f.euId})&purchase_price=gt.50&select=product_sku`, {
      headers: { 'x-tenant-id': f.moesa, 'x-tenant-ids': `${f.moesa},${f.europe}` },
   });
   assertEquals(filtered.body, [], 'the Europe price (77.7) is not an oracle');
});

t('a forged x-tenant-ids neither widens rows nor unmasks', async () => {
   const path = `sourcing?id=in.(${f.secretId},${f.euId})&select=product_sku,purchase_price&order=product_sku`;
   for (const headers of [
      { 'x-tenant-id': f.moesa, 'x-tenant-ids': `${f.moesa},${f.europe},${f.nova}` },
      { 'x-tenant-id': f.europe, 'x-tenant-ids': `${f.europe}` },
      { 'x-tenant-id': f.nova, 'x-tenant-ids': `${f.nova},${f.moesa}` },
   ]) {
      const r = await rest(f.restricted, path, { headers });
      const rows = Array.isArray(r.body) ? r.body : [];
      assert(rows.every((row: { product_sku: string }) => row.product_sku !== 'HTTP-EU'), `rows widened: ${JSON.stringify(r.body)}`);
      assert(rows.every((row: { purchase_price: unknown }) => row.purchase_price === null), `unmasked: ${JSON.stringify(r.body)}`);
   }
   // The mixed user naming Nova (not a member): Europe stays masked, nothing from Nova appears.
   const m = await rest(f.mixed, path, { headers: { 'x-tenant-id': f.europe, 'x-tenant-ids': `${f.europe},${f.nova}` } });
   const rows = Array.isArray(m.body) ? m.body : [];
   assert(rows.every((row: { product_sku: string; purchase_price: unknown }) => row.product_sku !== 'HTTP-EU' || row.purchase_price === null), JSON.stringify(m.body));
});

t('a client tenant reads no provider row', async () => {
   // Sharing comes in Plan 2: until then a client tenant holds no right on the provider's rows,
   // even when it names the provider tenant in the scope header.
   const headers = { 'x-tenant-id': f.client, 'x-tenant-ids': `${f.client},${f.moesa}` };
   for (const table of ['purchase_order', 'sourcing', 'supplier', 'provider_relationship']) {
      const r = await rest(f.clientOwner, `${table}?select=id`, { headers });
      assertEquals(r.status, 200, `${table}: ${JSON.stringify(r.body)}`);
      assertEquals(r.body.length, 0, `${table} leaked rows to the client owner`);
   }
   assertEquals((await rest(f.clientOwner, 'document?type=eq.pi&select=id', { headers })).body, []);
   // The koordinator does see the PI document (so the empty answers above are the row rule).
   assert((await rest(f.koordinator, 'document?type=eq.pi&notes=eq.HTTP-PI&select=id', { headers: h() })).body.length === 1);
});

t('Storage: a client owner cannot download a provider PI file, the koordinator can', async () => {
   const url = `${API_URL}/storage/v1/object/authenticated/media/${f.piObject}`;
   const get = (token: string) => fetch(url, { headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}` } });
   const client = await get(f.clientOwner);
   const clientText = await client.text();
   assert(!client.ok, `client owner downloaded the PI file (${client.status})`);
   assert(!clientText.includes('HTTP-PI'));
   const restricted = await get(f.restricted);
   await restricted.body?.cancel();
   assert(!restricted.ok, `restricted downloaded the PI file (${restricted.status})`);
   const koordinator = await get(f.koordinator);
   assertEquals(koordinator.status, 200);
   assert((await koordinator.text()).includes('HTTP-PI'));
   // Signing a URL is a read of the object too.
   const sign = await fetch(`${API_URL}/storage/v1/object/sign/media/${f.piObject}`, {
      method: 'POST',
      headers: { apikey: ANON_KEY, Authorization: `Bearer ${f.clientOwner}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ expiresIn: 60 }),
   });
   const signBody = await sign.text();
   assert(!sign.ok, `client owner signed a PI URL: ${signBody.slice(0, 120)}`);
});

t('audit keys are masked for a restricted reader', async () => {
   const r = await rest(f.restricted, `audit_log?record_id=eq.${f.secretId}&select=new_data&order=id.desc&limit=1`, { headers: h() });
   assertEquals(r.status, 200);
   assertEquals(r.body.length, 1, 'the restricted user sees the audit row');
   assertEquals(r.body[0].new_data.purchase_price, { masked: true });
   assertEquals(r.body[0].new_data.notes, { masked: true });
   const filter = await rest(f.restricted, `audit_log?record_id=eq.${f.secretId}&new_data->>purchase_price=eq.12.5&select=id`, { headers: h() });
   assertEquals(filter.body, [], 'the audit JSON is not an oracle');
});

t('error bodies never contain a seeded secret', async () => {
   for (const path of [
      `sourcing?id=eq.${f.secretId}&purchase_price=eq.abc`,
      `sourcing?id=eq.${f.secretId}&notes=gt.%5B`,
      `sourcing?id=eq.${f.secretId}&select=x:purchase_price::int`,
      `sourcing?id=eq.${f.secretId}&select=n:notes::int`,
   ]) {
      const r = await rest(f.restricted, path, { headers: h() });
      const text = JSON.stringify(r.body);
      assert(!text.includes('12.5') && !text.includes('secret note'), `${path}: ${text}`);
   }
   const w = await rest(f.restricted, `sourcing?id=eq.${f.secretId}`, { method: 'PATCH', body: { purchase_price: 'abc' }, headers: h() });
   const text = JSON.stringify(w.body);
   assert(!text.includes('12.5') && !text.includes('secret note'), text);
});

t('user Edge Function refuses another user\'s personal-data write', async () => {
   let probe: Response;
   try {
      probe = await fetch(`${API_URL}/functions/v1/user/${f.koordinatorUserId}`, { method: 'OPTIONS' });
      await probe.body?.cancel();
   } catch (error) {
      console.log(`SKIP: the Edge runtime is not reachable (${(error as Error).message}); run supabase functions serve`);
      return;
   }
   if ([404, 502, 503].includes(probe.status)) {
      console.log(`SKIP: the user Edge Function is not served (${probe.status}); run supabase functions serve`);
      return;
   }
   const r = await fetch(`${API_URL}/functions/v1/user/${f.koordinatorUserId}`, {
      method: 'PUT',
      headers: { apikey: ANON_KEY, Authorization: `Bearer ${f.restricted}`, 'x-tenant-id': f.moesa, 'Content-Type': 'application/json' },
      body: JSON.stringify({ user_metadata: { display_name: 'pwned' } }),
   });
   const body = await r.json().catch(() => null);
   assertEquals(r.status, 403, JSON.stringify(body));
   assertEquals(body?.error ?? body?.code ?? body?.message, 'field_write_forbidden', JSON.stringify(body));
});

t('teardown', async () => {
   await adminTeardown(f);
});
