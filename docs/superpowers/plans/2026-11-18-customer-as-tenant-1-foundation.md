# Customer = Tenant, Plan 1 of 3: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `public.customer` and every `customer_id`, make brands, contacts, warehouses and platform accounts tenant-level, add the provider relationship and the sourcing table, place procurement in the procuring tenant, retire M21 and `customer_viewer`, and leave the app, both seeds and every test suite green on the new model.

**Architecture:** The customer concept is woven into the bodies of 36 migrations, so it is removed **in place**: each migration is edited so the history reads as if tenants had always been the model (production holds nothing; spec "Constraints"). The provider relationship lives in `018` (renamed), the sourcing table in `019`, because later migrations reference both. A provider row names its client with `client_tenant_id`, backed by a composite foreign key to the relationship; links from a provider row to a client master record (product, project, warehouse) carry a snapshot and are guarded by one trigger. No row is shared with a client yet: Plan 2 adds sharing. M21 (`040`–`045`) is deleted; Plan 3 ports the parts the general copy tool reuses from git history (`git show 055b03b:<path>`).

**Tech Stack:** Postgres 15 + pgTAP + PostgREST (Supabase CLI), Deno Edge Functions, Vue 3.5 + PrimeVue 4 + TanStack Query + CASL + zod, vitest.

**Spec:** `docs/superpowers/specs/2026-11-18-customer-as-tenant-design.md` (binding: owner decisions 1–18, "Onboarding", "Calls made"). Security model kept from `docs/superpowers/specs/2026-11-08-field-permissions-design.md` (R1–R12) and `docs/superpowers/specs/2026-11-08-field-classification.md`.

**Plan series:** 1 Foundation (this) → 2 Sharing and its security → 3 Onboarding, copy tool and walk. Each ends green on every suite.

## Global Constraints

- "`public.customer` and every `customer_id` column are gone. A record belongs to the tenant it lives in." Columns that name the end customer as a party (`incident.customer_notice_due_at`, `customer_notified_at`, `customer_closure_notified_on`, `change_request.customer_approved_on`, `customer_approval_document_id`, setting `s1_customer_notify_hours`) keep their names: they are not the customer concept.
- "Every child→parent link within a tenant stays composite `(x_id, tenant_id)`." The only cross-tenant references are those the provider relationship allows, "guarded by an active relationship, in RLS and in triggers".
- "'MOESA' must not be hard-coded. Any tenant can be a provider to any client." No schema object, enum label, error code or app string names MOESA. Seed display names ("MOESA LTD") are demo data and stay.
- "Each tenant defines its own suppliers. There is no shared supplier catalog."
- "Rows already created stay where they were created." Switching a relationship's procurement model moves nothing.
- The field-security stack stays: masked `api` views owned by `api_owner`, `private.api_forward`, closed base tables (064), `role_field_permission`, `field_class`, `private.api_view_drift()` empty, the definer allowlist in `064_field_security_cutover.test.sql`.
- Every new SECURITY DEFINER function executable by `authenticated` is added to the 064 allowlist deliberately; every new private function gets `REVOKE ALL … FROM PUBLIC, anon, authenticated` unless a policy or view must call it.
- Error codes are snake_case `check_violation` messages (business rules) or 42501 with the existing JSON shape (rights), as the existing guards do.
- Verification commands: `cd app && pnpm test:db`, `pnpm test`, `pnpm typecheck`, `pnpm lint`, `pnpm build`, `pnpm dev:seed-story`; `cd supabase/functions && deno task check && deno task test && deno task test:http`; `cd app && pnpm perf:fields`.

## Review Focus

- **A client product deleted under a provider PO line:** the line keeps `product_sku`/`product_name`, `product_id` becomes NULL, and the PO page still renders the line (Task 5 test `client product delete keeps the line snapshot`; Task 16 vitest `renders a line without product_id from its snapshot`).
- **A provider user without an invitation into the client tenant links a client product by a guessed id:** refused with `client_link_forbidden`, with the same message for an existing and an unknown id (Task 2 tests `uninvited staff refused`, `unknown id refused with the same message`).
- **Two clients of one provider with the same `client_code`:** refused by the unique key `(tenant_id, client_code)`; a client's own `tenant.code` may equal another tenant's (Task 1 tests).
- **A relationship ended while orders reference it:** existing rows keep `client_tenant_id`; new orders for that client are refused with `relationship_inactive`; deleting the relationship is refused while rows reference it (Task 1 and Task 5 tests).
- **A tenant name with Turkish or non-letter characters gets a default code:** `private.default_tenant_code('Çağ Ödül Ltd')` = `'CAG'`, `'1 2'` = `'12X'`, `'— —'` = `'XXX'` (Task 1 tests).

---

## File Structure

Migrations edited in place (customer removed): `015_ops_core.sql`, `016_documents.sql`, `018_customers.sql` → renamed `018_tenant_relations.sql`, `019_products.sql`, `020_products_import.sql`, `021_projects.sql`, `022_dashboard.sql`, `023_phase1_fixes.sql`, `024_media.sql`, `025_media_link.sql`, `026_document_media.sql`, `029_purchase_orders.sql`, `030_purchase_order_rules.sql`, `031_shipments.sql`, `032_gate_links.sql`, `033_dashboard_operations.sql`, `034_market_matrix.sql`, `035_incidents.sql`, `036_gate_rollback_incident.sql`, `037_change_requests.sql`, `038_dashboard_matrix_incidents.sql`, `039_company_price_column.sql` → renamed `039_sell_price.sql`, `046_amazon_listing_core.sql`, `049_field_catalog.sql`, `050_field_rights.sql`, `052_guard_request_identity.sql`, `054_api_customer_supplier.sql` → renamed `054_api_company_supplier.sql`, `057_api_core.sql`, `058_api_derived.sql`, `059_api_audit.sql`, `064_field_security_cutover.sql`, `065_list_indexes.sql`.
Deleted: `040`–`045` migrations and their tests (`040_transfer_core.test.sql` … `045_transfer_files.test.sql`, `042_transfer_scale.test.sql`, `043_transfer_locks.test.sql`).
Tests rewritten alongside each migration: `supabase/tests/database/<same number>_*.test.sql`.
Seeds: `supabase/seed.sql`, `supabase/seed_story.sql`, `supabase/seed_story.check.sql`, `scripts/seed-story.mjs`, `scripts/seed-story.test.mjs`.
App: `app/src/api/company/` (new, replaces `api/customer/`), `app/src/api/relationship/` (new), `app/src/api/sourcing/` (new), `app/src/views/pages/ops/company/` (new, replaces `ops/customer/`), removal of `store/customerFilter/`, `api/customerFilter.ts`, `components/service-components/customer-filter/`, `select-customer/`, `views/pages/ops/transfer/`, `api/transfer/`.

---

### Task 1: Tenant code, provider relationship, tenant-level brand/contact/warehouse

**Files:**
- Rename + rewrite: `supabase/migrations/018_customers.sql` → `supabase/migrations/018_tenant_relations.sql`
- Modify: `supabase/migrations/015_ops_core.sql` (module/permission rows for the new resources), `supabase/migrations/016_documents.sql` (enum label)
- Rename + rewrite test: `supabase/tests/database/018_customers.test.sql` → `018_tenant_relations.test.sql`

