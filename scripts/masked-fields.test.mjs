// The generated masked-field list against public.field_class. The comparison needs the local
// database and is skipped without it, unless MASKED_FIELDS_REQUIRE_DB is set (CI's database job,
// `pnpm test:db`), where a missing database fails it. Dependency-free: node builtins only.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import {
   CLIENT_VISIBLE_OUTPUT,
   fetchClientVisible,
   fetchPairs,
   OUTPUT,
   parseGenerated,
   parseRows,
   render,
   renderClientVisible
} from './masked-fields.mjs';

test('renders the pairs by table and reads them back', () => {
   const pairs = parseRows('product|notes\nproduct|purchase_price\nuser|email\n');
   assert.deepEqual(parseGenerated(render(pairs)), pairs);
   assert.match(render(pairs), /product: \['notes', 'purchase_price'\]/);
});

let database = null;
let unreachable = null;
try {
   database = fetchPairs();
} catch (error) {
   unreachable = error;
}
const required = !!process.env.MASKED_FIELDS_REQUIRE_DB;

test('the committed list matches public.field_class', { skip: !database && !required && 'no local database' }, () => {
   if (!database) throw new Error(`the local database is required: ${unreachable?.message}`);
   assert.ok(database.length > 0, 'field_class lists sensitive fields');
   assert.deepEqual(parseGenerated(readFileSync(OUTPUT, 'utf8')), database);
});

test('renders the client-visible fields by table and reads them back', () => {
   const rows = parseRows('purchase_order|code\npurchase_order|client_status\nshipment|eta\n');
   const source = renderClientVisible(rows);
   assert.deepEqual(parseGenerated(source), rows);
   assert.match(source, /purchase_order: \['client_status', 'code'\]/);
});

const needDb = { skip: !database && !required && 'no local database' };
const generated = () => {
   const masked = {};
   for (const [table, field] of parseGenerated(readFileSync(OUTPUT, 'utf8'))) (masked[table] ??= []).push(field);
   return masked;
};

test('a provider-only open column of a shared table is listed', needDb, () => {
   assert.ok(generated().purchase_order.includes('notes') && generated().shipment.includes('forwarder'));
});

test('raw purchase_order.status is listed, the derived client_status is not (Q1)', needDb, () => {
   assert.ok(generated().purchase_order.includes('status'));
   assert.ok(!generated().purchase_order.includes('client_status'));
});

test('a client-visible open column is not listed', needDb, () => {
   assert.ok(!generated().purchase_order.includes('code'));
   // A sensitive field that is also client-visible (Q3) stays listed: a role of the owning tenant
   // without the read still gets NULL.
   assert.ok(generated().sourcing.includes('manufacturer_art_no'));
});

test('the guarded cost fields are listed, affected_parties too (it is sensitive, not guarded)', needDb, () => {
   for (const f of ['cost_impact', 'cost_payer']) assert.ok(generated().change_request.includes(f));
   for (const f of ['cost_amount', 'cost_currency', 'cost_payer']) assert.ok(generated().incident_log.includes(f));
   assert.ok(generated().incident.includes('affected_parties'));
});

test('the client-visible constants match public.field_class and carry client_status', needDb, () => {
   if (!database) throw new Error(`the local database is required: ${unreachable?.message}`);
   const rows = fetchClientVisible();
   assert.deepEqual(parseGenerated(readFileSync(CLIENT_VISIBLE_OUTPUT, 'utf8')), rows);
   assert.ok(rows.some(([t, f]) => t === 'purchase_order' && f === 'client_status'));
   assert.ok(!rows.some(([t, f]) => t === 'purchase_order' && f === 'status'));
});
