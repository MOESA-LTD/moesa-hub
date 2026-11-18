# Customer = Tenant, Plan 1: Remove the Customer Concept

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `public.customer`, every `customer_id`, the M21 customer-package transfer and the `customer_viewer` role. Each customer's data then lives in a tenant of its own, and brands, contacts, warehouses and platform accounts become tenant-level tables.

**Architecture:** Removal edits the existing migrations in place, so a fresh `supabase db reset` builds a schema that never had customers. The removal runs leaves-first: change requests and incidents, then market cells, the directory tables, orders and shipments, projects, documents and media, products, and finally the customer table itself. After every task `pnpm test:db` is green. The app, the Edge Functions, the HTTP suite, the perf harness and both seeds follow in later tasks. Business codes lose their customer scope and take a per-company `code_prefix` setting instead. The ops roles move from `seed.sql` into a migration (`private.create_ops_roles`), which Plan 3's invitations need.

**Tech Stack:** Supabase (Postgres 15, PostgREST, pgTAP via `supabase test db`), Deno Edge Functions, Vue 3.5 + PrimeVue 4 + TanStack Query 5 + CASL + zod, vitest 3, pnpm.

**Spec:** `docs/superpowers/specs/2026-11-18-customer-as-tenant-design.md` (owner decisions 1–18 and "Calls made" are binding). Security model kept from `docs/superpowers/specs/2026-11-08-field-permissions-design.md` and `docs/superpowers/specs/2026-11-08-field-classification.md`.

**Series:** Plan 1 of 4, executed in order on branch `feat/customer-as-tenant`:
1. Remove customer (this plan).
2. `2026-11-18-customer-as-tenant-2-provider-sharing.md`: the relationship, procurement placement, sharing and its security.
3. `2026-11-18-customer-as-tenant-3-onboarding.md`: invitations, the signup gate and the plan chooser.
4. `2026-11-18-customer-as-tenant-4-client-views-and-copy.md`: the client-side app, the tenant copy tool and the walk.

## Global Constraints

- Spec, Done means: "No `customer` table and no `customer_id` remain in the database or the app."
- Spec, Constraints: "existing migrations may be edited in place or replaced; no data migration and no backwards compatibility are needed."
- Spec, Anti-goals: "'MOESA' must not be hard-coded." Seed data and test fixtures may name the seeded tenants. Schema, functions, app code and copy must not.
- **Migration strategy (this plan).** Removal edits in place. Every migration that creates or redefines a customer object is edited, including the earlier "Superseded by …" definitions of a function, so no stale customer text survives. Reasons:
  - production holds nothing;
  - every touched pgTAP test is rewritten anyway;
  - a create-then-drop history of 5 tables and 32 columns would double the reading load;
  - the generated `api` views, the field catalog and the drift check must never have seen those columns.

  The edits by file:
  - **Deleted:** `042_transfer_rehearsal.sql`, `043_transfer_copy.sql`, `044_transfer_cheap_path.sql`, `045_transfer_files.sql` and their tests.
  - **Renamed with `git mv`:** `018_customers.sql` → `018_tenant_directory.sql`, `054_api_customer_supplier.sql` → `054_api_directory_supplier.sql`, and their tests.
  - **New migration:** `066_ops_roles.sql` holds this plan's only new object.
- **Grep gate** (used by the final task). It must print nothing:

  ```
  git grep -nwE "customer_id|customer_code|target_customer_id|customer_brand|customer_contact|customer_warehouse|customer_platform_account|customer_viewer|transfer_customer|withCustomerFilter|useCustomerFilter|CustomerFilter" -- supabase app/src app/tests scripts ':!*.md' ':!supabase/functions/_shared/database.types.ts'
  ```

  Also `git grep -nE "public\.customer\b"` prints nothing. These stay, because they name the counterpart role rather than the removed table: `incident.customer_notice_due_at`, `customer_notified_at`, `customer_closure_notified_on`, `incident_log.customer_approved`, `change_request.customer_approved_on`, `customer_approval_document_id`, `project_gate.needs_customer_approval`, `customer_approved_on`, the enum values `customer` of `incident_party`, `cost_payer`, `change_request_source` and `payment_payer`, `stock_source.customer_warehouse`, and the setting `s1_customer_notify_hours`.
- **Uniqueness that was per customer becomes per tenant.** `product (tenant_id, sku)` replaces `(customer_id, sku)`. `platform_account (tenant_id, platform_id)` replaces `(customer_id, platform_id)`. Composite keys `(id, customer_id, tenant_id)` collapse to the existing `(id, tenant_id)`. Every child→parent FK stays composite `(x_id, tenant_id)` and keeps its `ON DELETE` action and `DEFERRABLE`.
- **pgTAP conventions:**
  - Each file opens `BEGIN; SELECT plan(N);` and ends `SELECT * FROM finish(); ROLLBACK;`.
  - N equals the assertions after the edit. When a task removes or adds assertions in an existing file, it recounts N.
  - Fixtures come from `private.field_test_fixtures()` and `private.create_test_helpers()` (050), with `private.impersonate(user, tenant)` and `private.impersonate_scope(user, active, scope)`.
- **Errors** follow the existing pattern: `RAISE SQLSTATE 'PGRST' USING MESSAGE = json_build_object('code','P0001','message','<code>')::TEXT, DETAIL = json_build_object('status',<s>,'headers',json_build_object())::TEXT`. A new code gets `errors.<code>` in `en` and `tr` and a `NAMED_ERRORS` entry.
- **i18n:**
  - `en` is the source and `tr` is hand-written; the other locales come from `pnpm i18n-sync`.
  - Every new TR string is **[owner to confirm]**.
  - Removed keys are removed from all locales.