**Interfaces:**
- Produces:
  - `public.tenant.code TEXT NOT NULL CHECK (code ~ '^[A-Z0-9]{2,6}$')`, filled BEFORE INSERT by trigger `tenant_default_code` → `private.default_tenant_code(p_name TEXT) RETURNS TEXT` (IMMUTABLE): `translate(upper(p_name), 'ÇĞİIÖŞÜÂÎÛ', 'CGIIOSUAIU')`, keep `[A-Z0-9]`, first 3, right-padded with `X` to 3.
  - Enums: `public.procurement_model AS ENUM ('client', 'provider')`; `public.relationship_status AS ENUM ('active', 'ended')`; `public.customer_status` renamed `public.contract_status` (labels unchanged: lead, onboarding, active, paused, closed); `public.commercial_model` unchanged.
  - Table `public.provider_relationship` (row lives in the provider tenant):
    `id UUID PK, tenant_id UUID NOT NULL → tenant ON DELETE CASCADE` (provider), `client_tenant_id UUID NOT NULL → tenant ON DELETE RESTRICT`, `client_code TEXT NOT NULL CHECK (client_code ~ '^[A-Z]{3}$')`, `client_name TEXT NOT NULL` (the provider's label for the client; the client's tenant row is not readable to provider staff without an invitation), `provider_name TEXT NOT NULL` (snapshot of the provider tenant's `display_name` at creation, so the client can name its provider without reading the provider's tenant row), `procurement_model public.procurement_model NOT NULL`, `status public.relationship_status NOT NULL DEFAULT 'active'`, `accepted_at TIMESTAMPTZ NOT NULL DEFAULT now()`, `ended_at TIMESTAMPTZ`, contract terms moved from `customer`: `commercial_model, packages TEXT[], contract_status public.contract_status, contract_accepted_on DATE, contract_document_id UUID, start_on DATE, deposit_rate NUMERIC(5,2), extra_cost_rule TEXT, eu_responsible_person TEXT`, provider-internal: `restricted_drive_url TEXT, notes TEXT`, `created_at, updated_at`.
    Constraints: `UNIQUE (id, tenant_id)`, `UNIQUE (tenant_id, client_tenant_id)` (the composite target later FKs use), `UNIQUE (tenant_id, client_code)`, `CHECK (tenant_id <> client_tenant_id)`, `CHECK ((status = 'ended') = (ended_at IS NOT NULL))`, FK `(contract_document_id, tenant_id) → document(id, tenant_id)`.
  - Trigger `private.provider_relationship_guard()` BEFORE UPDATE: `tenant_id`, `client_tenant_id`, `accepted_at` immutable (`relationship_immutable`); `status` only `active → ended` (`relationship_ended_final`), setting `ended_at := now()`; `client_code` immutable once any row uses it in `public.code_sequence` scope (`client_code_immutable`, replaces `private.customer_code_immutable`). `private.customer_contract_guard` keeps its rule on the new columns, renamed `private.relationship_contract_guard`.
  - `private.relationship_allows(p_provider UUID, p_client UUID, p_new BOOLEAN) RETURNS BOOLEAN` STABLE SECURITY DEFINER: `p_client IS NULL` → TRUE; else a row `(tenant_id = p_provider, client_tenant_id = p_client)` exists and, when `p_new`, `status = 'active' AND procurement_model = 'provider'`.
  - `private.relationship_status(p_provider UUID, p_client UUID) RETURNS public.relationship_status` STABLE SECURITY DEFINER: the pair's status, NULL when there is none.
  - `public.end_provider_relationship(relationship_id UUID) RETURNS public.provider_relationship` SECURITY DEFINER: allowed for a caller holding `update` on `public.provider_relationship` in the provider tenant (`private.tenants_permitting(auth.uid(), ARRAY[tenant_id], 'public.provider_relationship', 'update')`) or owning the client company (`private.owns_company(auth.uid(), client_tenant_id)`); else 42501 `relationship_end_forbidden`. Sets `status = 'ended'`. Ending touches no membership and moves no row.
  - INSERT into `provider_relationship` is not granted to `authenticated` (no `insert` permission row): rows come from invitation acceptance (Plan 3) or the seed. DELETE is refused by the FKs of Task 5/6 while any row names the pair.
  - Tables `public.brand`, `public.contact`, `public.warehouse`: the columns of `customer_brand`, `customer_contact`, `customer_warehouse` without `customer_id`; each `UNIQUE (id, tenant_id)`; `warehouse` partial unique index `warehouse_one_default ON warehouse (tenant_id) WHERE is_default`.
  - Module `customer` is replaced by module `client` (resource `public.provider_relationship`; Plan 3 adds `public.provider_invitation`). `brand`, `contact`, `warehouse` join module `ops_setting`. Permission rows: select/insert/update/delete for brand, contact, warehouse; select/update for provider_relationship.
  - `public.document_entity`: label `customer` renamed `provider_relationship` (`ALTER TYPE … RENAME VALUE` is not possible in place in 016's CREATE; edit the CREATE list).

- [ ] **Step 1: Write the failing test `018_tenant_relations.test.sql` (`SELECT plan(16)`)**

```sql
SELECT has_table('public', 'provider_relationship', 'provider_relationship exists');
SELECT hasnt_table('public', 'customer', 'customer is gone');
SELECT is_empty($$ SELECT table_name FROM information_schema.columns WHERE column_name = 'customer_id' AND table_schema IN ('public','api','private') $$, 'no customer_id anywhere');
SELECT is(private.default_tenant_code('Çağ Ödül Ltd'), 'CAG', 'default code folds Turkish letters');
SELECT is(private.default_tenant_code('1 2'), '12X', 'default code keeps digits and pads');
SELECT is(private.default_tenant_code('— —'), 'XXX', 'default code of no letters');
SELECT ok((SELECT code FROM public.tenant WHERE id = :'provider') ~ '^[A-Z0-9]{2,6}$', 'a tenant gets a code on insert');
SELECT throws_ok($$ INSERT INTO public.provider_relationship (tenant_id, client_tenant_id, client_code, client_name, procurement_model) VALUES (:'provider', :'client2', 'THO', 'Dup', 'provider') $$, '23505', NULL, 'client_code unique per provider');
SELECT throws_ok($$ INSERT INTO public.provider_relationship (tenant_id, client_tenant_id, client_code, client_name, procurement_model) VALUES (:'provider', :'provider', 'SLF', 'Self', 'provider') $$, '23514', NULL, 'no relationship with oneself');
SELECT ok(private.relationship_allows(:'provider', :'client', TRUE), 'active provider-procures allows new links');
SELECT ok(NOT private.relationship_allows(:'provider', :'client_proc', TRUE), 'client-procures allows no new provider links');
SELECT ok(private.relationship_allows(:'provider', :'client_proc', FALSE), 'client-procures still allows history');
SELECT throws_ok($$ UPDATE public.provider_relationship SET client_tenant_id = :'client2' WHERE id = :'rel' $$, '23514', 'relationship_immutable', 'pair immutable');
-- as the client owner
SELECT lives_ok($$ SELECT public.end_provider_relationship(:'rel') $$, 'client owner may end');
SELECT throws_ok($$ UPDATE public.provider_relationship SET status = 'active', ended_at = NULL WHERE id = :'rel' $$, '23514', 'relationship_ended_final', 'ended is final');
-- as a client member without ownership
SELECT throws_ok($$ SELECT public.end_provider_relationship(:'rel2') $$, '42501', NULL, 'a plain client member may not end');
```

Fixture: two provider-procures clients and one client-procures client of one provider, built in the test with `private.create_test_helpers()` users (`tests.create_supabase_user`, `tests.authenticate_as`) as the existing tests do.

- [ ] **Step 2: Run to verify it fails** — `cd app && pnpm test:db` → FAIL: `018_tenant_relations.test.sql` (`provider_relationship` missing).
- [ ] **Step 3: Rewrite 018 and edit 015/016** with the objects above; `private.enable_tenant_level_security` and `private.audit_enable` on the four tables; drop every `customer*` object from 018.
- [ ] **Step 4: Run** `cd app && pnpm test:db` → `018_tenant_relations.test.sql .. ok` (later tests may still fail until their tasks; that is expected inside this plan until Task 10).
- [ ] **Step 5: Commit** `git add supabase/migrations/015_ops_core.sql supabase/migrations/016_documents.sql supabase/migrations/018_tenant_relations.sql supabase/tests/database/018_tenant_relations.test.sql && git rm supabase/migrations/018_customers.sql supabase/tests/database/018_customers.test.sql && git commit -m "feat(tenancy): provider relationship and tenant-level brand, contact, warehouse"`

> Note for the executor: Tasks 1–10 edit migrations that depend on each other; `supabase db reset` only succeeds once every migration referencing `customer` is edited. Work Tasks 1–10 in order, running the single test file with `cd supabase && supabase db reset && supabase test db --file tests/database/<file>` when the reset reaches it, and treat Task 10 Step 4 as the first full `pnpm test:db` gate.

---

### Task 2: Product without customer; the sourcing table

**Files:**
- Modify: `supabase/migrations/019_products.sql`, `supabase/migrations/020_products_import.sql`
- Rename + rewrite: `supabase/migrations/039_company_price_column.sql` → `039_sell_price.sql`
- Tests: `supabase/tests/database/019_products.test.sql`, `020_products_import.test.sql`, `039_company_price_column.test.sql` → `039_sell_price.test.sql`

**Interfaces:**
- Consumes: `public.provider_relationship`, `private.relationship_allows` (Task 1).
- Produces:
  - `public.product` loses `customer_id, supplier_id, supplier_product_code, manufacturer_art_no, purchase_price, purchase_currency, purchase_incoterm, landed_cost_eur, landed_cost_on, target_price_eur, company_price_eur, price_list_version`. `sku` unique per `tenant_id` (was per customer).
  - Table `public.sourcing` (row lives in the procuring tenant): `id UUID PK, tenant_id UUID NOT NULL`, `client_tenant_id UUID NULL` (the product's tenant when it is not `tenant_id`), `product_tenant_id UUID GENERATED ALWAYS AS (coalesce(client_tenant_id, tenant_id)) STORED`, `product_id UUID NULL`, `product_sku TEXT NOT NULL`, `product_name TEXT NOT NULL`, `supplier_id UUID`, `supplier_product_code TEXT`, `manufacturer_art_no TEXT`, `purchase_price NUMERIC(12,4)`, `purchase_currency TEXT`, `purchase_incoterm TEXT`, `landed_cost_eur NUMERIC(12,4)`, `landed_cost_on DATE`, `target_price_eur NUMERIC(12,4)`, `sell_price_eur NUMERIC(12,2)` (was `product.company_price_eur`), `price_list_version TEXT`, `notes TEXT`, `created_at, updated_at`.
    Keys: `UNIQUE (id, tenant_id)`, `UNIQUE (tenant_id, product_id)` (one row per procuring tenant and product), FK `(product_id, product_tenant_id) → product(id, tenant_id) ON DELETE SET NULL (product_id)`, FK `(supplier_id, tenant_id) → supplier(id, tenant_id)`, FK `(tenant_id, client_tenant_id) → provider_relationship(tenant_id, client_tenant_id) ON DELETE RESTRICT`, `CHECK (client_tenant_id IS DISTINCT FROM tenant_id)`.
  - The client-link guard and snapshot (shared by Tasks 5 and 6), in `019_products.sql`:
    `private.client_link_guard() RETURNS TRIGGER` SECURITY DEFINER, BEFORE INSERT OR UPDATE, with `TG_ARGV` = pairs of `(<id column>, <resource>)`, e.g. `('product_id', 'public.product')`. The exact rule, for each pair whose id is non-NULL and (INSERT or changed):

```text
target_tenant := coalesce(NEW.client_tenant_id, NEW.tenant_id)
if NEW.client_tenant_id IS NOT NULL and not private.rules_bypassed():
    if TG_OP = 'INSERT' and TG_TABLE_NAME in ('purchase_order', 'shipment', 'sourcing'):
        -- a new root row naming the client: active and provider-procures
        if not private.relationship_allows(NEW.tenant_id, NEW.client_tenant_id, TRUE):
            raise check_violation 'relationship_inactive'
    elif private.relationship_status(NEW.tenant_id, NEW.client_tenant_id) IS DISTINCT FROM 'active':
        -- a child of an existing shared row, or a changed link: the relationship must still be active
        -- (after a switch to client-procures the provider may finish its open orders; after the end, nothing changes)
        raise check_violation 'relationship_inactive'
    if NEW.client_tenant_id <> ALL (private.tenants_permitting(auth.uid(), ARRAY[NEW.client_tenant_id], <resource>, 'select')):
        raise check_violation 'client_link_forbidden'      -- same message whether or not the id exists
if no row <resource> with id = <id> and tenant_id = target_tenant:
    raise check_violation 'client_link_forbidden'          -- the FK would say more; check first
write the snapshot columns of that pair from the target row (product: product_sku := sku, product_name := display_name;
project: project_code := code; warehouse: delivery_address := concat_ws(', ', display_name, address, postal_code, city, country))
```

    A change of `client_tenant_id` after INSERT is refused by each table's immutability trigger (`client_tenant_immutable`). The snapshot is not refreshed when the client edits the product (no sync; anti-goal).
  - `private.client_link_guard` is attached on `sourcing` as `('product_id', 'public.product')`.
  - `public.import_products(rows JSONB)` (020) writes sourcing columns to `public.sourcing` in the active tenant (`client_tenant_id` NULL) and product columns to `product`; its CSV column list drops `customer_code`.
  - `039_sell_price.sql`: the grants and group of `sourcing.sell_price_eur`, `sourcing.price_list_version` (group `sell_price`), replacing the `company_price_eur` column work.
  - Module `product` gains resource `public.sourcing` (select/insert/update/delete).

- [ ] **Step 1: Write the failing tests.** `019_products.test.sql` gains nine assertions (its `plan(n)` grows by 9):

```sql
SELECT hasnt_column('public', 'product', 'purchase_price', 'cost left product');
SELECT hasnt_column('public', 'product', 'company_price_eur', 'sell price left product');
SELECT col_is_unique('public', 'sourcing', ARRAY['tenant_id', 'product_id'], 'one sourcing row per procuring tenant and product');
-- provider staff invited into the client: may link and gets the snapshot
SELECT lives_ok($$ INSERT INTO public.sourcing (tenant_id, client_tenant_id, product_id, sell_price_eur) VALUES (:'provider', :'client', :'client_product', 9.90) $$, 'invited provider staff link a client product');
SELECT is((SELECT product_sku FROM public.sourcing WHERE product_id = :'client_product'), 'THO-MOP', 'sku snapshot');
-- provider staff not invited into the client
SELECT throws_ok($$ INSERT INTO public.sourcing (tenant_id, client_tenant_id, product_id) VALUES (:'provider', :'client', :'client_product2') $$, '23514', 'client_link_forbidden', 'uninvited staff refused');
SELECT throws_ok($$ INSERT INTO public.sourcing (tenant_id, client_tenant_id, product_id) VALUES (:'provider', :'client', gen_random_uuid()) $$, '23514', 'client_link_forbidden', 'unknown id refused with the same message');
-- the client deletes its product
SELECT lives_ok($$ DELETE FROM public.product WHERE id = :'client_product' $$, 'client delete is not blocked');
```

  And a ninth, after the delete: `SELECT results_eq($$ SELECT product_id IS NULL, product_sku FROM public.sourcing WHERE product_sku = 'THO-MOP' $$, $$ VALUES (TRUE, 'THO-MOP') $$, 'client product delete keeps the snapshot');`). `039_sell_price.test.sql`: `SELECT plan(3)`: `sell_price_eur` group `sell_price`; coordinator reads but cannot write it (`field_tenants(..., TRUE)` empty); management writes it.
- [ ] **Step 2: Run** `cd supabase && supabase db reset && supabase test db --file tests/database/019_products.test.sql` → FAIL.
- [ ] **Step 3: Implement** in 019/020/039 as above.
- [ ] **Step 4: Run** the three test files → PASS.
- [ ] **Step 5: Commit** `feat(tenancy): sourcing table in the procuring tenant; product without customer`.

---

### Task 3: Code scope; projects and gates without customer

**Files:**
- Modify: `supabase/migrations/015_ops_core.sql` (`public.next_code`), `021_projects.sql`, `023_phase1_fixes.sql`, `032_gate_links.sql`, `036_gate_rollback_incident.sql`, `022_dashboard.sql`
- Tests: `015_core.test.sql`, `021_projects.test.sql`, `023_phase1_fixes.test.sql`, `032_gate_links.test.sql`, `036_gate_rollback_incident.test.sql`, `022_dashboard.test.sql`

**Interfaces:**
- Produces:
  - `private.code_scope(p_tenant UUID, p_client UUID) RETURNS TEXT` STABLE SECURITY DEFINER: `p_client` NULL → `tenant.code` of `p_tenant`; else `provider_relationship.client_code` of the pair. Replaces every `SELECT c.code INTO customer_code` (project, po, shp, incident and cr `set_code` triggers).
  - `public.project` loses `customer_id`; projects live in the tenant that owns the work (the client's). `private.project_set_code` uses `private.code_scope(NEW.tenant_id, NULL)`; `private.project_immutable` drops its customer clause.
  - Gate evidence (032): "the project's orders" are the purchase orders whose `(project_id, project_tenant_id)` names the project (Task 5 adds `project_tenant_id`), in any tenant. `gate_pi_required` for an order whose `tenant_id <> project.tenant_id` (provider-procured) requires the order at `pi_approved` or later and no evidence document: the provider's PI is provider-only and may not be cited by a client gate. `gate_evidence_invalid` accepts only documents of the gate's own tenant.
  - `private.management_gates(tenant_id UUID)` unchanged in signature.

- [ ] **Step 1: Failing tests.** In `032_gate_links.test.sql` add (plan +3):

```sql
SELECT lives_ok($$ SELECT public.pass_gate(:'g3_client', 'G3', current_date, NULL, '{}') $$, 'G3 of a client project passes on a provider order at pi_approved without citing the PI');
SELECT throws_ok($$ SELECT public.pass_gate(:'g3_client', 'G3', current_date, NULL, ARRAY[:'provider_pi_doc']::UUID[]) $$, '23514', 'gate_evidence_invalid', 'a provider document cannot be client gate evidence');
SELECT is(private.code_scope(:'provider', :'client'), 'THO', 'code scope of a client row is its client_code');
```
  In `021_projects.test.sql`: replace every `customer_id` fixture with tenant fixtures; the project code assertion becomes `matches(code, '^' || (SELECT code FROM public.tenant WHERE id = :'tenant') || '-\d{4}-\d{3,}$')`.
- [ ] **Step 2: Run** the files → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `refactor(tenancy): code scope from tenant or relationship; projects without customer`.

---

### Task 4: Media and documents without customer

**Files:**
- Modify: `supabase/migrations/016_documents.sql`, `024_media.sql`, `025_media_link.sql`, `026_document_media.sql`, `027_media_roles.sql`
- Tests: `016_documents.test.sql`, `024_media.test.sql`, `025_media_link.test.sql`, `026_document_media.test.sql`, `027_media_roles.test.sql`

**Interfaces:**
- Produces: `public.document` and `public.media` lose `customer_id`. `private.entity_customer(...)`, `private.media_customer_lock()` and the "customer" rule of `private.media_link_check()` and `private.document_check_media()` are deleted: a link or document is valid when its entity is in the same tenant (rule "record" already does this). `private.document_check_entity` maps `provider_relationship` to `public.provider_relationship`.
- [ ] **Step 1: Failing tests.** `025_media_link.test.sql`: delete the customer-lock cases; add `SELECT throws_ok($$ INSERT INTO public.media_link (tenant_id, media_id, entity_type, entity_id) VALUES (:'t1', :'m1', 'product', :'product_in_t2') $$, '23514', NULL, 'a link to another tenant''s product is refused');` `016_documents.test.sql`: `SELECT lives_ok(... entity_type 'provider_relationship', entity_id :'rel' ...)` for the contract document.
- [ ] **Step 2–4: Run → FAIL; implement; run → PASS.**
- [ ] **Step 5: Commit** `refactor(tenancy): media and documents without customer`.

---

### Task 5: Purchase orders: client tenant, client links, line snapshot and sell price

**Files:**
- Modify: `supabase/migrations/029_purchase_orders.sql`, `030_purchase_order_rules.sql`
- Tests: `029_purchase_orders.test.sql`, `030_purchase_order_rules.test.sql`

**Interfaces:**
- Consumes: `private.client_link_guard`, `private.relationship_allows`, `private.code_scope`.
- Produces:
  - `public.purchase_order`: `customer_id` → `client_tenant_id UUID NULL`; `project_tenant_id UUID GENERATED ALWAYS AS (coalesce(client_tenant_id, tenant_id)) STORED`; `project_code TEXT` (snapshot); FKs `(tenant_id, client_tenant_id) → provider_relationship(tenant_id, client_tenant_id) ON DELETE RESTRICT`, `(project_id, project_tenant_id) → project(id, tenant_id) ON DELETE SET NULL (project_id)`; `UNIQUE (id, tenant_id, client_tenant_id)` not needed (children inherit by trigger). Index `purchase_order_client_idx ON (client_tenant_id, created_at DESC) WHERE client_tenant_id IS NOT NULL`.
  - Guard: `private.client_link_guard('project_id', 'public.project')` on `purchase_order`. `private.purchase_order_immutable` refuses a change of `client_tenant_id` (`client_tenant_immutable`). INSERT with `client_tenant_id` requires `private.relationship_allows(tenant_id, client_tenant_id, TRUE)` (`relationship_inactive`) — checked in `client_link_guard` even when no link column is set.
  - `public.purchase_order_line`: `customer_id` → `client_tenant_id UUID NULL` inherited from the order by `private.inherit_client_tenant()` (BEFORE INSERT OR UPDATE; generic: `TG_ARGV[0]` parent table, `TG_ARGV[1]` parent id column; sets `NEW.client_tenant_id` from the parent row in `NEW.tenant_id`, ignoring what was sent). Replaces `private.purchase_order_line_customer`. Adds `product_tenant_id` (generated, as on sourcing), `product_sku TEXT NOT NULL`, `product_name TEXT NOT NULL`, `sell_price_eur NUMERIC(12,2)`; `product_id` becomes NULL-able with FK `(product_id, product_tenant_id) → product(id, tenant_id) ON DELETE SET NULL (product_id)`; guard `private.client_link_guard('product_id', 'public.product')`.
    `sell_price_eur` default: BEFORE INSERT, when NULL, `sourcing.sell_price_eur` of `(NEW.tenant_id, NEW.product_id)`. It is the provider's selling price per line (spec decision 9); `unit_price`, `line_total`, `pi_line_total` stay the purchase side (group `cost`).
  - `public.purchase_order_payment`, `public.purchase_order_update`: no client column (never shared, decision 15).
  - `private.po_line_needs_spec`, `private.purchase_order_figures`, `private.purchase_order_guard`, `private.purchase_order_line_guard`, `private.purchase_order_child_guard` lose their customer clauses; `private.purchase_order_set_code` uses `private.code_scope(NEW.tenant_id, NEW.client_tenant_id)`.
  - `private.purchase_order_defaults()`: `deposit_rate` default from `provider_relationship.deposit_rate` of the pair when `client_tenant_id` is set, else the `deposit_rate_default` setting (was `customer.deposit_rate`).

- [ ] **Step 1: Failing tests** in `029_purchase_orders.test.sql` (plan +10):

```sql
SELECT lives_ok($$ INSERT INTO public.purchase_order (id, tenant_id, client_tenant_id, supplier_id) VALUES (:'po', :'provider', :'client', :'sup') $$, 'provider order for an active provider-procures client');
SELECT throws_ok($$ INSERT INTO public.purchase_order (tenant_id, client_tenant_id, supplier_id) VALUES (:'provider', :'client_proc', :'sup') $$, '23514', 'relationship_inactive', 'no provider order for a client-procures client');
SELECT throws_ok($$ INSERT INTO public.purchase_order (tenant_id, client_tenant_id, supplier_id) VALUES (:'provider', :'stranger', :'sup') $$, '23514', 'relationship_inactive', 'no order for a tenant without relationship');
SELECT matches((SELECT code FROM public.purchase_order WHERE id = :'po'), '^THO-', 'code scoped by client_code');
SELECT lives_ok($$ INSERT INTO public.purchase_order_line (tenant_id, purchase_order_id, product_id, quantity, unit_price) VALUES (:'provider', :'po', :'client_product', 100, 2.5) $$, 'line on a client product');
SELECT results_eq($$ SELECT client_tenant_id, product_sku, sell_price_eur FROM public.purchase_order_line WHERE purchase_order_id = :'po' $$, $$ VALUES (:'client'::UUID, 'THO-MOP', 9.90::NUMERIC(12,2)) $$, 'line inherits client, snapshots sku, defaults sell price from sourcing');
SELECT throws_ok($$ UPDATE public.purchase_order SET client_tenant_id = :'client2' WHERE id = :'po' $$, '23514', 'client_tenant_immutable', 'client of an order is immutable');
SELECT lives_ok($$ DELETE FROM public.product WHERE id = :'client_product' $$, 'client product delete keeps the line snapshot');
SELECT results_eq($$ SELECT product_id IS NULL, product_sku FROM public.purchase_order_line WHERE purchase_order_id = :'po' $$, $$ VALUES (TRUE, 'THO-MOP') $$, 'the line keeps its snapshot');
SELECT throws_ok($$ DELETE FROM public.provider_relationship WHERE client_tenant_id = :'client' $$, '23503', NULL, 'a referenced relationship cannot be deleted');
```
  `030_purchase_order_rules.test.sql`: every `customer_id` fixture replaced by tenant fixtures; the rule tests keep their assertions.
- [ ] **Step 2–4: Run → FAIL; implement; run → PASS.**
- [ ] **Step 5: Commit** `feat(tenancy): provider orders name their client tenant; lines snapshot client products`.

---

### Task 6: Shipments: client tenant and delivery snapshot

**Files:**
- Modify: `supabase/migrations/031_shipments.sql`, `033_dashboard_operations.sql`
- Tests: `031_shipments.test.sql`, `033_dashboard_operations.test.sql`

**Interfaces:**
- Produces:
  - `public.shipment`: `customer_id` → `client_tenant_id` (FK to the relationship as in Task 5, immutable, index `shipment_client_idx ON (client_tenant_id, created_at DESC) WHERE client_tenant_id IS NOT NULL`); `warehouse_tenant_id` generated; `delivery_address TEXT` snapshot; FK `(delivery_warehouse_id, warehouse_tenant_id) → warehouse(id, tenant_id) ON DELETE SET NULL (delivery_warehouse_id)`; guard `private.client_link_guard('delivery_warehouse_id', 'public.warehouse')`.
  - `public.shipment_event`, `public.shipment_line`: `client_tenant_id` inherited from the shipment by `private.inherit_client_tenant('shipment', 'shipment_id')`.
  - `public.shipment_purchase_order`: `customer_id` → `client_tenant_id` inherited from the shipment; `private.shipment_purchase_order_guard` refuses an order whose `client_tenant_id IS DISTINCT FROM` the shipment's (`client_mismatch`, replaces the customer equality rule; `private.shipment_purchase_order_customer` deleted).
  - `public.shipment_overview` (031 view, `customer_code` column) → `client_code` from the relationship (NULL for own shipments).
- [ ] **Step 1: Failing tests** in `031_shipments.test.sql` (plan +4): shipment for client with a client warehouse snapshots `delivery_address`; event inherits `client_tenant_id`; `client_mismatch` when linking an own-tenant order to a client shipment; `client_link_forbidden` for a warehouse of a tenant the caller was not invited into.
- [ ] **Step 2–4: Run → FAIL; implement; run → PASS.**
- [ ] **Step 5: Commit** `feat(tenancy): shipments name their client tenant; delivery address snapshot`.

---

### Task 7: Market cells, incidents, change requests, dashboards

**Files:**
- Modify: `supabase/migrations/022_dashboard.sql`, `034_market_matrix.sql`, `035_incidents.sql`, `037_change_requests.sql`, `038_dashboard_matrix_incidents.sql`
- Tests: `022_dashboard.test.sql`, `034_market_matrix.test.sql`, `035_incidents.test.sql`, `037_change_requests.test.sql`, `038_dashboard_matrix_incidents.test.sql`

**Interfaces:**
- Produces: `market_cell`, `incident`, `change_request`, `change_request_product` lose `customer_id`; `private.market_cell_customer`, `private.change_request_product_customer` deleted; `private.incident_set_code` and `private.change_request_set_code` use `private.code_scope(NEW.tenant_id, NULL)`; `private.incident_notice_due`, `private.incident_guard`, `private.change_request_guard` lose customer clauses. Every `dashboard_*` view and `*_overview` view drops `customer_id`/customer columns; a view that showed `customer_code` shows `client_code` only where the row has `client_tenant_id`. Incident and change-request links to provider orders are Plan 2.
- [ ] **Step 1: Failing tests:** in each test file remove customer fixtures; `022_dashboard.test.sql` adds `SELECT hasnt_column('public', 'dashboard_purchase_order', 'customer_id', 'dashboard without customer');`; `034_market_matrix.test.sql` keeps its rule assertions with products of the tenant.
- [ ] **Step 2–4: Run → FAIL; implement; run → PASS.**
- [ ] **Step 5: Commit** `refactor(tenancy): markets, incidents, change requests and dashboards without customer`.

---

### Task 8: Amazon: platform_account per tenant

**Files:**
- Modify: `supabase/migrations/046_amazon_listing_core.sql`, `047_amazon_cron.sql`
- Modify: `supabase/functions/amazon-auth/index.ts`, `amazon-listing/index.ts`, `amazon-poll/index.ts`, `_shared/amazonAccount.ts`
- Tests: `supabase/tests/database/046_amazon_listing_core.test.sql`, `supabase/functions/tests/amazon_auth_test.ts`, `amazon_listing_test.ts`, `amazon_poll_test.ts`

**Interfaces:**
- Produces: `public.customer_platform_account` → `public.platform_account` (no `customer_id`), unique `(tenant_id, platform_id)`; `private.platform_account_authorize(uuid, api_connection)`, `private.platform_account_connected()`, `public.amazon_account_connect`, `public.amazon_account_disconnect`, `public.listing_parent_cell`, `private.listing_authorize(uuid)` find the account by the cell's `tenant_id` (was by its customer). Module `listing` gains resource `public.platform_account`. Edge Functions select `platform_account` by tenant.
- [ ] **Step 1: Failing tests.** `046_amazon_listing_core.test.sql`: replace customer fixtures; add `SELECT is((SELECT count(*)::INT FROM public.platform_account WHERE tenant_id = :'client'), 1, 'one Amazon account per tenant and platform');`. Deno: `amazon_auth_test.ts` test `"connect stores the token on the tenant's platform_account"` asserts the RPC is called with `{ account_id }` of a `platform_account` row.
- [ ] **Step 2: Run** `cd supabase/functions && deno task test` and the pgTAP file → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `refactor(tenancy): Amazon seller connection per tenant`.

---

### Task 9: Retire M21 and customer_viewer

**Files:**
- Delete: `supabase/migrations/040_transfer_core.sql` … `045_transfer_files.sql` and tests `040_transfer_core.test.sql`, `041_transfer_triggers.test.sql`, `042_transfer_rehearsal.test.sql`, `042_transfer_scale.test.sql`, `043_transfer_copy.test.sql`, `043_transfer_locks.test.sql`, `044_transfer_cheap_path.test.sql`, `045_transfer_files.test.sql`
- Modify: `supabase/migrations/010_init_audit.sql` (revert guard stays generic), `058_api_derived.sql` (remove section "3. The transfer gate (S3)": `private.transfer_field_rights`, `public.transfer_options`, the transfer view), `049_field_catalog.sql` (`private.field_default` rows of `customer_viewer`), `008_init_reference_data.sql` (module `transfer` removed)
- Delete in app later (Task 14): `app/src/views/pages/ops/transfer/`, `app/src/api/transfer/`

**Interfaces:**
- Produces: no `public.transfer`, no `private.transfer_*`, no module `transfer`, no `private.transferring()`; `private.rules_bypassed()` keeps only the test-fixture bypass (030). `public.revert_audit_transaction` loses the `audit_transfer_locked` call (`public.audit_transfer_locked` deleted). `private.field_default` keeps profiles `management` and `coordinator` only. Plan 3 Task 12 re-adds a transfer engine from git history.
- [ ] **Step 1: Failing test** in `supabase/tests/database/015_core.test.sql` (plan +2): `SELECT hasnt_table('public', 'transfer', 'M21 retired');` `SELECT is_empty($$ SELECT 1 FROM private.field_default WHERE profile = 'customer_viewer' $$, 'customer_viewer retired');`
- [ ] **Step 2–4: Run → FAIL; delete and edit; run → PASS.**
- [ ] **Step 5: Commit** `refactor(tenancy): retire the M21 customer transfer and the customer_viewer profile`.

---

### Task 10: Field catalog, api views and the generated masked list

**Files:**
- Modify: `supabase/migrations/049_field_catalog.sql`, `050_field_rights.sql`, `052_guard_request_identity.sql`, `054_api_customer_supplier.sql` → rename `054_api_company_supplier.sql`, `055_api_orders_shipments.sql`, `057_api_core.sql`, `058_api_derived.sql`, `059_api_audit.sql`, `064_field_security_cutover.sql`, `065_list_indexes.sql`
- Modify: `docs/superpowers/specs/2026-11-08-field-classification.md` (sections `customer*` → `provider_relationship`, `brand`, `contact`, `warehouse`, `platform_account`; `product` split into `product` and `sourcing`; `purchase_order_line` gains `sell_price_eur`, snapshots)
- Regenerate: `app/src/@types/maskedFields.generated.ts`, `supabase/functions/_shared/database.types.ts`, `app/src/@types/database.types.ts` (via `cd app && pnpm dev:supabase-types`)
- Tests: `049_field_catalog.test.sql`, `050_field_rights.test.sql`, `052_guard_request_identity.test.sql`, `053_api_schema.test.sql`, `054_api_customer_supplier.test.sql` → `054_api_company_supplier.test.sql`, `055_api_orders_shipments.test.sql`, `057_api_core.test.sql`, `058_api_derived.test.sql`, `059_api_audit.test.sql`, `064_field_security_cutover.test.sql`, `099_seed.test.sql`

**Interfaces:**
- Produces: classification (sensitive) per moved column, with groups unchanged from today's:
  - `provider_relationship`: `contract_accepted_on, contract_document_id, deposit_rate, extra_cost_rule, start_on` → `contract`; `notes, restricted_drive_url` → `internal_note`; everything else open.
  - `contact`: `email, name, phone` → `personal_data`; `warehouse.receiving_person`, `platform_account.account_holder` → `personal_data`; `platform_account.notes` → `internal_note`.
  - `sourcing`: `purchase_price, purchase_currency, purchase_incoterm, landed_cost_eur, landed_cost_on, target_price_eur` → `cost`; `supplier_id, supplier_product_code, manufacturer_art_no` → `supplier_identity`; `sell_price_eur, price_list_version` → `sell_price`; `notes` → `internal_note`.
  - `purchase_order_line.sell_price_eur` → `sell_price`. Snapshot and `*_tenant_id` columns are open.
  - `product.notes` stays `internal_note` (the product's owner's note).
  - 054 enables field security on `provider_relationship, brand, contact, warehouse, supplier, supplier_contact`; 055 adds `sourcing`; `platform_account` in 057 (where 046's table was enabled).
- [ ] **Step 1: Failing tests.** `049_field_catalog.test.sql` (`plan(18)` unchanged):

```sql
SELECT is((SELECT count(*)::INT FROM public.field_class WHERE class = 'sensitive'), 86, '86 sensitive fields');
SELECT results_eq($$ SELECT group_name, count(*)::INT FROM public.field_class WHERE class = 'sensitive' GROUP BY 1 ORDER BY 1 $$,
   $$ VALUES ('contract',5),('cost',18),('finance',5),('internal_note',22),('personal_data',8),('sell_price',3),('supplier_contact',4),('supplier_identity',8),('supplier_terms',13) $$, 'group sizes after customer = tenant');
SELECT is((SELECT group_name FROM public.field_class WHERE resource_name = 'public.sourcing' AND field = 'target_price_eur'), 'cost', 'OD2: target price is cost');
SELECT is((SELECT group_name FROM public.field_class WHERE resource_name = 'public.provider_relationship' AND field = 'restricted_drive_url'), 'internal_note', 'OD2: drive URL is an internal note');
```
  `064_field_security_cutover.test.sql`: the definer allowlist gains `public.end_provider_relationship(uuid)`; loses `public.transfer_customer(...)`, `public.transfer_options(uuid,uuid)`, `public.transfer_check_files(uuid)`, `public.audit_transfer_locked(uuid)`; `SELECT is_empty($$ SELECT * FROM private.api_view_drift() $$, 'api_view_drift() is empty')` stays. Every `customer` fixture in 050–059 tests becomes a tenant fixture; assertion counts stay unless a test only existed for `customer_viewer` (delete it and lower that file's plan count by the number deleted).
- [ ] **Step 2: Run** `cd app && pnpm test:db` → FAIL (counts and drift).
- [ ] **Step 3: Implement** the catalog rows, `enable_field_security` calls, list indexes (`065`: `(tenant_id, created_at DESC)` on `brand, contact, warehouse, sourcing, provider_relationship`), then `cd app && pnpm dev:supabase-types`.
- [ ] **Step 4: Run** `cd app && pnpm test:db` → all files `ok`, `masked-fields.test.mjs` passes. This is the first full green database gate of the plan.
- [ ] **Step 5: Commit** `feat(tenancy): field classification and api views for the tenant-level tables and sourcing`.

---

### Task 11: seed.sql on the new model

**Files:**
- Modify: `supabase/seed.sql`
- Test: `supabase/tests/database/099_seed.test.sql`

**Interfaces:**
- Produces (demo accounts, all `Demo1234!`; the header comment lists them):
  - Unchanged: `admin@`, `ayse@`, `mehmet@`, `zeynep@`, `can@`, `ali@`, `elif@`, `deniz@`, `burak@`, `selin@`, `baris@` (owner MOESA LTD), `akif@` (management MOESA LTD, MOESA Europe), `koordinator@` (coordinator MOESA LTD).
  - Tenant **THOMETZKI ONLINE HANDEL** (code `THO`, Germany, its own Pro subscription), owner `thomas@moesa-panel.test`; `portal@moesa-panel.test` is now a THO member with role `viewer` (THO's own role: select on product, project, market_matrix, media, document; field defaults: `sell_price` read only). `koordinator@` and `akif@` are THO members with THO's `management` role (they joined by invitation). Relationship MOESA LTD → THO: `client_code 'THO'`, `procurement_model 'provider'`, contract terms of today's THO customer row (`trading_partner`, packages `{A1,B,C,E}`, `contract_status 'active'`, `start_on '2025-01-01'`, `deposit_rate 30`).
  - THO's warehouse, Amazon `platform_account`, brand and contact move into the THO tenant; THO's three products move into the THO tenant; their sourcing rows (cost, supplier, sell price) are in MOESA LTD with `client_tenant_id` = THO. The five suppliers stay in MOESA LTD. The "Mop ailesi çok ülke pilotu" project is in THO.
  - `private.seed_ops_roles(tenant_id)` builds `management` and `coordinator` only; a new `private.seed_client_roles(tenant_id)` builds `management` and `viewer` for a client tenant.
  - MOESA Europe and MOESA Trading GmbH stay (copy-tool demo, Plan 3).
- [ ] **Step 1: Failing test** `099_seed.test.sql` (`plan(21)`, the customer assertions replaced):

```sql
SELECT is((SELECT procurement_model::TEXT FROM public.provider_relationship r JOIN public.tenant t ON t.id = r.client_tenant_id WHERE t.display_name = 'THOMETZKI ONLINE HANDEL'), 'provider', 'THO is provider-procured');
SELECT is((SELECT count(*)::INT FROM public.product p JOIN public.tenant t ON t.id = p.tenant_id WHERE t.code = 'THO'), 3, 'THO products live in THO');
SELECT is((SELECT count(*)::INT FROM public.sourcing s JOIN public.tenant t ON t.id = s.tenant_id WHERE t.display_name = 'MOESA LTD' AND s.client_tenant_id IS NOT NULL), 3, 'their sourcing lives in the provider');
SELECT ok(EXISTS (SELECT 1 FROM public.tenant_owner o JOIN public.user u ON u.id = o.user_id JOIN public.tenant t ON t.id = o.tenant_id WHERE u.email = 'thomas@moesa-panel.test' AND t.code = 'THO'), 'thomas owns THO');
SELECT is_empty($$ SELECT 1 FROM public.role WHERE display_name = 'customer_viewer' $$, 'no customer_viewer role');
```
- [ ] **Step 2–4: Run `cd app && pnpm test:db` → FAIL; rewrite seed.sql; run → PASS.**
- [ ] **Step 5: Commit** `feat(seed): THO as a provider-procured client tenant`.

---

### Task 12: Story seed on the new model

**Files:**
- Modify: `supabase/seed_story.sql`, `supabase/seed_story.check.sql`, `scripts/seed-story.mjs`, `scripts/seed-story.test.mjs`

**Interfaces:**
- Produces:
  - The "already loaded" check becomes `EXISTS (SELECT 1 FROM public.tenant WHERE display_name = 'Kernhaus Living GmbH')` (SQL and `seed-story.mjs`).
  - Step 02 creates every story customer as a tenant with a relationship to MOESA LTD: **Kernhaus Living GmbH (KRN) is client-procures** (owner `kerstin@moesa-panel.test`, its own suppliers, sourcing, POs and shipments live in KRN; `koordinator@` is a KRN member); every other story customer (LEA, CLS, …) is provider-procures, owner `owner.<code lowercase>@moesa-panel.test`.
  - Steps 03–11 write each row in its tenant per the spec's Goals (customer data in the client tenant, procurement in the procuring tenant). `private.story_begin(actor, tenant)` keeps its signature.
  - Step 10 (M21 copy) is removed; Plan 3 Task 14 adds a copy-tool step.
  - `seed-story.mjs` uploads each media file under its row's own tenant folder (`<tenant id>/<media id>/…`), no longer all under MOESA LTD.
  - `seed_story.check.sql`: the `fp.portal_*` checks are replaced by `tenancy.*` checks: KRN owns its POs (`tenant_id` = KRN, `client_tenant_id` NULL); THO's POs are in MOESA LTD with `client_tenant_id` = THO; no row anywhere has `client_tenant_id` = KRN.
- [ ] **Step 1: Failing test** `scripts/seed-story.test.mjs`: test `"refuses a second run when Kernhaus Living GmbH exists"` asserts the guard SQL string contains `display_name = 'Kernhaus Living GmbH'`; test `"uploads media under each row's tenant"` asserts `mediaFolder({ tenant_id: 'T', id: 'M' }) === 'T/M'` (new exported helper `mediaFolder(row: { tenant_id: string; id: string }): string`).
- [ ] **Step 2: Run** `cd app && pnpm test:scripts` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd app && pnpm test:scripts && cd ../supabase && supabase db reset && cd ../app && pnpm dev:seed-story` → the script ends with the check file's `ok` lines and exit 0.
- [ ] **Step 5: Commit** `feat(seed): story with one provider-procured and one client-procures customer tenant`.

---

### Task 13: HTTP suite and Edge Functions on the new model

**Files:**
- Modify: `supabase/functions/http-tests/helpers.ts`, `supabase/functions/http-tests/field_security_http_test.ts`, `supabase/functions/user/index.ts` (only the `customer` mentions in types), `supabase/functions/_shared/company.ts`

**Interfaces:**
- Produces: `Fixture` drops `portal`'s customer meaning: `portal` is the THO `viewer` user; `HTTP_EU_CUSTOMER` is removed; new fields `client: string` (THO tenant id) and `clientOwner: string` (token of `thomas@`). The two portal tests are replaced (sharing comes in Plan 2, so isolation is what holds now):
  - `t('a client tenant reads no provider row', …)`: `rest(clientOwner, '/purchase_order?select=id', { headers: { 'x-tenant-id': f.client, 'x-tenant-ids': `${f.client},${f.moesa}` } })` → `status 200`, `body.length === 0`; same for `/sourcing`, `/supplier`, `/provider_relationship`.
  - `t('Storage: a client owner cannot download a provider PI file, the koordinator can', …)`: as today's portal storage test with `clientOwner`.
- [ ] **Step 1: Write the replaced tests.**
- [ ] **Step 2: Run** `cd supabase/functions && deno task check && deno task test:http` → FAIL until Tasks 10–11 are in, then PASS.
- [ ] **Step 3: Commit** `test(http): client tenant isolation on the new model`.

---

### Task 14: App: remove the customer concept and M21

**Files:**
- Delete: `app/src/views/pages/ops/customer/`, `app/src/views/pages/ops/transfer/`, `app/src/api/customer/`, `app/src/api/transfer/`, `app/src/api/customerFilter.ts`, `app/src/store/customerFilter/`, `app/src/components/service-components/customer-filter/`, `app/src/components/service-components/select-customer/`, `app/tests/api/customer.test.ts`, `app/tests/api/customerFilter.test.ts`, `app/tests/api/transfer.test.ts`, `app/tests/components/TransferFilesNotice.test.ts`
- Modify: `app/src/router/routes/ops.ts` (routes `ops-customer*`, `ops-transfer` removed), `app/src/layouts/dashboard/ScopeControls.vue`, `app/src/plugins/i18n/locales/*` (customer and transfer keys removed), `app/src/constants/terms.ts`, `constants/guide.ts`, `constants/dashboard.ts`, `constants/form/field.ts`, `lib/form/zod.ts`, `lib/form/postgrestErrors.ts`, `composables/useFieldAccess.ts`, and every list/table component that filtered by `customerFilter` (`purchase-order-table`, `shipment-table`, `incident-table`, `market-cell-table`, `market-matrix-grid`, `gate-panel`, `entity-media`, `entity-documents`, `product-multi-select`, `select-supplier`, `select-platform`, `select-permissions`, `amazon-form`)
- Tests: `app/tests/layouts/scopeControls.test.ts`, the list tests in `app/tests/api/*.test.ts` that asserted a `customer_id` filter

**Interfaces:**
- Produces: no app file matches `grep -rniE "customer_id|customerFilter|customer_viewer|ops-customer|transfer_customer" app/src app/tests` (the verification step runs it). `lib/form/postgrestErrors.ts` maps the new codes: `relationship_inactive`, `client_link_forbidden`, `client_tenant_immutable`, `client_mismatch`, `relationship_immutable`, `relationship_ended_final`, `relationship_end_forbidden`, `client_code_immutable` (each with a tr and en message).
- [ ] **Step 1: Update tests.** `scopeControls.test.ts`: `it('renders the tenant picker and no customer filter')` asserts `wrapper.findComponent({ name: 'CustomerFilter' }).exists() === false`. `app/tests/api/purchaseOrder.test.ts`: `it('lists orders without a customer filter')` asserts the query string has no `customer_id`. `app/tests/lib/postgrestErrors.test.ts`: `it.each` over the eight new codes asserts a non-empty message in `tr` and `en`.
- [ ] **Step 2: Run** `cd app && pnpm test` → FAIL.
- [ ] **Step 3: Implement** the deletions and edits.
- [ ] **Step 4: Run** `cd app && pnpm test && pnpm typecheck && pnpm lint` → PASS (typecheck may still fail on product/PO/shipment pages until Tasks 15–16; run it as the gate in Task 18).
- [ ] **Step 5: Commit** `refactor(app): remove customer pages, filters and the M21 wizard`.

---

### Task 15: App: company profile pages (brands, contacts, warehouses, platform accounts)

**Files:**
- Create: `app/src/api/company/index.ts` (from the non-customer parts of the deleted `api/customer/index.ts`), `app/src/views/pages/ops/company/Index.vue`, `tabs/Brands.vue`, `tabs/Contacts.vue`, `tabs/Warehouses.vue`, `tabs/Platforms.vue`, `BrandUpsert.vue`, `ContactUpsert.vue`, `WarehouseUpsert.vue`, `PlatformUpsert.vue`, `AmazonConnection.vue` (moved from `ops/customer/`)
- Modify: `app/src/router/routes/ops.ts` (routes `ops-company`, `ops-company-brands|contacts|warehouses|platforms`, and the add/edit children), menu entry under settings
- Test: `app/tests/api/company.test.ts`

**Interfaces:**
- Produces: `brandResource = defineResource('brand')`, `contactResource = defineResource('contact')`, `warehouseResource = defineResource('warehouse')`, `platformAccountResource = defineResource('platform_account')`; schemas `brandSchema`, `contactSchema`, `warehouseSchema`, `platformAccountSchema` (the customer schemas without `customer_id`); types `BrandRow`, `ContactRow`, `WarehouseRow`, `PlatformAccountRow`; constants `WAREHOUSE_TYPES`, `PLATFORM_ACCESSES`, `PACKAGES`, `COMMERCIAL_MODELS`, `CONTRACT_STATUSES` (Enums['contract_status']). The pages read the active tenant; CASL subjects `brand`, `contact`, `warehouse`, `platform_account`.
- [ ] **Step 1: Failing test** `company.test.ts`: `it('warehouseSchema rejects a payload with customer_id')` (`strict()` schema: `expect(warehouseSchema.safeParse({ ...valid, customer_id: 'x' }).success).toBe(false)`); `it('toContactPayload keeps only contact columns')`.
- [ ] **Step 2–4: Run `pnpm test` → FAIL; implement; → PASS.**
- [ ] **Step 5: Commit** `feat(app): company profile pages for tenant-level brands, contacts, warehouses and platform accounts`.

---

### Task 16: App: product sourcing, client picker on orders and shipments, line snapshots

**Files:**
- Create: `app/src/api/sourcing/index.ts`, `app/src/api/relationship/index.ts`, `app/src/components/service-components/select-client/SelectClient.vue`, `app/src/views/pages/ops/product/tabs/Sourcing.vue`
- Modify: `app/src/api/product/index.ts`, `api/product/csv.ts`, `api/product/import.ts`, `views/pages/ops/product/useProductForm.ts`, `views/pages/ops/product/Manage.vue`, `views/pages/ops/purchase-order/usePurchaseOrderForm.ts`, `Manage.vue`, `LineUpsert.vue`, `ProductSelect.vue`, `ProjectSelect.vue`, `views/pages/ops/shipment/useShipmentForm.ts`, `Manage.vue`, `components/service-components/purchase-order-table/*`, `shipment-table/*`
- Tests: `app/tests/api/sourcing.test.ts`, `app/tests/api/product.test.ts`, `app/tests/api/productCsv.test.ts`, `app/tests/api/purchaseOrder.test.ts`, `app/tests/api/shipment.test.ts`, `app/tests/components/PurchaseOrderTable.test.ts`

**Interfaces:**
- Produces:
  - `sourcingResource = defineResource('sourcing')`; `sourcingSchema` (`client_tenant_id: z.string().uuid().nullable()`, `product_id`, the cost/supplier/sell columns); `useSourcing(productId: Ref<string>)` reads `sourcing` rows for that product across the scope (`.eq('product_id', id)`), so a provider user with both tenants in scope sees the provider's sourcing next to the client's product (spec Goals).
  - `relationshipResource = defineResource('provider_relationship')`; `useClientOptions()` → `{ value: client_tenant_id, label: `${client_code} · ${client_name}`, procurement_model, status }[]` of active provider-procures relationships of the active tenant.
  - `SelectClient.vue` (props `modelValue: string | null`; emits `update:modelValue`), used by the PO and shipment forms; `null` means an own order.
  - `ProductSelect.vue` lists products of `client_tenant_id ?? active tenant`; the line form shows `product_sku · product_name` from the snapshot when `product_id` is NULL.
  - CSV import/export drops `customer_code` and moves cost/sell columns into a `sourcing` block written to `sourcing`.
- [ ] **Step 1: Failing tests:**
  - `sourcing.test.ts`: `it('useSourcing queries sourcing by product_id without tenant filter')` asserts the request URL contains `product_id=eq.<id>` and no `tenant_id=`.
  - `PurchaseOrderTable.test.ts`: `it('renders a line without product_id from its snapshot')` mounts a line `{ product_id: null, product_sku: 'THO-MOP', product_name: 'Mop' }` and expects text `THO-MOP · Mop`.
  - `purchaseOrder.test.ts`: `it('payload carries client_tenant_id and no customer_id')`.
  - `productCsv.test.ts`: `it('exports sourcing columns from sourcing, not product')`.
- [ ] **Step 2–4: Run `pnpm test` → FAIL; implement; → PASS.**
- [ ] **Step 5: Commit** `feat(app): sourcing tab, client picker and line snapshots`.

---

### Task 17: App: the scope picker lists the user's tenants

**Files:**
- Rename: `app/src/components/service-components/branch-picker/BranchPicker.vue` → `tenant-picker/TenantPicker.vue`
- Modify: `app/src/layouts/dashboard/ScopeControls.vue`, `app/src/store/auth/index.ts` (no API change), locales
- Test: `app/tests/components/TenantPicker.test.ts` (new), `app/tests/layouts/scopeControls.test.ts`

**Interfaces:**
- Produces: `TenantPicker.vue` groups the user's tenants by company root (a tenant whose parent the user cannot use is a root, as today), labels each root with its `display_name` and `code`, and keeps the star for the active tenant. It is shown when the user has more than one tenant (unchanged rule). Copy says "company/branch", never "customer".
- [ ] **Step 1: Failing test** `TenantPicker.test.ts`: `it('shows a client tenant as its own root next to the provider tree')` with tenants `[{id:'P',parent_id:null},{id:'PB',parent_id:'P'},{id:'C',parent_id:null}]` expects two root nodes `P` and `C`, `PB` under `P`; `it('selecting two roots sets x-tenant-ids to both')` asserts `scopeTenants` ids `['P','C']`.
- [ ] **Step 2–4: Run → FAIL; implement; → PASS.**
- [ ] **Step 5: Commit** `feat(app): tenant picker lists the user's companies and branches`.

---

### Task 18: Full verification of Plan 1

**Files:** none new.

- [ ] **Step 1: Run** `cd app && pnpm test:db` → every file `ok`; `masked-fields.test.mjs` passes.
- [ ] **Step 2: Run** `cd app && pnpm test && pnpm typecheck && pnpm lint && pnpm build` → all exit 0.
- [ ] **Step 3: Run** `cd supabase && supabase db reset && cd ../app && pnpm dev:seed-story` → exit 0 with the check's `ok` lines.
- [ ] **Step 4: Run** `cd supabase/functions && deno task check && deno task test && deno task test:http` → all pass.
- [ ] **Step 5: Run** `cd app && pnpm perf:fields` → within R10 as amended: reads max(+15%, +5 ms) internal, max(+40%, +10 ms) restricted; writes +15 ms.
- [ ] **Step 6: Run** `grep -rniE "customer_id|public\.customer\b|customer_viewer|customerFilter|transfer_customer" supabase/migrations supabase/functions app/src app/tests scripts` → no output (the incident/CR party columns named in Global Constraints do not match these patterns).
- [ ] **Step 7: Commit** any fixes with `chore(tenancy): plan 1 verification fixes`.
