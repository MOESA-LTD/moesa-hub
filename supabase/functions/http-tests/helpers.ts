// HTTP attack suite helpers (Task 20, R12): real requests against the local PostgREST, GoTrue and
// Storage. The keys come from `supabase status -o env` through the environment (API_URL, ANON_KEY,
// SERVICE_ROLE_KEY, JWT_SECRET) and are never printed. Local stack only.
import { create, getNumericDate } from 'jsr:@zaubrik/djwt@3';
// The client-visible fields of each shared table (generated from field_class, Task 8); the shared-rows
// suite checks it against the catalog.
export { CLIENT_VISIBLE_FIELDS as CLIENT_VISIBLE } from '../../../app/src/constants/clientVisible.ts';

const env = (name: string): string => {
   const value = Deno.env.get(name);
   if (!value) throw new Error(`${name} is not set: eval "$(supabase status -o env | sed 's/^/export /')"`);
   return value;
};

export const API_URL = env('API_URL').replace(/\/$/, '');
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(API_URL)) {
   throw new Error('the HTTP suite runs against the local stack only (API_URL must be http://127.0.0.1 or http://localhost)');
}
export const ANON_KEY = env('ANON_KEY');
const SERVICE_ROLE_KEY = env('SERVICE_ROLE_KEY');
export const JWT_SECRET = env('JWT_SECRET');

export const DEMO_PASSWORD = 'Demo1234!';
export const RESTRICTED_EMAIL = 'http-restricted@moesa-panel.test';
export const MIXED_EMAIL = 'http-mixed@moesa-panel.test';

export type Profile = 'api' | 'public' | (string & {});
export type RestInit = {
   method?: string;
   body?: unknown;
   headers?: Record<string, string>;
   profile?: Profile;
};
export type RestResult = { status: number; body: any; headers: Headers };

/** Signs in with the demo password and returns the access token. */
export async function signIn(email: string): Promise<string> {
   const r = await fetch(`${API_URL}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password: DEMO_PASSWORD }),
   });
   const body = await r.json();
   if (!r.ok || !body.access_token) throw new Error(`sign-in failed for ${email}: ${r.status} ${body.error_code ?? body.msg ?? ''}`);
   return body.access_token;
}

/** HS256 JWT, for forged-claim attacks. */
export async function signJwt(payload: Record<string, unknown>, secret: string): Promise<string> {
   const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [
      'sign',
      'verify',
   ]);
   return await create({ alg: 'HS256', typ: 'JWT' }, { exp: getNumericDate(60), ...payload }, key);
}

const readBody = async (r: Response): Promise<unknown> => {
   const text = await r.text();
   if (!text) return null;
   try {
      return JSON.parse(text);
   } catch {
      return text;
   }
};

/** A PostgREST request as the bearer of `token`; Accept-Profile (and Content-Profile on writes) from `profile`. */
export async function rest(token: string, path: string, init: RestInit = {}): Promise<RestResult> {
   const method = init.method ?? 'GET';
   const profile = init.profile ?? 'api';
   const headers: Record<string, string> = {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Accept-Profile': profile,
      ...(method !== 'GET' && method !== 'HEAD' ? { 'Content-Profile': profile, 'Content-Type': 'application/json' } : {}),
      ...init.headers,
   };
   const r = await fetch(`${API_URL}/rest/v1/${path}`, {
      method,
      headers,
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
   });
   return { status: r.status, body: await readBody(r), headers: r.headers };
}

/** The same with the service key; throws on an HTTP error unless `allowError`. */
export async function admin(path: string, init: RestInit & { allowError?: boolean } = {}): Promise<RestResult> {
   const r = await rest(SERVICE_ROLE_KEY, path, { profile: 'public', ...init, headers: { apikey: SERVICE_ROLE_KEY, ...init.headers } });
   if (!init.allowError && r.status >= 400) {
      throw new Error(`admin ${init.method ?? 'GET'} ${path.split('?')[0]}: ${r.status} ${JSON.stringify(r.body).slice(0, 300)}`);
   }
   return r;
}

/** GoTrue admin API. */
async function authAdmin(path: string, method: string, body?: unknown): Promise<RestResult> {
   const r = await fetch(`${API_URL}/auth/v1/admin/${path}`, {
      method,
      headers: { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
   });
   return { status: r.status, body: await readBody(r), headers: r.headers };
}

/** Storage with the service key (upload / remove). */
async function storageAdmin(path: string, init: RequestInit): Promise<Response> {
   return await fetch(`${API_URL}/storage/v1/${path}`, {
      ...init,
      headers: { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}`, ...(init.headers ?? {}) },
   });
}

export type Fixture = {
   restricted: string;
   mixed: string;
   /** The THO viewer (portal@): a user of the client tenant, no provider membership. */
   portal: string;
   /** The token of thomas@, owner of the client tenant THO. */
   clientOwner: string;
   koordinator: string;
   /** The sourcing row HTTP-SECRET (MOESA LTD, client THO): cost 12.5, a supplier and an internal note. */
   secretId: string;
   /** The sourcing row HTTP-EU in MOESA Europe (a tenant procuring its own product), cost 77.7. */
   euId: string;
   /** MOESA LTD's own product HTTP-NEW, without a sourcing row yet. */
   newProductId: string;
   /** The client tenant THO. */
   client: string;
   moesa: string;
   europe: string;
   nova: string;
   poId: string;
   lineId: string;
   restrictedUserId: string;
   /** http-mixed: MOESA LTD and its branch MOESA Europe only, so no other company shares the account. */
   mixedUserId: string;
   koordinatorUserId: string;
   piObject: string;
   /** A MOESA LTD supplier (TR1 by code order). */
   supplierId: string;
   // Shared rows (Plan 2, Task 9; F18: the existing fixture, found by id and sentinel, never by code).
   /** akif: management in MOESA LTD and in THO (invited), the provider's staff with both tenants. */
   providerMgmt: string;
   /** baris: owner of MOESA LTD, not invited into THO. */
   providerOwner: string;
   portalUserId: string;
   /** THO's viewer role (portal@'s). */
   viewerRoleId: string;
   /** A second client of MOESA LTD (HTTP Other Client) and the token of its owner. */
   otherClient: string;
   otherClientOwner: string;
   otherRelationshipId: string;
   /** MOESA LTD's order shared with THO: pi_total, notes, supplier, currency and deposit rate set. */
   poShared: string;
   lineShared: string;
   shipmentShared: string;
   eventShared: string;
   /** MOESA LTD's order for the other client, and its own order (no client). */
   poOther: string;
   poOwn: string;
   /** THO's change request on poShared; its cost (provider-guarded) written by akif. */
   crShared: string;
};