- **Types:** regenerate with `cd app && pnpm dev:supabase-types`. This also rewrites `app/src/@types/maskedFields.generated.ts`. Commit the type output only in the tasks that say so (Task 11 onward). Until then the DB tasks verify with `pnpm test:db` only.
- **Commands** (from `app/` unless noted):
  - `pnpm test:db`, `pnpm test`, `pnpm typecheck`, `pnpm lint`, `pnpm build`, `pnpm test:scripts`, `pnpm dev:seed-story`, `pnpm perf:fields`;
  - from `supabase/functions`: `deno task check`, `deno task test`, `deno task test:http` (local stack and `supabase functions serve` running).
- Commits are conventional, one per task, staging only the task's files. Each message ends with a blank line and `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never `git stash`, never push.

## Review Focus

- **The same SKU in two tenants** (previously unique per customer). It is allowed across tenants and refused twice in one tenant (`product_tenant_id_sku_key`). Pinned in Task 8.
- **A company whose `code_prefix` setting is missing, null or malformed**, e.g. a branch created before the setting existed, or a hand-edited value. Code generation must still work: fall back to the root's value, then to `ORG`, and refuse a malformed write. Pinned in Task 2.
- **A second Amazon account for the same platform in one tenant.** It is refused, and the connect flow finds the tenant's single account. Pinned in Task 4.
- **Bookmarks and open tabs on the removed routes** (`/ops/customers/...`, `/ops/transfer`). They land on NotFound, never on a crash or an empty page. Pinned in Task 12.
- **A user whose tenants belong to different companies.** The scope picker shows each company tree as its own root and keeps the multi-tenant scope (owner decision 4). Pinned in Task 12.

---

### Task 1: Retire the M21 customer-package transfer

**Files:**
- Delete:
  - migrations `supabase/migrations/042_transfer_rehearsal.sql`, `043_transfer_copy.sql`, `044_transfer_cheap_path.sql`, `045_transfer_files.sql`;
  - tests `supabase/tests/database/042_transfer_rehearsal.test.sql`, `042_transfer_scale.test.sql`, `043_transfer_copy.test.sql`, `043_transfer_locks.test.sql`, `044_transfer_cheap_path.test.sql`, `045_transfer_files.test.sql`.
- Modify:
  - `supabase/migrations/040_transfer_core.sql`: `public.transfer` loses `customer_id`, `target_customer_id` and `path`, and `idx_transfer_files_open` becomes `(tenant_id) WHERE files_status <> 'done'`. `private.transfer_registry` and its seed rows are removed. These stay: `private.owns_company`, `private.transferring`, `private.rules_bypassed`, `public.audit_transfer_locked`, `public.revert_audit_transaction`.
  - `supabase/migrations/058_api_derived.sql`: remove `private.transfer_field_rights`, `public.transfer_options`, `public.transfer_check_files` and `public.transfer_customer`.
  - `supabase/migrations/049_field_catalog.sql`: remove the `field_class` rows of the three dropped columns.
  - `supabase/tests/database/040_transfer_core.test.sql`, `064_field_security_cutover.test.sql`: drop `public.transfer_check_files`, `public.transfer_customer` and `public.transfer_options` from the definer allowlist.
  - `supabase/seed_story.sql` and `supabase/seed_story.check.sql`: remove Step 10 and its checks.
- Delete (app):
  - `app/src/views/pages/ops/transfer/` (all files) and `app/src/api/transfer/index.ts`;
  - `app/tests/api/transfer.test.ts`, `app/tests/views/transferStepper.test.ts`, `app/tests/views/transferWizard.test.ts`, `app/tests/components/TransferFilesNotice.test.ts`;
  - the `TransferFilesNotice` component imported by `src/views/pages/ops/customer/Manage.vue` and `ResultStep.vue`.
- Modify (app):
  - `app/src/router/routes/ops.ts`: remove the route `ops-transfer`;
  - `app/src/plugins/i18n/locales/*/index.json`: remove `ops.transfer.*` and `errors.transfer_*`;
  - the `NAMED_ERRORS` entries for the transfer codes.
- Test: `app/tests/router/opsRoutes.test.ts` (new).

**Interfaces:**
- Produces: `public.transfer` with no customer columns and no `path`. `private.transferring()` and `private.rules_bypassed()` are unchanged; Plan 4 reuses them and the `transfer` table.

- [ ] **Step 1: Write the failing tests.** Append these to `040_transfer_core.test.sql` and raise its plan by 5:

```sql
SELECT hasnt_column('public', 'transfer', 'customer_id', 'transfer has no customer');
SELECT hasnt_column('public', 'transfer', 'target_customer_id', 'transfer has no target customer');
SELECT hasnt_column('public', 'transfer', 'path', 'transfer has no cheap/copy path');
SELECT hasnt_table('private', 'transfer_registry', 'the customer-rooted registry is gone');
SELECT hasnt_function('public', 'transfer_customer', 'the customer-package entry point is gone');
```

`app/tests/router/opsRoutes.test.ts`:

```ts
import opsRoutes from '@/router/routes/ops';
import { createMemoryHistory, createRouter } from 'vue-router';
const router = createRouter({ history: createMemoryHistory(), routes: [opsRoutes].flat() });
it('has no transfer route', () => expect(router.hasRoute('ops-transfer')).toBe(false));
```

