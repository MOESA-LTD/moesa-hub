// Shared provider rows over real HTTP (Plan 2, Task 9): a client tenant must not read the provider-only
// fields of the rows its provider shares with it, even through direct PostgREST, RPC and Storage calls.
// The attacker is a client user (thomas@, THO's owner, and portal@, THO's viewer) calling the API
// directly. A failing case is a leak.
//
// Run: eval "$(supabase status -o env | sed 's/^/export /')" && cd supabase/functions && deno task test:http
import { assert, assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import {
   admin,
   adminSetup,
   adminTeardown,
   ANON_KEY,
   API_URL,
   APP_SELECTS,
   CLIENT_VISIBLE,
   type Fixture,
   rest,
   type RestInit,
   type RestResult,
   SECRET_NOTE,
   SECRET_PI,
   SECRET_PI_TEXT,
   SECRET_UNIT_PRICE,
   SHARED_SELL_PRICE,
} from './helpers.ts';

let f: Fixture;
const t = (name: string, fn: () => Promise<void>) => Deno.test({ name, fn, sanitizeResources: false, sanitizeOps: false });

/** The scope headers of a request in `tenant`, naming `tenants` (default: the active tenant alone). */
const h = (tenant: string, tenants?: string[]) => ({ 'x-tenant-id': tenant, ...(tenants ? { 'x-tenant-ids': tenants.join(',') } : {}) });
const rep = { Prefer: 'return=representation' };

/** Both client users: the owner (every right of THO) and the viewer (no order rights of its own). */
const clients = (): [string, string][] => [
   ['owner', f.clientOwner],
   ['viewer', f.portal],
];
/** A request of a client user in THO. */
const asClient = (token: string, path: string, init: RestInit = {}) =>
   rest(token, path, { ...init, headers: { ...h(f.client), ...init.headers } });

/** Every provider-only value the fixture wrote: the PI figures, the cost and every LEAK- text. */
const SECRETS = [SECRET_PI_TEXT, String(SECRET_UNIT_PRICE), '987656.32', '296296.3', '691358.02', 'LEAK-', 'secret note'];
const noLeak = (r: RestResult | unknown, what: string) => {
   const text = JSON.stringify(r && typeof r === 'object' && 'body' in r ? (r as RestResult).body : r);
   for (const s of SECRETS) assert(!text.includes(s), `${what} leaked ${s}: ${text.slice(0, 300)}`);
};
const rows = (r: RestResult, what: string): Record<string, unknown>[] => {
   assertEquals(r.status, 200, `${what}: ${JSON.stringify(r.body).slice(0, 300)}`);
   assert(Array.isArray(r.body), what);
   return r.body;
};
/** Every key outside the table's client-visible set is null on every row. */
const onlyClientVisible = (table: keyof typeof CLIENT_VISIBLE, list: Record<string, unknown>[], who: string) => {
   const visible = new Set<string>(CLIENT_VISIBLE[table]);
   for (const row of list) {
      for (const [key, value] of Object.entries(row)) {
         if (!visible.has(key)) assertEquals(value, null, `${who}: ${table}.${key} is not client-visible but reads ${JSON.stringify(value)}`);
      }
   }
};
const SHARED_TABLES = Object.keys(CLIENT_VISIBLE) as (keyof typeof CLIENT_VISIBLE)[];

t('setup', async () => {
   f = await adminSetup();
});

t('CLIENT_VISIBLE equals the field_class catalog', async () => {
   const catalog = (await admin('field_class?client_visible=is.true&select=resource_name,field')).body as { resource_name: string; field: string }[];
   const fromCatalog: Record<string, string[]> = {};
   for (const { resource_name, field } of catalog) (fromCatalog[resource_name.replace('public.', '')] ??= []).push(field);
   const constant: Record<string, string[]> = {};
   for (const table of SHARED_TABLES) constant[table] = [...CLIENT_VISIBLE[table]];
   for (const table of Object.keys(fromCatalog)) fromCatalog[table].sort();
   for (const table of Object.keys(constant)) constant[table].sort();
   assertEquals(constant, fromCatalog);
   assertEquals(SHARED_TABLES.length, 8);
});

// 1. Masked reads.

t('client owner reads its shared order, line, shipment and sourcing with provider-only fields null', async () => {
   const [po] = rows(await asClient(f.clientOwner, `purchase_order?id=eq.${f.poShared}&select=*`), 'order');
   assertEquals([po.pi_total, po.notes, po.supplier_id, po.currency, po.deposit_rate, po.pi_number, po.incoterm_place], [
      null,
      null,
      null,
      null,
      null,
      null,
      null,
   ]);
   assertEquals(po.status, null, 'Q1: the raw status is provider-only');
   assertEquals(po.client_status, 'confirmed', 'the derived client status is visible');
   assert(typeof po.code === 'string' && po.code.length > 0);
   const [line] = rows(await asClient(f.clientOwner, `purchase_order_line?id=eq.${f.lineShared}&select=*`), 'line');
   assertEquals([line.unit_price, line.line_total, line.notes, line.spec_document_id], [null, null, null, null]);
   assertEquals([line.quantity, line.sell_price_eur, line.product_sku], [7, SHARED_SELL_PRICE, 'HTTP-SECRET']);
   const [ship] = rows(await asClient(f.clientOwner, `shipment?id=eq.${f.shipmentShared}&select=*`), 'shipment');
   assertEquals([ship.forwarder, ship.customs_broker, ship.demurrage_note, ship.incoterm_buy, ship.notes], [null, null, null, null, null]);
   assertEquals([ship.carrier, ship.mode], ['Visible Carrier', 'fcl20']);
   const [event] = rows(await asClient(f.clientOwner, `shipment_event?id=eq.${f.eventShared}&select=*`), 'event');
   assertEquals([event.channel, event.note, event.from_party], [null, null, null]);
   assertEquals(event.step, 1);
   const [src] = rows(await asClient(f.clientOwner, `sourcing?id=eq.${f.secretId}&select=*`), 'sourcing');
   assertEquals([src.purchase_price, src.notes, src.supplier_id, src.purchase_currency], [null, null, null, null]);
   assertEquals([src.manufacturer_art_no, src.product_sku], ['HTTP-ART', 'HTTP-SECRET'], 'Q3: manufacturer_art_no is client-visible');
   const [cr] = rows(await asClient(f.clientOwner, `change_request?id=eq.${f.crShared}&select=*`), 'change request');
   assertEquals([cr.cost_impact, cr.cost_payer], [null, null], 'Task 6: the CR cost on a provider order is provider-guarded');
   assertEquals(cr.title, 'HTTP-SHARED-CR');
});

t('client viewer reads shared rows masked or not at all', async () => {
   for (const table of SHARED_TABLES) {
      const r = await asClient(f.portal, `${table}?select=*&limit=50`);
      onlyClientVisible(table, rows(r, table), 'viewer');
      noLeak(r, `viewer ${table}`);
   }
   const [src] = rows(await asClient(f.portal, `sourcing?id=eq.${f.secretId}&select=purchase_price,notes,supplier_id`), 'sourcing');
   assertEquals(src, { purchase_price: null, notes: null, supplier_id: null });
   assertEquals(rows(await asClient(f.portal, `change_request?id=eq.${f.crShared}&select=cost_impact`), 'cr').every((x) => x.cost_impact === null), true);
});

t('every shared table returns only the client-visible set', async () => {
   for (const [who, token] of clients()) {
      for (const table of SHARED_TABLES) {
         const r = await asClient(token, `${table}?select=*&limit=50`);
         onlyClientVisible(table, rows(r, `${who} ${table}`), who);
         noLeak(r, `${who} ${table}`);
      }
   }
   const shared = rows(await asClient(f.clientOwner, 'purchase_order?select=id'), 'orders').map((x) => x.id);
   assert(shared.includes(f.poShared) && shared.includes(f.poId), 'the owner sees the shared orders');
});

t('client owner sees no unshared provider row', async () => {
   for (const [who, token] of clients()) {
      const ids = rows(await asClient(token, 'purchase_order?select=id,client_tenant_id'), who);
      assert(ids.every((x) => x.client_tenant_id === f.client), `${who}: ${JSON.stringify(ids)}`);
      for (const id of [f.poOther, f.poOwn]) assert(!ids.some((x) => x.id === id), `${who} sees ${id}`);
      for (const table of ['purchase_order_payment', 'purchase_order_update', 'supplier', 'supplier_contact']) {
         assertEquals(rows(await asClient(token, `${table}?select=*`), `${who} ${table}`), [], `${who} ${table}`);
      }
      const rel = rows(await asClient(token, 'provider_relationship?select=*'), `${who} relationship`);
      assert(rel.every((x) => x.client_tenant_id === f.client), `${who} sees another client's relationship`);
   }
});

// 2. Oracles.

t('filter oracle on a provider-only field returns nothing', async () => {
   for (const [who, token] of clients()) {
      for (const path of [
         `purchase_order?pi_total=eq.${SECRET_PI_TEXT}&select=id`,
         'purchase_order?pi_total=gt.0&select=id',
         'purchase_order?notes=like.*LEAK*&select=id',
         'purchase_order?supplier_id=not.is.null&select=id',
         'purchase_order?status=eq.pi_approved&select=id',
         'purchase_order?or=(pi_total.gt.0,notes.like.*LEAK*)&select=id',
         `purchase_order_line?unit_price=eq.${SECRET_UNIT_PRICE}&select=id`,
         'purchase_order_line?notes=like.*LEAK*&select=id',
         'shipment?forwarder=like.LEAK*&select=id',
         'shipment?demurrage_note=not.is.null&select=id',
         'shipment_event?channel=like.LEAK*&select=id',
         'sourcing?purchase_price=gt.0&select=id',
         'sourcing?notes=like.secret*&select=id',
         'change_request?cost_impact=like.*LEAK*&select=id',
         'change_request?cost_payer=eq.supplier&select=id',
      ]) {
         assertEquals(rows(await asClient(token, path), `${who} ${path}`), [], `${who} ${path}`);
      }
      // IS NULL sees the masked value, so it matches every row the plain read returns.
      const all = rows(await asClient(token, 'purchase_order?select=id&order=id'), who);
      assertEquals(rows(await asClient(token, 'purchase_order?pi_total=is.null&notes=is.null&select=id&order=id'), who), all);
   }
});

t('order by a provider-only field does not reorder', async () => {
   for (const [who, token] of clients()) {
      for (const [table, field] of [
         ['purchase_order', 'pi_total'],
         ['purchase_order', 'notes'],
         ['purchase_order', 'status'],
         ['purchase_order_line', 'unit_price'],
         ['shipment', 'forwarder'],
         ['sourcing', 'purchase_price'],
      ]) {
         const byField = await asClient(token, `${table}?select=id&order=${field}.desc,id`);
         const byId = await asClient(token, `${table}?select=id&order=id`);
         assertEquals(byField.status, 200, `${who} ${table}.${field}`);
         assertEquals(byField.body, byId.body, `${who} ${table} ordered by ${field}`);
      }
   }
});

t('count with a provider-only filter is zero and the row count does not change', async () => {
   for (const [who, token] of clients()) {
      const count = (path: string) => asClient(token, path, { headers: { Prefer: 'count=exact' } }).then((r) => r.headers.get('content-range'));
      assertEquals(await count('purchase_order?pi_total=gt.0&select=id'), '*/0', who);
      assertEquals(await count('purchase_order?notes=like.LEAK*&select=id'), '*/0', who);
      assertEquals(await count('purchase_order_line?unit_price=gt.0&select=id'), '*/0', who);
      const total = (await count('purchase_order?select=id'))?.split('/')[1];
      assertEquals((await count('purchase_order?pi_total=is.null&select=id'))?.split('/')[1], total, `${who}: count over a masked IS NULL`);
      // HEAD with a count: no body, and the same zero.
      const head = await asClient(token, 'purchase_order?pi_total=gt.0', { method: 'HEAD', headers: { Prefer: 'count=exact' } });
      assertEquals(head.headers.get('content-range'), '*/0', `${who} HEAD`);
   }
});

t('casts and aliases of a provider-only field read null', async () => {
   for (const [who, token] of clients()) {
      const r = await asClient(
         token,
         `purchase_order?id=eq.${f.poShared}&select=p:pi_total::text,n:notes::text,s:status::text,c:currency::text,d:deposit_rate::text`,
      );
      for (const row of rows(r, who)) assertEquals(row, { p: null, n: null, s: null, c: null, d: null }, who);
      const j = await asClient(token, `purchase_order?id=eq.${f.poShared}&select=pi_check->1,pi_check->>2`);
      noLeak(j, `${who} pi_check json path`);
   }
});

t('error bodies never contain a provider secret', async () => {
   for (const [who, token] of clients()) {
      const bodies: RestResult[] = [];
      for (const path of [
         `purchase_order?id=eq.${f.poShared}&pi_total=eq.abc`,
         `purchase_order?id=eq.${f.poShared}&notes=gt.%5B`,
         `purchase_order?id=eq.${f.poShared}&select=x:pi_total::int`,
         `purchase_order?id=eq.${f.poShared}&select=x:notes::int`,
         `purchase_order?id=eq.${f.poShared}&select=x:pi_number::int`,
         `purchase_order?id=eq.${f.poShared}&select=x:pi_total::date`,
         `purchase_order_line?id=eq.${f.lineShared}&select=x:notes::uuid`,
         `shipment?id=eq.${f.shipmentShared}&select=x:forwarder::int`,
         `purchase_order?id=eq.${f.poShared}&select=nope`,
      ]) {
         bodies.push(await asClient(token, path));
      }
      bodies.push(await asClient(token, `purchase_order?id=eq.${f.poShared}`, { method: 'PATCH', body: { pi_total: 'abc' } }));
      bodies.push(await asClient(token, `purchase_order?id=eq.${f.poShared}`, { method: 'PATCH', body: { pi_total: 1 } }));
      bodies.push(
         await asClient(token, 'purchase_order_line', {
            method: 'POST',
            body: { tenant_id: f.moesa, purchase_order_id: f.poShared, product_id: f.newProductId, quantity: 1, unit_price: 1 },
         }),
      );
      bodies.push(
         await asClient(token, 'purchase_order_line', {
            method: 'POST',
            body: { tenant_id: f.client, purchase_order_id: f.poShared, product_id: f.newProductId, quantity: 1, unit_price: 1 },
         }),
      );
      bodies.push(
         await asClient(token, 'shipment_line', {
            method: 'POST',
            body: { tenant_id: f.moesa, shipment_id: f.shipmentShared, purchase_order_id: f.poShared, purchase_order_line_id: f.lineShared, quantity: 1 },
         }),
      );
      for (const b of bodies) noLeak(b, `${who} error body`);
   }
});

// 3. Embeds.

t('embeds and R4 relationships carry no provider-only data', async () => {
   for (const [who, token] of clients()) {
      const r = await asClient(
         token,
         `purchase_order?id=eq.${f.poShared}&select=id,client_status,supplier(*),purchase_order_payment(*),purchase_order_update(*),purchase_order_line(id,unit_price,sell_price_eur,spec_document(*))`,
      );
      noLeak(r, `${who} order embeds`);
      for (const po of rows(r, who)) {
         assertEquals(po.supplier, null, who);
         assertEquals(po.purchase_order_payment, [], who);
         assertEquals(po.purchase_order_update, [], who);
         for (const line of po.purchase_order_line as Record<string, unknown>[]) {
            assertEquals([line.unit_price, line.spec_document, line.sell_price_eur], [null, null, SHARED_SELL_PRICE], who);
         }
      }
      const s = await asClient(
         token,
         `shipment?id=eq.${f.shipmentShared}&select=id,forwarder,shipment_purchase_order!shipment_purchase_order_shipment_fkey(purchase_order!shipment_purchase_order_po_fkey(id,status,pi_total,notes,client_status,supplier(*),purchase_order_line!purchase_order_line_po_fkey(unit_price,notes))),shipment_line!shipment_line_shipment_fkey(*),shipment_event(*)`,
      );
      noLeak(s, `${who} shipment embeds`);
      for (const ship of rows(s, who)) {
         for (const link of ship.shipment_purchase_order as { purchase_order: Record<string, unknown> | null }[]) {
            if (!link.purchase_order) continue;
            assertEquals([link.purchase_order.status, link.purchase_order.pi_total, link.purchase_order.supplier], [null, null, null], who);
         }
      }
      const sr = await asClient(token, `sourcing?id=eq.${f.secretId}&select=id,supplier(*)`);
      for (const row of rows(sr, who)) assertEquals(row.supplier, null, who);
      // There is no order → document relationship in api; the documents themselves stay in the provider.
      const d = await asClient(token, `purchase_order?id=eq.${f.poShared}&select=id,document(*)`);
      assert(d.status === 400 || rows(d, who).every((x) => x.document === null || (x.document as unknown[]).length === 0), who);
      noLeak(d, `${who} document embed`);
      for (const path of [
         `document?entity_id=eq.${f.poShared}&select=*`,
         `document?entity_id=eq.${f.secretId}&select=*`,
         'document?notes=like.LEAK*&select=*',
         'document?type=eq.pi&select=*',
         `media?select=*&storage_path=like.${f.moesa}*`,
      ]) {
         assertEquals(rows(await asClient(token, path), `${who} ${path}`), [], `${who} ${path}`);
      }
   }
});

t('audit history of a shared order is invisible to the client', async () => {
   for (const [who, token] of clients()) {
      for (const id of [f.poShared, f.lineShared, f.shipmentShared, f.eventShared, f.secretId]) {
         assertEquals(rows(await asClient(token, `audit_log?record_id=eq.${id}&select=*`), who), [], `${who} audit of ${id}`);
      }
      for (const table of ['purchase_order', 'purchase_order_line', 'purchase_order_payment', 'purchase_order_update', 'shipment', 'shipment_event', 'sourcing']) {
         assertEquals(rows(await asClient(token, `audit_log?table_name=eq.${table}&select=id`), who), [], `${who} audit of ${table}`);
      }
      // THO's own change request: its audit rows are visible to the owner, the provider's cost masked.
      const cr = await asClient(token, `audit_log?record_id=eq.${f.crShared}&select=*`);
      noLeak(cr, `${who} CR audit`);
      for (const row of rows(cr, who)) {
         for (const data of [row.new_data, row.old_data] as (Record<string, unknown> | null)[]) {
            if (data && 'cost_impact' in data && data.cost_impact !== null) assertEquals(data.cost_impact, { masked: true }, who);
         }
      }
      assertEquals(rows(await asClient(token, `audit_log?record_id=eq.${f.crShared}&new_data->>cost_impact=like.*LEAK*&select=id`), who), []);
      noLeak(await asClient(token, 'audit_transaction?select=*,actor(*)&limit=200&order=id.desc'), `${who} audit transactions`);
   }
});

// 4. Writes.

t('writes to shared rows are refused or reach nothing', async () => {
   for (const [who, token] of clients()) {
      const results: [string, RestResult][] = [];
      const w = async (label: string, path: string, init: RestInit) => {
         const r = await asClient(token, path, { ...init, headers: { ...rep, ...init.headers } });
         results.push([label, r]);
         return r;
      };
      const masked = await w('PATCH pi_total', `purchase_order?id=eq.${f.poShared}`, { method: 'PATCH', body: { pi_total: 1 } });
      if (who === 'owner') {
         assertEquals(masked.status, 403, JSON.stringify(masked.body));
         assertEquals(masked.body.message, 'field_write_forbidden');
      }
      for (const [label, path, body] of [
         ['order status', `purchase_order?id=eq.${f.poShared}`, { status: 'cancelled' }],
         ['order ready_on', `purchase_order?id=eq.${f.poShared}`, { ready_on: '2027-01-01' }],
         ['order project', `purchase_order?id=eq.${f.poShared}`, { project_id: null }],
         ['line quantity', `purchase_order_line?id=eq.${f.lineShared}`, { quantity: 1 }],
         ['line sell price', `purchase_order_line?id=eq.${f.lineShared}`, { sell_price_eur: 1 }],
         ['shipment carrier', `shipment?id=eq.${f.shipmentShared}`, { carrier: 'x' }],
         ['shipment status', `shipment?id=eq.${f.shipmentShared}`, { status: 'cancelled' }],
         ['event step', `shipment_event?id=eq.${f.eventShared}`, { step: 2 }],
         ['shipment line', `shipment_line?shipment_id=eq.${f.shipmentShared}`, { quantity: 1 }],
         ['sourcing name', `sourcing?id=eq.${f.secretId}`, { product_name: 'x' }],
         ['relationship', `provider_relationship?client_tenant_id=eq.${f.client}`, { client_name: 'x' }],
         ['order by masked filter', 'purchase_order?pi_total=gt.0', { ready_on: '2027-01-01' }],
      ] as [string, string, Record<string, unknown>][]) {
         const r = await w(label, path, { method: 'PATCH', body });
         assert(r.status >= 400 || (Array.isArray(r.body) && r.body.length === 0), `${who} PATCH ${label}: ${r.status} ${JSON.stringify(r.body).slice(0, 200)}`);
      }
      for (const [label, table, body] of [
         ['line', 'purchase_order_line', { tenant_id: f.moesa, purchase_order_id: f.poShared, product_id: f.newProductId, quantity: 1, unit_price: 1 }],
         ['payment', 'purchase_order_payment', { tenant_id: f.moesa, purchase_order_id: f.poShared, kind: 'other', amount: 1, currency: 'USD' }],
         ['update', 'purchase_order_update', { tenant_id: f.moesa, purchase_order_id: f.poShared, note: 'x' }],
         ['event', 'shipment_event', { tenant_id: f.moesa, shipment_id: f.shipmentShared, step: 2 }],
         ['shipment link', 'shipment_purchase_order', { tenant_id: f.moesa, shipment_id: f.shipmentShared, purchase_order_id: f.poId }],
         ['order', 'purchase_order', { tenant_id: f.moesa, client_tenant_id: f.client, supplier_id: f.supplierId, currency: 'USD', incoterm: 'FOB', deposit_rate: 1 }],
      ] as [string, string, Record<string, unknown>][]) {
         const r = await w(`POST ${label}`, table, { method: 'POST', body });
         assert(r.status >= 400, `${who} POST ${label}: ${r.status} ${JSON.stringify(r.body).slice(0, 200)}`);
      }
      for (const [label, path] of [
         ['order', `purchase_order?id=eq.${f.poShared}`],
         ['line', `purchase_order_line?purchase_order_id=eq.${f.poShared}`],
         ['shipment', `shipment?id=eq.${f.shipmentShared}`],
         ['shipment line', `shipment_line?shipment_id=eq.${f.shipmentShared}`],
         ['shipment link', `shipment_purchase_order?shipment_id=eq.${f.shipmentShared}`],
         ['event', `shipment_event?id=eq.${f.eventShared}`],
         ['sourcing', `sourcing?id=eq.${f.secretId}`],
         ['relationship', `provider_relationship?client_tenant_id=eq.${f.client}`],
      ]) {
         const r = await w(`DELETE ${label}`, path, { method: 'DELETE' });
         assert(r.status >= 400 || (Array.isArray(r.body) && r.body.length === 0), `${who} DELETE ${label}: ${r.status} ${JSON.stringify(r.body).slice(0, 200)}`);
      }
      // The client's own change request on the shared order: its cost stays the provider's.
      const cost = await w('PATCH CR cost', `change_request?id=eq.${f.crShared}`, { method: 'PATCH', body: { cost_impact: 'client cost' } });
      assert(cost.status >= 400 || (Array.isArray(cost.body) && cost.body.length === 0), `${who} CR cost: ${cost.status}`);
      for (const [label, r] of results) noLeak(r, `${who} ${label}`);
   }
   // Nothing changed.
   const [po] = (await admin(`purchase_order?id=eq.${f.poShared}&select=pi_total,status,ready_on,notes`)).body;
   assertEquals(po, { pi_total: SECRET_PI, status: 'pi_approved', ready_on: null, notes: `${SECRET_NOTE} shared` });
   assertEquals((await admin(`purchase_order_line?purchase_order_id=eq.${f.poShared}&select=id,quantity,sell_price_eur`)).body, [
      { id: f.lineShared, quantity: 7, sell_price_eur: SHARED_SELL_PRICE },
   ]);
   const [ship] = (await admin(`shipment?id=eq.${f.shipmentShared}&select=carrier,status`)).body;
   assertEquals(ship, { carrier: 'Visible Carrier', status: 'planned' });
   assertEquals((await admin(`shipment_event?shipment_id=eq.${f.shipmentShared}&select=id,step`)).body, [{ id: f.eventShared, step: 1 }]);
   assertEquals((await admin(`shipment_line?shipment_id=eq.${f.shipmentShared}&select=quantity`)).body, [{ quantity: 7 }]);
   assertEquals((await admin(`shipment_purchase_order?shipment_id=eq.${f.shipmentShared}&select=purchase_order_id`)).body, [{ purchase_order_id: f.poShared }]);
   assertEquals((await admin(`purchase_order_payment?purchase_order_id=eq.${f.poShared}&select=id`)).body.length, 1);
   assertEquals((await admin(`purchase_order_update?purchase_order_id=eq.${f.poShared}&select=id`)).body.length, 1);
   const [src] = (await admin(`sourcing?id=eq.${f.secretId}&select=purchase_price,product_name`)).body;
   assertEquals(src, { purchase_price: 12.5, product_name: 'HTTP secret' });
   const [cr] = (await admin(`change_request?id=eq.${f.crShared}&select=cost_impact,cost_payer`)).body;
   assertEquals(cr, { cost_impact: `${SECRET_PI_TEXT} LEAK-COST`, cost_payer: 'supplier' });
   const [rel] = (await admin(`provider_relationship?client_tenant_id=eq.${f.client}&select=client_name,status`)).body;
   assertEquals(rel, { client_name: 'THOMETZKI ONLINE HANDEL', status: 'active' });
});

t('return=representation of the client\'s own change request masks the provider cost', async () => {
   const r = await asClient(f.clientOwner, `change_request?id=eq.${f.crShared}`, {
      method: 'PATCH',
      body: { other_documents: 'client note' },
      headers: rep,
   });
   assertEquals(r.status, 200, JSON.stringify(r.body));
   assertEquals(r.body.length, 1);
   assertEquals([r.body[0].cost_impact, r.body[0].cost_payer], [null, null]);
   noLeak(r, 'CR representation');
});

// 5. Scope.

t('a forged x-tenant-ids naming the provider or another client changes nothing', async () => {
   for (const [who, token] of clients()) {
      for (const table of SHARED_TABLES) {
         const path = `${table}?select=*&order=created_at,${table === 'shipment_purchase_order' ? 'shipment_id' : 'id'}`;
         const honest = await rest(token, path, { headers: h(f.client) });
         assertEquals(honest.status, 200, `${who} ${table}`);
         for (const tenants of [
            [f.client, f.moesa],
            [f.client, f.moesa, f.europe],
            [f.client, f.otherClient],
            [f.moesa, f.client],
         ]) {
            const forged = await rest(token, path, { headers: h(f.client, tenants) });
            assertEquals(forged.body, honest.body, `${who} ${table} with x-tenant-ids ${tenants.length} tenants`);
         }
         // F17: a forged active tenant the user is no member of gives an empty scope.
         for (const tenant of [f.moesa, f.otherClient]) {
            const forged = await rest(token, path, { headers: h(tenant) });
            assert(forged.status >= 400 || (Array.isArray(forged.body) && forged.body.length === 0), `${who} ${table} as ${tenant}: ${JSON.stringify(forged.body).slice(0, 200)}`);
         }
      }
      const ids = rows(
         await rest(token, `purchase_order?id=in.(${f.poShared},${f.poOther},${f.poOwn})&select=id`, { headers: h(f.client, [f.client, f.moesa, f.otherClient]) }),
         who,
      ).map((x) => x.id);
      assert(!ids.includes(f.poOther) && !ids.includes(f.poOwn), `${who}: ${ids}`);
   }
});

// 6. RPCs and derived views.

t('RPCs and dashboards return no provider-only value', async () => {
   for (const [who, token] of clients()) {
      const rpc = (name: string, body: unknown, tenant = f.client) => rest(token, `rpc/${name}`, { method: 'POST', body, profile: 'public', headers: h(tenant) });
      const access = await rpc('my_access', {});
      assertEquals(access.status, 200);
      noLeak(access, `${who} my_access`);
      const forged = await rpc('my_access', { requested: f.moesa });
      assertEquals(forged.body.tenant_id, f.client, `${who}: my_access answered for the provider`);
      assert(!(forged.body.tenants as { id: string }[]).some((x) => x.id === f.moesa), `${who}: my_access lists the provider`);
      noLeak(forged, `${who} my_access(provider)`);
      const proc = await rpc('client_procurement', {});
      assertEquals(proc.status, 200);
      for (const row of proc.body as Record<string, unknown>[]) assertEquals(Object.keys(row).sort(), ['procurement_model', 'status']);
      const imp = await rpc('import_products', {
         rows: [{ sku: 'HTTP-SECRET', purchase_price: 1, supplier_code: 'TR1', manufacturer_art_no: 'X', sell_price_eur: 1 }],
      });
      noLeak(imp, `${who} import_products`);
      for (const view of [
         'purchase_order_overview',
         'shipment_overview',
         'incident_overview',
         'dashboard_purchase_order',
         'dashboard_shipment',
         'dashboard_change_request',
         'dashboard_incident',
         'dashboard_notification_feed',
         'dashboard_task_due',
         'dashboard_gate_pending',
         'dashboard_market',
         'dashboard_product_evidence',
         'product_with_evidence',
         'market_cell_overview',
         'media_library',
      ]) {
         const r = await asClient(token, `${view}?select=*`);
         assertEquals(r.status, 200, `${who} ${view}: ${JSON.stringify(r.body).slice(0, 200)}`);
         noLeak(r, `${who} ${view}`);
      }
      const [overview] = rows(await asClient(token, `purchase_order_overview?id=eq.${f.poShared}&select=*`), who);
      if (overview) assertEquals([overview.status, overview.pi_total ?? null, overview.supplier_code ?? null], [null, null, null], who);
   }
   // The provider's sourcing row is untouched by the client's import.
   const [src] = (await admin(`sourcing?id=eq.${f.secretId}&select=purchase_price,manufacturer_art_no,supplier_id`)).body;
   assertEquals([src.purchase_price, src.manufacturer_art_no], [12.5, 'HTTP-ART']);
   assertNotEquals(src.supplier_id, null);
});

// 7. Storage.

t('Storage: client users cannot download the provider PI file, the provider can', async () => {
   const url = `${API_URL}/storage/v1/object/authenticated/media/${f.piObject}`;
   const get = (token: string) => fetch(url, { headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}` } });
   for (const [who, token] of clients()) {
      const r = await get(token);
      const text = await r.text();
      assert(!r.ok, `${who} downloaded the PI file (${r.status})`);
      assert(!text.includes('HTTP-PI'), who);
      const sign = await fetch(`${API_URL}/storage/v1/object/sign/media/${f.piObject}`, {
         method: 'POST',
         headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
         body: JSON.stringify({ expiresIn: 60 }),
      });
      const signText = await sign.text();
      assert(!sign.ok, `${who} signed the PI URL: ${signText.slice(0, 120)}`);
      const list = await fetch(`${API_URL}/storage/v1/object/list/media`, {
         method: 'POST',
         headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
         body: JSON.stringify({ prefix: `${f.moesa}/`, limit: 100 }),
      });
      const listed = await list.text();
      assert(!listed.includes('pi.pdf'), `${who} listed the provider's files: ${listed.slice(0, 120)}`);
   }
   const provider = await get(f.providerMgmt);
   assertEquals(provider.status, 200);
   assert((await provider.text()).includes('HTTP-PI'));
});

// 9. Self-widening.

t('a self-granted role does not unmask shared rows', async () => {
   const permissions = ((await admin('permission?select=id')).body as { id: string }[]).map((p) => p.id);
   const pub = (path: string, body: unknown) => rest(f.clientOwner, path, { method: 'POST', body, profile: 'public', headers: h(f.client) });
   // Every sensitive field right the owner holds in THO (all of them, as the owner), read and write.
   const own = (await pub('rpc/my_access', {})).body.fields as { resource_name: string; field: string; can_read: boolean; can_write: boolean }[];
   assert(own.some((x) => x.resource_name === 'public.purchase_order' && x.field === 'pi_total' && x.can_read), 'the owner holds pi_total in THO');
   const saved = await pub('rpc/save_role', {
      role_data: { tenant_id: f.client, display_name: 'http_spy' },
      permission_ids: permissions,
      field_rights: own.filter((x) => x.can_read).map(({ resource_name, field, can_write }) => ({ resource_name, field, can_read: true, can_write })),
   });
   assertEquals(saved.status, 200, JSON.stringify(saved.body));
   const spy = saved.body as string;
   const assigned = await pub('rpc/set_user_roles', { user_id: f.portalUserId, role_ids: [f.viewerRoleId, spy] });
   assert(assigned.status < 300, JSON.stringify(assigned.body));
   try {
      const access = await rest(f.portal, 'rpc/my_access', { method: 'POST', body: {}, profile: 'public', headers: h(f.client) });
      const fields = access.body.fields as { resource_name: string; field: string; can_read: boolean }[];
      assert(fields.some((x) => x.resource_name === 'public.purchase_order' && x.field === 'pi_total' && x.can_read), 'the spy role holds pi_total');
      const [po] = rows(await asClient(f.portal, `purchase_order?id=eq.${f.poShared}&select=*`), 'spy order');
      assert(po, 'the spy role reads the shared order');
      assertEquals([po.pi_total, po.notes, po.supplier_id, po.status], [null, null, null, null]);
      for (const table of SHARED_TABLES) {
         const r = await asClient(f.portal, `${table}?select=*&limit=50`);
         onlyClientVisible(table, rows(r, `spy ${table}`), 'spy');
         noLeak(r, `spy ${table}`);
      }
      assertEquals(rows(await asClient(f.portal, 'purchase_order?pi_total=gt.0&select=id'), 'spy'), []);
      assertEquals(rows(await asClient(f.portal, `change_request?id=eq.${f.crShared}&select=cost_impact`), 'spy'), [{ cost_impact: null }]);
      assertEquals(rows(await asClient(f.portal, 'purchase_order_payment?select=id'), 'spy'), []);
      assertEquals(rows(await asClient(f.portal, 'supplier?select=id'), 'spy'), []);
      assertEquals(rows(await asClient(f.portal, `audit_log?record_id=eq.${f.poShared}&select=id`), 'spy'), []);
      const w = await asClient(f.portal, `purchase_order?id=eq.${f.poShared}`, { method: 'PATCH', body: { pi_total: 1 }, headers: rep });
      assert(w.status >= 400 || (Array.isArray(w.body) && w.body.length === 0), `spy write: ${w.status}`);
      noLeak(w, 'spy write');
   } finally {
      await pub('rpc/set_user_roles', { user_id: f.portalUserId, role_ids: [f.viewerRoleId] });
   }
});

// 10. Provider side.

t('a provider user with both tenants in scope reads everything its provider rights allow', async () => {
   const scope = h(f.moesa, [f.moesa, f.client]);
   const get = (path: string) => rest(f.providerMgmt, path, { headers: scope });
   const [po] = rows(await get(`purchase_order?id=eq.${f.poShared}&select=pi_total,notes,status,supplier_id,currency`), 'provider order');
   assertEquals([po.pi_total, po.notes, po.status, po.currency], [SECRET_PI, `${SECRET_NOTE} shared`, 'pi_approved', 'USD']);
   assertNotEquals(po.supplier_id, null);
   const [line] = rows(await get(`purchase_order_line?id=eq.${f.lineShared}&select=unit_price,notes`), 'provider line');
   assertEquals(line, { unit_price: SECRET_UNIT_PRICE, notes: `${SECRET_NOTE} line` });
   const [ship] = rows(await get(`shipment?id=eq.${f.shipmentShared}&select=forwarder,demurrage_note`), 'provider shipment');
   assertEquals(ship, { forwarder: 'LEAK-FORWARDER', demurrage_note: 'LEAK-DEMURRAGE' });
   const [src] = rows(await get(`sourcing?id=eq.${f.secretId}&select=purchase_price,notes`), 'provider sourcing');
   assertEquals(src, { purchase_price: 12.5, notes: 'secret note' });
   assertEquals(rows(await get(`purchase_order_payment?purchase_order_id=eq.${f.poShared}&select=amount`), 'payments'), [{ amount: 296296.3 }]);
   const [cr] = rows(await get(`change_request?id=eq.${f.crShared}&select=cost_impact`), 'provider CR');
   assertEquals(cr.cost_impact, `${SECRET_PI_TEXT} LEAK-COST`);
   assert(rows(await get(`product?tenant_id=eq.${f.client}&select=id`), 'client products').length > 0);
   // The same user acting in THO alone reads the client's view of the provider's rows.
   const [asClientView] = rows(await rest(f.providerMgmt, `purchase_order?id=eq.${f.poShared}&select=pi_total,status`, { headers: h(f.client) }), 'akif in THO');
   assertEquals(asClientView, { pi_total: null, status: null });
});

t('a provider user without an invitation reads no client row', async () => {
   const scope = h(f.moesa, [f.moesa, f.client]);
   assertEquals(rows(await rest(f.providerOwner, `product?tenant_id=eq.${f.client}&select=id`, { headers: scope }), 'baris'), []);
   assertEquals(rows(await rest(f.providerOwner, `change_request?id=eq.${f.crShared}&select=id`, { headers: scope }), 'baris'), []);
   const [po] = rows(await rest(f.providerOwner, `purchase_order?id=eq.${f.poShared}&select=pi_total`, { headers: scope }), 'baris order');
   assertEquals(po.pi_total, SECRET_PI, 'the provider owner reads its own order');
});

t('every app select string resolves for client users', async () => {
   for (const [who, token] of clients()) {
      const failures: string[] = [];
      for (const [path, select] of APP_SELECTS) {
         const r = await asClient(token, `${path}?select=${encodeURIComponent(select)}&limit=1`);
         if (r.status !== 200) failures.push(`${r.status} ${path} ${select}: ${JSON.stringify(r.body).slice(0, 200)}`);
         noLeak(r, `${who} ${path}`);
      }
      assertEquals(failures, [], who);
   }
});

// 8. Ended relationship (last: ending is final; the other client is the fixture's own).

t('after the relationship ends the shared history stays readable, masked and read-only', async () => {
   const other = (path: string, init: RestInit = {}) => rest(f.otherClientOwner, path, { ...init, headers: { ...h(f.otherClient), ...init.headers } });
   const before = rows(await other(`purchase_order?select=*`), 'other before');
   assertEquals(before.map((x) => x.id), [f.poOther]);
   const ended = await rest(f.otherClientOwner, 'rpc/end_provider_relationship', {
      method: 'POST',
      body: { relationship_id: f.otherRelationshipId },
      profile: 'public',
      headers: h(f.otherClient),
   });
   assert(ended.status < 300, JSON.stringify(ended.body));
   const after = await other('purchase_order?select=*');
   const [po] = rows(after, 'other after');
   assertEquals(po.id, f.poOther);
   assertEquals([po.pi_total, po.notes, po.status, po.supplier_id], [null, null, null, null]);
   assertEquals(po.client_status, 'pending');
   onlyClientVisible('purchase_order', [po], 'ended');
   noLeak(after, 'ended order');
   const [rel] = rows(await other('provider_relationship?select=*'), 'other relationship');
   assertEquals([rel.status, rel.notes, rel.restricted_drive_url], ['ended', null, null]);
   onlyClientVisible('provider_relationship', [rel], 'ended');
   assertEquals(rows(await other('purchase_order?pi_total=gt.0&select=id'), 'ended oracle'), []);
   const forged = await other('purchase_order?select=*', { headers: h(f.otherClient, [f.otherClient, f.moesa]) });
   assertEquals(forged.body, after.body);
   for (const [method, body] of [['PATCH', { ready_on: '2027-01-01' }], ['PATCH', { pi_total: 1 }], ['DELETE', undefined]] as const) {
      const w = await other(`purchase_order?id=eq.${f.poOther}`, { method, body, headers: rep });
      assert(w.status >= 400 || (Array.isArray(w.body) && w.body.length === 0), `ended ${method}: ${w.status} ${JSON.stringify(w.body)}`);
      noLeak(w, `ended ${method}`);
   }
   const [stored] = (await admin(`purchase_order?id=eq.${f.poOther}&select=pi_total,ready_on`)).body;
   assertEquals(stored, { pi_total: SECRET_PI, ready_on: null });
   // Nothing new is shared under the ended relationship.
   const fresh = await rest(f.providerMgmt, 'purchase_order', {
      method: 'POST',
      headers: h(f.moesa),
      body: { tenant_id: f.moesa, client_tenant_id: f.otherClient, supplier_id: f.supplierId, currency: 'USD', incoterm: 'FOB', deposit_rate: 30 },
   });
   assertEquals(fresh.body?.message, 'relationship_inactive', `a new order for an ended client: ${fresh.status} ${JSON.stringify(fresh.body)}`);
});

t('teardown', async () => {
   await adminTeardown(f);
});
