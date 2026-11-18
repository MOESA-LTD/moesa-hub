# Customer = Tenant, Plan 2 of 3: Sharing and its Security Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Share provider-procured rows with the client tenant relationally, limited to a fixed client-visible field set that the client can narrow but never widen, link client incidents and change requests to provider orders, and prove over SQL and HTTP that a client user, owner included, cannot read a provider-only field or an unshared provider row by any path.

**Architecture:** A row is shared when it carries `client_tenant_id` (Plan 1: set only under an active provider-procures relationship, immutable, backed by a composite FK to the relationship). Sharing is one more RLS predicate, `client_tenant_id = ANY (scope)`, on SELECT only, so shared rows stay read-only. The masked-view generator learns two catalog facts per field: `client_visible` (in the fixed client-visible set of a shared table) and `rights_column` (the column naming the tenant whose rights decide). A provider-only field is evaluated against the row's own `tenant_id` with no "readable in the whole scope" shortcut, so the client tenant's rights, including owner bypass, never reach it. Everything lives in new migrations `066`–`068`, because it extends the field-security generator the way `059` did and is the new security surface a reviewer reads in one place.

**Tech Stack:** Postgres 15 + pgTAP + PostgREST, Deno HTTP attack suite, Vue 3.5 + PrimeVue 4 + TanStack Query + CASL, vitest.

**Spec:** `docs/superpowers/specs/2026-11-18-customer-as-tenant-design.md` (decisions 9, 10, 12, 13, 15; Goals; Anti-goals; "Calls made"). Security model: `docs/superpowers/specs/2026-11-08-field-permissions-design.md` (R1–R12, S1–S8). Depends on Plan 1 (`docs/superpowers/plans/2026-11-18-customer-as-tenant-1-foundation.md`).

## Global Constraints

- "Müşteri tenant'ı okumaması gereken alanları API istekleriyle dahi okuyamasın." It "holds for the tenant owner too."
- Client-visible set (spec): "status, dates, quantities, products, the selling price per line, shipment ETA and tracking". "Payments, the deposit and any balance stay provider-only." "Purchase price, landed cost, supplier identity and contact, supplier terms and provider-internal notes are never visible to the client tenant, owner included." Contract terms are readable by the client; "Provider-internal notes and the restricted Drive link are not."
- Paths that must not leak: "filters, ordering, counts, embeds, forged tenant headers, RETURNING, error messages or audit history", R4 relationships, RPCs, Storage files of provider documents.
- "No owner bypass on shared rows. … Their role editor cannot even offer those fields." Client roles "can narrow but never widen" the client-visible set.
- "Shared rows are read-only for the client in this round."
- "After the relationship ends, the client keeps seeing the shared history."
- "Provider users reach client data only through their invitation into the client tenant. The relationship grants no extra read."
- "No sync": no copy of provider data in the client tenant.
- R10 budget as amended: reads max(+15%, +5 ms) internal, max(+40%, +10 ms) restricted; writes +15 ms.
- No "MOESA" in schema, error codes or app copy.
- `private.api_view_drift()` stays empty; every new definer callable by `authenticated` enters the 064 allowlist deliberately.

## Review Focus