- [ ] **Step 2: Run both and confirm they fail.** Run `pnpm test:db` and `pnpm test tests/router/opsRoutes.test.ts`. Expected: 5 pgTAP failures, and the vitest fails on `hasRoute`.
- [ ] **Step 3: Make the edits listed above.** Then grep `supabase/migrations` for `transfer_registry|transfer_collect|transfer_report|transfer_apply` and remove every remaining reference. The guards in 041 keep their `private.transferring()` early return.
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test:db`, `pnpm test`, `pnpm typecheck` and `pnpm lint` all PASS.
- [ ] **Step 5: Commit** with `refactor(transfer): retire the M21 customer-package transfer`.

### Task 2: Code prefix per company instead of the customer code

**Files:**
- Modify:
  - `supabase/migrations/015_ops_core.sql`: `private.default_settings` gains a `code_prefix` row with value `"ORG"`. `private.copy_default_settings` writes `code_prefix` from `private.default_code_prefix(display_name)`.
  - the `*_set_code` triggers in `021_projects.sql`, `029_purchase_orders.sql`, `031_shipments.sql`, `035_incidents.sql`, `037_change_requests.sql` and their redefinitions in `041_transfer_triggers.sql`.
  - `supabase/migrations/041_transfer_triggers.sql`: `private.next_code_in` and `public.next_code` keep their signatures; only the callers change.
- Test: `supabase/tests/database/015_core.test.sql`.

**Interfaces:**
- Produces:
  - `private.default_code_prefix(p_display_name TEXT) RETURNS TEXT`, IMMUTABLE. It runs `upper()`, then `translate(…, 'ÇĞİÖŞÜÄÀÁÂÉÈÊÍÎÓÔÚÛ', 'CGIOSUAAAAEEEIIOOUU')`, keeps the `[A-Z]` letters and takes the first three. With fewer than two letters it returns `'ORG'`. It does not use `unaccent`: that extension is not installed and is not immutable.
  - `private.code_scope(p_tenant UUID) RETURNS TEXT`, STABLE SECURITY DEFINER. It returns the `code_prefix` setting of the tenant's root company when that is a JSON string matching `^[A-Z0-9]{2,6}$`, else `'ORG'`.
  - Trigger `setting_code_prefix_check`, BEFORE INSERT OR UPDATE ON `public.setting` WHEN `(NEW.key = 'code_prefix')`. It raises `code_prefix_invalid` (status 400) unless the value matches.
  - Every `*_set_code` trigger calls `public.next_code('<kind>', private.code_scope(NEW.tenant_id))`.

- [ ] **Step 1: Write the failing tests** in `015_core.test.sql` (plan +6):

```sql
SELECT is(private.default_code_prefix('Kernhaus Living GmbH'), 'KER', 'prefix from the name');
SELECT is(private.default_code_prefix('Ölçü Ltd'), 'OLC', 'accents dropped');
SELECT is(private.default_code_prefix('9'), 'ORG', 'too few letters falls back');
SELECT is(private.code_scope(current_setting('test.europe')::UUID),
          private.code_scope(current_setting('test.moesa')::UUID), 'a branch uses its root''s prefix');
SELECT throws_like($$ UPDATE public.setting SET value = '"ab"' WHERE key = 'code_prefix' $$, '%code_prefix_invalid%', 'lower case refused');
SELECT t.definer_exec(format('DELETE FROM public.setting WHERE key = %L AND tenant_id = %L', 'code_prefix', current_setting('test.moesa')));
SELECT is(private.code_scope(current_setting('test.moesa')::UUID), 'ORG', 'missing setting falls back to ORG');
```
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL, functions missing.
- [ ] **Step 3: Implement the three functions, the trigger and the caller changes.** Seeded tenants get their prefix from `copy_default_settings`. `seed.sql` sets MOESA LTD to `MOE`.
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS. The existing code assertions now expect `PO-<prefix>-<year>-001`, and each test that asserted a customer-coded value is updated to the tenant prefix.
- [ ] **Step 5: Commit** with `refactor(codes): number business codes by company prefix`.

### Task 3: Change requests and incidents without customer

**Files:**
- Modify:
  - `supabase/migrations/035_incidents.sql`, `036_gate_rollback_incident.sql`, `037_change_requests.sql`, `038_dashboard_matrix_incidents.sql`;
  - the redefinitions of `private.incident_guard`, `private.incident_notice_due`, `private.change_request_guard`, `private.change_request_due` and `private.change_request_set_code` in `041_transfer_triggers.sql`, and of `private.incident_child_guard` in `052_guard_request_identity.sql`;
  - `api.incident_overview`, `api.dashboard_incident` and `api.dashboard_change_request` in `058_api_derived.sql` (drop `customer_code`);
  - the `field_class` rows in `049_field_catalog.sql`;
  - `supabase/seed.sql` (any CR or incident rows).
- Delete: `private.change_request_product_customer` and its trigger.
- Test: `supabase/tests/database/035_incidents.test.sql`, `037_change_requests.test.sql`, `038_dashboard_matrix_incidents.test.sql`, and `018_customers.test.sql`, which becomes the cross-cutting absence test (renamed in Task 8; until then it keeps its name).

**Interfaces:**
- Produces:
  - `change_request`: `UNIQUE (id, tenant_id)` and `FOREIGN KEY (project_id, tenant_id) REFERENCES project (id, tenant_id) ON DELETE RESTRICT DEFERRABLE`.
  - `change_request_product`: FKs `(change_request_id, tenant_id) ON DELETE CASCADE` and `(product_id, tenant_id) ON DELETE RESTRICT`, both DEFERRABLE.
  - `incident` has no customer column.

- [ ] **Step 1: Write the failing test.** In `018_customers.test.sql`, add an absence block (plan +3):

```sql
SELECT is_empty($$ SELECT table_name FROM information_schema.columns
   WHERE table_schema IN ('public', 'api') AND column_name IN ('customer_id', 'customer_code')
     AND table_name IN ('incident', 'incident_overview', 'dashboard_incident', 'change_request', 'change_request_product', 'dashboard_change_request') $$,
   'incidents and change requests carry no customer');
