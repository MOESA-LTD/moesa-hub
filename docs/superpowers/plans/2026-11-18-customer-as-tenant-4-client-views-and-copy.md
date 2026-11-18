# Customer = Tenant, Plan 4: Client Views, Tenant Copy Tool and the Walk

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Client users see their providers, the orders and shipments a provider procures for them, and the selling prices, all read-only and within the client-visible set. Any user holding the rights in two tenants can copy or move products with their linked records between them. A browser walk with four users proves the whole refactor.

**Architecture:**
- **Client pages.** They read only the `api.shared_*` views (Plan 2) and never ask for a provider-only column. The database refuses those anyway, so the UI is convenience, not the boundary.
- **The copy tool** reuses the M21 engine's design and code from git history (`git show 1a5c995e:supabase/migrations/042_transfer_rehearsal.sql`, `043_transfer_copy.sql`, `045_transfer_files.sql`), re-rooted at a product set.
  - Kept: a registry of tables, a rehearsal report with a hash, decisions, a generic jsonb copy writer with an id map, the `private.transferring()` flag, and file copy by the app with `transfer_check_files`.
  - Dropped: M21's customer root, its cheap path and its root-company ownership rule. In their place goes a field-rights gate in both tenants (owner decision 14).
- **The walk** runs the app against the story seed for four users.

**Tech Stack:** Supabase (Postgres 15, PostgREST, pgTAP), Deno HTTP tests, Vue 3.5 + PrimeVue 4 + TanStack Query 5 + CASL, vitest 3, the Chrome DevTools MCP tools for the walk.

**Spec:** `docs/superpowers/specs/2026-11-18-customer-as-tenant-design.md`:
- decisions 4, 11, 13 and 14;
- Goals: "Picking the MOESA tenant together with a customer tenant shows the product with MOESA's sourcing data side by side";
- Left to the builder: the app;
- Done means: "A browser walk covers four users".

**Series:** Plan 4 of 4. It requires Plans 1–3.

## Global Constraints

- Owner decision 14: "copy or move products and their linked records from one tenant to another… the caller must hold the needed table and field rights in both the source and the target tenant."
- Owner decision 11: "The M21 customer transfer is retired. Its role is taken by moving data between tenants."
- Spec: "Shared rows are read-only for the client in this round." Client pages offer no edit, delete or upload on shared rows.
- Spec, Done means: "A browser walk covers four users: a MOESA staff member, a client owner, a client user with a limited role, and a client-procures owner."
- **Migration strategy (this plan).** `075_tenant_copy.sql` is new. It brings back the parts of M21 deleted in Plan 1, rewritten for products:
  - Reused from M21 (adapt the bodies from `1a5c995e`): the registry table shape, the report-hash comparison, the decision actions `map | new_code | clear_gtin | skip` (verbatim), the generic writer `transfer_write` (jsonb, `jsonb_populate_record`, id map), `transfer_media_paths`, `transfer_check_files`, `files_status` `pending | done | partial`, and the stale code `transfer_report_stale`.
  - Not reused: `transfer_collect` by customer, `transfer_apply_cheap`, `private.owns_company` as a gate, and customer `new_code`.
  - Signature: `public.copy_products(source_tenant UUID, target_tenant UUID, product_ids UUID[], mode TEXT, decisions JSONB DEFAULT '{}', dry_run BOOLEAN DEFAULT TRUE, report_hash TEXT DEFAULT NULL) RETURNS JSONB`. `mode` is `copy` or `move`.