- **A client user whose role lacks `select` on `purchase_order` in its own tenant:** sees no shared order at all (table-level narrowing), not an order with NULLs (Task 2 test `client without select sees no shared order`).
- **A provider staff member with both tenants in scope and a client-tenant role that grants `cost`:** a provider order's `pi_total` follows the provider-tenant role only; a coordinator without cost rights in the provider tenant still reads NULL (Task 3 test `client-tenant rights never unmask a provider-only field`).
- **A relationship switched to client-procures, then ended:** the client still reads the old shared orders with the same masked set, and a line the provider adds to an existing shared order after the switch is shared too (the line inherits the order's client; no new order may name the client) (Task 2 tests `ended relationship keeps history`, `a line added after the switch is shared`).
- **A change request whose provider-order link is removed by the client to unmask the cost:** refused with `cost_link_forbidden` (Task 6 test).
- **The client's dashboard and overview pages (derived api views) on a shared order:** every provider-only figure reads NULL, including totals computed from it (Task 7 leak scan over every api relation).

---

## File Structure

- Create: `supabase/migrations/066_shared_catalog.sql`, `067_shared_rows.sql`, `068_provider_order_links.sql`
- Create tests: `supabase/tests/database/066_shared_catalog.test.sql`, `067_shared_rows.test.sql`, `068_provider_order_links.test.sql`, `069_shared_leak_scan.test.sql`
- Modify: `supabase/tests/database/053_api_schema.test.sql` (drift fixtures for shared tables), `064_field_security_cutover.test.sql` (allowlist), `scripts/masked-fields.mjs`, `scripts/masked-fields.test.mjs`, `app/src/@types/maskedFields.generated.ts`, `docs/superpowers/specs/2026-11-08-field-classification.md`
- Create: `supabase/functions/http-tests/shared_rows_http_test.ts`; modify `supabase/functions/http-tests/helpers.ts`
- Modify: `supabase/perf/field_security_perf.sql`, `supabase/perf/field_security_perf_load.sql`, `scripts/field-security-perf.mjs`
- Modify: `supabase/seed_story.sql`, `supabase/seed_story.check.sql`
- App: `app/src/composables/useSharedRow.ts` (new), PO and shipment pages and tables, `components/service-components/select-permissions/*`, incident and change-request forms.

---

### Task 1: Catalog: client-visible set and rights column

**Files:**
- Create: `supabase/migrations/066_shared_catalog.sql`
- Test: `supabase/tests/database/066_shared_catalog.test.sql`

**Interfaces:**
- Produces:
  - `public.field_class` gains `client_visible BOOLEAN NOT NULL DEFAULT FALSE` and `rights_column TEXT NULL`. CHECK `field_class_client_visible_shared`: `client_visible` only on a resource for which `private.is_shared_table(split_part(resource_name, '.', 2))`; trigger-free CHECK is impossible across tables, so the rule is a pgTAP schema assertion (below), as `field_class` completeness already is.
  - `private.is_shared_table(p_table TEXT) RETURNS BOOLEAN` STABLE: `public.<p_table>` has a column `client_tenant_id` with a foreign key `(tenant_id, client_tenant_id) → public.provider_relationship (tenant_id, client_tenant_id)`.
  - The shared tables are exactly: `provider_relationship` (its `client_tenant_id` is the pair itself; `is_shared_table` returns TRUE for it by name), `sourcing`, `purchase_order`, `purchase_order_line`, `shipment`, `shipment_event`, `shipment_line`, `shipment_purchase_order`.
  - The fixed client-visible set (`client_visible = TRUE`), every other column of those tables provider-only:
    - `provider_relationship`: `id, tenant_id, client_tenant_id, client_code, client_name, provider_name, procurement_model, status, accepted_at, ended_at, commercial_model, packages, contract_status, contract_accepted_on, start_on, deposit_rate, extra_cost_rule, eu_responsible_person, created_at, updated_at`
    - `sourcing`: `id, tenant_id, client_tenant_id, product_tenant_id, product_id, product_sku, product_name, sell_price_eur, price_list_version, created_at, updated_at`
    - `purchase_order`: `id, tenant_id, client_tenant_id, code, status, project_id, project_tenant_id, project_code, ready_on, created_at, updated_at`
    - `purchase_order_line`: `id, tenant_id, client_tenant_id, purchase_order_id, position, product_id, product_tenant_id, product_sku, product_name, quantity, sell_price_eur, created_at, updated_at`
    - `shipment`: `id, tenant_id, client_tenant_id, code, status, mode, carrier, container_no, seal_no, delivery_warehouse_id, warehouse_tenant_id, delivery_address, ready_on, booking_confirmed_on, etd, eta, customs_cleared_on, planned_delivery_on, delivered_at, carton_count, pallet_count, volume_m3, gross_kg, accepted_on, quantity_matches, has_damage, dispute_deadline_at, created_at, updated_at`
    - `shipment_event`: `id, tenant_id, client_tenant_id, shipment_id, happened_at, step, created_at, updated_at`
    - `shipment_line`: every column; `shipment_purchase_order`: every column.
  - Provider-only therefore includes, among others: `purchase_order.supplier_id, currency, incoterm, incoterm_place, deposit_rate, tolerance_pct, penalty_rule, packing_instruction_document_id, pi_*, notes`; `purchase_order_line.unit_price, line_total, pi_line_total, spec_document_id, notes`; `shipment.forwarder, customs_broker, incoterm_buy, incoterm_sell, is_insured, free_days_port, free_days_detention, demurrage_note, accepted_by, notes`; `shipment_event.from_party, to_party, channel, note, created_by`; `provider_relationship.contract_document_id, restricted_drive_url, notes`; all sourcing cost and supplier columns.
  - `rights_column` rows are added by Task 6 (`guard_tenant_id`).
- [ ] **Step 1: Write `066_shared_catalog.test.sql` (`SELECT plan(6)`)**

```sql
SELECT set_eq($$ SELECT c.relname::TEXT FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' AND private.is_shared_table(c.relname) $$,
   ARRAY['provider_relationship','sourcing','purchase_order','purchase_order_line','shipment','shipment_event','shipment_line','shipment_purchase_order'], 'the shared tables');
SELECT is_empty($$ SELECT resource_name, field FROM public.field_class WHERE client_visible AND NOT private.is_shared_table(split_part(resource_name, '.', 2)) $$, 'client_visible only on shared tables');
SELECT set_eq($$ SELECT field FROM public.field_class WHERE resource_name = 'public.purchase_order' AND client_visible $$,
   ARRAY['id','tenant_id','client_tenant_id','code','status','project_id','project_tenant_id','project_code','ready_on','created_at','updated_at'], 'purchase_order client-visible set');
SELECT set_eq($$ SELECT field FROM public.field_class WHERE resource_name = 'public.purchase_order_line' AND client_visible $$,
   ARRAY['id','tenant_id','client_tenant_id','purchase_order_id','position','product_id','product_tenant_id','product_sku','product_name','quantity','sell_price_eur','created_at','updated_at'], 'line client-visible set');
SELECT is_empty($$ SELECT field FROM public.field_class WHERE client_visible AND group_name IN ('cost','supplier_identity','supplier_contact','supplier_terms','finance','internal_note') $$, 'no cost, supplier, finance or internal note is client-visible');
SELECT is_empty($$ SELECT 1 FROM public.field_class WHERE resource_name IN ('public.purchase_order_payment','public.purchase_order_update','public.supplier','public.supplier_contact') AND client_visible $$, 'payments, updates and suppliers are never shared');
```
- [ ] **Step 2: Run** `cd supabase && supabase db reset && supabase test db --file tests/database/066_shared_catalog.test.sql` → FAIL (`is_shared_table` missing).
- [ ] **Step 3: Implement** `066_shared_catalog.sql`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(sharing): client-visible field set in the catalog`.

---

### Task 2: Shared-row RLS

**Files:**
- Create: `supabase/migrations/067_shared_rows.sql` (section 1)
- Test: `supabase/tests/database/067_shared_rows.test.sql` (section "rows")

**Interfaces:**
- Consumes: `private.is_shared_table`, `private.tenant_scope()`, `private.permitted_tenants(text, text)`.
- Produces: `private.enable_shared_rows(p_table TEXT) RETURNS VOID` (owner postgres, revoked from all), run for each shared table. It:
  1. refuses (`field_security_unsupported`) a table where `private.is_shared_table` is FALSE;
  2. replaces the restrictive SELECT policy `restrict_selects_to_current_tenant` with
     `USING (tenant_id = ANY ((SELECT private.tenant_scope())::UUID[]) OR client_tenant_id = ANY ((SELECT private.tenant_scope())::UUID[]))`;
  3. adds the permissive policy `shared_select` `FOR SELECT TO authenticated USING (client_tenant_id = ANY ((SELECT private.permitted_tenants('public.<table>', 'select'))::UUID[]))`;
  4. leaves INSERT/UPDATE/DELETE policies untouched (their restrictive `tenant_id = ANY (scope)` keeps shared rows read-only);
  5. creates `<table>_client_idx ON (client_tenant_id) WHERE client_tenant_id IS NOT NULL` when Plan 1 did not.
  `private.enable_tenant_level_security` gets one guard: on a shared table it calls `enable_shared_rows` after creating the default policies, so re-running it cannot silently drop sharing.
  The sharing predicate in words: **a client user sees a provider row exactly when the row's `client_tenant_id` is one of the tenants of the request scope (header `x-tenant-ids` ∩ the user's tenants) and the user's roles grant `select` on that table in that client tenant.** Because `client_tenant_id` exists only under an accepted relationship (Plan 1 FK) and is immutable, nothing else is needed; ending the relationship changes neither.
- [ ] **Step 1: Write the "rows" section of `067_shared_rows.test.sql` (this section: 12 assertions; the file's `SELECT plan(32)` covers Tasks 2–4).** Fixture: provider P with coordinator `pc`, client C (provider-procures) with owner `co`, member `cv` (role `viewer`: select on purchase_order, shipment, sourcing, provider_relationship), member `cn` (role without select on purchase_order); client D (another provider-procures client of P); P orders `po_c` (client C), `po_d` (client D), `po_own` (no client); `rel_c` with notes.

```sql
SELECT tests.authenticate_as_scope('co', ARRAY[:'C']);
SELECT set_eq($$ SELECT id FROM api.purchase_order $$, ARRAY[:'po_c']::UUID[], 'client owner sees exactly its shared order');
SELECT is_empty($$ SELECT 1 FROM api.purchase_order_payment $$, 'payments are never shared');
SELECT is_empty($$ SELECT 1 FROM api.supplier $$, 'suppliers are never shared');
SELECT is((SELECT count(*)::INT FROM api.provider_relationship), 1, 'client reads its relationship');
SELECT tests.authenticate_as_scope('co', ARRAY[:'C', :'P']);
SELECT set_eq($$ SELECT id FROM api.purchase_order $$, ARRAY[:'po_c']::UUID[], 'a forged scope naming the provider changes nothing');
SELECT tests.authenticate_as_scope('cn', ARRAY[:'C']);
SELECT is_empty($$ SELECT 1 FROM api.purchase_order $$, 'client without select sees no shared order');
SELECT tests.authenticate_as_scope('pc', ARRAY[:'P']);
SELECT set_eq($$ SELECT id FROM api.purchase_order $$, ARRAY[:'po_c', :'po_d', :'po_own']::UUID[], 'provider sees its own rows');
SELECT tests.unauthenticate();
SELECT lives_ok($$ UPDATE public.provider_relationship SET procurement_model = 'client' WHERE id = :'rel_c' $$, 'switch to client-procures');
SELECT tests.authenticate_as_scope('pc', ARRAY[:'P']);
SELECT lives_ok($$ INSERT INTO api.purchase_order_line (tenant_id, purchase_order_id, product_id, quantity) VALUES (:'P', :'po_c', :'client_product', 5) $$, 'provider adds a line after the switch');
SELECT tests.authenticate_as_scope('co', ARRAY[:'C']);
SELECT is((SELECT count(*)::INT FROM api.purchase_order_line WHERE purchase_order_id = :'po_c'), 2, 'a line added after the switch is shared');
SELECT lives_ok($$ SELECT public.end_provider_relationship(:'rel_c') $$, 'the client owner ends the relationship');
SELECT set_eq($$ SELECT id FROM api.purchase_order $$, ARRAY[:'po_c']::UUID[], 'ended relationship keeps history');
```
  (`tests.authenticate_as_scope(user, tenants)` is a test helper added to `private.create_test_helpers()` in this task: it sets `request.jwt.claims` and `request.headers` with `x-tenant-id` = first tenant and `x-tenant-ids` = all, as `private.impersonate_scope` does. `pc` holds `select` on `product` in C through an invitation membership, so the line's client link passes Plan 1's guard. The fixture's `po_c` has one line before this section.)
- [ ] **Step 2: Run** the file → FAIL.
- [ ] **Step 3: Implement** section 1 of `067_shared_rows.sql` and the helper.
- [ ] **Step 4: Run** → the 12 row assertions PASS (masking assertions of Task 3 still fail).
- [ ] **Step 5: Commit** `feat(sharing): shared rows readable by the client tenant`.

---

### Task 3: Masking generator for shared rows

**Files:**
- Modify: `supabase/migrations/067_shared_rows.sql` (section 2)
- Test: `supabase/tests/database/067_shared_rows.test.sql` (section "masking"), `supabase/tests/database/053_api_schema.test.sql`

**Interfaces:**
- Produces: `CREATE OR REPLACE` of `private.api_column_expr(text, text)`, `private.api_view_from(text)` and `private.api_view_drift()`, then `private.enable_field_security(t)` re-run for every shared table and for `incident`, `change_request` (Task 6), and `audit_log`.
  - `api_view_from` adds one entry `(SELECT coalesce(private.tenant_scope(), '{}')) AS s` to `m` when the table is shared (once per view).
  - `api_column_expr(p_table, p_column)`: the exact rule, `n` the column's attnum, `shared := private.is_shared_table(p_table)`, `cv := field_class.client_visible`, `rc := field_class.rights_column`:

```text
sensitive and rc IS NOT NULL                → CASE WHEN t.<rc> = ANY (m.t<n>) THEN t.<c> END
sensitive and shared and cv                 → CASE WHEN m.a<n> OR t.tenant_id = ANY (m.t<n>) OR t.client_tenant_id = ANY (m.t<n>) THEN t.<c> END
sensitive and shared and not cv             → CASE WHEN t.tenant_id = ANY (m.t<n>) THEN t.<c> END
sensitive otherwise                         → unchanged: CASE WHEN m.a<n> OR t.tenant_id = ANY (m.t<n>) THEN t.<c> END
open and shared and not cv                  → CASE WHEN t.tenant_id = ANY (m.s) THEN t.<c> END
open otherwise                              → t.<c>
JSON-masked column on a shared table        → refused (field_security_unsupported) unless it is sensitive and not cv
```

    Why the shortcut goes: `m.a<n>` means "readable in every tenant of the scope"; a shared row's `tenant_id` lies outside the client's scope, so the shortcut would unmask it for a client owner (owner bypass). `t.tenant_id = ANY (m.t<n>)` names the provider tenant only, so a client-tenant right (or ownership) never reaches a provider-only field. A client-visible sensitive field may be read through either tenant's right, which is how a client role narrows it (a role without `sell_price` read reads NULL).
  - `api_view_drift()` adds problems `'unshared <c>'` (a provider-only column of a shared table not gated on `t.tenant_id`) and `'shared without s'` (a shared table's `m` without `s`); the existing `'expression <c>'` comparison covers the rest.
- [ ] **Step 1: Write the "masking" section of `067_shared_rows.test.sql` (12 assertions).** Fixture values on `po_c`: `pi_total 1234.56`, `notes 'P-NOTE'`, `supplier_id :'sup'`, `currency 'USD'`; its line: `unit_price 2.50`, `sell_price_eur 9.90`; `rel_c.notes 'REL-NOTE'`, `rel_c.restricted_drive_url 'https://drive/secret'`, `rel_c.deposit_rate 30`.

```sql
SELECT tests.authenticate_as_scope('co', ARRAY[:'C']);
SELECT results_eq($$ SELECT pi_total, notes, supplier_id, currency, status IS NOT NULL FROM api.purchase_order WHERE id = :'po_c' $$,
   $$ VALUES (NULL::NUMERIC, NULL::TEXT, NULL::UUID, NULL::TEXT, TRUE) $$, 'client owner: provider-only fields NULL, status visible');
SELECT results_eq($$ SELECT unit_price, sell_price_eur FROM api.purchase_order_line WHERE purchase_order_id = :'po_c' $$,
   $$ VALUES (NULL::NUMERIC, 9.90::NUMERIC) $$, 'client owner: purchase price NULL, sell price visible');
SELECT results_eq($$ SELECT notes, restricted_drive_url, deposit_rate FROM api.provider_relationship $$,
   $$ VALUES (NULL::TEXT, NULL::TEXT, 30::NUMERIC) $$, 'client reads contract terms, not notes or drive URL');
SELECT is_empty($$ SELECT 1 FROM api.purchase_order WHERE pi_total = 1234.56 $$, 'filter on a provider-only field finds nothing');
SELECT is_empty($$ SELECT 1 FROM api.purchase_order WHERE notes LIKE 'P-%' $$, 'filter on a provider-only open field finds nothing');
SELECT is((SELECT count(*)::INT FROM api.purchase_order WHERE supplier_id IS NOT NULL), 0, 'count over a provider-only field is zero');
SELECT is_empty($$ SELECT 1 FROM api.purchase_order p CROSS JOIN LATERAL api.supplier(p) s WHERE p.id = :'po_c' $$, 'R4 supplier relationship is empty');
-- client owner grants itself every field right in its own tenant
SELECT lives_ok($$ SELECT public.save_role(:'viewer_role_data'::JSONB, :'viewer_permission_ids'::UUID[], :'all_field_rights'::JSONB) $$, 'client owner may grant its viewer role every field');
SELECT is((SELECT pi_total FROM api.purchase_order WHERE id = :'po_c'), NULL, 'self-granted rights do not unmask a shared row');
SELECT tests.authenticate_as_scope('cv', ARRAY[:'C']);
SELECT is((SELECT sell_price_eur FROM api.purchase_order_line WHERE purchase_order_id = :'po_c'), NULL, 'a client role without sell_price narrows the set');
SELECT tests.authenticate_as_scope('pc_invited', ARRAY[:'P', :'C']);
SELECT is((SELECT pi_total FROM api.purchase_order WHERE id = :'po_c'), NULL, 'client-tenant rights never unmask a provider-only field');
SELECT tests.authenticate_as_scope('pm', ARRAY[:'P', :'C']);
SELECT is((SELECT pi_total FROM api.purchase_order WHERE id = :'po_c'), 1234.56::NUMERIC, 'provider management with both tenants sees both sides');
```
  (`pc_invited`: a provider coordinator whose provider role has no `cost` read and whose client-tenant role has every field; `pm`: provider management invited into C. `:'viewer_role_data'`, `:'viewer_permission_ids'`, `:'all_field_rights'` are `save_role(role_data JSONB, permission_ids UUID[], field_rights JSONB)` arguments that keep C's `viewer` role and grant it read and write on every field of every table. The `self-granted` assertion runs as `co`, whose ownership already grants everything in C; the narrowing assertion runs as `cv` before the grant: order the fixture so `cv` is checked first, then the grant, then `co`.) In `053_api_schema.test.sql` add `SELECT is_empty($$ SELECT * FROM private.api_view_drift() WHERE problem LIKE 'unshared %' OR problem = 'shared without s' $$, 'shared views gate every provider-only column');` (+1 to its plan).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** section 2.
- [ ] **Step 4: Run** `cd app && pnpm test:db` → `067` masking and `053` PASS; `api_view_drift()` empty.
- [ ] **Step 5: Commit** `feat(sharing): masked views show shared rows with the client-visible set only`.

---

### Task 4: Writes: shared rows read-only; rights-column writes

**Files:**
- Modify: `supabase/migrations/067_shared_rows.sql` (section 3)
- Test: `supabase/tests/database/067_shared_rows.test.sql` (section "writes")

**Interfaces:**
- Produces:
  - `private.field_rights_column(p_resource TEXT, p_field TEXT) RETURNS TEXT` STABLE: `coalesce(rights_column, 'tenant_id')`.
  - `private.api_forward()` (CREATE OR REPLACE, owner `api_owner`): the write check of a sensitive field uses the tenant in column `private.field_rights_column(resource, field)` of NEW (INSERT) or of the masked OLD **and** NEW (UPDATE: both must allow) instead of `tenant_id`. Everything else (S1 comparison at the column type, re-read through the view, NULL return when RLS reaches no base row) is unchanged.
  - `private.enable_field_write_guard(text)` (051): the generated condition `NEW.tenant_id = ANY (private.field_write_tenants(…))` becomes `NEW.<rc> = ANY (…)` and, on UPDATE, also `OLD.<rc> = ANY (…)`, with `<rc>` from `field_rights_column`; re-run for `incident` and `change_request` (the only tables with `rights_column` rows).
- [ ] **Step 1: Write the "writes" section (8 assertions).** As `co` in scope `{C}`:

```sql
SELECT throws_ok($$ UPDATE api.purchase_order SET pi_total = 1 WHERE id = :'po_c' $$, '42501', 'field_write_forbidden', 'write to a provider-only sensitive field refused (wrong guess)');
SELECT throws_ok($$ UPDATE api.purchase_order SET pi_total = 1234.56 WHERE id = :'po_c' $$, '42501', 'field_write_forbidden', 'refused the same on a correct guess');
SELECT is((WITH u AS (UPDATE api.purchase_order SET status = 'cancelled' WHERE id = :'po_c' RETURNING 1) SELECT count(*)::INT FROM u), 0, 'open field update reaches no shared row');
SELECT is((WITH d AS (DELETE FROM api.purchase_order_line WHERE purchase_order_id = :'po_c' RETURNING 1) SELECT count(*)::INT FROM d), 0, 'delete reaches no shared row');
SELECT throws_ok($$ INSERT INTO api.purchase_order_line (tenant_id, purchase_order_id, product_id, quantity) VALUES (:'P', :'po_c', :'client_product', 1) $$, '42501', NULL, 'insert into the provider tenant refused');
SELECT throws_ok($$ INSERT INTO api.purchase_order_line (tenant_id, purchase_order_id, product_id, quantity) VALUES (:'C', :'po_c', :'client_product', 1) $$, '23503', NULL, 'a client line cannot hang under a provider order');
SELECT tests.unauthenticate();
SELECT is((SELECT status::TEXT FROM public.purchase_order WHERE id = :'po_c'), 'draft', 'the shared order is unchanged');
SELECT is((SELECT pi_total FROM public.purchase_order WHERE id = :'po_c'), 1234.56::NUMERIC, 'its cost is unchanged');
```
- [ ] **Step 2–4: Run → FAIL; implement; run → PASS** (`067_shared_rows.test.sql` 32/32).
- [ ] **Step 5: Commit** `feat(sharing): shared rows are read-only; writes checked in the rights tenant`.

---

### Task 5: Client links to provider orders

**Files:**
- Create: `supabase/migrations/068_provider_order_links.sql` (section 1)
- Test: `supabase/tests/database/068_provider_order_links.test.sql` (section "links")

**Interfaces:**
- Produces:
  - `public.incident.entity_tenant_id UUID NULL` (NULL: the entity is in the incident's tenant). Allowed only with `entity_type IN ('purchase_order', 'shipment')`; CHECK `incident_entity_tenant_kind`.
  - `public.change_request.purchase_order_id UUID NULL`, `order_tenant_id UUID NULL`, CHECK `(purchase_order_id IS NULL) = (order_tenant_id IS NULL)` relaxed for SET NULL: CHECK `purchase_order_id IS NULL OR order_tenant_id IS NOT NULL`; FK `(purchase_order_id, order_tenant_id) → purchase_order(id, tenant_id) ON DELETE SET NULL (purchase_order_id)`.
  - Generated `guard_tenant_id UUID GENERATED ALWAYS AS (coalesce(entity_tenant_id, tenant_id)) STORED` on `incident`; `GENERATED ALWAYS AS (coalesce(order_tenant_id, tenant_id)) STORED` on `change_request`.
  - Uses `private.relationship_status(p_provider, p_client)` from Plan 1 Task 1.
  - `private.provider_order_link_guard() RETURNS TRIGGER` SECURITY DEFINER, BEFORE INSERT OR UPDATE on `incident` (`TG_ARGV`: `'entity_id', 'entity_tenant_id', 'entity_type'`) and `change_request` (`'purchase_order_id', 'order_tenant_id', NULL` → table `purchase_order`). The exact rule, for a link whose target tenant `x` is non-NULL and differs from `NEW.tenant_id`, applied when INSERT or the link changed:

```text
if private.rules_bypassed(): skip
target_table := entity_type for incident ('purchase_order' | 'shipment'), 'purchase_order' for change_request
if private.relationship_status(x, NEW.tenant_id) IS DISTINCT FROM 'active':
    raise check_violation 'relationship_inactive'
if NEW.tenant_id <> ALL (private.tenants_permitting(auth.uid(), ARRAY[NEW.tenant_id], 'public.' || target_table, 'select')):
    raise check_violation 'provider_link_forbidden'
if not exists (select 1 from public.<target_table> r where r.id = <link id> and r.tenant_id = x and r.client_tenant_id = NEW.tenant_id):
    raise check_violation 'provider_link_forbidden'        -- same message: the row is not shared with this tenant
```
    A link whose target tenant equals `NEW.tenant_id` keeps today's same-tenant rule (`entity_tenant_id` is then stored as NULL by the trigger). An existing link stays valid after the relationship ends (history); only new or changed links need `active`.
- [ ] **Step 1: Write the "links" section (`SELECT plan(14)` for the file; this section 7).** As `co` in `{C}`:

```sql
SELECT lives_ok($$ INSERT INTO api.incident (tenant_id, family, incident_type, severity, title, entity_type, entity_id, entity_tenant_id) VALUES (:'C', 'quality', 'damage', 's2', 'Damaged', 'purchase_order', :'po_c', :'P') $$, 'client incident on a shared provider order');
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, incident_type, severity, title, entity_type, entity_id, entity_tenant_id) VALUES (:'C', 'quality', 'damage', 's2', 'X', 'purchase_order', :'po_d', :'P') $$, '23514', 'provider_link_forbidden', 'an order shared with another client is refused');
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, incident_type, severity, title, entity_type, entity_id, entity_tenant_id) VALUES (:'C', 'quality', 'damage', 's2', 'X', 'purchase_order', :'po_own', :'P') $$, '23514', 'provider_link_forbidden', 'an unshared provider order is refused');
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, incident_type, severity, title, entity_type, entity_id, entity_tenant_id) VALUES (:'C', 'quality', 'damage', 's2', 'X', 'purchase_order', gen_random_uuid(), :'P') $$, '23514', 'provider_link_forbidden', 'an unknown id gets the same message');
SELECT lives_ok($$ INSERT INTO api.change_request (tenant_id, title, purchase_order_id, order_tenant_id) VALUES (:'C', 'Change colour', :'po_c', :'P') $$, 'client change request on a shared provider order');
SELECT lives_ok($$ SELECT public.end_provider_relationship(:'rel_c') $$, 'relationship ended (as the client owner)');
SELECT tests.authenticate_as_scope('co', ARRAY[:'C']);
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, incident_type, severity, title, entity_type, entity_id, entity_tenant_id) VALUES (:'C', 'quality', 'damage', 's2', 'Late', 'purchase_order', :'po_c', :'P') $$, '23514', 'relationship_inactive', 'no new link after the end; existing ones stay');
```
- [ ] **Step 2–4: Run → FAIL; implement; run → PASS.**
- [ ] **Step 5: Commit** `feat(sharing): client incidents and change requests may cite a shared provider order`.

---

### Task 6: Provider-guarded fields on client incidents and change requests; audit masking

**Files:**
- Modify: `supabase/migrations/068_provider_order_links.sql` (section 2)
- Test: `supabase/tests/database/068_provider_order_links.test.sql` (section "guarded", 7 assertions), `supabase/tests/database/059_api_audit.test.sql`

**Interfaces:**
- Produces:
  - `field_class` rows: `change_request.cost_impact` and `change_request.cost_payer` (open today) become `sensitive`, group `cost`; they and `incident.affected_parties` (already `supplier_identity`) get `rights_column = 'guard_tenant_id'`. When the linked order is the provider's, these fields are read and written under the provider tenant's rights; otherwise under the row's own (`guard_tenant_id = tenant_id`). `049_field_catalog.test.sql` becomes 88 sensitive fields, `('cost',20)`; the classification doc records the change.
  - `private.provider_order_link_guard` adds, on UPDATE of a row whose `OLD.guard_tenant_id <> OLD.tenant_id`: a change of the link columns requires `OLD.guard_tenant_id = ANY (private.field_write_tenants('public.change_request', 'cost_impact'))` (change request) or `('public.incident', 'affected_parties')` (incident); else `cost_link_forbidden` (42501). This stops a client from unlinking to unmask.
  - `private.rights_columns_map() RETURNS JSONB` STABLE: `{ "<resource>": { "<field>": "<rights_column>" } }` from `field_class`.
  - `private.mask_audit_data(p_table TEXT, p_tenant UUID, p_data JSONB, p_rights JSONB, p_sensitive JSONB, p_rcols JSONB) RETURNS JSONB` (replaces the five-argument version): for a field in `p_rcols[resource]`, the rights tenant is `p_data ->> <rights_column>` (falling back to `p_tenant` when absent); otherwise unchanged. `api_column_expr` passes `m.rcols`; `api_view_from` adds `(SELECT private.rights_columns_map()) AS rcols` to `audit_log`'s `m`.
- [ ] **Step 1: Write the section.** Fixture: `cr_c` (in C, linked to `po_c`) with `cost_impact 500`, `cost_payer 'provider'` written by `pm`; `inc_c` with `affected_parties 'Supplier X Ltd'`.

```sql
SELECT tests.authenticate_as_scope('co', ARRAY[:'C']);
SELECT results_eq($$ SELECT cost_impact, cost_payer FROM api.change_request WHERE id = :'cr_c' $$, $$ VALUES (NULL::NUMERIC, NULL::TEXT) $$, 'client owner: cost of a provider-order change request is NULL');
SELECT is((SELECT affected_parties FROM api.incident WHERE id = :'inc_c'), NULL, 'client owner: supplier identity on a provider-order incident is NULL');
SELECT throws_ok($$ UPDATE api.change_request SET cost_impact = 1 WHERE id = :'cr_c' $$, '42501', 'field_write_forbidden', 'client owner cannot write the guarded cost');
SELECT throws_ok($$ UPDATE api.change_request SET purchase_order_id = NULL, order_tenant_id = NULL WHERE id = :'cr_c' $$, '42501', 'cost_link_forbidden', 'client cannot unlink to unmask');
SELECT is_empty($$ SELECT 1 FROM api.audit_log a WHERE a.table_name = 'change_request' AND (a.new_data::TEXT LIKE '%500%' OR a.old_data::TEXT LIKE '%500%') $$, 'audit history masks the guarded cost');
SELECT tests.authenticate_as_scope('pm', ARRAY[:'P', :'C']);
SELECT is((SELECT cost_impact FROM api.change_request WHERE id = :'cr_c'), 500::NUMERIC, 'provider management reads the guarded cost');
SELECT lives_ok($$ UPDATE api.change_request SET cost_impact = 600 WHERE id = :'cr_c' $$, 'provider management writes it');
```
  `059_api_audit.test.sql`: the existing `mask_audit_data` calls take the sixth argument `'{}'::JSONB`; assertion counts unchanged.
- [ ] **Step 2–4: Run → FAIL; implement; run `cd app && pnpm test:db` → PASS.**
- [ ] **Step 5: Commit** `feat(sharing): provider-guarded cost and supplier fields on client records, audit included`.

---

### Task 7: Leak scan over every api relation

**Files:**
- Create: `supabase/tests/database/069_shared_leak_scan.test.sql`

**Interfaces:**
- Consumes: the Task 2–6 fixture style. The scan seeds unique sentinels into every provider-only column type it can reach on `po_c`, its line, payment, update, its shipment, event, the sourcing row, `rel_c`, the supplier and supplier contact, and the PI document's file name: numerics `987654.32`, texts `'LEAK-<column>'`, the supplier's `display_name 'LEAK-SUPPLIER'`.
- [ ] **Step 1: Write the test (`SELECT plan(3)`).**

```sql
-- as co in {C}: no api relation (view or table function without arguments) returns a sentinel
SELECT is_empty($$
  SELECT c.relname FROM pg_class c
  WHERE c.relnamespace = 'api'::regnamespace AND c.relkind = 'v'
    AND tests.relation_contains('api.' || quote_ident(c.relname), ARRAY['%987654.32%', '%LEAK-%'])
$$, 'no api view shows a provider-only sentinel to the client owner');
-- tests.relation_contains(rel TEXT, patterns TEXT[]) RETURNS BOOLEAN: EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s x WHERE x::TEXT LIKE ANY ($1))', rel) USING patterns; SECURITY INVOKER, created in private.create_test_helpers()
SELECT is_empty($$ SELECT 1 FROM api.dashboard_purchase_order d WHERE d.client_tenant_id = :'C' AND d::TEXT LIKE '%987654.32%' $$, 'dashboards carry no provider figure');
SELECT is((SELECT subtotal FROM private.purchase_order_figures(:'po_c', :'P')), NULL, 'figures over a shared order are NULL for the client');
```
- [ ] **Step 2: Run** → PASS if Tasks 2–6 are right; if a view leaks, fix the derived view in `058_api_derived.sql` (it must read the api twin) and re-run. Record which view leaked in the commit message.
- [ ] **Step 3: Commit** `test(sharing): leak scan over every api relation for a client owner`.

---

### Task 8: Generated masked list and classification doc

**Files:**
- Modify: `scripts/masked-fields.mjs`, `scripts/masked-fields.test.mjs`, `app/src/@types/maskedFields.generated.ts`, `docs/superpowers/specs/2026-11-08-field-classification.md`

**Interfaces:**
- Produces: the generated list adds, per shared table, every column that is not `client_visible` (it can now read NULL for a client), and the guarded fields. Export shape unchanged (`MaskedFields: Record<table, readonly string[]>`), so `app/src/@types/database.ts` types them nullable without a code change. The classification doc gains a section "Shared rows" with the client-visible set of Task 1 verbatim and the three guarded fields of Task 6.
- [ ] **Step 1: Failing test** in `masked-fields.test.mjs`: `test('a provider-only open column of a shared table is listed', …)` asserts `generated.purchase_order.includes('notes') && generated.shipment.includes('forwarder')`; `test('a client-visible open column is not listed', …)` asserts `!generated.purchase_order.includes('status')`.
- [ ] **Step 2: Run** `cd app && pnpm test:scripts` → FAIL.
- [ ] **Step 3: Implement**, then `cd app && pnpm dev:supabase-types`.
- [ ] **Step 4: Run** `cd app && pnpm test:scripts && pnpm typecheck` → PASS (fix any page that now sees a nullable field by rendering `—`).
- [ ] **Step 5: Commit** `feat(sharing): masked field list covers provider-only columns of shared tables`.

---

### Task 9: HTTP attack suite for shared rows

**Files:**
- Create: `supabase/functions/http-tests/shared_rows_http_test.ts`
- Modify: `supabase/functions/http-tests/helpers.ts`

**Interfaces:**
- Produces: `sharedSetup(): Promise<SharedFixture>` and `sharedTeardown(f)` in `helpers.ts`; `SharedFixture = { provider: string; client: string; otherClient: string; clientOwner: string /* token */; clientViewer: string; providerMgmt: string; providerCoord: string; poShared: string; poOther: string; poOwn: string; lineShared: string; crShared: string; piObject: string; secretPi: '987654.32'; secretNote: 'LEAK-NOTE'; secretSupplier: 'LEAK-SUPPLIER' }`. Built with the admin API (service role) as `adminSetup` is; uses `HTTP-SHARED-*` codes so teardown can find them.
- [ ] **Step 1: Write the tests** (each `t(name, fn)`; `h(f, tenants)` builds `x-tenant-id`/`x-tenant-ids`):
  - `'client owner reads its shared order with provider-only fields null'`: `GET /purchase_order?id=eq.${poShared}&select=*` → one row; `pi_total`, `notes`, `supplier_id`, `currency`, `deposit_rate` are `null`; `status` non-null.
  - `'client owner sees no unshared provider row'`: `GET /purchase_order?select=id` → ids exactly `[poShared]`; `GET /purchase_order_payment`, `/purchase_order_update`, `/supplier`, `/supplier_contact` → `[]`.
  - `'filter oracle on a provider-only field returns nothing'`: `GET /purchase_order?pi_total=eq.987654.32`, `?notes=like.LEAK*`, `?supplier_id=not.is.null` → `[]`.
  - `'order by a provider-only field does not reorder'`: `?order=pi_total.desc` equals `?order=id` order.
  - `'count with a provider-only filter is zero'`: `Prefer: count=exact`, `?pi_total=gt.0` → `content-range` ends `/0`.
  - `'embeds and R4 relationships carry no provider-only data'`: `?select=id,supplier(*),purchase_order_payment(*),purchase_order_line(unit_price,sell_price_eur)` → `supplier` null, payments `[]`, `unit_price` null, `sell_price_eur` non-null.
  - `'every shared table returns only the client-visible set'`: for each of the eight shared tables `GET /<t>?select=*&limit=50` and assert every key not in the Task 1 set is `null` on every row (the set is imported from a `CLIENT_VISIBLE` constant in `helpers.ts`, kept equal to the catalog by a test that reads `field_class` through the admin API).
  - `'writes to shared rows are refused or reach nothing'`: `PATCH ?id=eq.${poShared}` `{pi_total:1}` → 403 `field_write_forbidden`; `{status:'cancelled'}` with `Prefer: return=representation` → `[]`; `DELETE /purchase_order_line?purchase_order_id=eq.${poShared}` → `[]`; then admin read shows the row unchanged.
  - `'a forged x-tenant-ids naming the provider changes nothing'`: same reads with `x-tenant-ids: client,provider` and with `x-tenant-id: provider` → identical bodies to the honest request.
  - `'a self-granted role does not unmask shared rows'`: `POST /rpc/save_role` as `clientOwner` granting every field to its viewer role, then as `clientViewer` the shared row's `pi_total` is still `null`.
  - `'audit history of a shared order is invisible to the client'`: `GET /audit_log?table_name=eq.purchase_order` → `[]`; `GET /audit_log?table_name=eq.change_request` body contains no `987654.32`.
  - `'error bodies never contain a provider secret'`: a set of failing requests (bad filter on `pi_total`, PATCH, insert under the provider order) → no body contains `987654.32`, `LEAK-`.
  - `'Storage: the client owner cannot download the provider PI file'`: `GET /storage/v1/object/authenticated/<bucket>/${piObject}` → 400/404; as `providerMgmt` → 200.
  - `'a provider user with both tenants in scope sees both sides'`: as `providerMgmt` with `x-tenant-ids: provider,client`: `GET /purchase_order?id=eq.${poShared}` has `pi_total = 987654.32`; `GET /product?tenant_id=eq.${client}` returns the client's products.
  - `'a provider user without an invitation reads no client row'`: as `providerCoord` (not a client member) with `x-tenant-ids: provider,client` → `GET /product?tenant_id=eq.${client}` → `[]`.
  - `'every app select string resolves for a client owner'`: the `APP_SELECTS` loop of the field-security suite, as `clientOwner` in `{client}` → every status 200.
- [ ] **Step 2: Run** `cd supabase/functions && deno task check && deno task test:http` → the new file PASSES against Tasks 1–7 (a failure is a real leak: fix the database, not the test).
- [ ] **Step 3: Commit** `test(http): attack suite for shared provider rows`.

---

### Task 10: Performance under the R10 budget

**Files:**
- Modify: `supabase/perf/field_security_perf_load.sql`, `supabase/perf/field_security_perf.sql`, `scripts/field-security-perf.mjs`, `supabase/functions/scripts/field_perf_http.ts`

**Interfaces:**
- Produces: load data adds a client tenant with 2 000 shared orders (8 lines each) among the existing volume; scenarios `shared_client_owner_po_list` (client owner, scope `{C}`, `api.purchase_order` list of 50 with lines embedded), `shared_client_owner_shipment_list`, `provider_two_tenants_po_list` (provider management, scope `{P, C}`), and the write scenario `provider_po_update_shared` (PATCH an open field of a shared order). Baseline for each: the same query on the base table as `postgres` with the same scope filter, as the existing scenarios do. Budget classes: client owner and viewer are "restricted"; provider management is "internal".
- [ ] **Step 1: Add the scenarios.**
- [ ] **Step 2: Run** `cd app && pnpm perf:fields` → every scenario within max(+15%, +5 ms) internal, max(+40%, +10 ms) restricted; writes +15 ms. If `shared_*` misses: check `EXPLAIN` uses `BitmapOr` over `(tenant_id …)` and `<table>_client_idx`; add the composite list index `(client_tenant_id, created_at DESC)` on the failing table in `067_shared_rows.sql`, rerun.
- [ ] **Step 3: Run** `cd supabase/functions && deno task perf:http` → same budget over HTTP.
- [ ] **Step 4: Commit** `perf(sharing): shared-row scenarios within the R10 budget`.

---

### Task 11: Story seed: sharing checks

**Files:**
- Modify: `supabase/seed_story.sql`, `supabase/seed_story.check.sql`

**Interfaces:**
- Produces: the story's THO orders carry PI figures, notes and a payment; one THO change request and one incident cite a provider order (`purchase_order_id`/`entity_tenant_id`), with a guarded cost written by `akif@`. Checks (each a `DO` block raising on failure, as the file does): `sharing.thomas_sees_orders` (as `thomas@` in `{THO}`: count of `api.purchase_order` = THO's provider orders, every `pi_total` NULL, every line's `sell_price_eur` non-NULL), `sharing.portal_narrowed` (as `portal@`: `sell_price_eur` NULL), `sharing.kerstin_owns_procurement` (as `kerstin@` in `{KRN}`: her orders' `pi_total` non-NULL, no provider order visible), `sharing.akif_both_sides` (as `akif@` in `{MOESA LTD, THO}`: `pi_total` non-NULL on THO orders).
- [ ] **Step 1: Write the checks.**
- [ ] **Step 2: Run** `cd supabase && supabase db reset && cd ../app && pnpm dev:seed-story` → exit 0, the four `sharing.*` lines `ok`.
- [ ] **Step 3: Commit** `feat(seed): story exercises shared orders and guarded change-request cost`.

---

### Task 12: App: shared orders and shipments on the client side

**Files:**
- Create: `app/src/composables/useSharedRow.ts`
- Modify: `app/src/views/pages/ops/purchase-order/Index.vue`, `Manage.vue`, `PurchaseOrderCard.vue`, `tabs/*`, `app/src/views/pages/ops/shipment/Index.vue`, `Manage.vue`, `ShipmentCard.vue`, `tabs/*`, `app/src/components/service-components/purchase-order-table/*`, `shipment-table/*`, `app/src/router/routes/ops.ts` (route guard), locales
- Test: `app/tests/composables/useSharedRow.test.ts`, `app/tests/components/PurchaseOrderTable.test.ts`, `app/tests/components/ShipmentTable.test.ts`

**Interfaces:**
- Produces: `useSharedRow()` → `{ isShared(row: { tenant_id: string; client_tenant_id?: string | null }): boolean; providerName(row): string | null }`. `isShared` is TRUE when the row's `tenant_id` is not one of the user's tenants and its `client_tenant_id` is (from the auth store's tenant list); `providerName` reads the matching `provider_relationship.provider_name` (query key `['provider_relationship', 'mine']`). Shared rows render with a "From <provider_name>" tag, no edit/delete/add-line/add-payment actions, the payments and updates tabs hidden, and provider-only columns hidden (not shown as `—`) using the `CLIENT_VISIBLE` list exported from `app/src/constants/clientVisible.ts` (generated alongside `maskedFields.generated.ts` by `scripts/masked-fields.mjs`, export `ClientVisibleFields: Record<table, readonly string[]>`). The Manage route of a shared order opens read-only (`meta.readonlyWhenShared: true`).
- [ ] **Step 1: Failing tests:**
  - `useSharedRow.test.ts`: `it('a provider row whose client is my tenant is shared')`, `it('my own row is not shared')`, `it('a row of a tenant I belong to is not shared even with a client_tenant_id')` (provider staff with both tenants).
  - `PurchaseOrderTable.test.ts`: `it('hides provider-only columns and actions on a shared row')` expects no `pi_total` column header and no edit button for the shared row, and the tag text `From MOESA LTD` from the fixture.
  - `ShipmentTable.test.ts`: `it('shows eta and tracking on a shared shipment')`.
- [ ] **Step 2–4: Run `cd app && pnpm test` → FAIL; implement; → PASS; `pnpm typecheck && pnpm lint` → PASS.**
- [ ] **Step 5: Commit** `feat(app): client views of shared orders and shipments`.

---

### Task 13: App: role editor sections

**Files:**
- Modify: `app/src/components/service-components/select-permissions/*` (field rights panel), `app/src/api/role/*`, locales
- Test: `app/tests/components/SelectPermissions.test.ts`

**Interfaces:**
- Produces: for a shared table, the field rights panel shows two sections: "This company's records" (every field, as today; applies to the tenant's own rows, e.g. a client-procures tenant's own orders) and "Shared by a provider" listing only the sensitive client-visible fields (`field_class.client_visible AND class = 'sensitive'`), each narrowable; provider-only fields are never offered in that section. Both sections write the same `role_field_permission` rows (the database decides by row), so no new RPC. Copy explains: "Fields a provider keeps private are never shown on shared records, whatever this role allows."
- [ ] **Step 1: Failing test** `it('offers only client-visible fields under Shared by a provider')`: with catalog rows for `purchase_order_line` (`sell_price_eur` client-visible sensitive, `unit_price` provider-only sensitive), the shared section lists `sell_price_eur` and not `unit_price`.
- [ ] **Step 2–4: Run → FAIL; implement; → PASS.**
- [ ] **Step 5: Commit** `feat(app): role editor separates own records from shared records`.

---

### Task 14: App: incident and change-request link to a provider order

**Files:**
- Modify: `app/src/views/pages/ops/incident/useIncidentForm.ts`, `Manage.vue`, `app/src/views/pages/ops/change-request/useChangeRequestForm.ts`, `Manage.vue`, `app/src/api/incident/index.ts`, `app/src/api/changeRequest/index.ts`, `app/src/lib/form/postgrestErrors.ts`
- Test: `app/tests/api/incident.test.ts`, `app/tests/api/changeRequest.test.ts`, `app/tests/lib/postgrestErrors.test.ts`

**Interfaces:**
- Produces: the order/shipment pickers of both forms list own rows and shared rows (`api.purchase_order` over the scope); picking a shared row sets `entity_tenant_id`/`order_tenant_id` to its `tenant_id`; cost fields render read-only and hidden when masked. New error codes mapped: `provider_link_forbidden`, `cost_link_forbidden`.
- [ ] **Step 1: Failing tests:** `it('payload sets order_tenant_id from the picked shared order')`, `it('payload leaves entity_tenant_id null for an own order')`, and the two codes in `postgrestErrors.test.ts`.
- [ ] **Step 2–4: Run → FAIL; implement; → PASS.**
- [ ] **Step 5: Commit** `feat(app): client incidents and change requests cite shared provider orders`.

---

### Task 15: Full verification of Plan 2

- [ ] **Step 1: Run** `cd app && pnpm test:db` → every file `ok`, `api_view_drift()` empty, masked-fields check passes.
- [ ] **Step 2: Run** `cd app && pnpm test && pnpm typecheck && pnpm lint && pnpm build` → exit 0.
- [ ] **Step 3: Run** `cd supabase && supabase db reset && cd ../app && pnpm dev:seed-story` → exit 0.
- [ ] **Step 4: Run** `cd supabase/functions && deno task check && deno task test && deno task test:http` → all pass, including `shared_rows_http_test.ts`.
- [ ] **Step 5: Run** `cd app && pnpm perf:fields` → within budget.
- [ ] **Step 6: Commit** fixes as `chore(sharing): plan 2 verification fixes`.