SELECT hasnt_function('private', 'change_request_product_customer', 'no customer consistency trigger on CR products');
SELECT is_empty($$ SELECT * FROM private.api_view_drift() $$, 'drift is empty');
```

- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Edit the migrations.** Drop the column, its FK, its index and the triple keys. Guards that compared a parent's `customer_id` now compare only `tenant_id`, which the composite FK already enforces, so drop those checks.
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS, with the incident and CR tests recounted.
- [ ] **Step 5: Commit** with `refactor(incidents): incidents and change requests belong to the tenant only`.

### Task 4: Directory tables `brand`, `contact`, `warehouse`, `platform_account`

**Files:**
- Rename with `git mv`:
  - `supabase/migrations/018_customers.sql` → `018_tenant_directory.sql`, keeping `public.customer` until Task 8;
  - `054_api_customer_supplier.sql` → `054_api_directory_supplier.sql`;
  - `supabase/tests/database/054_api_customer_supplier.test.sql` → `054_api_directory_supplier.test.sql`.
- Modify:
  - `018_tenant_directory.sql`: `customer_brand|contact|warehouse|platform_account` become `public.brand`, `public.contact`, `public.warehouse` and `public.platform_account`, with no `customer_id`. `platform_account` is `UNIQUE (tenant_id, platform_id)` and `warehouse` is `UNIQUE (id, tenant_id)`.
  - Permissions: `public.brand|contact|warehouse|platform_account` with the same commands. Their `group_name` is the new module `directory` (`module` row `('directory', TRUE, 130)`).
  - `031_shipments.sql`: `shipment_warehouse_fkey` becomes `(delivery_warehouse_id, tenant_id) REFERENCES warehouse (id, tenant_id) ON DELETE RESTRICT DEFERRABLE`.
  - `046_amazon_listing_core.sql` and `052_guard_request_identity.sql`: `private.platform_account_api_server_only`, `private.platform_account_authorize`, `private.platform_account_connected`, `public.amazon_account_connect`, `public.amazon_account_disconnect` and `public.listing_parent_cell` look the account up by `(tenant_id, platform_id)`.
  - `049_field_catalog.sql`: rename the resources and drop the `customer_id` rows. `053`/`057` `enable_field_security` calls use the new table names.
  - `supabase/seed.sql`.
  - `supabase/migrations/013_init_subscriptions.sql` or wherever `plan_module` rows list `customer`: replace the module `customer` with `directory`.
- Test: `supabase/tests/database/018_customers.test.sql`, `046_amazon_listing_core.test.sql`, `054_api_directory_supplier.test.sql`.

**Interfaces:**
- Produces:
  - tables `public.brand`, `public.contact`, `public.warehouse`, `public.platform_account` and their views `api.brand`, `api.contact`, `api.warehouse`, `api.platform_account`;
  - module `directory`;
  - CASL subjects `brand`, `contact`, `warehouse`, `platform_account`.
- Consumes: `private.enable_field_security(p_table TEXT, p_read_only BOOLEAN)` (057).

- [ ] **Step 1: Write the failing tests.** Add to `018_customers.test.sql` (plan +6):

```sql
SELECT has_table('public', 'brand', 'brand is a tenant table');
SELECT has_table('public', 'platform_account', 'platform_account is a tenant table');
SELECT hasnt_table('public', 'customer_brand', 'customer_brand is gone');
SELECT col_is_unique('public', 'platform_account', ARRAY['tenant_id', 'platform_id'], 'one account per platform per tenant');
SELECT throws_ok($$ INSERT INTO public.platform_account (tenant_id, platform_id, countries, access)
   SELECT tenant_id, platform_id, countries, access FROM public.platform_account LIMIT 1 $$, '23505', NULL, 'a second Amazon account in one tenant is refused');