/** The sentinels of the shared rows' provider-only fields. None may reach a client tenant. */
export const SECRET_PI = 987654.32;
export const SECRET_PI_TEXT = '987654.32';
export const SECRET_NOTE = 'LEAK-NOTE';
export const LEAK = 'LEAK-';
export const SHARED_SELL_PRICE = 24.5;
export const SECRET_UNIT_PRICE = 141093.76;

const HTTP_SKUS = '(HTTP-SECRET,HTTP-EU,HTTP-NEW)';
const HTTP_ROLES = '(http_restricted,http_no_cost,http_spy)';
const HTTP_PI = 'HTTP-PI';
const OTHER_CLIENT = 'HTTP Other Client';
const OTHER_EMAIL = 'http-other@moesa-panel.test';
const HTTP_CR = 'HTTP-SHARED-CR';

const one = <T>(r: RestResult, what: string): T => {
   if (!Array.isArray(r.body) || r.body.length !== 1) throw new Error(`expected one ${what}, got ${JSON.stringify(r.body).slice(0, 200)}`);
   return r.body[0] as T;
};

/** Removes everything adminSetup creates, by name; safe to run when nothing is there. */
async function cleanup(): Promise<void> {
   const docs = await admin(`document?notes=eq.${HTTP_PI}&select=id,media_id`);
   for (const d of docs.body as { id: string; media_id: string | null }[]) {
      await admin(`document?id=eq.${d.id}`, { method: 'DELETE' });
      if (d.media_id) {
         const m = await admin(`media?id=eq.${d.media_id}&select=storage_path`);
         for (const { storage_path } of m.body as { storage_path: string }[]) {
            const res = await storageAdmin('object/media', {
               method: 'DELETE',
               headers: { 'Content-Type': 'application/json' },
               body: JSON.stringify({ prefixes: [storage_path] }),
            });
            await res.body?.cancel();
         }
         await admin(`media?id=eq.${d.media_id}`, { method: 'DELETE' });
      }
   }
   // The shared rows (Task 9): the change request, the shipment and its children, then the orders.
   await admin(`change_request?title=eq.${HTTP_CR}`, { method: 'DELETE' });
   const shipments = (await admin(`shipment?notes=like.${SECRET_NOTE}*&select=id`)).body as { id: string }[];
   for (const { id } of shipments) {
      for (const child of ['shipment_event', 'shipment_line', 'shipment_purchase_order']) {
         await admin(`${child}?shipment_id=eq.${id}`, { method: 'DELETE' });
      }
      await admin(`shipment?id=eq.${id}`, { method: 'DELETE' });
   }
   const orders = (await admin(`purchase_order?notes=like.${SECRET_NOTE}*&select=id`)).body as { id: string }[];
   for (const { id } of orders) {
      await admin(`purchase_order_payment?purchase_order_id=eq.${id}`, { method: 'DELETE' });
      await admin(`purchase_order_update?purchase_order_id=eq.${id}`, { method: 'DELETE' });
      await admin(`purchase_order?id=eq.${id}`, { method: 'DELETE' });
   }
   await admin(`document?notes=like.LEAK-*`, { method: 'DELETE' });
   await admin(`purchase_order?pi_number=eq.${HTTP_PI}`, { method: 'DELETE' });
   // Sourcing rows first: they keep a product's sku as a snapshot and would outlive it.
   await admin(`sourcing?product_sku=in.${HTTP_SKUS}`, { method: 'DELETE' });
   await admin(`product?sku=in.${HTTP_SKUS}`, { method: 'DELETE' });
   const others = (await admin(`tenant?display_name=eq.${encodeURIComponent(OTHER_CLIENT)}&select=id`)).body as { id: string }[];
   for (const { id } of others) {
      await admin(`provider_relationship?client_tenant_id=eq.${id}`, { method: 'DELETE' });
      await admin(`tenant?id=eq.${id}`, { method: 'DELETE' });
   }
   const users = await admin(`user?email=in.(${RESTRICTED_EMAIL},${MIXED_EMAIL},${OTHER_EMAIL})&select=id`);
   for (const { id } of users.body as { id: string }[]) {
      await admin(`user_role?user_id=eq.${id}`, { method: 'DELETE' });
      await admin(`tenant_owner?user_id=eq.${id}`, { method: 'DELETE' });
      await admin(`tenant_user?user_id=eq.${id}`, { method: 'DELETE' });
      const r = await authAdmin(`users/${id}`, 'DELETE');
      if (r.status >= 400 && r.status !== 404) throw new Error(`deleting user ${id}: ${r.status}`);
   }
   const roles = await admin(`role?display_name=in.${HTTP_ROLES}&select=id`);
   for (const { id } of roles.body as { id: string }[]) {
      await admin(`user_role?role_id=eq.${id}`, { method: 'DELETE' });
      await admin(`role_field_permission?role_id=eq.${id}`, { method: 'DELETE' });
      await admin(`role_permission?role_id=eq.${id}`, { method: 'DELETE' });
      await admin(`role?id=eq.${id}`, { method: 'DELETE' });
   }
}

async function createUser(email: string): Promise<string> {
   const r = await authAdmin('users', 'POST', { email, password: DEMO_PASSWORD, email_confirm: true });
   if (r.status >= 400) throw new Error(`creating ${email}: ${r.status}`);
   return r.body.id;
}

/**
 * The HTTP fixtures, through the service key and the GoTrue admin API:
 * - http-restricted: MOESA LTD, role http_restricted (product (with sourcing) and client select/insert/update,
 *   purchase_order with delete, audit_log select, user select/update; no field rows: every
 *   sensitive field denied);
 * - http-mixed: management in MOESA LTD, http_no_cost in MOESA Europe (management's permissions and
 *   field rights without the cost group);
 * - products HTTP-SECRET (client tenant THO) and HTTP-EU (Europe's own), each with a sourcing row in the
 *   procuring tenant: HTTP-SECRET in MOESA LTD for client THO (cost and note set, a supplier), HTTP-EU in
 *   Europe (cost 77.7);
 * - an HTTP purchase order (draft) with a line priced 12.5 (written by akif, management in both
 *   MOESA LTD and THO), and a PI document on it with a file in Storage (the 060 row rule).
 */