- **The package** (the registry, in insert order):
  1. `supplier` and `supplier_contact`: suppliers referenced by the package's own sourcing rows. A supplier code that exists in the target is a conflict: `map` or `new_code` with `code`.
  2. `product`: the selected products plus the parents of selected variants. A SKU that exists in the target is a conflict: `map`, `new_code` with `sku`, or `skip`. A GTIN that exists in the target is a conflict: `clear_gtin` or `skip`.
  3. `product_sourcing`: only the source tenant's own rows (`tenant_id = source AND client_tenant_id IS NULL`). A provider's sourcing rows in other tenants are never read or copied.
  4. `media`: media linked to the package's products or documents.
  5. `media_link` with `entity_type = 'product'`.
  6. `document` with `entity_type = 'product'`.
  7. `market_cell`: copied with `project_id = NULL`.
  - Never in the package: projects, purchase orders, shipments, incidents, change requests, `project_product`, `listing_submission`.
  - In `move` mode, a source row outside the package in the same tenant that references a package product refuses the move with `transfer_product_in_use`. Rows of another tenant that point at the product (a provider's sourcing or PO lines) do not block: their FK sets `product_id` NULL and the snapshot remains (Plan 2).
- **Rights gate** (binding; checked in the rehearsal and again in the real run):
  - **Table rights:** `public.transfer` insert in both tenants (`tenants_permitting` with the explicit tenant, not the request scope); select on every registry table that has a package row in the source; insert on each in the target; and in `move` mode, the source rows are deleted under the transfer flag.
  - **Field rights:** for every sensitive field (`field_class.class = 'sensitive'`) of every registry table with a package row, `private.field_tenants(auth.uid(), ARRAY[source_tenant], <resource>, <field>, FALSE)` is non-empty and `private.field_tenants(auth.uid(), ARRAY[target_tenant], <resource>, <field>, TRUE)` is non-empty.
  - Else it refuses with `transfer_field_forbidden` (42501, status 403) and the detail `<resource>.<field>` (the first in sort order). The rehearsal report also lists all such fields under `forbidden_fields`.
  - A super admin passes by `field_tenants`.
  - No root-company ownership rule.
- Error codes: `transfer_field_forbidden` (403), `transfer_report_stale` (409), `transfer_product_in_use` (409), `transfer_same_tenant` (400), `transfer_decision_invalid` (400). Each gets `errors.<code>` in `en`/`tr` and a `NAMED_ERRORS` entry.
- pgTAP, i18n, definer, commit and command conventions as in Plans 1–3.

## Review Focus

- **A client user without `purchase_order` select (or whose plan lacks the module).** The shared orders page and menu stay hidden, with no error toast or 403 noise. Pinned in Task 2.
- **A shared order line whose client product was deleted.** The line shows the snapshot SKU and name and no broken link. Pinned in Task 2.
- **A copy into a tenant where the SKU or the supplier code exists.** The rehearsal lists the conflict, the real run refuses until it is decided, and `map` reuses the target row. Pinned in Task 6.
- **A copy by a user who lacks one sensitive field's write right in the target.** It is refused with `transfer_field_forbidden` naming the field, in the rehearsal and in the real run, and nothing is written. Pinned in Task 6.
- **A move of a product that a provider's sourcing row (another tenant) points at.** The move succeeds, the provider row keeps its snapshot with `product_id` NULL, and the report reveals nothing about the provider's rows. Pinned in Task 7.

---

### Task 1: App: the client's providers page

**Files:**
- Create:
  - `app/src/api/shared/index.ts`;
  - `app/src/views/pages/ops/provider/Index.vue` (tabs `relationships`, `orders`, `shipments`), `app/src/views/pages/ops/provider/RelationshipCard.vue`;
  - `app/tests/api/shared.test.ts`, `app/tests/views/providerRelationships.test.ts`.
- Modify: `app/src/router/routes/ops.ts` (`ops-providers` path `providers/:tab?`), i18n (`ops.provider.*`; menu "Providers" / TR "Tedarikçi firmalar" **[owner to confirm]**).

**Interfaces:**
- Produces, in `app/src/api/shared/index.ts`: one read-only resource per view, with no write method:
  - `sharedRelationshipApi` (`shared_provider_relationship`, select `*, provider_name`);
  - `sharedPurchaseOrderApi`, `sharedPurchaseOrderLineApi`, `sharedShipmentApi`, `sharedShipmentLineApi`, `sharedShipmentEventApi`, `sharedShipmentPurchaseOrderApi`, `sharedProductSourcingApi`.
  - `SHARED_COLUMNS: Record<string, readonly string[]>` lists each view's columns (Plan 2 Task 7). Every select string is built from it.
- Consumes: `endRelationship(id)` (Plan 3 Task 10).
- Page:
  - One card per relationship: provider name, code, procurement model, status with start and end, and the contract terms. A masked (null) term shows "—".
  - The client owner gets "End relationship", with a confirmation that names decision 13: "Shared history stays visible".
  - The menu shows when `can('read', 'provider_relationship')`.

- [ ] **Step 1: Write the failing tests.**
  - `shared.test.ts`: `it('has no write methods')` (`'create' in sharedPurchaseOrderApi` is false); `it('never selects a provider-only column')` (every `SHARED_COLUMNS` entry is in the generated types of the view, and none is in `['unit_price', 'line_total', 'pi_total', 'supplier_id', 'notes', 'from_party', 'deposit_amount']`).
  - `providerRelationships.test.ts`: `it('shows the provider name and terms')`, `it('shows a dash for a masked term')`, `it('offers ending to the client owner only')`.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint`: PASS.
- [ ] **Step 5: Commit** with `feat(app): the client's providers page`.

### Task 2: App: shared orders, read-only

**Files:**
- Create: `app/src/views/pages/ops/provider/orders/OrderList.vue`, `app/src/views/pages/ops/provider/orders/OrderDetail.vue`, `app/tests/views/sharedOrders.test.ts`.
- Modify: `app/src/router/routes/ops.ts` (`ops-provider-order` path `providers/orders/:id`), `app/src/views/pages/ops/project/tabs/*` (the project's purchase-orders tab also lists `shared_purchase_order` rows where `project_id` is the project), i18n.

**Interfaces:**
- Consumes: `sharedPurchaseOrderApi`, `sharedPurchaseOrderLineApi`, `sharedShipmentPurchaseOrderApi`, `sharedShipmentApi`.
- Detail:
  - Header: code, status, ready date.
  - Lines: position, product, quantity and selling price. The product links to the client's product page when `product_id` is not null; otherwise it shows `product_sku · product_name` as plain text.
  - The order's shipments with ETA and tracking.
  - No edit, delete, document or media actions.

- [ ] **Step 1: Write the failing tests.** `sharedOrders.test.ts`:
  - `it('lists shared orders with code, status and ready date')`;
  - `it('shows the snapshot when the client product is gone')`;
  - `it('has no edit, delete or upload controls')`;
  - `it('hides the page without purchase_order read')` (the route's `meta` ability check hides the menu, and no request is made);
  - `it('shows the selling price as a dash when masked')`.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint`: PASS.
- [ ] **Step 5: Commit** with `feat(app): shared orders for the client`.

### Task 3: App: shared shipments, read-only

**Files:**
- Create: `app/src/views/pages/ops/provider/shipments/ShipmentList.vue`, `app/src/views/pages/ops/provider/shipments/ShipmentDetail.vue`, `app/tests/views/sharedShipments.test.ts`.
- Modify: `app/src/router/routes/ops.ts` (`ops-provider-shipment` path `providers/shipments/:id`), the shipments box in `app/src/views/pages/dashboard/boxes/*` (a client tenant sees the next shared ETAs), `app/src/constants/dashboard.ts`, i18n.

**Interfaces:**
- Consumes: `sharedShipmentApi`, `sharedShipmentLineApi`, `sharedShipmentEventApi`.
- Detail: status, mode, delivery warehouse name, carrier, container and seal, the dates (ETD, ETA, customs, planned delivery, delivered), acceptance, lines (with their order code), and an event timeline (`happened_at`, `step`).

- [ ] **Step 1: Write the failing tests.** `sharedShipments.test.ts`:
  - `it('shows ETA and tracking')`;
  - `it('shows the event timeline without parties or notes')` (asserts the requested select string equals `SHARED_COLUMNS.shared_shipment_event.join(',')`);
  - `it('has no edit controls')`;
  - `dashboardBoxes.test.ts`: `it('shows the next shared ETAs to a client tenant')`.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint`: PASS.
- [ ] **Step 5: Commit** with `feat(app): shared shipments for the client`.

### Task 4: App: shared prices on products; shared orders in incidents and change requests

**Files:**
- Modify:
  - `app/src/views/pages/ops/product/tabs/Sourcing.vue`: for a product of the active tenant, also list `shared_product_sourcing` rows as "Provider's price" (selling price and price-list version);
  - `app/src/views/pages/ops/incident/*`: the entity picker for `purchase_order` and `shipment` also lists shared rows, labelled with the provider name;
  - `app/src/views/pages/ops/change-request/tabs/*`: a new "Order" field, `purchase_order_id` + `purchase_order_tenant_id`, picking an own or a shared order;
  - `app/src/api/incident/index.ts`, `app/src/api/changeRequest/index.ts`;
  - the incident log form: the cost fields are hidden when `cost_amount` comes back masked on a provider-linked incident, with the note `ops.incident.providerCost` ("Managed by the provider").
- Test: `app/tests/views/productSourcing.test.ts`, `incidentForm.test.ts`, `changeRequestForm.test.ts`.

**Interfaces:**
- Consumes: `sharedProductSourcingApi`, `sharedPurchaseOrderApi`, `sharedShipmentApi`.

- [ ] **Step 1: Write the failing tests.**
  - `productSourcing.test.ts`: `it('shows the provider\'s selling price to the client')`.
  - `incidentForm.test.ts`: `it('offers shared orders as the incident entity')` and `it('hides provider-managed cost fields')`.
  - `changeRequestForm.test.ts`: `it('links a shared order and sends purchase_order_tenant_id')`.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint`: PASS.
- [ ] **Step 5: Commit** with `feat(app): provider prices and shared orders in client workflows`.

### Task 5: App: role editor note on shared fields

**Files:**
- Modify: `app/src/views/pages/branch/role/Upsert.vue` and the `SelectFieldPermissions` component (find it with `grep -rl SelectFieldPermissions app/src`). Add `app/src/constants/sharedFields.ts`.
- Test: `app/tests/components/SelectFieldPermissions.test.ts`.

**Interfaces:**
- Produces: `SHARED_FIELDS: Record<string, readonly string[]>`, generated alongside `maskedFields.generated.ts`.
  - `scripts/masked-fields.mjs` gains a second export written to `app/src/@types/sharedFields.generated.ts` from `SELECT … FROM public.field_class WHERE shared`.
  - `scripts/masked-fields.test.mjs` checks both files.
- Editor: for a resource with shared fields, a note: "Rows a provider shares with this company show only these fields: …. You can hide them from this role here; fields outside this list are never shared." (`roles.sharedFieldsNote`). No new toggles: the existing field toggles narrow both own and shared rows.

- [ ] **Step 1: Write the failing tests.**
  - `SelectFieldPermissions.test.ts`: `it('shows the shared-fields note for purchase_order_line')`, `it('lists only shared fields in the note')`.
  - `masked-fields.test.mjs`: `test('sharedFields.generated.ts matches the catalog')`.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test && pnpm test:scripts`: FAIL.
- [ ] **Step 3: Implement.** Run `pnpm dev:supabase-types`.
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm test:scripts && pnpm typecheck && pnpm lint`: PASS.
- [ ] **Step 5: Commit** with `feat(app): role editor explains shared fields`.

### Task 6: Tenant copy: registry, rehearsal and the rights gate

**Files:**
- Create: `supabase/migrations/075_tenant_copy.sql`, `supabase/tests/database/075_tenant_copy.test.sql`.

**Interfaces:**
- Produces, in 075:
  - `private.copy_registry (tbl TEXT PRIMARY KEY, position INT NOT NULL UNIQUE, entity_type public.document_entity, late_columns TEXT[] NOT NULL DEFAULT '{}', user_columns TEXT[] NOT NULL DEFAULT '{}', code_column TEXT)`, with the seven rows in the package order of Global Constraints.
  - `private.copy_collect(source_tenant UUID, product_ids UUID[]) RETURNS VOID`: fills the temp table `pg_temp.copy_rows (tbl TEXT, id UUID, data JSONB)` per the package rules.
  - `private.copy_rights(source_tenant UUID, target_tenant UUID, mode TEXT) RETURNS JSONB`: `{ "missing_tables": [...], "forbidden_fields": [...] }` per the gate.
  - `private.copy_report(source_tenant UUID, target_tenant UUID, mode TEXT) RETURNS JSONB`: `{ counts: {tbl: n}, conflicts: [{ key: '<table>:<source_id>', kind: 'sku'|'gtin'|'code', value, target_id }], in_use: [...], non_members: [...], forbidden_fields: [...], hash }`. The hash is `encode(digest(<canonical report without hash>, 'sha256'), 'hex')`.
  - `public.copy_products(...)` (signature in Global Constraints): SECURITY DEFINER, owner `api_owner`, executable by `authenticated`.
    - It refuses `transfer_same_tenant` when the tenants are equal, and refuses when the caller lacks the rights (`transfer_field_forbidden`, or 42501 for table rights).
    - In this task only `dry_run = TRUE` is implemented; `FALSE` raises `transfer_decision_invalid` until Task 7.
  - `public.transfer` rows are written only by the real run (Task 7).

- [ ] **Step 1: Write the failing test.** `075_tenant_copy.test.sql` with `plan(11)`. Fixtures: `private.share_test_fixtures()`, plus a root tenant `Copy Source` and its branch `Copy Target`, both owned by `test.krn_owner`. The source holds a product with own sourcing (`purchase_price` set), its supplier, a product document and media.
  - `has_function('public', 'copy_products', ARRAY['uuid','uuid','uuid[]','text','jsonb','boolean','text'])`;
  - as the owner, the rehearsal `counts` are `{product:1, product_sourcing:1, supplier:1, document:1, media:1, media_link:1}` (one `is` on the JSONB);
  - with a same-SKU product in the target, the report has one `sku` conflict keyed `product:<id>`;
  - `throws_like` same tenant → `transfer_same_tenant`;
  - a user with `public.transfer` insert in both tenants but without `cost` write in the target (a fixture role) → `throws_like '%transfer_field_forbidden%'`;
  - `t.error_detail` of that call = `public.product_sourcing.landed_cost_eur`, the first sensitive field in sort order lacking the right (compute it in the test with the same query);
  - that user's report via `private.copy_report` lists `forbidden_fields` containing `public.product_sourcing.purchase_price`;
  - a user without `public.transfer` insert in the target → 42501;
  - `koordinator` (no `public.transfer`) → 42501;
  - the rehearsal never reads a provider's sourcing row: with MOESA's sourcing for a THO product in place, a THO-owner rehearsal of that product counts `product_sourcing: 0`;
  - `ok(NOT EXISTS (SELECT 1 FROM public.transfer))`: the rehearsal writes nothing.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Implement**, adapting `transfer_collect`, `transfer_report` and `transfer_check_decisions` from `1a5c995e` to the product root.
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS; add the definer to the allowlist in `064_field_security_cutover.test.sql`.
- [ ] **Step 5: Commit** with `feat(copy): product copy rehearsal with rights in both tenants`.

### Task 7: Tenant copy: copy, move and files

**Files:**
- Modify: `supabase/migrations/075_tenant_copy.sql` (append), `supabase/tests/database/075_tenant_copy.test.sql` (+12).

**Interfaces:**
- Produces:
  - `private.copy_write(transfer_id UUID, tbl TEXT) RETURNS VOID`: the jsonb writer from M21's `transfer_write`, over `copy_rows`, with the id map in `public.transfer.id_map`. It applies the users rule from M21 (`created_by`, `uploaded_by` and `author_id` of non-members become the caller; assignment columns become NULL).
  - `private.copy_apply(transfer_id UUID) RETURNS VOID`: inserts in registry order, then late columns. In `move` mode it then deletes the source rows children-first under the transfer flag, in their own audit transaction (as M21's copy path).
  - `public.copy_products(…, dry_run => FALSE, report_hash)`:
    - it recomputes the report and refuses `transfer_report_stale` on a hash mismatch;
    - it checks that the decisions cover every conflict (`transfer_decision_invalid`);
    - it re-runs the rights gate;
    - in move mode it refuses `transfer_product_in_use` on in-tenant references;
    - it inserts the `public.transfer` row (`product_ids`, `mode`, `report`, `decisions`, `xact_id`, `files_status = 'pending'` when media were copied) and applies.

    It returns `{ transfer_id, id_map, files: [{ from, to }] }`.
  - `private.copy_media_paths(transfer_id UUID) RETURNS TABLE (source_path TEXT, target_path TEXT)` (from M21's `transfer_media_paths`; paths `<tenant_id>/<media_id>/<file>` and `/thumb/thumb.webp`).
  - `public.transfer_check_files(transfer_id UUID) RETURNS api.transfer` (from M21 `045`/`058`): reads `storage.objects` and sets `files_status` (`done` or `partial`, with `missing_files`). The caller must hold `public.transfer` select in the target.

- [ ] **Step 1: Write the failing tests** (+12):
  - a copy with no conflicts leaves the source unchanged and creates the target rows (two `is` on counts);
  - the copied sourcing row keeps `purchase_price` in the target;
  - `id_map` has one entry per copied row;
  - a stale hash → `transfer_report_stale`;
  - a missing SKU decision → `transfer_decision_invalid`;
  - `map` on the SKU conflict copies the documents onto the target's existing product and copies no product;
  - `new_code` with `sku` creates the product with the new SKU;
  - a move deletes the source product and its own sourcing;
  - a move of a product used by an own PO line in the source → `transfer_product_in_use`;
  - a move of a THO product that MOESA's sourcing points at succeeds, and MOESA's row has `product_id` NULL and its snapshot kept (checked as postgres);
  - `transfer_check_files` sets `partial` with a missing object and `done` after the object row is inserted.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement**, adapting `transfer_build_map`, `transfer_write`, `transfer_delete_source`, `transfer_apply_copy` and `transfer_check_files` from `1a5c995e`.
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS.
- [ ] **Step 5: Commit** with `feat(copy): copy and move products between tenants`.

### Task 8: App: the copy wizard

**Files:**
- Create in `app/src/views/pages/ops/copy/`: `CopyWizard.vue`, `TargetStep.vue`, `ReportStep.vue`, `ConflictDecision.vue`, `ResultStep.vue`, `useCopyWizard.ts`. Adapt them from `git show 1a5c995e:app/src/views/pages/ops/transfer/<file>` without the customer step.
- Create: `app/src/api/copy/index.ts`, `app/src/components/service-components/transfer-files-notice/TransferFilesNotice.vue` (restored from `1a5c995e` and adapted), `app/tests/views/copyWizard.test.ts`, `app/tests/api/copy.test.ts`.
- Modify:
  - `app/src/router/routes/ops.ts` (`ops-copy` path `copy`, opened from the product list's bulk action "Copy to another tenant" with `?products=<ids>`);
  - `app/src/views/pages/ops/product/Index.vue`;
  - i18n (`ops.copy.*`; the plural `ops.copy.files.partial` uses `|`; TR **[owner to confirm]**).

**Interfaces:**
- Produces: `copyProducts(args: { source: string; target: string; productIds: string[]; mode: 'copy' | 'move'; decisions: Record<string, CopyDecision>; dryRun: boolean; reportHash?: string })`, `copyFiles(files: { from: string; to: string }[]): Promise<string[]>` (Storage copy, returns the failures), and `checkFiles(transferId: string)`.
  - Targets offered: the user's tenants (`authStore.branches`) other than the source.
  - The report step shows counts, conflicts with decisions, `forbidden_fields` (blocking, naming each field with its label), `in_use` (blocking for a move) and non-members.

- [ ] **Step 1: Write the failing tests.**
  - `copyWizard.test.ts`: `it('rehearses, then runs with the report hash')`, `it('blocks on forbidden fields and names them')`, `it('requires a decision per conflict')`, `it('copies files after the run and checks them')`, `it('offers only the user\'s other tenants as targets')`.
  - `copy.test.ts`: `it('posts copy_products with the exact argument names')`.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint && pnpm build`: PASS.
- [ ] **Step 5: Commit** with `feat(app): copy products between tenants`.

### Task 9: HTTP tests for the copy tool and the story's copy step

**Files:**
- Create: `supabase/functions/http-tests/copy_http_test.ts`.
- Modify:
  - `supabase/seed_story.sql`: a new Step 10, "`kernhaus@` (owner of Kernhaus Living GmbH) first creates the branch `Kernhaus Living AT` with `public.create_branch`, then copies KRN-VASE-01 with its media and documents to the branch". The step uploads no files: `scripts/seed-story.mjs` copies the media object to the branch folder after the SQL, then the check calls `transfer_check_files`;
  - `supabase/seed_story.check.sql` (`copy.vase_in_branch`, `copy.files_done`);
  - `scripts/seed-story.mjs` and `scripts/seed-story.test.mjs`.

- [ ] **Step 1: Write the failing tests** (`Deno.test` names):
  - `a client owner cannot copy from the provider tenant` (`thometzki`, source MOESA LTD → 403 or 42501);
  - `a provider coordinator cannot copy (no transfer right)`;
  - `field rights in the target are required` (403 `transfer_field_forbidden`, the body names the field and contains no value from the source);
  - `the rehearsal reveals no provider rows` (`thometzki` rehearses a THO product that MOESA sources: the body contains no `purchase_price`, no MOESA id and no `product_sourcing` count above 0).

  In `seed-story.test.mjs`: `test('the copy step copies the vase media to the branch folder')`.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `deno task test:http`, `cd app && pnpm dev:supabase-reset && pnpm test:scripts`: PASS.
- [ ] **Step 5: Commit** with `test(copy): HTTP checks and the story's copy step`.

### Task 10: Browser walk and the final gate

**Files:**
- Modify: `supabase/README.md` (production checklist for the whole series: `db push` of 066–075, the `api` exposed schema unchanged, deploy `client-invitation`, Auth URL, `self_signup` off), `supabase/CHANGELOG.md`, `docs/superpowers/specs/2026-11-18-customer-as-tenant-design.md` (an "Implemented" line linking the four plans).

- [ ] **Step 1: Run every suite.**
  - `cd app && pnpm dev:supabase-reset && pnpm test:db && pnpm test && pnpm typecheck && pnpm lint && pnpm build && pnpm test:scripts && pnpm perf:fields`;
  - `cd supabase/functions && deno task check && deno task test && deno task test:http`;
  - the Plan 1 grep gate and the Plan 2 `MOESA` grep.

  Expected: all PASS, with no output from the greps.
- [ ] **Step 2: Walk** with `pnpm dev` (and `supabase functions serve`), using the Chrome DevTools tools. Every user's password is `Demo1234!`. Each line is checked by looking at the page and its network responses:
  1. **`koordinator@`** (MOESA staff).
     - Scope MOESA LTD + THOMETZKI: the product list shows THO's products with MOESA's purchase and selling price side by side.
     - A new PO for client THO picks THO's project and products, and its code is `PO-THO-…`.
     - The Relationships page lists THO, Kernhaus, Clearstar (ended), Leafline and Paxton.
     - Creating an invitation shows the link once.
  2. **`thometzki@`** (client owner, provider procures).
     - Providers shows MOESA LTD with the contract terms; Orders shows the shared POs with selling prices and no purchase price, payments or supplier.
     - A shipment shows ETA and tracking.
     - An incident on a shared PO hides the cost fields.
     - The network tab shows only `shared_*` reads for provider rows.
     - Manually requesting `/rest/v1/shared_purchase_order_line?select=unit_price` in the console gives 400.
  3. **`narrow@`** (client user, limited role): shared orders without selling prices; no suppliers, payments or audit of provider rows.
  4. **`kernhaus@`** (client-procures owner): its own suppliers, costs and POs fully visible; Providers shows MOESA LTD with model "client procures" and no shared orders. The copy wizard copies a product to `Kernhaus Living AT`.
  5. **The invitation link** from the story (`/auth/invitation#t=5eed0012…`), opened in a private window: the plan step explains the plans, and acceptance creates `Nordwind Haushalt GmbH` with `koordinator@` as a member.

  Record the checklist with pass or fail per line in the PR description; screenshots are not committed.
- [ ] **Step 3: Fix** any walk failure in the owning plan's files, with its own test first, and re-run Step 1.
- [ ] **Step 4: Commit** with `docs(tenancy): customer = tenant complete`.