SELECT ok(has_table_privilege('authenticated', 'api.warehouse', 'INSERT'), 'warehouse is writable through api');
```

In `046_amazon_listing_core.test.sql`, add one assertion (plan +1): `public.listing_parent_cell` finds the tenant's account with no customer argument.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Edit as listed.**
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS.
- [ ] **Step 5: Commit** with `refactor(directory): brands, contacts, warehouses and platform accounts belong to the tenant`.

### Task 5: Market cells and Amazon listing without customer

**Files:**
- Modify:
  - `supabase/migrations/034_market_matrix.sql`, `046_amazon_listing_core.sql`;
  - `private.market_cell_guard` in `041_transfer_triggers.sql` and `052_guard_request_identity.sql`;
  - `api.market_cell_overview` and `api.dashboard_market` in `058_api_derived.sql`;
  - `049_field_catalog.sql` rows and `supabase/seed.sql`.
- Delete: `private.market_cell_customer` and its trigger.
- Test: `supabase/tests/database/034_market_matrix.test.sql`, `018_customers.test.sql`.

**Interfaces:**
- Produces: `market_cell` FKs `(product_id, tenant_id) REFERENCES product (id, tenant_id)` and `(project_id, tenant_id) REFERENCES project (id, tenant_id)`, both `ON DELETE RESTRICT DEFERRABLE`.

- [ ] **Step 1: Write the failing test.** In `018_customers.test.sql` (plan +1): `is_empty` of the `customer_id`/`customer_code` columns of `market_cell`, `market_cell_overview` and `dashboard_market`, plus `hasnt_function('private','market_cell_customer')` folded into the same file (plan +1).
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Edit.**
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS.
- [ ] **Step 5: Commit** with `refactor(market): market cells belong to the tenant only`.

### Task 6: Purchase orders and shipments without customer

**Files:**
- Modify:
  - `supabase/migrations/029_purchase_orders.sql`, `030_purchase_order_rules.sql`, `031_shipments.sql`, `033_dashboard_operations.sql`;
  - the redefinitions in `041_transfer_triggers.sql` (`purchase_order_defaults`, `purchase_order_immutable`, `purchase_order_line_guard`, `shipment_guard`) and `052_guard_request_identity.sql` (`purchase_order_line_guard`, `purchase_order_child_guard`, `shipment_purchase_order_guard`, `shipment_line_guard`);
  - `058_api_derived.sql`: `private.purchase_order_figures`, `api.purchase_order_overview`, `api.dashboard_purchase_order`, `api.shipment_overview`, `api.dashboard_shipment`;
  - `049_field_catalog.sql` and `supabase/seed.sql`.
- Delete: `private.purchase_order_line_customer` and `private.shipment_purchase_order_customer` and their triggers.
- Test: `supabase/tests/database/029_purchase_orders.test.sql`, `031_shipments.test.sql`, `018_customers.test.sql`.

**Interfaces:**
- Produces:
  - `purchase_order`: `UNIQUE (id, tenant_id)` and `(project_id, tenant_id) REFERENCES project (id, tenant_id)`.
  - `purchase_order_line`: `(purchase_order_id, tenant_id) ON DELETE CASCADE` and `(product_id, tenant_id) ON DELETE RESTRICT`.
  - `shipment_purchase_order`: `(purchase_order_id, tenant_id)` and `(shipment_id, tenant_id) ON DELETE CASCADE`.
  - All of these are DEFERRABLE.

- [ ] **Step 1: Write the failing test.** In `018_customers.test.sql` (plan +2): `is_empty` of the customer columns over `purchase_order`, `purchase_order_line`, `shipment`, `shipment_purchase_order`, `purchase_order_overview`, `shipment_overview`, `dashboard_purchase_order` and `dashboard_shipment`; and `hasnt_function` for both deleted triggers in one `ok(NOT EXISTS (… pg_proc …))`.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Edit.** `purchase_order_figures` keeps its signature minus any customer parameter.
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS.
- [ ] **Step 5: Commit** with `refactor(orders): purchase orders and shipments belong to the tenant only`.

### Task 7: Projects, gates, documents and media without customer

**Files:**
- Modify:
  - `supabase/migrations/016_documents.sql`: drop the `document_entity` value `customer` and `document.customer_id`;
  - `021_projects.sql`, `022_dashboard.sql`, `023_phase1_fixes.sql`, `024_media.sql`, `025_media_link.sql`, `026_document_media.sql`, `032_gate_links.sql`, `036_gate_rollback_incident.sql`;
  - `041_transfer_triggers.sql` (`project_set_code`, `project_create_gates`, `project_immutable`, `project_gate_guard`, `media_customer_lock`, `media_link_check`, `media_check_file`, `document_transition`);
  - `058_api_derived.sql` (`api.dashboard_gate_pending`, `api.dashboard_task_due`, `api.media_library`, `public.pass_gate`);
  - `060_file_row_rule.sql`, `049_field_catalog.sql` and `supabase/seed.sql`.
- Delete: `private.entity_customer`, `private.media_customer_lock` and its trigger, and `idx_document_customer` / `idx_media_customer`.
- Test: `supabase/tests/database/016_documents.test.sql`, `021_projects.test.sql`, `024_media.test.sql`, `025_media_link.test.sql`, `032_gate_links.test.sql`, `018_customers.test.sql`.

**Interfaces:**
- Produces:
  - `document_entity` = `supplier, product, project, project_gate, purchase_order, shipment, incident, market_cell, change_request`;
  - `project UNIQUE (id, tenant_id)`;
  - `media` with no owner other than its tenant.

- [ ] **Step 1: Write the failing test.** In `018_customers.test.sql` (plan +2):

```sql
SELECT ok(NOT ('customer' = ANY (enum_range(NULL::public.document_entity)::TEXT[])), 'no customer document entity');
SELECT is_empty($$ SELECT table_name FROM information_schema.columns WHERE table_schema IN ('public','api')
   AND column_name IN ('customer_id','customer_code') AND table_name IN ('project','document','media','media_library','dashboard_gate_pending','dashboard_task_due') $$,
   'projects, documents and media carry no customer');
```

- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Edit.** Media sharing across customers (seed media 09, "shared: THO and KRN products") becomes sharing within one tenant.
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS.
- [ ] **Step 5: Commit** with `refactor(projects): projects, documents and media belong to the tenant only`.

### Task 8: Products without customer; the customer table and `customer_viewer` go

**Files:**
- Modify:
  - `supabase/migrations/019_products.sql`: `UNIQUE (tenant_id, sku)` as `product_tenant_id_sku_key`, no `customer_id`;
  - `020_products_import.sql` and `058_api_derived.sql` (`public.import_products` without the customer column; `api.product_evidence`, `api.product_with_evidence`, `api.dashboard_product_evidence`);
  - `039_company_price_column.sql`;
  - `018_tenant_directory.sql`: remove `public.customer`, `customer_status`, `customer_code_immutable` and `customer_contract_guard`, and drop the `contract_document_id` link. `commercial_model` stays, because Plan 2 uses it;
  - `015_ops_core.sql`, `022_dashboard.sql` (any customer lookups);
  - `049_field_catalog.sql`: remove `public.customer` rows and the `customer_viewer` profile rows from `private.field_default`; `private.backfill_role_fields` lists only `management` and `coordinator`;
  - `050_field_rights.sql`: `private.field_test_fixtures` has no customer and no `customer_viewer`. Its portal fixture becomes the role `viewer` in a tenant `THOMETZKI ONLINE HANDEL` created by the fixture;
  - `supabase/seed.sql` (see Step 3) and `supabase/tests/database/099_seed.test.sql`.
- Create: `supabase/migrations/066_ops_roles.sql`, `supabase/tests/database/066_ops_roles.test.sql`.
- Rename with `git mv`: `supabase/tests/database/018_customers.test.sql` → `018_tenant_directory.test.sql`.

**Interfaces:**
- Produces:
  - `private.create_ops_roles(p_tenant UUID) RETURNS VOID`, SECURITY DEFINER, revoked from PUBLIC, anon and authenticated. It creates in `p_tenant` the roles `management` and `coordinator` with the permission sets `seed.sql`'s `private.seed_ops_roles` gives today (minus `public.transfer` for coordinator, as before) and applies `private.apply_field_defaults(role, profile)`. It is idempotent: an existing role of that name is left alone.
  - `public.register_tenant(owner_id UUID, company JSONB)` now also calls `private.create_ops_roles(created.id)`.
  - Seeded users and tenants after this task:
    - `thometzki@moesa-panel.test` (Thomas Metzki): owner of the new root tenant `THOMETZKI ONLINE HANDEL`, code prefix `THO`.
    - `baris@`: owner of MOESA LTD and a member of THO with the role `management`.
    - `akif@`: management in MOESA LTD, Europe and THO.
    - `koordinator@`: coordinator in MOESA LTD and THO.
    - `portal@moesa-panel.test`: a member of THO only, with a custom role `viewer` that has select on `directory`, `product`, `project`, `purchase_order`, `shipment` and `document`, and field read on `sell_price`, `contract` and `personal_data` only.
    - THO's warehouse, platform account, brand, contact, suppliers, products and project now live in the THO tenant.

- [ ] **Step 1: Write the failing tests.** In `018_tenant_directory.test.sql` (plan +5):

```sql
SELECT hasnt_table('public', 'customer', 'no customer table');
SELECT is_empty($$ SELECT table_schema || '.' || table_name FROM information_schema.columns
   WHERE table_schema IN ('public', 'api', 'private') AND column_name IN ('customer_id', 'customer_code', 'target_customer_id') $$,
   'no customer_id anywhere');