export async function adminSetup(): Promise<Fixture> {
   await cleanup();

   const tenants = (await admin('tenant?select=id,display_name&display_name=in.("MOESA LTD","MOESA Europe","Nova Yazılım","THOMETZKI ONLINE HANDEL")'))
      .body as { id: string; display_name: string }[];
   const tenant = (name: string) => {
      const t = tenants.find((x) => x.display_name === name);
      if (!t) throw new Error(`tenant ${name} missing (run supabase db reset)`);
      return t.id;
   };
   const moesa = tenant('MOESA LTD');
   const europe = tenant('MOESA Europe');
   const nova = tenant('Nova Yazılım');
   const client = tenant('THOMETZKI ONLINE HANDEL');
   const inMoesa = { 'x-tenant-id': moesa };
   const inEurope = { 'x-tenant-id': europe };
   const inClient = { 'x-tenant-id': client };
   const rep = { Prefer: 'return=representation' };

   const supplierId = one<{ id: string }>(
      await admin(`supplier?tenant_id=eq.${moesa}&select=id&order=code&limit=1`),
      'MOESA supplier',
   ).id;
   const koordinatorUserId = one<{ id: string }>(await admin('user?email=eq.koordinator@moesa-panel.test&select=id'), 'koordinator').id;

   // Users.
   const restrictedUserId = await createUser(RESTRICTED_EMAIL);
   const mixedUserId = await createUser(MIXED_EMAIL);

   // Roles.
   const restrictedRole = one<{ id: string }>(
      await admin('role', { method: 'POST', body: { tenant_id: moesa, display_name: 'http_restricted' }, headers: rep }),
      'role',
   ).id;
   const noCostRole = one<{ id: string }>(
      await admin('role', { method: 'POST', body: { tenant_id: europe, display_name: 'http_no_cost' }, headers: rep }),
      'role',
   ).id;

   const permissions = (await admin('permission?select=id,group_name,command')).body as {
      id: string;
      group_name: string;
      command: string;
   }[];
   const restrictedPermissions = permissions.filter(
      (p) =>
         (['product', 'client'].includes(p.group_name) && ['select', 'insert', 'update'].includes(p.command)) ||
         p.group_name === 'purchase_order' ||
         (p.group_name === 'audit_log' && p.command === 'select') ||
         (p.group_name === 'user' && ['select', 'update'].includes(p.command)),
   );
   await admin('role_permission', {
      method: 'POST',
      body: restrictedPermissions.map((p) => ({ role_id: restrictedRole, permission_id: p.id })),
   });

   const europeManagement = one<{ id: string }>(
      await admin(`role?tenant_id=eq.${europe}&display_name=eq.management&select=id`),
      'Europe management',
   ).id;
   const managementPermissions = (await admin(`role_permission?role_id=eq.${europeManagement}&select=permission_id`)).body as {
      permission_id: string;
   }[];
   await admin('role_permission', {
      method: 'POST',
      body: managementPermissions.map((p) => ({ role_id: noCostRole, permission_id: p.permission_id })),
   });
   const costFields = new Set(
      ((await admin('field_class?group_name=eq.cost&select=resource_name,field')).body as { resource_name: string; field: string }[]).map(
         (f) => `${f.resource_name}.${f.field}`,
      ),
   );
   const managementFields = (await admin(
      `role_field_permission?role_id=eq.${europeManagement}&select=resource_name,field,can_read,can_write`,
   )).body as { resource_name: string; field: string; can_read: boolean; can_write: boolean }[];
   const noCostFields = managementFields.filter((f) => !costFields.has(`${f.resource_name}.${f.field}`));
   if (noCostFields.length === managementFields.length) throw new Error('management holds no cost field rows to drop');
   await admin('role_field_permission', { method: 'POST', body: noCostFields.map((f) => ({ ...f, role_id: noCostRole })) });

   // Memberships.
   const moesaManagement = one<{ id: string }>(
      await admin(`role?tenant_id=eq.${moesa}&display_name=eq.management&select=id`),
      'MOESA management',
   ).id;
   await admin('tenant_user', {
      method: 'POST',
      body: [
         { tenant_id: moesa, user_id: restrictedUserId },
         { tenant_id: moesa, user_id: mixedUserId },
         { tenant_id: europe, user_id: mixedUserId },
      ],
   });
   await admin('user_role', {
      method: 'POST',
      body: [
         { user_id: restrictedUserId, role_id: restrictedRole },
         { user_id: mixedUserId, role_id: moesaManagement },
         { user_id: mixedUserId, role_id: noCostRole },
      ],
   });

   // Products and their sourcing. The product HTTP-SECRET is THO's; MOESA LTD sources it for THO.
   // HTTP-EU is Europe's own product, sourced in Europe.
   const productSecret = one<{ id: string }>(
      await admin('product', {
         method: 'POST',
         headers: { ...inClient, ...rep },
         body: { tenant_id: client, sku: 'HTTP-SECRET', display_name: 'HTTP secret' },
      }),
      'product',
   ).id;
   // A link into a client tenant needs a caller who reads the client's products (the link guard), which
   // the service key is not: akif is management in MOESA LTD and a member of THO.
   const akif = await signIn('akif@moesa-panel.test');
   const secretSourcing = await rest(akif, 'sourcing', {
      method: 'POST',
      headers: { ...inMoesa, ...rep },
      body: {
         tenant_id: moesa,
         client_tenant_id: client,
         product_id: productSecret,
         supplier_id: supplierId,
         purchase_price: 12.5,
         purchase_currency: 'USD',
         manufacturer_art_no: 'HTTP-ART',
         notes: 'secret note',
      },
   });
   if (secretSourcing.status !== 201) {
      throw new Error(`creating the HTTP sourcing row: ${secretSourcing.status} ${JSON.stringify(secretSourcing.body).slice(0, 200)}`);
   }
   const secretId = one<{ id: string }>(secretSourcing, 'sourcing').id;
   const productEu = one<{ id: string }>(
      await admin('product', {
         method: 'POST',
         headers: { ...inEurope, ...rep },
         body: { tenant_id: europe, sku: 'HTTP-EU', display_name: 'HTTP EU' },
      }),
      'product',
   ).id;
   const euId = one<{ id: string }>(
      await admin('sourcing', {
         method: 'POST',
         headers: { ...inEurope, ...rep },
         body: { tenant_id: europe, product_id: productEu, purchase_price: 77.7, purchase_currency: 'EUR' },
      }),
      'sourcing',
   ).id;
   // MOESA LTD's own product with no sourcing row, for the restricted user's sourcing POST (the user is no
   // member of THO, so it cannot link a THO product).
   const newProductId = one<{ id: string }>(
      await admin('product', {
         method: 'POST',
         headers: { ...inMoesa, ...rep },
         body: { tenant_id: moesa, sku: 'HTTP-NEW', display_name: 'HTTP new' },
      }),
      'product',
   ).id;

   // A PI file (060): purchase order, Storage object, media row and the pi document.
   // The PO code is numbered in the request's tenant, which the service role has none of: akif
   // (management in MOESA LTD, member of THO, so the line may link THO's product) creates it through api.
   const mixed = await signIn(MIXED_EMAIL);
   const po = await rest(akif, 'purchase_order', {
      method: 'POST',
      headers: { ...inMoesa, ...rep },
      body: {
         tenant_id: moesa,
         client_tenant_id: client,
         supplier_id: supplierId,
         currency: 'USD',
         incoterm: 'FOB',
         deposit_rate: 0.3,
         pi_number: HTTP_PI,
      },
   });
   if (po.status !== 201) throw new Error(`creating the HTTP purchase order: ${po.status} ${JSON.stringify(po.body).slice(0, 200)}`);
   const poId = one<{ id: string }>(po, 'purchase order').id;
   const line = await rest(akif, 'purchase_order_line', {
      method: 'POST',
      headers: { ...inMoesa, ...rep },
      body: { tenant_id: moesa, purchase_order_id: poId, product_id: productSecret, quantity: 10, unit_price: 12.5 },
   });
   if (line.status !== 201) throw new Error(`creating the HTTP order line: ${line.status} ${JSON.stringify(line.body).slice(0, 200)}`);
   const lineId = one<{ id: string }>(line, 'order line').id;
   const mediaId = crypto.randomUUID();
   const piObject = `${moesa}/${mediaId}/pi.pdf`;
   const upload = await storageAdmin(`object/media/${piObject}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/pdf' },
      body: new TextEncoder().encode('%PDF-1.4\n% HTTP-PI\n'),
   });
   if (!upload.ok) throw new Error(`uploading the PI file: ${upload.status} ${await upload.text()}`);
   await upload.body?.cancel();
   await admin('media', {
      method: 'POST',
      headers: inMoesa,
      body: {
         id: mediaId,
         tenant_id: moesa,
         storage_path: piObject,
         file_name: 'pi.pdf',
         mime_type: 'application/pdf',
         size_bytes: 19,
      },
   });
   await admin('document', {
      method: 'POST',
      headers: inMoesa,
      body: {
         tenant_id: moesa,
         entity_type: 'purchase_order',
         entity_id: poId,
         type: 'pi',
         media_id: mediaId,
         notes: HTTP_PI,
      },
   });

   const [restricted, portal, clientOwner, koordinator] = await Promise.all([
      signIn(RESTRICTED_EMAIL),
      signIn('portal@moesa-panel.test'),
      signIn('thomas@moesa-panel.test'),
      signIn('koordinator@moesa-panel.test'),
   ]);
   const shared = await sharedSetup({ akif, clientOwner, moesa, client, supplierId, productSecret, secretId });

   return {
      restricted,
      mixed,
      portal,
      clientOwner,
      koordinator,
      secretId,
      euId,
      newProductId,
      client,
      moesa,
      europe,
      nova,
      poId,
      lineId,
      restrictedUserId,
      mixedUserId,
      koordinatorUserId,
      piObject,
      supplierId,
      ...shared,
   };
}

const created = <T = { id: string }>(r: RestResult, what: string): T => {
   if (r.status !== 201) throw new Error(`creating ${what}: ${r.status} ${JSON.stringify(r.body).slice(0, 300)}`);
   return one<T>(r, what);
};

/**
 * The shared rows (Task 9, F18), written as a real provider would write them: akif (management in
 * MOESA LTD and THO) through api. Every provider-only text carries LEAK-, pi_total is 987654.32.
 * - poShared: MOESA LTD's order for THO, with a line (sell price 24.5), a payment and an update; a
 *   shipment carrying it, with a line and an event; THO's change request on it (cost by akif);
 * - poOwn: MOESA LTD's own order; poOther: its order for a second client (HTTP Other Client, owned by
 *   http-other@, a relationship of its own that the suite ends).
 */
async function sharedSetup(x: {
   akif: string;
   clientOwner: string;
   moesa: string;
   client: string;
   supplierId: string;
   productSecret: string;
   secretId: string;
}): Promise<
   Pick<
      Fixture,
      | 'providerMgmt'
      | 'providerOwner'
      | 'portalUserId'
      | 'viewerRoleId'
      | 'otherClient'
      | 'otherClientOwner'
      | 'otherRelationshipId'
      | 'poShared'
      | 'lineShared'
      | 'shipmentShared'
      | 'eventShared'
      | 'poOther'
      | 'poOwn'
      | 'crShared'
   >
> {
   const { akif, clientOwner, moesa, client, supplierId, productSecret, secretId } = x;
   const inMoesa = { 'x-tenant-id': moesa, Prefer: 'return=representation' };
   const both = { 'x-tenant-id': client, 'x-tenant-ids': `${client},${moesa}`, Prefer: 'return=representation' };
   const order = (extra: Record<string, unknown>) => ({
      tenant_id: moesa,
      supplier_id: supplierId,
      currency: 'USD',
      incoterm: 'FOB',
      incoterm_place: 'LEAK-PLACE',
      deposit_rate: 30,
      penalty_rule: 'LEAK-PENALTY',
      ...extra,
   });

   // The second client: its tenant, owner and relationship.
   const otherClient = created(
      await admin('tenant', { method: 'POST', headers: { Prefer: 'return=representation' }, body: { display_name: OTHER_CLIENT } }),
      'other client',
   ).id;
   const otherUserId = await createUser(OTHER_EMAIL);
   await admin('tenant_owner', { method: 'POST', body: { tenant_id: otherClient, user_id: otherUserId } });
   await admin('tenant_user', { method: 'POST', body: { tenant_id: otherClient, user_id: otherUserId } });
   const otherRelationshipId = created(
      await admin('provider_relationship', {
         method: 'POST',
         headers: { Prefer: 'return=representation' },
         body: {
            tenant_id: moesa,
            client_tenant_id: otherClient,
            client_code: 'HOC',
            client_name: OTHER_CLIENT,
            procurement_model: 'provider',
            restricted_drive_url: 'https://drive.test/LEAK-DRIVE',
            provider_name: 'x',
            notes: 'LEAK-RELATIONSHIP',
         },
      }),
      'other relationship',
   ).id;

   // The orders.
   const poShared = created(
      await rest(akif, 'purchase_order', {
         method: 'POST',
         headers: inMoesa,
         body: order({ client_tenant_id: client, notes: `${SECRET_NOTE} shared`, pi_number: 'LEAK-PI-NO' }),
      }),
      'shared order',
   ).id;
   const poOther = created(
      await rest(akif, 'purchase_order', {
         method: 'POST',
         headers: inMoesa,
         body: order({ client_tenant_id: otherClient, notes: `${SECRET_NOTE} other`, pi_total: SECRET_PI }),
      }),
      'other client order',
   ).id;
   const poOwn = created(
      await rest(akif, 'purchase_order', {
         method: 'POST',
         headers: inMoesa,
         body: order({ notes: `${SECRET_NOTE} own`, pi_total: SECRET_PI }),
      }),
      'own order',
   ).id;
   // The provider's signed spec sheet of THO's product (on its sourcing row, the 030 rule).
   const specDoc = created(
      await admin('document', {
         method: 'POST',
         headers: { 'x-tenant-id': moesa, Prefer: 'return=representation' },
         body: { tenant_id: moesa, entity_type: 'sourcing', entity_id: secretId, type: 'spec_sheet', status: 'signed', notes: 'LEAK-SPEC', url: 'https://drive.test/LEAK-SPEC', file_name: 'LEAK-SPEC', is_signed: true, is_stamped: true, sent_from_official_email: true, issued_on: '2026-10-15' },
      }),
      'spec sheet',
   ).id;
   const lineShared = created(
      await rest(akif, 'purchase_order_line', {
         method: 'POST',
         headers: inMoesa,
         body: {
            tenant_id: moesa,
            purchase_order_id: poShared,
            product_id: productSecret,
            quantity: 7,
            unit_price: SECRET_UNIT_PRICE,
            sell_price_eur: SHARED_SELL_PRICE,
            spec_document_id: specDoc,
            notes: `${SECRET_NOTE} line`,
         },
      }),
      'shared order line',
   ).id;
   // Through the PI to pi_approved (030): 7 × 141093.76 = 987656.32, less a 2.00 discount = 987654.32;
   // a 30 % deposit. A shipment may carry an order from pi_approved on.
   const piDoc = created(
      await admin('document', {
         method: 'POST',
         headers: { 'x-tenant-id': moesa, Prefer: 'return=representation' },
         body: { tenant_id: moesa, entity_type: 'purchase_order', entity_id: poShared, type: 'pi', notes: 'LEAK-PI-DOC', url: 'https://drive.test/LEAK-PI-DOC' },
      }),
      'PI document',
   ).id;
   const step = async (body: Record<string, unknown>) => {
      const r = await rest(akif, `purchase_order?id=eq.${poShared}`, { method: 'PATCH', headers: inMoesa, body });
      if (r.status !== 200 || r.body.length !== 1) throw new Error(`shared order ${JSON.stringify(body).slice(0, 80)}: ${r.status} ${JSON.stringify(r.body).slice(0, 300)}`);
   };
   await step({ status: 'sent' });
   await step({
      status: 'pi_received',
      pi_document_id: piDoc,
      pi_subtotal: 987656.32,
      pi_discount_amount: 2,
      pi_total: SECRET_PI,
      pi_deposit_amount: 296296.3,
      pi_balance_amount: 691358.02,
      pi_check: Object.fromEntries(Array.from({ length: 30 }, (_, i) => [String(i + 1), 'ok'])),
   });
   await step({ status: 'pi_approved' });
   created(
      await rest(akif, 'purchase_order_payment', {
         method: 'POST',
         headers: inMoesa,
         body: { tenant_id: moesa, purchase_order_id: poShared, kind: 'deposit', amount: 296296.3, currency: 'USD', notes: `${SECRET_NOTE} payment` },
      }),
      'payment',
   );
   created(
      await rest(akif, 'purchase_order_update', {
         method: 'POST',
         headers: inMoesa,
         body: { tenant_id: moesa, purchase_order_id: poShared, note: `${SECRET_NOTE} update` },
      }),
      'order update',
   );

   // The shipment carrying the shared order, to THO's warehouse.
   const warehouseId = one<{ id: string }>(await admin(`warehouse?tenant_id=eq.${client}&select=id&limit=1`), 'THO warehouse').id;
   const shipmentShared = created(
      await rest(akif, 'shipment', {
         method: 'POST',
         headers: inMoesa,
         body: {
            tenant_id: moesa,
            client_tenant_id: client,
            mode: 'fcl20',
            delivery_warehouse_id: warehouseId,
            warehouse_tenant_id: client,
            forwarder: 'LEAK-FORWARDER',
            customs_broker: 'LEAK-BROKER',
            demurrage_note: 'LEAK-DEMURRAGE',
            incoterm_buy: 'EXW',
            notes: `${SECRET_NOTE} shipment`,
            carrier: 'Visible Carrier',
         },
      }),
      'shipment',
   ).id;
   created(
      await rest(akif, 'shipment_purchase_order', {
         method: 'POST',
         headers: inMoesa,
         body: { tenant_id: moesa, shipment_id: shipmentShared, purchase_order_id: poShared },
      }),
      'shipment order link',
   );
   created(
      await rest(akif, 'shipment_line', {
         method: 'POST',
         headers: inMoesa,
         body: { tenant_id: moesa, shipment_id: shipmentShared, purchase_order_id: poShared, purchase_order_line_id: lineShared, quantity: 7 },
      }),
      'shipment line',
   );
   const eventShared = created(
      await rest(akif, 'shipment_event', {
         method: 'POST',
         headers: inMoesa,
         body: { tenant_id: moesa, shipment_id: shipmentShared, step: 1, channel: 'LEAK-CHANNEL', note: 'LEAK-EVENT', from_party: 'LEAK-FROM' },
      }),
      'shipment event',
   ).id;

   // THO's change request on the shared order; the provider writes its (provider-guarded) cost.
   const crShared = created(
      await rest(clientOwner, 'change_request', {
         method: 'POST',
         headers: { 'x-tenant-id': client, Prefer: 'return=representation' },
         body: {
            tenant_id: client,
            title: HTTP_CR,
            source: 'customer',
            change_kinds: ['spec'],
            current_value: 'a',
            requested_value: 'b',
            reason: 'client reason',
            purchase_order_id: poShared,
            order_tenant_id: moesa,
         },
      }),
      'change request',
   ).id;
   const cost = await rest(akif, `change_request?id=eq.${crShared}`, {
      method: 'PATCH',
      headers: both,
      body: { cost_impact: `${SECRET_PI_TEXT} LEAK-COST`, cost_payer: 'supplier' },
   });
   if (cost.status !== 200 || cost.body.length !== 1) throw new Error(`writing the CR cost: ${cost.status} ${JSON.stringify(cost.body).slice(0, 300)}`);

   const portalUserId = one<{ id: string }>(await admin('user?email=eq.portal@moesa-panel.test&select=id'), 'portal').id;
   const viewerRoleId = one<{ id: string }>(await admin(`role?tenant_id=eq.${client}&display_name=eq.viewer&select=id`), 'THO viewer').id;
   const [providerMgmt, providerOwner, otherClientOwner] = await Promise.all([
      Promise.resolve(akif),
      signIn('baris@moesa-panel.test'),
      signIn(OTHER_EMAIL),
   ]);
   return {
      providerMgmt,
      providerOwner,
      portalUserId,
      viewerRoleId,
      otherClient,
      otherClientOwner,
      otherRelationshipId,
      poShared,
      lineShared,
      shipmentShared,
      eventShared,
      poOther,
      poOwn,
      crShared,
   };
}

export async function adminTeardown(_f: Fixture | undefined): Promise<void> {
   await cleanup();
}

// ---------------------------------------------------------------------------------------------
// Invitation onboarding (Plan 3, Task 7). A provider tenant of its own per run (the 50-a-day
// invitation cap is per provider tenant, and a run must not starve the next one), its owner and
// staff, and invitees created per test (the accept throttle is per user). Everything is named
// http-inv-* / HTTP Inv * and removed by name.

/** The local mail catcher (Inbucket), where Supabase Auth delivers the invitation mails. */
export const INBUCKET_URL = (Deno.env.get('INBUCKET_URL') ?? 'http://127.0.0.1:54324').replace(/\/$/, '');
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(INBUCKET_URL)) throw new Error('INBUCKET_URL must be local');

const INV_PREFIX = 'http-inv-';
const INV_DOMAIN = '@moesa-panel.test';
const INV_TENANT_PREFIX = 'HTTP Inv ';
export const invEmail = (tag: string) => `${INV_PREFIX}${tag}${INV_DOMAIN}`;

/** A request to an Edge Function as the bearer of `token` (the anon key when null). */
export async function edge(
   token: string | null,
   path: string,
   init: { method?: string; body?: unknown; headers?: Record<string, string> } = {},
): Promise<RestResult> {
   const r = await fetch(`${API_URL}/functions/v1/${path}`, {
      method: init.method ?? 'POST',
      headers: { apikey: ANON_KEY, Authorization: `Bearer ${token ?? ANON_KEY}`, 'Content-Type': 'application/json', ...init.headers },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
   });
   return { status: r.status, body: await readBody(r), headers: r.headers };
}

const inbucket = (path: string, init: RequestInit = {}) => fetch(`${INBUCKET_URL}/api/v1/mailbox/${path}`, init);
const mailbox = (email: string) => encodeURIComponent(email.split('@')[0]);

/** The number of mails in the address's mailbox. */
export async function mailCount(email: string): Promise<number> {
   const r = await inbucket(mailbox(email));
   const list = r.ok ? ((await r.json()) as unknown[]) : (await r.body?.cancel(), []);
   return list.length;
}

/**
 * The newest mail to `email` once there are more than `after`: its Auth verify link and the
 * invitation token carried in its redirect_to (SITE_URL/invitation/<token>). Polls up to 10 s.
 */
export async function mailedInvitation(email: string, after = 0): Promise<{ verifyUrl: string; token: string }> {
   for (let i = 0; i < 50; i++) {
      const r = await inbucket(mailbox(email));
      const list = r.ok ? ((await r.json()) as { id: string; date: string }[]) : (await r.body?.cancel(), []);
      if (list.length > after) {
         const newest = list.sort((a, b) => Date.parse(b.date) - Date.parse(a.date))[0];
         const m = await (await inbucket(`${mailbox(email)}/${newest.id}`)).json();
         const text = `${m.body?.html ?? ''}\n${m.body?.text ?? ''}`.replaceAll('&amp;', '&');
         const link = text.match(/https?:\/\/[^\s"'<>]+\/auth\/v1\/verify\?[^\s"'<>]+/)?.[0];
         if (!link) throw new Error(`the mail to ${email} carries no verify link`);
         const redirect = new URL(link).searchParams.get('redirect_to') ?? '';
         const match = redirect.match(/\/invitation\/([^/?#]+)$/);
         if (!match) throw new Error(`the mail to ${email} does not link to an invitation (is /invitation/** an Auth redirect URL? restart the stack)`);
         return { verifyUrl: link, token: decodeURIComponent(match[1]) };
      }
      await new Promise((resolve) => setTimeout(resolve, 200));
   }
   throw new Error(`no mail reached ${email}`);
}

/** Follows the mailed Auth link as the browser would: the session it signs the user in with. */
export async function followVerifyLink(verifyUrl: string): Promise<{ access: string; refresh: string }> {
   const r = await fetch(verifyUrl, { redirect: 'manual' });
   await r.body?.cancel();
   const location = r.headers.get('location') ?? '';
   const params = new URLSearchParams(location.split('#')[1] ?? '');
   const access = params.get('access_token');
   const refresh = params.get('refresh_token');
   if (!access || !refresh) throw new Error(`the verify link signed nobody in (${r.status}, ${params.get('error_code') ?? 'no session'})`);
   return { access, refresh };
}

/** A fresh access token for the session (its claims read the memberships anew). */
export async function refreshSession(refresh: string): Promise<string> {
   const r = await fetch(`${API_URL}/auth/v1/token?grant_type=refresh_token`, {
      method: 'POST',
      headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: refresh }),
   });
   const body = await r.json();
   if (!r.ok || !body.access_token) throw new Error(`refresh failed: ${r.status}`);
   return body.access_token;
}

/** Every account in GoTrue with this e-mail (admin API). */
export async function authUsersWithEmail(email: string): Promise<number> {
   let found = 0;
   for (let page = 1; ; page++) {
      const r = await authAdmin(`users?page=${page}&per_page=500`, 'GET');
      if (r.status >= 400) throw new Error(`listing auth users: ${r.status}`);
      const users = (r.body?.users ?? []) as { email?: string }[];
      found += users.filter((u) => u.email?.toLowerCase() === email.toLowerCase()).length;
      if (users.length < 500) return found;
   }
}

/** An account's user_metadata, from GoTrue. */
export async function authUserMetadata(id: string): Promise<Record<string, unknown>> {
   const r = await authAdmin(`users/${id}`, 'GET');
   if (r.status >= 400) throw new Error(`reading user ${id}: ${r.status}`);
   return r.body.user_metadata ?? {};
}

async function invitationCleanup(): Promise<void> {
   const tenants = (await admin(`tenant?display_name=like.${encodeURIComponent(INV_TENANT_PREFIX)}*&select=id,display_name`)).body as {
      id: string;
      display_name: string;
   }[];
   const users = (await admin(`user?email=like.${INV_PREFIX}*&select=id,email`)).body as { id: string; email: string }[];
   for (const { id } of users) {
      await admin(`user_role?user_id=eq.${id}`, { method: 'DELETE' });
      await admin(`tenant_owner?user_id=eq.${id}`, { method: 'DELETE' });
      await admin(`tenant_user?user_id=eq.${id}`, { method: 'DELETE' });
   }
   // Clients first: a tenant a relationship names as client is kept (F14) until it ends.
   for (const { id } of tenants) await admin(`provider_relationship?client_tenant_id=eq.${id}`, { method: 'DELETE' });
   for (const { id } of tenants) {
      await admin(`provider_invitation?tenant_id=eq.${id}`, { method: 'DELETE' });
      await admin(`tenant?id=eq.${id}`, { method: 'DELETE' });
   }
   for (const { id, email } of users) {
      const r = await authAdmin(`users/${id}`, 'DELETE');
      if (r.status >= 400 && r.status !== 404) throw new Error(`deleting user ${id}: ${r.status}`);
      const m = await inbucket(mailbox(email), { method: 'DELETE' });
      await m.body?.cancel();
   }
}

export type InvitationFixture = {
   provider: string;
   providerName: string;
   /** The provider tenant's owner (every right, insert/update on provider_invitation included). */
   owner: { id: string; email: string; token: string };
   /** Provider staff named on invitations (management, coordinator), and one who is not. */
   staff: { id: string; email: string }[];
   extraStaff: { id: string; email: string };
   /** An account with no membership anywhere. */
   stranger: { id: string; email: string; token: string };
   proPlan: string;
};

/** A confirmed account with the demo password, signed in. */
export async function invitee(tag: string): Promise<{ id: string; email: string; token: string }> {
   const email = invEmail(tag);
   const id = await createUser(email);
   return { id, email, token: await signIn(email) };
}

let codeSeq = 0;
/** A client code no earlier call of this run used (Q + two letters). */
export const nextClientCode = () => {
   const n = codeSeq++;
   return `Q${String.fromCharCode(65 + Math.floor(n / 26) % 26)}${String.fromCharCode(65 + (n % 26))}`;
};

/**
 * Creates an invitation the way the Edge Function does, with the service role: the only way a test
 * holds a plaintext token without the mail (create_provider_invitation is service-role only).
 */
export async function issueInvitation(
   f: InvitationFixture,
   email: string,
   invitation: Record<string, unknown> = {},
   staff: { user_id: string; role_name: string }[] = [],
): Promise<{ id: string; token: string; clientCode: string }> {
   const clientCode = nextClientCode();
   const r = await admin('rpc/create_provider_invitation', {
      method: 'POST',
      headers: { 'x-audit-role': 'provider-invitation', 'x-audit-actor': f.owner.id },
      body: {
         p_tenant: f.provider,
         p_actor: f.owner.id,
         p_invitation: { email, company_name: 'HTTP Inv Company', client_code: clientCode, procurement_model: 'provider', ...invitation },
         p_staff: staff,
      },
   });
   const row = (Array.isArray(r.body) ? r.body[0] : r.body) as { id: string; token: string };
   if (!row?.id || !row?.token) throw new Error('create_provider_invitation returned no invitation');
   return { id: row.id, token: row.token, clientCode };
}

/** The provider tenant (register_tenant, service role), its owner, two staff and an outsider. */
export async function invitationSetup(): Promise<InvitationFixture> {
   await invitationCleanup();
   codeSeq = 0;

   const ownerId = await createUser(invEmail('owner'));
   const providerName = `${INV_TENANT_PREFIX}Provider`;
   const registered = await admin('rpc/register_tenant', {
      method: 'POST',
      body: { owner_id: ownerId, company: { display_name: providerName, email: invEmail('provider-co') } },
   });
   const provider = (registered.body as { id: string }).id;
   if (!provider) throw new Error('register_tenant returned no tenant');

   const coordinator = one<{ id: string }>(
      await admin(`role?tenant_id=eq.${provider}&display_name=eq.coordinator&select=id`),
      'provider coordinator role',
   ).id;
   const staff: { id: string; email: string }[] = [];
   for (const tag of ['staff-mgmt', 'staff-coord', 'staff-extra']) {
      const email = invEmail(tag);
      staff.push({ id: await createUser(email), email });
   }
   await admin('tenant_user', { method: 'POST', body: staff.map((s) => ({ tenant_id: provider, user_id: s.id })) });
   await admin('user_role', { method: 'POST', body: staff.map((s) => ({ user_id: s.id, role_id: coordinator })) });

   const proPlan = one<{ id: string }>(await admin('plan?display_name=eq.Pro&is_active=is.true&select=id'), 'Pro plan').id;
   const stranger = await invitee('stranger');

   return {
      provider,
      providerName,
      owner: { id: ownerId, email: invEmail('owner'), token: await signIn(invEmail('owner')) },
      staff: staff.slice(0, 2),
      extraStaff: staff[2],
      stranger,
      proPlan,
   };
}

export async function invitationTeardown(): Promise<void> {
   await invitationCleanup();
}

/**
 * Every `.from(...).select(...)` the app sends, as [api view, select] (Task 20). Static on purpose:
 * the suite asserts that each one still resolves through the masked api views for a restricted user.
 *
 * To regenerate after the app changes, from app/src:
 *   grep -rn "\.from(\|from=\"\|:from=\|useLookup\|defineResource\|select:\|select=\|_SELECT\s*=" --include=*.ts --include=*.vue . | grep -v test
 * and copy each table/view with its select string (constants such as PURCHASE_ORDER_SELECT,
 * CHANGE_REQUEST_SELECT and DOCUMENT_MEDIA_SELECT expanded; defineResource without a select is '*';
 * ResourceTable adds BRANCH_EMBED when sorting by branch). RPCs (.rpc) are not listed: they stay in public.
 */
export const APP_SELECTS: [string, string][] = [
   // admin
   ['plan', '*, plan_module(module_id), plan_limit(limit_key, value)'],
   ['plan', 'id,display_name,description,is_active,position,plan_module(module_id)'],
   ['module', 'id,is_core,position'],
   ['company_subscription', '*'],
   ['subscription', '*, status, plan(display_name)'],
   // amazon
   ['amazon_product_type_definition', '*'],
   ['market_cell', 'id, country, listing_language, price, currency'],
   ['platform_account', 'id, tenant_id, platform_id, api_connection, authorized_at, seller_id'],
   ['listing_submission', '*'],
   ['market_cell', 'id'],
   // audit
   ['audit_transaction', '*, actor(*, display_name), reverter(*, display_name)'],
   ['audit_log', '*'],
   // branch, user, role
   ['tenant', 'id'],
   [
      'tenant',
      'id, parent_id, logo_path, created_at, display_name, email, phone, website, legal_name, tax_office, tax_number, country, city, district, address',
   ],
   ['tenant', '*, branch:tenant(display_name)'],
   ['tenant_member', '*'],
   ['tenant_member', 'id, email, user_metadata'],
   ['user', '*, user_role(role(*)), tenant_owner(tenant_id), owned_via, tenant_id:managed_in'],
   ['role', '*'],
   [
      'role',
      '*, role_permission(permission(id, kind, group_name)), role_field_permission(resource_name, field, can_read, can_write)',
   ],
   ['permission', 'id,resource_name,group_name,kind'],
   ['field_group', 'id,position'],
   // company data and the provider relationship
   ['provider_relationship', '*'],
   ['provider_relationship', 'id, client_tenant_id, client_code, client_name, status'],
   [
      'provider_relationship',
      'tenant_id, client_tenant_id, client_code, client_name, procurement_model, status'
   ],
   ['contact', '*'],
   ['warehouse', '*'],
   ['warehouse', 'id, display_name, city, is_default, dock_hours, appointment_rule'],
   ['platform_account', '*'],
   ['brand', '*'],
   ['platform', 'id, display_name, countries'],
   // supplier
   ['supplier', '*'],
   ['supplier', 'id, code, display_name, default_incoterm, deposit_rate'],
   ['supplier_contact', '*'],
   // product
   ['product', '*'],
   ['sourcing', '*, supplier(code, display_name)'],
   ['sourcing', 'id, product_id, client_tenant_id, supplier_id, purchase_price, purchase_currency, sell_price_eur'],
   ['sourcing', 'id, product_id, purchase_price, purchase_currency'],
   ['product', 'id'],
   ['product', 'id, sku, display_name'],
   ['product', 'id, sku, display_name, status'],
   ['product', 'id, sku, display_name, status'],
   ['product_with_evidence', '*'],
   ['product_with_evidence', '*, branch:tenant(display_name)'],
   // project
   ['project', '*, project_gate(*), project_product(product(id, sku, display_name))'],
   ['project', '*, project_gate(id, code, position, status)'],
   ['project', 'id, code, display_name'],
   ['project', 'id, tenant_id'],
   ['project_task', '*'],
   ['project_product', '*'],
   ['project_gate', 'code, status, needs_customer_approval'],
   // purchase order
   [
      'purchase_order',
      [
         '*',
         'supplier(code, display_name, default_incoterm, deposit_rate)',
         'project!purchase_order_project_fkey(code, display_name)',
         'purchase_order_line!purchase_order_line_po_fkey(*, product!purchase_order_line_product_fkey(id, sku, display_name, status), spec_document(id, version, status))',
         'purchase_order_payment!purchase_order_payment_po_fkey(*)',
      ].join(', '),
   ],
   ['purchase_order', 'id'],
   ['purchase_order', '*'],
   ['purchase_order_line', '*'],
   ['purchase_order_payment', '*'],
   ['purchase_order_update', '*'],
   ['purchase_order_overview', '*'],
   ['purchase_order_overview', 'id'],
   ['purchase_order_overview', 'id, code, status, client_tenant_id'],
   // shipment
   [
      'shipment',
      [
         '*',
         'warehouse!shipment_warehouse_fkey(display_name, city, dock_hours, appointment_rule)',
         'shipment_purchase_order!shipment_purchase_order_shipment_fkey(purchase_order!shipment_purchase_order_po_fkey(id, code, status, tolerance_pct, purchase_order_line!purchase_order_line_po_fkey(id, quantity, product_sku, product_name, product!purchase_order_line_product_fkey(sku, display_name, is_hazmat))))',
         'shipment_line!shipment_line_shipment_fkey(*)',
      ].join(', '),
   ],
   ['shipment_line', '*'],
   ['shipment_line', 'quantity, shipment_id, shipment!shipment_line_shipment_fkey(status)'],
   ['shipment_event', '*'],
   ['shipment_purchase_order', '*'],
   ['shipment_purchase_order', 'shipment_id'],
   ['shipment_overview', '*'],
   ['shipment_overview', 'id'],
   // change request
   [
      'change_request',
      '*, project!change_request_project_fkey(code, display_name, project_gate!project_gate_project_fkey(code, status, needs_customer_approval)), change_request_product!change_request_product_cr_fkey(product_id, product!change_request_product_product_fkey(sku, display_name)), affected_document:document!change_request_affected_document_fkey(id, entity_type, entity_id, type, version, status), result_document:document!change_request_result_document_fkey(id, type, version, status)',
   ],
   ['change_request', '*, project!change_request_project_fkey(code)'],
   ['change_request_product', '*'],
   // incident
   [
      'incident',
      '*, incident_log!incident_log_incident_fkey(*), incident_deadline!incident_deadline_incident_fkey(*), project_gate!project_gate_rollback_incident_fkey(id, code, status, project_id)',
   ],
   ['incident', 'id, code, title'],
   ['incident_log', '*'],
   ['incident_deadline', '*'],
   ['incident_overview', '*'],
   ['project', 'id, code'],
   ['market_cell_overview', 'id, sku, cell_key'],
   // market matrix
   [
      'market_cell',
      '*, product!market_cell_product_fkey(sku, display_name), project!market_cell_project_fkey(code, display_name), platform!market_cell_platform_fkey(display_name, countries, product_id_label)',
   ],
   ['market_cell_overview', '*'],
   // documents and media
   ['document', '*, media!document_media_fkey(id, storage_path, file_name)'],
      ['document', 'id, type, version, status'],
   ['document', 'id, version, status'],
   ['document', 'id, entity_id, type, version, file_name'],
   ['document', 'id, type, version, file_name'],
   ['document', 'id, entity_type, type, status, version'],
   ['media', '*'],
   ['media_link', '*, media(*)'],
   ['media_link', 'position'],
   ['media_link', '*'],
   ['media_library', '*'],
   ['media_library', 'link_count, document_count'],
   // settings, dashboard
   ['setting', 'id, key, value, description'],
   ['dashboard_notification_feed', '*'],
   ['dashboard_shipment', '*'],
   ['dashboard_market', '*'],
   ['dashboard_incident', '*'],
   ['dashboard_change_request', '*'],
   ['dashboard_gate_pending', '*'],
   ['dashboard_product_evidence', '*'],
   ['dashboard_purchase_order', '*'],
   ['dashboard_task_due', '*'],
];