SELECT is_empty($$ SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public','private','api') AND pg_get_functiondef(p.oid) ~ '\mpublic\.customer\M' $$, 'no function reads public.customer');
SELECT is_empty($$ SELECT 1 FROM public.role WHERE display_name = 'customer_viewer' $$, 'customer_viewer retired');
SELECT is_empty($$ SELECT 1 FROM private.field_default WHERE profile = 'customer_viewer' $$, 'no customer_viewer defaults');
```

The new `066_ops_roles.test.sql` uses `plan(6)`:

```sql
SELECT has_function('private', 'create_ops_roles', ARRAY['uuid']);
-- a fresh tenant created by register_tenant has both roles
SELECT is((SELECT array_agg(display_name ORDER BY display_name) FROM public.role WHERE tenant_id = :new_tenant), ARRAY['coordinator','management'], 'register_tenant creates the ops roles');
SELECT ok(EXISTS (SELECT 1 FROM public.role_field_permission rfp JOIN public.role r ON r.id = rfp.role_id
   WHERE r.tenant_id = :new_tenant AND r.display_name = 'coordinator' AND rfp.resource_name = 'public.supplier' AND rfp.field = 'payment_terms' AND rfp.can_read AND NOT rfp.can_write), 'coordinator defaults applied');
SELECT lives_ok($$ SELECT private.create_ops_roles(:new_tenant) $$, 'idempotent');
SELECT is((SELECT count(*)::INT FROM public.role WHERE tenant_id = :new_tenant), 2, 'still two roles');
SELECT ok(NOT has_function_privilege('authenticated', 'private.create_ops_roles(uuid)', 'EXECUTE'), 'not callable by users');
```

(`:new_tenant` is a `set_config('test.new_tenant', …)` value from a `public.register_tenant` call made as postgres.) In the same file, add a Review Focus assertion (plan +1, so `plan(7)`): the same SKU inserts in two tenants, and a duplicate in one tenant throws `23505`.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Implement `066_ops_roles.sql` and the removals.** Rewrite `seed.sql`:
  - `private.seed_ops_roles` is replaced by `private.create_ops_roles`;
  - THO's rows move to the THO tenant;
  - the header comment lists the users above;
  - `099_seed.test.sql` asserts the THO tenant, its owner and the portal user's `viewer` role, recounted.
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS.
- [ ] **Step 5: Commit** with `refactor(tenancy): remove the customer table; ops roles per tenant`.

### Task 9: Field classification, masked fields and drift

**Files:**
- Modify:
  - `docs/superpowers/specs/2026-11-08-field-classification.md`: replace the `customer*` sections with `brand`, `contact`, `warehouse` and `platform_account`; remove the portal column, noting that "client tenants use ordinary roles; see the customer-as-tenant spec"; update the counts in the header;
  - `supabase/tests/database/049_field_catalog.test.sql`: the expected sensitive count is recounted from `field_class`, and `customer_viewer` is replaced by the `viewer` fixture;
  - `supabase/tests/database/053_api_schema.test.sql` (fixture names);
  - `supabase/tests/database/064_field_security_cutover.test.sql` (allowlist recount).
- Test: those files, plus `scripts/masked-fields.test.mjs`.

**Interfaces:**
- Consumes: `public.field_class` as Tasks 3–8 left it.

- [ ] **Step 1: Write the failing test.** In `049_field_catalog.test.sql`, the assertion `'every column of every public table is classified'` stays. Change the sensitive-count assertion to the new number: run `SELECT count(*) FROM public.field_class WHERE class = 'sensitive'` once after Task 8 and write that number. Also add `SELECT is_empty($$ SELECT 1 FROM public.field_class WHERE resource_name LIKE 'public.customer%' $$, 'no customer resources')` (plan +1).
- [ ] **Step 2: Run and confirm it fails or passes as expected.** `pnpm test:db`: FAIL until the count is written.
- [ ] **Step 3: Update the doc and the tests.**
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS.
- [ ] **Step 5: Commit** with `docs(fields): classification without customers`.

### Task 10: Edge Functions on tenant-level platform accounts

**Files:**
- Modify:
  - `supabase/functions/_shared/amazonAccount.ts`, `_shared/listingStatus.ts`, `_shared/serviceRole.ts`;
  - `supabase/functions/amazon-auth/index.ts`, `amazon-listing/index.ts`, `amazon-listing/listing.ts`, `amazon-poll/poll.ts`, `amazon-schema/index.ts`;
  - `supabase/functions/tests/amazon_auth_test.ts`, `amazon_listing_test.ts`, `amazon_schema_test.ts`, `amazon_test.ts`;
  - `supabase/functions/_shared/database.types.ts` (regenerated).

**Interfaces:**
- Produces: `loadAccount(tenantId: string, platformId: string)` in `_shared/amazonAccount.ts`, replacing any `(customerId, platformId)` lookup. The OAuth state carries `{ tenantId, accountId }`; `customerId` is dropped.

- [ ] **Step 1: Write the failing test.** In `amazon_auth_test.ts`, add `Deno.test('state carries tenant and account, no customer', …)`: assert that the parsed state equals `{ tenantId, accountId }` and that `'customerId' in state` is false.
- [ ] **Step 2: Run and confirm it fails.** `cd supabase/functions && deno task test`: FAIL.
- [ ] **Step 3: Regenerate the types** (`cd app && pnpm dev:supabase-types`) **and edit the functions** to read `platform_account`.
- [ ] **Step 4: Run and confirm everything passes.** `deno task check && deno task test`: PASS.
- [ ] **Step 5: Commit** with `refactor(amazon): accounts belong to the tenant`.

### Task 11: App data layer without customer

**Files:**
- Delete:
  - `app/src/api/customer/index.ts`, `app/src/api/customerFilter.ts`, `app/src/store/customerFilter/` (both files);
  - `app/src/components/service-components/customer-filter/CustomerFilter.vue`;
  - `app/tests/api/customer.test.ts`, `app/tests/api/customerFilter.test.ts`.
- Create: `app/src/api/directory/index.ts`, `app/tests/api/directory.test.ts`.
- Modify:
  - every API module that selects or filters `customer_id`/`customer(...)`: `src/api/product`, `project`, `purchaseOrder`, `shipment`, `marketMatrix`, `incident`, `changeRequest`, `document`, `media`, `dashboard`, `amazon`;
  - their zod schemas;
  - `src/constants/dashboard.ts`, `src/constants/form/field.ts`, `src/constants/guide.ts`, `src/constants/terms.ts`, `src/lib/form/postgrestErrors.ts`;
  - `src/layouts/dashboard/ScopeControls.vue` (BranchPicker only);
  - `supabase/functions/_shared/database.types.ts` and `app/src/@types/maskedFields.generated.ts` (regenerated);
  - the tests under `app/tests/api` and `app/tests/layouts/scopeControls.test.ts`.

**Interfaces:**
- Produces: `src/api/directory/index.ts` exports `brandApi`, `contactApi`, `warehouseApi` and `platformAccountApi`, each built with `defineResource` on `api.brand|contact|warehouse|platform_account`. Query keys are `['directory', '<table>', tenantKey]`.

- [ ] **Step 1: Write the failing tests.**
  - `tests/api/directory.test.ts`: `it('lists warehouses of the scope without a customer filter')` asserts that the PostgREST URL is `/rest/v1/warehouse?select=*&order=display_name.asc` and contains no `customer_id`.
  - `tests/layouts/scopeControls.test.ts`: `it('shows only the tenant picker')` asserts `find('[data-test="customer"]').exists()` is false.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test`: FAIL.
- [ ] **Step 3: Regenerate the types and implement.** Lists show a tenant column (from `authStore.branches` by `tenant_id`) when `scopeTenants.length > 1`, where they showed `customer_code` before.
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint`: PASS.
- [ ] **Step 5: Commit** with `refactor(app): data layer without customers`.

### Task 12: App pages: directory instead of customers, module pages cleaned

**Files:**
- Move to `app/src/views/pages/ops/directory/`, adapted to tenant scope: `BrandUpsert.vue`, `ContactUpsert.vue`, `WarehouseUpsert.vue`, `PlatformUpsert.vue`, `AmazonConnection.vue` and `tabs/Brands.vue`, `Contacts.vue`, `Warehouses.vue`, `Platforms.vue`.
- Create: `app/src/views/pages/ops/directory/Index.vue` (tabs).
- Delete: the rest of `app/src/views/pages/ops/customer/`.
- Modify:
  - `app/src/router/routes/ops.ts`: remove every `ops-customer*` route. Add `ops-directory` (path `directory/:tab?`, tabs `brands|contacts|warehouses|platforms`) and the dialogs `ops-directory-<entity>-add|edit`.
  - the module pages and components that showed or picked a customer: product (`Index`, `Manage`, `ProductCard`, `tabs/General`), project, purchase-order (`ProjectSelect`, `ProductSelect`, `Manage`, `tabs/*`), shipment (`Manage`, `tabs/*`, warehouse select), market, incident, change-request, document, media, dashboard boxes, amazon-form components, `change-request-table`, `incident-table`, `market-cell-table`, `market-matrix-grid`, `entity-documents`, `entity-media`, `gate-panel`, `media/MediaDropzone`;
  - `app/src/plugins/i18n/locales/*/index.json`: `ops.customer.*` becomes `ops.directory.*` for the kept keys, the rest is removed, and the menu label becomes "Company directory" / TR "Şirket rehberi" **[owner to confirm]**;
  - `app/src/components/service-components/branch-picker/BranchPicker.vue`: label "Tenants" / TR "Kiracılar" **[owner to confirm]**; its behaviour is unchanged.
- Test:
  - `app/tests/router/opsRoutes.test.ts`;
  - `app/tests/views/platformConnect.test.ts`, `productForm.test.ts`, `purchaseOrderForm.test.ts`, `shipmentForm.test.ts`, `incidentForm.test.ts`, `changeRequestForm.test.ts`, `marketMatrix.test.ts`, `dashboardBoxes.test.ts`, `mediaLibrary.test.ts`;
  - `app/tests/components/*` as needed;
  - `app/tests/plugins/i18n/usedKeys.test.ts`;
  - `app/tests/layouts/scopeControls.test.ts`.

**Interfaces:**
- Consumes: `brandApi`, `contactApi`, `warehouseApi` and `platformAccountApi` (Task 11).

- [ ] **Step 1: Write the failing tests.** In `opsRoutes.test.ts`:

```ts
it('has no customer routes', () =>
   expect(router.getRoutes().filter((r) => String(r.name).startsWith('ops-customer'))).toEqual([]));
it('has the directory', () => expect(router.hasRoute('ops-directory')).toBe(true));
it('resolves a removed bookmark to not-found', () =>
   expect(router.resolve('/ops/customers/list').matched.at(-1)?.name).toBe('not-found'));
```

Use the app's catch-all route name; check it in `src/router/index.ts` and use it here. In `scopeControls.test.ts`, add `it('shows tenants of two companies as two roots')`: with `branches` = MOESA LTD (root), MOESA Europe (child) and THOMETZKI (root), the BranchPicker tree has two root nodes.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint && pnpm build`: PASS.
- [ ] **Step 5: Commit** with `feat(app): company directory; customer pages removed`.

### Task 13: HTTP attack suite and perf harness on the tenant model

**Files:**
- Modify:
  - `supabase/functions/http-tests/helpers.ts`: drop `HTTP_EU_CUSTOMER` and the customer rows; `Fixture.thoId` becomes the THO tenant id; add `tho: string` (tenant), `thometzki: string` (token) and `portal` (token, now THO's viewer);
  - `supabase/functions/http-tests/field_security_http_test.ts`: the test `portal reads contract terms but not the drive URL, suppliers or PIs` is rewritten as `THO viewer reads sell prices but not cost, suppliers or PIs` against THO-tenant rows. Contract terms come back in Plan 2;
  - `supabase/functions/scripts/field_perf_http.ts`, `supabase/perf/field_security_perf.sql`, `supabase/perf/field_security_perf_load.sql`: the load creates products and orders per tenant instead of per customer, keeping the same row counts.

**Interfaces:**
- Produces: `Fixture` with `tho`, `thometzki` and `portal`. Plan 2 extends this type.

- [ ] **Step 1: Write the failing test.** Rename the portal test as above. It asserts that `GET /product?select=sku,company_price_eur,purchase_price&tenant_id=eq.<tho>` returns `purchase_price === null` and `company_price_eur !== null` for every row, and that `/supplier?select=id` returns `[]`.
- [ ] **Step 2: Run and confirm it fails.** `deno task test:http`: FAIL on the old fixture.
- [ ] **Step 3: Implement the helper and perf changes.**
- [ ] **Step 4: Run and confirm everything passes.** `deno task test:http` PASS, and `cd app && pnpm perf:fields` reports no line over budget.
- [ ] **Step 5: Commit** with `test(http): attack suite and perf load on the tenant model`.

### Task 14: Story seed on the tenant model

**Files:**
- Modify:
  - `supabase/seed_story.sql`: every step runs in the customer's own tenant. THO's story runs in `THOMETZKI ONLINE HANDEL` as `baris@`/`koordinator@`, who are its members. KRN becomes the root tenant `Kernhaus Living GmbH`, owned by the new seeded user `kernhaus@moesa-panel.test`, with `akif@` as management. LEA, PAU and CLS become tenants `Leafline Garten GmbH`, `Paxton Haushalt GmbH` and `Clearstar Handel GmbH`, owned by `baris@`, whose rows `story_begin` targets by tenant name. The second-run guard checks `EXISTS (SELECT 1 FROM public.tenant WHERE display_name = 'Kernhaus Living GmbH')`. The media of KRN move to KRN's folder (`<krn tenant>/<media id>/…`). The header comment is rewritten.
  - `supabase/seed_story.check.sql`: same intent, tenant-based. The `fp.portal_*` checks read through THO's `viewer`.
  - `scripts/seed-story.mjs`: the refusal message and the media folder per tenant (the `MEDIA` entries gain a `tenant` display name).
  - `scripts/seed-story.test.mjs`.
  - `supabase/seed.sql`: seeds `kernhaus@moesa-panel.test`.

**Interfaces:**
- Produces: tenants `Kernhaus Living GmbH`, `Leafline Garten GmbH`, `Paxton Haushalt GmbH` and `Clearstar Handel GmbH`, each with its prefix (`KER`, `LEA`, `PAX`, `CLE` from `default_code_prefix`; the seed sets `KRN`, `LEA`, `PAU`, `CLS` explicitly so story codes keep their letters). Plan 2 reshapes them into relationships.

- [ ] **Step 1: Write the failing test.** In `scripts/seed-story.test.mjs`, add `test('every media file has a tenant folder')`: every `MEDIA` entry has a non-empty `tenant`, and the upload path starts with that tenant's id placeholder.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:scripts`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm dev:supabase-reset` (which runs `dev:seed-story`) ends with no check rows, and `pnpm test:scripts` PASSES.
- [ ] **Step 5: Commit** with `chore(seed): story seed with one tenant per customer`.

### Task 15: Final gate for Plan 1

**Files:**
- Modify: `supabase/CHANGELOG.md` (one entry: customer removed, directory tables, code prefix, ops roles, M21 retired) and `supabase/README.md` (seeded users list).

- [ ] **Step 1: Run the grep gate** from Global Constraints. Expected: no output.
- [ ] **Step 2: Run everything.**
  - `cd app && pnpm test:db && pnpm test && pnpm typecheck && pnpm lint && pnpm build && pnpm test:scripts && pnpm dev:supabase-reset`;
  - `cd supabase/functions && deno task check && deno task test && deno task test:http`;
  - `cd app && pnpm perf:fields`.

  Expected: all PASS, and the perf run prints no `budget:` error.
- [ ] **Step 3: Commit** with `docs(tenancy): plan 1 done, customer removed`.
