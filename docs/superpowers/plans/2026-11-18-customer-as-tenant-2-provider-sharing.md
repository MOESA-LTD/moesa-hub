# Customer = Tenant, Plan 2: Provider Relationship, Procurement Placement and Sharing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A provider tenant procures for a client tenant under a provider relationship. The provider's orders, lines, shipments and sourcing stay one record in the provider tenant and are shared read-only with the client, which sees a fixed client-visible field set. Nothing provider-only reaches the client tenant by any path, owner included.

**Architecture:**
- **The relationship.** `public.provider_relationship` (provider = `tenant_id`, client = `client_tenant_id`, unique pair) holds the procurement model, the contract terms and the provider's internal fields.
- **Shared rows.** A provider row shared with a client carries `client_tenant_id`, with a composite FK `(tenant_id, client_tenant_id)` to the relationship pair. NULL means an own row. Cross-tenant references (to the client's product, project and warehouse) stay composite FKs `(x_id, x_tenant_id)`. Each is pinned by a CHECK to the row's own tenant or its client, and guarded by one trigger predicate, `private.check_cross_tenant_link`.
- **Read path.** Clients read shared rows only through generated read-only views `api.shared_<table>`. Their owner is `api_share_owner`: NOLOGIN, NOBYPASSRLS and not a member of `authenticated`. Its only access to the base rows is a per-table RLS policy keyed on `private.shared_client_tenants()`.
  - The view's columns are exactly the catalog's client-visible set (`field_class.shared`). Provider-only columns do not exist in the view, which is how "never widen" is enforced structurally.
  - The client's own roles narrow the sensitive shared columns through the existing per-tenant field rights, evaluated at the client tenant.
- **Client rows.** Incidents and change requests that refer to a provider-procured order carry `provider_tenant_id`. Their cost fields (`field_class.provider_only`) are masked, write-guarded and audit-masked by the caller's rights in the provider tenant, never by the client tenant's rights or ownership.

**Tech Stack:** Supabase (Postgres 15, PostgREST 12, pgTAP), Deno HTTP attack suite, Vue 3.5 + PrimeVue 4 + TanStack Query 5 + zod, vitest 3.

**Spec:** `docs/superpowers/specs/2026-11-18-customer-as-tenant-design.md`. Kept machinery: `docs/superpowers/specs/2026-11-08-field-permissions-design.md` (A-def views, R4, R10, S1, the write guard 051, audit masking 059).

**Series:** Plan 2 of 4. It requires Plan 1 to be merged on the branch. Plan 3 adds invitations, which are the only way users create relationships; until then relationships come from `private.create_provider_relationship` (seeds and tests).

## Global Constraints

- Owner decision 9: "When MOESA procures, the customer sees its own order relationally… This is not a copy that needs syncing."
- Owner decision 10: "Müşteri tenant'ı okumaması gereken alanları API istekleriyle dahi okuyamasın." This holds for the tenant owner too.
- Owner decision 12: in a client-procures tenant the client owns and sees all of its procurement data. Provider-only masking applies only to provider-procured data.
- Owner decision 13: after the relationship ends, the client keeps seeing the shared history with the client-visible field set. Rows stay where they were created.
- Owner decision 15: no deposit, payment or balance rows are visible to the client.
- Spec, client-visible set: "status, dates, quantities, products, the selling price per line, shipment ETA and tracking". Never visible: "Purchase price, landed cost, supplier identity and contact, supplier terms and provider-internal notes".
- Spec, Calls made:
  - "Contract terms are readable by the client… Provider-internal notes and the restricted Drive link are not."
  - "Shared rows are read-only for the client in this round."
  - "Provider users reach client data only through their invitation… The relationship grants no extra read."
  - "Provider rows that point at client products keep a snapshot of the product's identity (SKU and name)… The cross-tenant link does not block the client's delete."
  - "Incidents and change requests stay in the client tenant… Their cost amount and cost payer are provider-only fields when the order is provider-procured."
  - "Switching a customer from provider-procures to client-procures… moves nothing."
- Spec, Anti-goals:
  - No sync.
  - No owner bypass on shared rows.
  - No hidden coupling to MOESA: no function body, app source or copy may contain `MOESA`. Pinned in Task 2.
- **Migration strategy (this plan).**
  - Removal of product sourcing columns edits `019_products.sql`, `020_products_import.sql`, `039_company_price_column.sql` and `058_api_derived.sql` in place: the product never had them.
  - Every new structure goes in new migrations: `067_provider_relationship.sql`, `068_share_core.sql`, `069_product_sourcing.sql`, `070_procurement_placement.sql`, `071_provider_only_fields.sql`, `072_shared_views.sql`.
  - A function whose latest definition must change because of a new structure is redefined in the new migration with `CREATE OR REPLACE`, its body copied from the latest definition (`grep -l "FUNCTION <schema>.<name> (" supabase/migrations/*.sql | tail -1`), and its grants kept.
  - This reads as the feature's own history, while the product never carried cost.
- **Names fixed by this plan** (later plans use them):
  - enum `public.procurement_model` = `provider`, `client`; enum `public.relationship_status` = `active`, `ended`.
  - `public.provider_relationship`;
  - `public.product_sourcing`;
  - the column `client_tenant_id` on shared provider rows, and `provider_tenant_id` on client rows;
  - role `api_share_owner`;
  - `field_class.shared` and `field_class.provider_only`;
  - views `api.shared_provider_relationship`, `api.shared_purchase_order`, `api.shared_purchase_order_line`, `api.shared_shipment`, `api.shared_shipment_purchase_order`, `api.shared_shipment_line`, `api.shared_shipment_event`, `api.shared_product_sourcing`;
  - module `provider` (permissions on `public.provider_relationship`; Plan 3 adds `public.client_invitation`).
- **Where the cross-tenant guard lives.** The spec asks for links guarded "in RLS and in triggers".
  - Writes: the BEFORE trigger predicate below, plus the composite FK to the relationship pair. An RLS policy cannot see the target tenant without a per-row subquery.
  - Reads: RLS, through the `share_read` policy for `api_share_owner`.
- **Errors** (new codes, each with `errors.<code>` in `en`/`tr` and a `NAMED_ERRORS` entry):

  | code | SQLSTATE | status |
  |---|---|---|
  | `cross_tenant_link_forbidden` | 42501 | 403 |
  | `shipment_client_mismatch` | 23514 | 400 |
  | `client_link_immutable` | 23514 | 400 |
  | `provider_link_locked` | 23514 | 400 |
  | `relationship_not_found` | P0001 | 404 |
  | `relationship_code_taken` | 23505 | 409 |

  Refusals that could reveal another tenant's rows use `cross_tenant_link_forbidden` for every cause.
- pgTAP, i18n, commit and command conventions as in Plan 1's Global Constraints. Seeded actors after this plan:
  - `baris@`: owner of MOESA LTD and THO-member management;
  - `akif@`: management in MOESA LTD, Europe, THO and Kernhaus;
  - `koordinator@`: coordinator in MOESA LTD and THO;
  - `thometzki@`: owner of THO;
  - `portal@`: THO `viewer`;
  - `kernhaus@`: owner of Kernhaus Living GmbH.
- Definers: `SET search_path = ''`, schema-qualified names, `REVOKE ALL … FROM PUBLIC, anon`, owner `api_owner` for user-callable writes (never `postgres`). Every new definer executable by `authenticated` is added to the allowlist in `064_field_security_cutover.test.sql`.

## Review Focus

- **A consolidated shipment that would mix orders of two clients, or own and shared orders.** It is refused (`shipment_client_mismatch`): otherwise a client would see another client's lines. Pinned in Task 4.
- **The relationship ends while orders are open.** The client still reads the history. The provider can still update status and dates on existing rows, but cannot create new client-linked rows or re-point links. Pinned in Tasks 1 and 4.
- **The procurement model is switched from provider to client.** No new provider-procured order or sourcing row can be created for that client; existing shared rows stay shared and read-only. Pinned in Task 4.
- **The client deletes a product, or its whole tenant, that provider rows point at.** Provider sourcing rows and PO lines keep `product_sku`/`product_name` with `product_id` NULL, and nothing in the provider tenant errors. Pinned in Tasks 3 and 4.
- **A provider staff member is removed from the client tenant.** They can no longer link to that client's products, projects or warehouses, and get the same error whether or not the id exists. Existing provider rows are untouched. Pinned in Task 1 (predicate) and Task 10 (HTTP).

---

### Task 1: The provider relationship and the cross-tenant link predicate

**Files:**
- Create: `supabase/migrations/067_provider_relationship.sql`, `supabase/tests/database/067_provider_relationship.test.sql`.
- Modify:
  - `supabase/migrations/049_field_catalog.sql` gets no edit; the `field_class` rows for the new table go in 067.
  - `supabase/seed.sql`: the relationship MOESA LTD → THO, code `THO`, `procurement_model = 'provider'`, with the old THO contract terms.
  - `supabase/tests/database/099_seed.test.sql` (+1: the seeded relationship exists and is active).

**Interfaces:**
- Produces, in 067:
  - Enums `public.procurement_model` and `public.relationship_status`.
  - `public.provider_relationship`, with:
    - keys: `id UUID PK`, `tenant_id UUID NOT NULL` (provider) `REFERENCES tenant ON DELETE CASCADE`, `client_tenant_id UUID NOT NULL REFERENCES tenant ON DELETE CASCADE`, `code CHAR(3) NOT NULL CHECK (code ~ '^[A-Z]{3}$')`;
    - model and state: `procurement_model public.procurement_model NOT NULL`, `status public.relationship_status NOT NULL DEFAULT 'active'`, `started_at TIMESTAMPTZ NOT NULL DEFAULT now()`, `ended_at TIMESTAMPTZ`;
    - contract terms: `commercial_model public.commercial_model`, `packages TEXT[] NOT NULL DEFAULT '{}'`, `start_on DATE`, `contract_accepted_on DATE`, `contract_document_id UUID`, `deposit_rate NUMERIC(5,2)`, `extra_cost_rule TEXT`, `eu_responsible_person TEXT`;
    - provider-internal: `restricted_drive_url TEXT`, `notes TEXT`;
    - `created_at`, `updated_at`;
    - constraints: `UNIQUE (id, tenant_id)`, `UNIQUE (tenant_id, client_tenant_id)`, `UNIQUE (tenant_id, code)` as `provider_relationship_code_key`, `CHECK (tenant_id <> client_tenant_id)`, `CHECK ((status = 'ended') = (ended_at IS NOT NULL))`, and `FOREIGN KEY (contract_document_id, tenant_id) REFERENCES document (id, tenant_id) ON DELETE RESTRICT DEFERRABLE`.
  - `field_class` rows:
    - open: `code`, `procurement_model`, `status`, `started_at`, `ended_at`, `commercial_model`, `packages`, `eu_responsible_person`;
    - sensitive/`contract`: `start_on`, `contract_accepted_on`, `contract_document_id`, `deposit_rate`, `extra_cost_rule`;
    - sensitive/`internal_note`: `restricted_drive_url`, `notes`;
    - system: the rest.
  - `private.enable_tenant_level_security('provider_relationship')`, `private.audit_enable(...)`, `private.enable_field_security('provider_relationship')`.
  - Module `provider` (`is_core TRUE`, position 135) and permissions `public.provider_relationship` select and update, with no insert or delete permission. The owner role gets both. `private.create_ops_roles` gives management select and update and coordinator select (redefined in 067 from 066).
  - Guard `private.provider_relationship_guard()`, BEFORE INSERT OR UPDATE, SECURITY DEFINER:
    - `tenant_id`, `client_tenant_id`, `code` and `started_at` are immutable;
    - on INSERT, `private.server_write()` must be on (users never insert), the client must be a root tenant (`parent_id IS NULL`), and the client must belong to another company (`(SELECT company_id FROM private.entitlements(ARRAY[client])) <> (… provider …)`);
    - `status` and `ended_at` change only under `moesa.relationship_end = '1'` (set by the end RPC) or a server write.
  - `private.create_provider_relationship(p_provider UUID, p_client UUID, p_code TEXT, p_model public.procurement_model, p_terms JSONB DEFAULT '{}') RETURNS UUID`, SECURITY DEFINER, not executable by `authenticated`. It inserts under `private.begin_server_write()`/`end_server_write()`; the terms keys are the contract-term columns above. When an ended relationship already exists for the pair, it reactivates it (`status = 'active'`, `ended_at = NULL`, new `procurement_model`) and returns its id.
  - `public.end_provider_relationship(p_relationship UUID) RETURNS VOID`, SECURITY DEFINER, owner `api_owner`, executable by `authenticated`. The caller must hold `public.provider_relationship` update in the provider tenant (`private.tenants_permitting(auth.uid(), ARRAY[r.tenant_id], 'public.provider_relationship', 'update')`) or own the client tenant (`r.client_tenant_id = ANY (private.owned_tenants(auth.uid()))`). Otherwise it raises `relationship_not_found` (404, the same as a missing id). It sets `status = 'ended'` and `ended_at = now()`; on an already-ended row it does nothing.
  - **The cross-tenant link predicate** (security-critical; this body is binding):

```sql
-- One rule for every provider row that points into its client tenant. p_tenant is the row's tenant,
-- p_client its client_tenant_id (NULL: an own row; the CHECKs keep its links in p_tenant).
-- p_target_tenant is the linked row's tenant, NULL when the link is cleared.
-- p_target_resource is the resource whose select permission the caller needs there.
-- p_procurement: the row is procurement (order, line, shipment, sourcing), which needs a
-- provider-procures relationship. Called only when the row is new or its client or a link changed.
-- Every refusal is the same error, raised before the FK check runs (BEFORE trigger),
-- so it reveals nothing about ids in another tenant.
CREATE OR REPLACE FUNCTION private.check_cross_tenant_link (p_tenant UUID, p_client UUID, p_target_tenant UUID,
    p_target_resource TEXT, p_procurement BOOLEAN) RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' AS $$
DECLARE
    rel public.provider_relationship;
BEGIN
    IF p_client IS NULL THEN
        RETURN;
    END IF;
    SELECT * INTO rel FROM public.provider_relationship r WHERE r.tenant_id = p_tenant AND r.client_tenant_id = p_client;
    IF NOT FOUND OR rel.status <> 'active' OR (p_procurement AND rel.procurement_model <> 'provider') THEN
        PERFORM private.raise_cross_tenant_link();
    END IF;
    IF private.server_write() OR private.field_guard_bypassed() THEN
        RETURN;
    END IF;
    -- The relationship grants no read: the caller must see the client's rows by their own membership.
    IF p_target_tenant IS NOT NULL AND cardinality(private.tenants_permitting(auth.uid(), ARRAY[p_target_tenant], p_target_resource, 'select')) = 0 THEN
        PERFORM private.raise_cross_tenant_link();
    END IF;
END;
$$;
```

  - `private.raise_cross_tenant_link() RETURNS VOID` raises 42501 with message `cross_tenant_link_forbidden`.
  - `private.share_test_fixtures() RETURNS JSONB` (tests only, revoked from everyone but postgres). It runs `private.field_test_fixtures()`, then sets:
    - `test.tho` (the seeded THO tenant), `test.thometzki`, `test.portal`, `test.rel_tho`;
    - `test.krn_t`: a fixture root tenant `KRN Fixture` owned by `test.krn_owner` (a fixture user), with relationship `test.rel_krn` (code `KRF`, model `client`);
    - `test.nova` (the unrelated tenant);
    - `test.narrow`: the fixture user `narrow-fixture@moesa-panel.test`, a member of THO with role `narrow_fixture`. The role has select on `purchase_order`, `purchase_order_line`, `shipment`, `shipment_line`, `shipment_event`, `shipment_purchase_order` and `provider_relationship`, and no field rights;
    - `test.viewer_role`: the id of THO's `viewer` role.

- [ ] **Step 1: Write the failing test.** `067_provider_relationship.test.sql` with `plan(16)`:

```sql
SELECT private.share_test_fixtures(); SELECT private.create_test_helpers();
SELECT has_table('public', 'provider_relationship');
SELECT col_is_unique('public', 'provider_relationship', ARRAY['tenant_id', 'client_tenant_id']);
SELECT is((SELECT status::TEXT FROM public.provider_relationship WHERE id = current_setting('test.rel_tho')::UUID), 'active', 'seeded THO relationship is active');
-- users never insert
SELECT private.impersonate(current_setting('test.baris')::UUID, current_setting('test.moesa')::UUID);
SELECT throws_ok($$ INSERT INTO api.provider_relationship (client_tenant_id, code, procurement_model) VALUES (current_setting('test.nova')::UUID, 'NOV', 'provider') $$, '42501');
-- the client is a root of another company
RESET ROLE; SELECT private.unimpersonate();
SELECT throws_like($$ SELECT private.create_provider_relationship(current_setting('test.moesa')::UUID, current_setting('test.europe')::UUID, 'EUR', 'provider') $$, '%relationship_client_invalid%', 'a branch of the provider cannot be a client');
SELECT throws_ok($$ SELECT private.create_provider_relationship(current_setting('test.moesa')::UUID, current_setting('test.nova')::UUID, 'THO', 'provider') $$, '23505', NULL, 'code unique per provider');
-- immutable keys
SELECT throws_like($$ UPDATE public.provider_relationship SET client_tenant_id = current_setting('test.nova')::UUID WHERE id = current_setting('test.rel_tho')::UUID $$, '%relationship_immutable%');
-- end: provider management or client owner; others get 404
SELECT private.impersonate(current_setting('test.portal')::UUID, current_setting('test.tho')::UUID);
SELECT throws_like($$ SELECT public.end_provider_relationship(current_setting('test.rel_tho')::UUID) $$, '%relationship_not_found%', 'a client viewer cannot end it');
RESET ROLE; SELECT private.impersonate(current_setting('test.thometzki')::UUID, current_setting('test.tho')::UUID);
SELECT lives_ok($$ SELECT public.end_provider_relationship(current_setting('test.rel_tho')::UUID) $$, 'the client owner ends it');
RESET ROLE; SELECT private.unimpersonate();
SELECT is((SELECT status::TEXT FROM public.provider_relationship WHERE id = current_setting('test.rel_tho')::UUID), 'ended');
SELECT ok((SELECT ended_at IS NOT NULL FROM public.provider_relationship WHERE id = current_setting('test.rel_tho')::UUID), 'ended_at set');
-- predicate
SELECT throws_like($$ SELECT private.check_cross_tenant_link(current_setting('test.moesa')::UUID, current_setting('test.tho')::UUID, current_setting('test.tho')::UUID, 'public.product', TRUE) $$, '%cross_tenant_link_forbidden%', 'ended relationship: no new links');
SELECT lives_ok($$ SELECT private.create_provider_relationship(current_setting('test.moesa')::UUID, current_setting('test.tho')::UUID, 'THO', 'provider') $$, 'reactivation by the server');
SELECT throws_like($$ SELECT private.check_cross_tenant_link(current_setting('test.moesa')::UUID, current_setting('test.nova')::UUID, current_setting('test.nova')::UUID, 'public.product', FALSE) $$, '%cross_tenant_link_forbidden%', 'no relationship: refused');
-- a provider user who is not a member of the client is refused, a member passes
SELECT private.impersonate(current_setting('test.elif')::UUID, current_setting('test.moesa')::UUID);
SELECT throws_like($$ SELECT private.check_cross_tenant_link(current_setting('test.moesa')::UUID, current_setting('test.tho')::UUID, current_setting('test.tho')::UUID, 'public.product', TRUE) $$, '%cross_tenant_link_forbidden%', 'not a member of the client');
RESET ROLE; SELECT private.impersonate(current_setting('test.koordinator')::UUID, current_setting('test.moesa')::UUID);
SELECT lives_ok($$ SELECT private.check_cross_tenant_link(current_setting('test.moesa')::UUID, current_setting('test.tho')::UUID, current_setting('test.tho')::UUID, 'public.product', TRUE) $$, 'a member of the client passes');
```

(`test.baris` and `test.koordinator` come from the fixtures; add `test.baris` to `share_test_fixtures` if `field_test_fixtures` lacks it. `elif` is not a member of THO.)
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Implement 067 and the seed.**
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS, drift included.
- [ ] **Step 5: Commit** with `feat(tenancy): provider relationship and the cross-tenant link rule`.

### Task 2: Share core: owner role, catalog flags, rights and the view generator

**Files:**
- Create: `supabase/migrations/068_share_core.sql`, `supabase/tests/database/068_share_core.test.sql`.
- Modify: none of the earlier migrations. `api_view_drift` is redefined here (latest is 059).

**Interfaces:**
- Produces:
  - Role `api_share_owner` (NOLOGIN NOBYPASSRLS, never granted `authenticated`), with USAGE on schema `api`.
  - `public.field_class` gains `shared BOOLEAN NOT NULL DEFAULT FALSE` (the field is in the client-visible set of its table) and `provider_only BOOLEAN NOT NULL DEFAULT FALSE` (on a row with `provider_tenant_id`, the field is read and written only with the provider tenant's right).
  - `private.shared_client_tenants(p_resource TEXT) RETURNS UUID[]`, STABLE SECURITY DEFINER, executable by `authenticated` and `api_share_owner`. **The sharing predicate** (binding):

```sql
-- The client tenants whose shared rows of p_resource the caller reads: the request's tenants where
-- the caller holds p_resource select (live membership or ownership, plan entitlement:
-- permitted_tenants) and that are the client of some relationship (active or ended).
-- A forged x-tenant-ids cannot add a tenant: tenant_scope intersects it with allowed_tenant.
CREATE OR REPLACE FUNCTION private.shared_client_tenants (p_resource TEXT) RETURNS UUID[] LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = '' AS $$
DECLARE
    clients UUID[];
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN '{}';
    END IF;
    clients := private.permitted_tenants(p_resource, 'select');
    RETURN ARRAY(
        SELECT DISTINCT r.client_tenant_id FROM public.provider_relationship r WHERE r.client_tenant_id = ANY (clients)
    );
END;
$$;
```

  - `private.provider_read_rights(p_resource TEXT, p_fields TEXT[]) RETURNS private.field_read_right[]`, STABLE SECURITY DEFINER. Element i has `readable_all = FALSE` and `ids = nullif(private.field_tenants(auth.uid(), private.allowed_tenant(), p_resource, p_fields[i], FALSE), '{}')`: the tenants, among all the caller may use and **not** limited to the request scope, where the caller holds the read right.
  - `private.provider_write_allowed(p_resource TEXT, p_field TEXT, p_provider UUID) RETURNS BOOLEAN`: `p_provider = ANY (private.field_tenants(auth.uid(), ARRAY[p_provider], p_resource, p_field, TRUE))`.
  - `private.share_view_query(p_table TEXT) RETURNS TEXT`. The query is `SELECT <cols> FROM public.<t> t CROSS JOIN (WITH r AS MATERIALIZED (SELECT private.shared_client_tenants('public.<t>') AS s, private.field_read_rights('public.<t>', '{<sensitive shared fields>}') AS x) SELECT (SELECT r.s FROM r) AS s, (SELECT (r.x[i]).readable_all FROM r) AS a<n>, (SELECT (r.x[i]).ids FROM r) AS t<n> … OFFSET 0) m WHERE t.client_tenant_id = ANY (m.s)`.
    - `<cols>` are the `field_class.shared` columns in attnum order.
    - A sensitive one is `CASE WHEN m.a<n> OR t.client_tenant_id = ANY (m.t<n>) THEN t.<f> END AS <f>`: the right is evaluated at the client tenant, so the client's roles narrow it.
    - Any other is `t.<f>`.
  - `private.enable_share(p_table TEXT) RETURNS VOID`, SECURITY DEFINER. It:
    - creates `api.shared_<p_table>` from `share_view_query` (`security_invoker = false`) and sets its owner to `api_share_owner`;
    - `REVOKE ALL … FROM PUBLIC, anon, authenticated`, then `GRANT SELECT … TO authenticated`;
    - `GRANT SELECT ON public.<p_table> TO api_share_owner`;
    - `CREATE POLICY share_read ON public.<p_table> AS PERMISSIVE FOR SELECT TO api_share_owner USING (client_tenant_id = ANY ((SELECT private.shared_client_tenants('public.<p_table>'))::UUID[]))`;
    - creates the index `idx_<p_table>_client ON public.<p_table> (client_tenant_id) WHERE client_tenant_id IS NOT NULL` if missing;
    - adds no triggers.

    It raises `field_security_unsupported` when the table lacks `client_tenant_id` or when a shared field is in the groups `cost`, `supplier_identity`, `supplier_contact`, `supplier_terms`, `finance` or `internal_note`.
  - `private.api_view_drift()` (redefined) also reports, for every `api.shared_*` view: owner ≠ `api_share_owner`; definition ≠ `share_view_query`; any privilege for `authenticated` other than SELECT; any trigger; a missing or altered `share_read` policy; and `api_share_owner` membership in `authenticated` or `rolbypassrls`.
  - `api_column_expr` and `api_view_from` (redefined from 059) handle `provider_only`. For such a field on a table with `provider_tenant_id`, the expression is `CASE WHEN t.provider_tenant_id IS NULL THEN <the 059 expression> WHEN t.provider_tenant_id = ANY (m.p<n>) THEN t.<f> END AS <f>`, where `m.p<n>` is `(SELECT (r.y[i]).ids FROM r)` and `y = private.provider_read_rights('public.<t>', '{<provider_only fields>}')` sits in the same materialized CTE (one call per view).
  - `private.enable_field_write_guard` (redefined from 051) adds a rule for provider-only fields. For a provider-only field whose value changes (INSERT with a non-null value, or UPDATE `IS DISTINCT FROM`) on a row where `coalesce(NEW.provider_tenant_id, OLD.provider_tenant_id)` is not null, the check is `private.provider_write_allowed(resource, field, that provider)` **instead of** the per-tenant write right. It refuses with the existing `field_write_forbidden` naming the field.
  - `private.mask_audit_data` (redefined from 059) masks a provider-only key as `{"masked": true}` when the audited row's `provider_tenant_id` is not null and is not in the caller's provider-read tenants for that field. Those tenants come from a new once-per-query map, `private.provider_rights_map() RETURNS JSONB` (`{"public.incident_log": {"cost_amount": [tenant ids]}, …}`), which the audit view passes as an extra argument (`p_provider JSONB`). `api.audit_log`/`api.audit_transaction` are regenerated accordingly.

- [ ] **Step 1: Write the failing test.** `068_share_core.test.sql` with `plan(12)`:

```sql
SELECT private.share_test_fixtures(); SELECT private.create_test_helpers();
SELECT ok(NOT pg_has_role('api_share_owner', 'authenticated', 'MEMBER'), 'share owner is not authenticated');
SELECT ok(NOT (SELECT rolbypassrls OR rolcanlogin FROM pg_roles WHERE rolname = 'api_share_owner'), 'NOBYPASSRLS NOLOGIN');
SELECT has_column('public', 'field_class', 'shared');
SELECT has_column('public', 'field_class', 'provider_only');
-- predicate: the client owner gets THO; a forged header naming the provider adds nothing
SELECT private.impersonate_scope(current_setting('test.thometzki')::UUID, current_setting('test.tho')::UUID,
   ARRAY[current_setting('test.tho')::UUID, current_setting('test.moesa')::UUID]);
SELECT is(private.shared_client_tenants('public.purchase_order'), ARRAY[current_setting('test.tho')::UUID], 'only the client tenant, forged provider ignored');
RESET ROLE; SELECT private.impersonate(current_setting('test.portal')::UUID, current_setting('test.tho')::UUID);
SELECT is(private.shared_client_tenants('public.purchase_order_payment'), '{}'::UUID[], 'no table permission, no share');
RESET ROLE; SELECT private.unimpersonate();
SELECT is(private.shared_client_tenants('public.purchase_order'), '{}'::UUID[], 'no caller, nothing');
-- generator refuses a forbidden group
SELECT t.definer_exec($$ UPDATE public.field_class SET shared = TRUE WHERE resource_name = 'public.purchase_order_line' AND field = 'unit_price' $$);
SELECT throws_like($$ SELECT private.enable_share('purchase_order_line') $$, '%field_security_unsupported%', 'cost can never be shared');
SELECT t.definer_exec($$ UPDATE public.field_class SET shared = FALSE WHERE resource_name = 'public.purchase_order_line' AND field = 'unit_price' $$);
-- provider rights ignore the request scope but not membership
SELECT private.impersonate(current_setting('test.koordinator')::UUID, current_setting('test.tho')::UUID);
SELECT ok(current_setting('test.moesa')::UUID = ANY ((private.provider_read_rights('public.incident_log', ARRAY['cost_amount']))[1].ids), 'provider right counts outside the scope');
RESET ROLE; SELECT private.impersonate(current_setting('test.thometzki')::UUID, current_setting('test.tho')::UUID);
SELECT ok(NOT (current_setting('test.moesa')::UUID = ANY (coalesce((private.provider_read_rights('public.incident_log', ARRAY['cost_amount']))[1].ids, '{}'))), 'the client owner holds no provider right');
SELECT ok(NOT private.provider_write_allowed('public.incident_log', 'cost_amount', current_setting('test.moesa')::UUID), 'nor a provider write right');
RESET ROLE; SELECT private.unimpersonate();
SELECT is_empty($$ SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public','private','api') AND p.proname NOT IN ('field_test_fixtures', 'share_test_fixtures')
     AND pg_get_functiondef(p.oid) LIKE '%MOESA%' $$, 'no function names the operating company');
```

(`provider_read_rights` reads the right whether or not the field is flagged provider-only, so these assertions hold before Task 6 sets the flag. The fixture's `koordinator` holds `finance` read in MOESA LTD and the coordinator profile has no `finance` write. `thometzki` is a member of THO only.)
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Implement 068.**
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS, and `053_api_schema.test.sql`'s drift assertions are still empty.
- [ ] **Step 5: Commit** with `feat(security): share owner, client-visible catalog and the share view generator`.

### Task 3: Product sourcing in the procuring tenant

**Files:**
- Modify (in place, removal):
  - `supabase/migrations/019_products.sql`: drop `supplier_id`, `supplier_product_code`, `manufacturer_art_no`, `purchase_price`, `purchase_currency`, `purchase_incoterm`, `landed_cost_eur`, `landed_cost_on`, `target_price_eur`, `price_list_version` and their FK and indexes;
  - `039_company_price_column.sql`: no `product.company_price_eur`. The migration keeps only its non-product parts, or becomes empty with a one-line comment;
  - `020_products_import.sql` and `058_api_derived.sql`: `api.product_with_evidence`, `api.product_evidence`, the R4 `api.supplier(api.product_with_evidence)` (removed) and `public.import_products` without these columns;
  - `049_field_catalog.sql` (rows), `supabase/seed.sql`.
- Create: `supabase/migrations/069_product_sourcing.sql`, `supabase/tests/database/069_product_sourcing.test.sql`.

**Interfaces:**
- Produces, in 069:
  - `public.product_sourcing`, with:
    - `id UUID PK`, `tenant_id UUID NOT NULL` (procuring), `client_tenant_id UUID`;
    - `product_id UUID`, `product_tenant_id UUID NOT NULL`, `product_sku TEXT NOT NULL`, `product_name TEXT NOT NULL`;
    - `supplier_id UUID`, `supplier_product_code TEXT`, `manufacturer_art_no TEXT`;
    - `purchase_price NUMERIC(14,4)`, `purchase_currency CHAR(3)`, `purchase_incoterm TEXT`, `landed_cost_eur NUMERIC(14,4)`, `landed_cost_on DATE`, `target_price_eur NUMERIC(14,4)`;
    - `company_price_eur NUMERIC(14,4)`, `price_list_version TEXT`, `notes TEXT`;
    - `created_at`, `updated_at`.
  - Constraints:
    - `UNIQUE (id, tenant_id)`, `UNIQUE (tenant_id, product_id)`;
    - `CHECK ((client_tenant_id IS NULL AND product_tenant_id = tenant_id) OR product_tenant_id = client_tenant_id)`;
    - `FOREIGN KEY (tenant_id, client_tenant_id) REFERENCES provider_relationship (tenant_id, client_tenant_id) ON DELETE RESTRICT`;
    - `FOREIGN KEY (product_id, product_tenant_id) REFERENCES product (id, tenant_id) ON DELETE SET NULL (product_id)`;
    - `FOREIGN KEY (supplier_id, tenant_id) REFERENCES supplier (id, tenant_id) ON DELETE RESTRICT DEFERRABLE`.
  - Classification: supplier link and codes `supplier_identity`; prices, currency, incoterm, landed cost and target price `cost`; `company_price_eur` and `price_list_version` `sell_price`; `notes` `internal_note`. Shared: `id`, `tenant_id`, `client_tenant_id`, `product_id`, `product_tenant_id`, `product_sku`, `product_name`, `company_price_eur`, `price_list_version`, `updated_at`.
  - Trigger `private.product_sourcing_link()`, BEFORE INSERT OR UPDATE OF `client_tenant_id`, `product_id`, `product_tenant_id`:
    - `client_tenant_id` is immutable after insert (`client_link_immutable`);
    - calls `private.check_cross_tenant_link(NEW.tenant_id, NEW.client_tenant_id, NEW.product_tenant_id, 'public.product', TRUE)`;
    - when `product_id` is not null, sets `product_sku`/`product_name` from the product (definer read).
  - Permissions `public.product_sourcing` select, insert, update and delete in module `supplier`; the owner role gets all, management all, coordinator select, insert and update. `enable_tenant_level_security`, `audit_enable`, `enable_field_security`.
  - `public.import_products(rows JSONB)` (redefined from 058). The price columns of a row write the tenant's own sourcing row (`tenant_id = product_tenant_id`, `client_tenant_id NULL`), created when absent. The CSV header `moesa_fiyat_eur` becomes `satis_fiyati_eur`.

- [ ] **Step 1: Write the failing test.** `069_product_sourcing.test.sql` with `plan(10)`:

```sql
SELECT private.share_test_fixtures(); SELECT private.create_test_helpers();
SELECT hasnt_column('public', 'product', 'purchase_price', 'the product carries no cost');
SELECT hasnt_column('public', 'product', 'supplier_id', 'nor a supplier');
SELECT has_table('public', 'product_sourcing');
-- provider sourcing for a client product, by a member of the client
SELECT private.impersonate(current_setting('test.koordinator')::UUID, current_setting('test.moesa')::UUID);
SELECT lives_ok(format($$ INSERT INTO api.product_sourcing (client_tenant_id, product_id, product_tenant_id, purchase_price, company_price_eur)
   VALUES (%L, %L, %L, 4.2, 9.9) $$, current_setting('test.tho'), current_setting('test.tho_product'), current_setting('test.tho')), 'provider sources a client product');
SELECT is((SELECT product_sku FROM api.product_sourcing WHERE product_id = current_setting('test.tho_product')::UUID), (SELECT sku FROM public.product WHERE id = current_setting('test.tho_product')::UUID), 'sku snapshot');
SELECT throws_like(format($$ INSERT INTO api.product_sourcing (client_tenant_id, product_id, product_tenant_id) VALUES (%L, %L, %L) $$,
   current_setting('test.nova'), gen_random_uuid(), current_setting('test.nova')), '%cross_tenant_link_forbidden%', 'no relationship, no link (and no FK oracle)');
SELECT throws_ok(format($$ INSERT INTO api.product_sourcing (client_tenant_id, product_id, product_tenant_id) VALUES (%L, %L, %L) $$,
   current_setting('test.tho'), current_setting('test.tho_product'), current_setting('test.moesa')), '23514', NULL, 'a shared row points only into its client');
SELECT throws_like(format($$ UPDATE api.product_sourcing SET client_tenant_id = NULL WHERE product_id = %L $$, current_setting('test.tho_product')), '%client_link_immutable%');
-- the client deletes the product: the provider row keeps the snapshot
RESET ROLE; SELECT private.unimpersonate();
SELECT t.definer_exec(format('DELETE FROM public.product WHERE id = %L', current_setting('test.tho_product')));
SELECT is((SELECT product_id FROM public.product_sourcing WHERE product_sku = (SELECT current_setting('test.tho_sku'))), NULL, 'product_id set null');
SELECT isnt((SELECT product_name FROM public.product_sourcing WHERE product_sku = current_setting('test.tho_sku')), NULL, 'name snapshot kept');
```

(`test.tho_product` and `test.tho_sku` are a THO product set by `share_test_fixtures`; add them in 069 by redefining the fixture function. The delete may need to remove the product's own child rows first in the same `definer_exec`.)
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Implement.** Seed: MOESA LTD sources THO's three products with the old cost and sell prices. Suppliers `TR1…` move from THO to MOESA LTD.
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS.
- [ ] **Step 5: Commit** with `feat(procurement): product sourcing lives in the procuring tenant`.

### Task 4: Orders and shipments placed in the procuring tenant

**Files:**
- Create: `supabase/migrations/070_procurement_placement.sql`, `supabase/tests/database/070_procurement_placement.test.sql`.

**Interfaces:**
- Produces, in 070:
  - `purchase_order`:
    - adds `client_tenant_id UUID` with FK `(tenant_id, client_tenant_id) → provider_relationship (tenant_id, client_tenant_id) ON DELETE RESTRICT`;
    - adds `project_tenant_id UUID`;
    - `purchase_order_project_fkey` becomes `(project_id, project_tenant_id) REFERENCES project (id, tenant_id) ON DELETE SET NULL (project_id)`, with `CHECK (project_id IS NULL OR (client_tenant_id IS NULL AND project_tenant_id = tenant_id) OR project_tenant_id = client_tenant_id)`.
  - `purchase_order_line`:
    - adds `client_tenant_id`, `product_tenant_id UUID NOT NULL`, `product_sku TEXT NOT NULL`, `product_name TEXT NOT NULL` and `company_price_eur NUMERIC(14,4)` (sell_price, shared);
    - `product_id` becomes nullable;
    - `purchase_order_line_product_fkey` becomes `(product_id, product_tenant_id) REFERENCES product (id, tenant_id) ON DELETE SET NULL (product_id)`, with the same CHECK shape.
  - `shipment`:
    - adds `client_tenant_id` with the same relationship FK, `delivery_warehouse_tenant_id UUID` and `delivery_warehouse_name TEXT`;
    - the warehouse FK becomes `(delivery_warehouse_id, delivery_warehouse_tenant_id) REFERENCES warehouse (id, tenant_id) ON DELETE SET NULL (delivery_warehouse_id)`, with the same CHECK.
  - `shipment_event`, `shipment_line` and `shipment_purchase_order` add `client_tenant_id`.
  - Triggers:
    - `private.purchase_order_client()`, BEFORE INSERT OR UPDATE on `purchase_order`: `client_tenant_id` is immutable after insert (`client_link_immutable`). When the row is new, `client_tenant_id` changed, or `project_id`/`project_tenant_id` changed, it calls `check_cross_tenant_link(tenant, client, project_tenant_id, 'public.project', TRUE)`.
    - `private.purchase_order_line_client()`, BEFORE INSERT OR UPDATE: sets `NEW.client_tenant_id` from the PO (any input is overwritten). When the product link changes, it checks with `'public.product'` and refreshes the snapshot. On INSERT with a NULL `company_price_eur`, it defaults it from `product_sourcing.company_price_eur` of `(NEW.tenant_id, NEW.product_id)`.
    - `private.shipment_client()`: like the PO trigger, for the warehouse link (`'public.warehouse'`), filling `delivery_warehouse_name`.
    - `private.shipment_child_client()` on `shipment_event`, `shipment_line` and `shipment_purchase_order`: sets `client_tenant_id` from the shipment.
    - `private.shipment_purchase_order_guard` (redefined from 052) adds: the PO's `client_tenant_id IS NOT DISTINCT FROM` the shipment's, else `shipment_client_mismatch`.
  - Codes: `private.purchase_order_set_code` and `private.shipment_set_code` (redefined) use `coalesce((SELECT r.code FROM public.provider_relationship r WHERE r.tenant_id = NEW.tenant_id AND r.client_tenant_id = NEW.client_tenant_id), private.code_scope(NEW.tenant_id))`.
  - Classification rows for the new columns:
    - system: `client_tenant_id`, `project_tenant_id`, `product_tenant_id`, `delivery_warehouse_tenant_id`;
    - open: `product_sku`, `product_name`, `delivery_warehouse_name`;
    - sensitive/`sell_price`: `company_price_eur`.

    Re-run `enable_field_security` for the six tables.
  - `purchase_order_payment` and `purchase_order_update` get no `client_tenant_id`. They are never shared.

- [ ] **Step 1: Write the failing test.** `070_procurement_placement.test.sql` with `plan(12)`. As `koordinator` in MOESA LTD:
  1. `lives_ok` inserting a PO with `client_tenant_id = THO` and `project_id/project_tenant_id` set to THO's seeded project;
  2. `matches` its code against `'^PO-THO-[0-9]{4}-[0-9]{3,}$'`;
  3. `lives_ok` inserting a line for a THO product, then `is` its `client_tenant_id` = THO, overwriting a forged value;
  4. `is` the line's `company_price_eur` defaulted from sourcing;
  5. `throws_like` updating the PO's `client_tenant_id` → `client_link_immutable`;
  6. `throws_like` a line pointing at a Nova product → `cross_tenant_link_forbidden`;
  7. `throws_like` a `shipment_purchase_order` linking an own (unshared) PO to THO's shipment → `shipment_client_mismatch`;
  8. Same for two clients: with `test.rel_krn` switched to `provider` in the test, link a KRN-shared PO to a THO shipment → `shipment_client_mismatch`;
  9. after `UPDATE provider_relationship SET procurement_model = 'client'` (as postgres), `throws_like` a new THO-linked PO → `cross_tenant_link_forbidden`;
  10. after ending the relationship, `lives_ok` updating the existing PO's `status` (no link change);
  11. `throws_like` changing the existing line's product → `cross_tenant_link_forbidden`;
  12. after deleting the THO product as postgres, `is` the line's `product_id` NULL and `product_sku` unchanged.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Implement 070.**
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS. The existing PO and shipment tests stay green; own rows have `client_tenant_id` NULL and `*_tenant_id = tenant_id`. The app's existing inserts send `product_tenant_id`/`project_tenant_id` from Task 14 on. Until then a BEFORE trigger defaults a NULL `x_tenant_id` to `coalesce(client_tenant_id, tenant_id)`, and that default stays.
- [ ] **Step 5: Commit** with `feat(procurement): orders and shipments in the procuring tenant, linked to the client`.

### Task 5: Gates and derived views across the relationship

**Files:**
- Modify: `supabase/migrations/070_procurement_placement.sql` (append), `supabase/tests/database/070_procurement_placement.test.sql` (+4).

**Interfaces:**
- Produces:
  - `private.project_pi_ready(p_project UUID, p_tenant UUID) RETURNS BOOLEAN`, STABLE SECURITY DEFINER, not executable by users. It is true when a non-cancelled PO exists in any tenant with `project_id = p_project AND project_tenant_id = p_tenant`, status at `pi_approved` or later, and `client_tenant_id = p_tenant` (provider-procured) or `tenant_id = p_tenant` (own).
  - `private.project_gate_guard` and `public.pass_gate` (redefined from 058). G3:
    - an own order still needs the PI evidence document (unchanged);
    - when the project's only qualifying orders are provider-procured, G3 passes on `private.project_pi_ready`, with no evidence document. The provider's PI is a provider document the client cannot read.
    - The evidence predicate (032) still only accepts documents of the gate's tenant.
  - `api.purchase_order_overview`, `api.dashboard_purchase_order`, `api.shipment_overview`, `api.dashboard_shipment` (058, redefined): unchanged semantics. They read through `api.*` views, so a client sees none of the provider's rows there. A test pins it.

- [ ] **Step 1: Write the failing tests** (+4):
  - `ok(private.project_pi_ready(<tho project>, <tho>))` after the shared PO reaches `pi_approved` (set by postgres under `story_bypass`-style server write);
  - as `thometzki` in THO, `lives_ok` passing G3 of that project with no evidence document;
  - as `thometzki`, `is_empty` on `api.purchase_order_overview`;
  - `is_empty` on `api.dashboard_purchase_order`.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS.
- [ ] **Step 5: Commit** with `feat(gates): G3 on a provider-procured order`.

### Task 6: Provider-only fields on client rows

**Files:**
- Create: `supabase/migrations/071_provider_only_fields.sql`, `supabase/tests/database/071_provider_only_fields.test.sql`.

**Interfaces:**
- Produces, in 071:
  - `incident.provider_tenant_id UUID`, `incident_log.provider_tenant_id UUID` and `change_request.provider_tenant_id UUID`, each with FK `(provider_tenant_id, tenant_id) REFERENCES provider_relationship (tenant_id, client_tenant_id) ON DELETE RESTRICT`.
  - `change_request.purchase_order_id UUID` and `purchase_order_tenant_id UUID`, with FK `(purchase_order_id, purchase_order_tenant_id) REFERENCES purchase_order (id, tenant_id) ON DELETE SET NULL (purchase_order_id)`.
  - `private.shared_link(p_tenant UUID, p_table REGCLASS, p_id UUID) RETURNS UUID`, SECURITY DEFINER, for client rows pointing at a provider row (binding rule):
    - it returns the provider tenant when the row `p_id` of `p_table` (`public.purchase_order` or `public.shipment`) exists with `client_tenant_id = p_tenant`;
    - it returns NULL when the row is in `p_tenant` itself;
    - otherwise, including a row that exists elsewhere, it raises `cross_tenant_link_forbidden`.
    - Outside a server write, the caller must also hold `public.purchase_order` (or `public.shipment`) select in `p_tenant` (`tenants_permitting`).
  - Triggers. Each overwrites any `provider_tenant_id` input; users never write it directly.
    - `private.incident_provider()`, BEFORE INSERT OR UPDATE OF `entity_type`, `entity_id`: for `entity_type` in (`purchase_order`, `shipment`), `NEW.provider_tenant_id := private.shared_link(...)`; for other types, NULL.
    - `private.incident_log_provider()`, BEFORE INSERT: copies the incident's value.
    - `private.incident_provider_cascade()`, AFTER UPDATE OF `provider_tenant_id` ON incident: updates the logs under a server write.
    - `private.change_request_provider()`: from `purchase_order_id`, setting `purchase_order_tenant_id` and `provider_tenant_id`.
  - **Lock rule** (binding): `provider_tenant_id` may change after insert only while every provider-only field of the row, and for an incident every provider-only field of its logs, is NULL. Otherwise it raises `provider_link_locked`. A value written under the provider's right never becomes the client's by re-pointing the row.
  - `incident`'s own entity check (`private.incident_guard`, redefined) accepts a shared PO or shipment through `private.shared_link` instead of refusing a row of another tenant.
  - Catalog:
    - `provider_only = TRUE` on `public.incident_log.cost_amount`, `cost_currency` and `cost_payer`, and on `public.change_request.cost_impact` and `cost_payer`;
    - `change_request.cost_impact` and `cost_payer` are reclassified `sensitive`/`finance`;
    - `provider_tenant_id`, `purchase_order_id` and `purchase_order_tenant_id` are system.

    Re-run `enable_field_security` for `incident`, `incident_log` and `change_request`.
  - Defaults for the reclassification: every existing role keeps read and write on `change_request.cost_impact` and `cost_payer` (as field-permissions ruling 1 did); `field_default` gives management RW and coordinator R.

- [ ] **Step 1: Write the failing test.** `071_provider_only_fields.test.sql` (assertion count in the setup note below). Setup as postgres: a shared THO PO from the fixture (`test.shared_po`), and in THO an incident on it plus a log with `cost_amount = 555.55`. The log is written as `baris` (scope THO), who owns MOESA LTD and so holds the provider's `finance` write. A second log write as `koordinator`, who has `finance` read only in MOESA LTD, must fail with `field_write_forbidden`; this is assertion 14, so the file uses `plan(14)`.

```sql
SELECT is((SELECT provider_tenant_id FROM public.incident WHERE id = current_setting('test.inc')::UUID), current_setting('test.moesa')::UUID, 'incident on a shared order is provider-linked');
-- client owner: masked, filter-proof, write refused, cannot widen
SELECT private.impersonate(current_setting('test.thometzki')::UUID, current_setting('test.tho')::UUID);
SELECT is((SELECT cost_amount FROM api.incident_log WHERE id = current_setting('test.log')::UUID), NULL, 'owner of the client cannot read the provider cost');
SELECT is((SELECT count(*)::INT FROM api.incident_log WHERE cost_amount = 555.55), 0, 'filter oracle closed');
SELECT throws_like(format($$ UPDATE api.incident_log SET cost_amount = 1 WHERE id = %L $$, current_setting('test.log')), '%field_write_forbidden%', 'client cannot write it');
SELECT lives_ok(format($$ SELECT public.save_role(jsonb_build_object('id', %L, 'display_name', 'viewer'), ARRAY(SELECT permission_id FROM public.role_permission WHERE role_id = %L), '{"public.incident_log": {"cost_amount": {"read": true, "write": true}}}'::JSONB) $$,
   current_setting('test.viewer_role'), current_setting('test.viewer_role')), 'the owner grants their own role the field');
RESET ROLE; SELECT private.impersonate(current_setting('test.portal')::UUID, current_setting('test.tho')::UUID);
SELECT is((SELECT cost_amount FROM api.incident_log WHERE id = current_setting('test.log')::UUID), NULL, 'a client grant does not reach provider-linked rows');
-- provider staff: readable with the client alone in scope
RESET ROLE; SELECT private.impersonate(current_setting('test.koordinator')::UUID, current_setting('test.tho')::UUID);
SELECT is((SELECT cost_amount FROM api.incident_log WHERE id = current_setting('test.log')::UUID), 555.55::NUMERIC, 'provider staff read it');
-- lock rule
SELECT throws_like(format($$ UPDATE api.incident SET entity_type = 'project', entity_id = %L WHERE id = %L $$, current_setting('test.tho_project'), current_setting('test.inc')), '%provider_link_locked%', 'cannot re-point a costed incident');
-- forged provider_tenant_id is overwritten
SELECT lives_ok(format($$ INSERT INTO api.incident_log (incident_id, note, provider_tenant_id) VALUES (%L, 'x', NULL) $$, current_setting('test.inc')), 'log insert');
SELECT is((SELECT count(*)::INT FROM public.incident_log WHERE incident_id = current_setting('test.inc')::UUID AND provider_tenant_id IS NULL), 0, 'provider link copied, forged NULL ignored');
-- audit masking for the client owner
RESET ROLE; SELECT private.impersonate(current_setting('test.thometzki')::UUID, current_setting('test.tho')::UUID);
SELECT is((SELECT new_data -> 'cost_amount' FROM api.audit_log WHERE table_name = 'incident_log' AND record_id = current_setting('test.log')::UUID ORDER BY created_at LIMIT 1), '{"masked": true}'::JSONB, 'audit masks the provider cost');
-- a non-shared PO of the provider cannot be referenced
SELECT throws_like(format($$ UPDATE api.change_request SET purchase_order_id = %L WHERE id = %L $$, current_setting('test.own_po'), current_setting('test.cr')), '%cross_tenant_link_forbidden%', 'an unshared provider order cannot be referenced');
-- own incidents keep the client's own rules
SELECT is((SELECT cost_amount FROM api.incident_log WHERE id = current_setting('test.own_log')::UUID), 12.5::NUMERIC, 'client-procured incident cost readable by the client owner');
```

Use the audit column names exactly as `api.audit_log` names them (059). `test.viewer_role`, `test.cr`, `test.own_po`, `test.own_log` and `test.tho_project` are set by the setup block.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Implement 071.**
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS, drift empty.
- [ ] **Step 5: Commit** with `feat(security): provider-only fields on client incidents and change requests`.

### Task 7: Shared views and their security test

**Files:**
- Create: `supabase/migrations/072_shared_views.sql`, `supabase/tests/database/072_shared_views.test.sql`.

**Interfaces:**
- Produces, in 072:
  - `field_class.shared = TRUE` on exactly these sets (the `id`, `tenant_id`, `client_tenant_id`, `created_at` and `updated_at` of each table are always included):
    - `provider_relationship`: `code`, `procurement_model`, `status`, `started_at`, `ended_at`, `commercial_model`, `packages`, `start_on`, `contract_accepted_on`, `deposit_rate`, `extra_cost_rule`, `eu_responsible_person`.
    - `purchase_order`: `project_id`, `project_tenant_id`, `code`, `status`, `ready_on`.
    - `purchase_order_line`: `purchase_order_id`, `position`, `product_id`, `product_tenant_id`, `product_sku`, `product_name`, `quantity`, `company_price_eur`.
    - `shipment`: `code`, `status`, `mode`, `delivery_warehouse_id`, `delivery_warehouse_tenant_id`, `delivery_warehouse_name`, `carrier`, `incoterm_sell`, `ready_on`, `booking_confirmed_on`, `etd`, `eta`, `customs_cleared_on`, `planned_delivery_on`, `delivered_at`, `container_no`, `seal_no`, `carton_count`, `pallet_count`, `volume_m3`, `gross_kg`, `accepted_by`, `accepted_on`, `quantity_matches`, `has_damage`, `dispute_deadline_at`.
    - `shipment_purchase_order`: `shipment_id`, `purchase_order_id`.
    - `shipment_line`: `shipment_id`, `purchase_order_id`, `purchase_order_line_id`, `quantity`, `carton_count`.
    - `shipment_event`: `shipment_id`, `happened_at`, `step`.
    - `product_sourcing`: as in Task 3.
  - `SELECT private.enable_share(t) FROM unnest(ARRAY['provider_relationship', 'purchase_order', 'purchase_order_line', 'shipment', 'shipment_purchase_order', 'shipment_line', 'shipment_event', 'product_sourcing']) t;`
  - `api.provider_name(api.shared_provider_relationship) RETURNS TEXT` and `api.client_name(api.provider_relationship) RETURNS TEXT`: SECURITY DEFINER, STABLE, owner `api_owner`, executable by `authenticated`. Each returns the other party's `tenant.display_name`, only for a row the caller can already read through that view: it re-checks `$1.client_tenant_id = ANY (private.shared_client_tenants('public.provider_relationship'))`, respectively `$1.tenant_id = ANY (private.permitted_tenants('public.provider_relationship', 'select'))`, and returns NULL otherwise.
  - No new permissions. Shared reads need only the client tenant's own table select permissions: `provider_relationship` (Task 1), `purchase_order`, `shipment`, `product_sourcing` and so on.

- [ ] **Step 1: Write the failing test.** `072_shared_views.test.sql` with `plan(24)`. Setup as postgres:
  - in MOESA LTD: a THO-shared PO with a line (`unit_price = 777.77`, `company_price_eur = 9.90`), a payment, an update, a shipment with an event (`from_party = 'SECRET SUPPLIER'`) and a shipment line;
  - an own MOESA PO (unshared);
  - a KRN-shared PO (with `rel_krn` set to `provider`).

  The assertions:

```sql
-- structure
SELECT is_empty($$ SELECT column_name FROM information_schema.columns WHERE table_schema = 'api' AND table_name = 'shared_purchase_order_line'
   AND column_name IN ('unit_price', 'line_total', 'pi_line_total', 'notes') $$, 'no cost or note column in shared lines');
SELECT is_empty($$ SELECT column_name FROM information_schema.columns WHERE table_schema = 'api' AND table_name = 'shared_purchase_order'
   AND column_name IN ('supplier_id', 'incoterm', 'deposit_rate', 'pi_document_id', 'pi_total', 'notes', 'currency') $$, 'no supplier, terms, PI or note column');
SELECT is_empty($$ SELECT column_name FROM information_schema.columns WHERE table_schema = 'api' AND table_name = 'shared_shipment_event'
   AND column_name IN ('from_party', 'to_party', 'note', 'channel') $$, 'no party or note in shared events');
SELECT is_empty($$ SELECT column_name FROM information_schema.columns WHERE table_schema = 'api' AND table_name = 'shared_provider_relationship'
   AND column_name IN ('notes', 'restricted_drive_url', 'contract_document_id') $$, 'no internal field of the relationship');
SELECT is_empty($$ SELECT resource_name || '.' || field FROM public.field_class WHERE shared
   AND group_name IN ('cost', 'supplier_identity', 'supplier_contact', 'supplier_terms', 'finance', 'internal_note') $$, 'no forbidden group shared');
SELECT is_empty($$ SELECT resource_name FROM public.field_class WHERE shared AND resource_name IN ('public.purchase_order_payment', 'public.purchase_order_update', 'public.supplier', 'public.supplier_contact') $$, 'payments, updates and suppliers never shared');
SELECT is_empty($$ SELECT * FROM private.api_view_drift() $$, 'drift empty with the shared views');
SELECT ok(NOT has_table_privilege('authenticated', 'api.shared_purchase_order', 'INSERT,UPDATE,DELETE'), 'shared views are read-only');
-- client owner
SELECT private.impersonate(current_setting('test.thometzki')::UUID, current_setting('test.tho')::UUID);
SELECT is((SELECT count(*)::INT FROM api.shared_purchase_order), 1, 'exactly the THO-shared order');
SELECT is((SELECT company_price_eur FROM api.shared_purchase_order_line LIMIT 1), 9.90::NUMERIC, 'selling price visible');
SELECT is((SELECT count(*)::INT FROM api.purchase_order), 0, 'the provider table view shows nothing');
SELECT is((SELECT count(*)::INT FROM api.purchase_order_payment), 0, 'no payments');
SELECT is((SELECT count(*)::INT FROM api.purchase_order_update), 0, 'no updates');
SELECT is((SELECT count(*)::INT FROM api.product_sourcing), 0, 'no sourcing costs');
SELECT is((SELECT count(*)::INT FROM api.supplier), 0, 'no suppliers');
SELECT is((SELECT count(*)::INT FROM api.audit_log WHERE table_name IN ('purchase_order', 'purchase_order_line')), 0, 'no provider audit');
SELECT throws_ok($$ SELECT 1 FROM public.purchase_order $$, '42501', NULL, 'base table closed');
SELECT throws_ok($$ INSERT INTO api.shared_purchase_order (code) VALUES ('X') $$, '42501', NULL, 'insert refused');
-- forged scope with the provider tenant
RESET ROLE; SELECT private.impersonate_scope(current_setting('test.thometzki')::UUID, current_setting('test.tho')::UUID,
   ARRAY[current_setting('test.tho')::UUID, current_setting('test.moesa')::UUID, current_setting('test.krn_t')::UUID]);
SELECT is((SELECT count(*)::INT FROM api.shared_purchase_order), 1, 'forged x-tenant-ids neither widen the share');
SELECT is((SELECT count(*)::INT FROM api.purchase_order), 0, 'nor open provider orders');
-- narrowing: a THO role without sell_price
RESET ROLE; SELECT private.impersonate(current_setting('test.narrow')::UUID, current_setting('test.tho')::UUID);
SELECT is((SELECT company_price_eur FROM api.shared_purchase_order_line LIMIT 1), NULL, 'a client role narrows the selling price');
SELECT is((SELECT deposit_rate FROM api.shared_provider_relationship LIMIT 1), NULL, 'and the contract terms');
-- the provider sees both sides with both tenants in scope
RESET ROLE; SELECT private.impersonate_scope(current_setting('test.koordinator')::UUID, current_setting('test.moesa')::UUID,
   ARRAY[current_setting('test.moesa')::UUID, current_setting('test.tho')::UUID]);
SELECT is((SELECT unit_price FROM api.purchase_order_line WHERE client_tenant_id = current_setting('test.tho')::UUID LIMIT 1), 777.77::NUMERIC, 'provider reads cost on its own rows');
-- after the end, the history stays
RESET ROLE; SELECT private.unimpersonate();
SELECT t.definer_exec(format('SELECT public.end_provider_relationship(%L)', current_setting('test.rel_tho')));
SELECT private.impersonate(current_setting('test.thometzki')::UUID, current_setting('test.tho')::UUID);
SELECT is((SELECT count(*)::INT FROM api.shared_purchase_order), 1, 'ended relationship: history still shared');
```

(`test.narrow` is a fixture user in THO with a role that has `purchase_order`, `shipment` and `provider_relationship` select and no field rights. `end_provider_relationship` through `definer_exec` runs as postgres with a server-write flag set inside it; alternatively call it impersonating `baris`.)
- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL.
- [ ] **Step 3: Implement 072.**
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS.
- [ ] **Step 5: Commit** with `feat(security): shared read-only views for provider-procured rows`.

### Task 8: Classification, masked fields, allowlist

**Files:**
- Modify:
  - `docs/superpowers/specs/2026-11-08-field-classification.md`: sections for `provider_relationship` and `product_sourcing`; the new columns of the PO, line, shipment and children; the `shared` and `provider_only` columns of the catalog; the reclassified CR fields, with a note that the customer-as-tenant spec overrides field-permissions decision 2 on `cost_impact`; and the client-visible sets from Task 7;
  - `supabase/tests/database/049_field_catalog.test.sql` (sensitive count recounted; +1 `is_empty` for "every `provider_only` field is sensitive and its table has `provider_tenant_id`");
  - `supabase/tests/database/064_field_security_cutover.test.sql`: allowlist plus `public.end_provider_relationship`, `api.provider_name`, `api.client_name`, `private.shared_client_tenants` (if listed as executable) and `private.provider_read_rights`;
  - `app/src/@types/maskedFields.generated.ts`, `supabase/functions/_shared/database.types.ts` (regenerated).

- [ ] **Step 1: Write the failing test** (the 049 addition):

```sql
SELECT is_empty($$ SELECT c.resource_name || '.' || c.field FROM public.field_class c
   WHERE c.provider_only AND (c.class <> 'sensitive' OR NOT EXISTS (SELECT 1 FROM information_schema.columns i
      WHERE i.table_schema = 'public' AND 'public.' || i.table_name = c.resource_name AND i.column_name = 'provider_tenant_id')) $$,
   'provider-only fields are sensitive and their table is provider-linked');
```

- [ ] **Step 2: Run and confirm it fails.** `pnpm test:db`: FAIL on the counts and the allowlist.
- [ ] **Step 3: Update.** Run `pnpm dev:supabase-types`.
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test:db && node --test ../scripts/masked-fields.test.mjs`: PASS.
- [ ] **Step 5: Commit** with `docs(fields): classification for relationship, sourcing and sharing`.

### Task 9: Seeds for both procurement models

**Files:**
- Modify: `supabase/seed.sql`, `supabase/seed_story.sql`, `supabase/seed_story.check.sql`, `scripts/seed-story.mjs` (media of shared POs under MOESA LTD's folder), `supabase/tests/database/099_seed.test.sql`.

**Interfaces:**
- Produces this story:
  - **THO** (provider procures, active). Steps 02, 03, 05 and 06 run as `baris@`/`koordinator@` in MOESA LTD: suppliers, sourcing for THO's products, POs with `client_tenant_id = THO` and shipments to THO's warehouse. Step 08's incidents stay in THO, on shared POs, with provider costs in the logs. PO-011's PI file lives in MOESA LTD's folder.
  - **Kernhaus Living GmbH** (client procures, active, `akif@` management): its own suppliers, sourcing with costs, a PO and a shipment, all in the Kernhaus tenant.
  - **Clearstar Handel GmbH** (provider procures): one delivered PO. Step 04's second part ends the relationship instead of "closing CLS".
  - **Leafline and Paxton**: active provider-procures relationships with projects only.
  - In `seed.sql`, a THO role `narrow` with no field rights and the user `narrow@moesa-panel.test`, for the walk's limited client user. (`portal@`'s `viewer` keeps `sell_price` and `contract` read.)
  - `seed_story.check.sql` checks, each as a named failing row:
    - `share.tho_owner_sees_po`;
    - `share.tho_owner_no_cost` (no `unit_price` column: it checks `information_schema`, and `api.purchase_order_line` count 0);
    - `share.narrow_no_price`;
    - `share.krn_owner_sees_cost`;
    - `share.cls_history_after_end`;
    - `share.incident_cost_hidden_from_tho_owner`;
    - `share.koordinator_sees_both`.

- [ ] **Step 1: Write the failing check.** Add the seven checks to `seed_story.check.sql`. Each returns a row when violated, the file's existing convention.
- [ ] **Step 2: Run and confirm it fails.** `pnpm dev:supabase-reset`: FAIL, the checks report rows.
- [ ] **Step 3: Rewrite the steps.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm dev:supabase-reset` exits 0 with no check rows; `pnpm test:db && pnpm test:scripts` PASS.
- [ ] **Step 5: Commit** with `chore(seed): story with provider- and client-procured customers`.

### Task 10: HTTP attack suite for sharing

**Files:**
- Create: `supabase/functions/http-tests/sharing_http_test.ts`.
- Modify: `supabase/functions/http-tests/helpers.ts`.

**Interfaces:**
- Produces in `helpers.ts`:
  - `type ShareFixture = { thometzki: string; narrow: string; koordinator: string; outsider: string; tho: string; moesa: string; sharedPoId: string; sharedLineId: string; ownPoId: string; krnPoId: string; incidentLogId: string; piObject: string; novaProductId: string; thoProductId: string; relThoId: string }`.
    - `outsider` is a MOESA LTD coordinator who is not a member of THO.
  - `shareSetup(): Promise<ShareFixture>` creates, through admin calls, the rows of Task 7's setup: `unit_price` 777.77, `from_party` `'SECRET SUPPLIER'`, log cost 555.55, PI file uploaded under MOESA's folder.
  - `shareTeardown(f: ShareFixture): Promise<void>`.

- [ ] **Step 1: Write the failing tests.** The `Deno.test` names and assertions (`t(name, fn)` as in `field_security_http_test.ts`):
  - `setup`.
  - `client owner reads a shared order with the client-visible fields only`: `GET /shared_purchase_order_line?select=*` with `x-tenant-id: tho`. Assert 200, one row, the keys exactly the Task 7 set, `company_price_eur === 9.9`.
  - `selecting a provider-only column of a shared view is refused`: `GET /shared_purchase_order_line?select=unit_price` → 400, and the body does not contain `777`.
  - `filter, order and count reveal nothing outside the share`: `GET /shared_purchase_order?id=eq.<ownPoId>` → `[]`; `…?id=eq.<krnPoId>` → `[]`; `Prefer: count=exact` → `content-range` ends with `/1`.
  - `forged x-tenant-ids with the provider tenant neither widens rows nor unmasks`: `x-tenant-ids: tho,moesa`. `/purchase_order`, `/purchase_order_payment`, `/purchase_order_update`, `/product_sourcing` and `/supplier` each `[]`; `/shared_purchase_order` has length 1.
  - `embeds from shared views reach no provider row`: `GET /shared_purchase_order?select=id,purchase_order_payment(*),purchase_order_update(*)` → status 400, or every embed `[]`.
  - `shared views are read-only`: POST, PATCH and DELETE on `/shared_purchase_order` → 401/403 with code `42501`.
  - `a narrow client role reads no selling price or contract terms`: `narrow` token. `company_price_eur === null`, `deposit_rate === null`.
  - `the client owner cannot widen by granting a provider-only field`: `rpc/save_role` granting `incident_log.cost_amount` read to THO's `viewer`, then the `portal` token reads `/incident_log?id=eq.<incidentLogId>&select=cost_amount` → `null`.
  - `incident log cost on a provider-procured order is hidden from the client owner, visible to provider staff`: thometzki gets `null`; koordinator with `x-tenant-id: tho` gets `555.55`.
  - `writing a provider-only field from the client tenant is refused`: PATCH `/incident_log?id=eq.<incidentLogId>` `{cost_amount: 1}` as thometzki → 403 `field_write_forbidden`.
  - `audit history masks provider-only keys and hides provider rows`: `/audit_log?table_name=eq.incident_log` → `cost_amount` keys `{masked:true}`; `/audit_log?table_name=eq.purchase_order` → `[]`.
  - `Storage: the client owner cannot download the PI of a shared order`: `GET /storage/v1/object/authenticated/media/<piObject>` → 400 or 404, and the body does not contain `%PDF`.
  - `error bodies never contain a provider secret`: casts and filters on shared and provider views (`?company_price_eur=eq.abc`, `?unit_price=gt.0`); no body contains `777.77`, `555.55` or `SECRET SUPPLIER`.
  - `a provider user sees both sides when both tenants are in scope`: koordinator with `x-tenant-ids: moesa,tho`. `/purchase_order_line?client_tenant_id=eq.<tho>&select=unit_price` → 777.77, and `/product?select=sku,product_sourcing(purchase_price)` returns THO products with MOESA's purchase price.
  - `a cross-tenant link without access is refused with one error`: `outsider` POSTs a line with `product_id = thoProductId` and then with a random uuid; both 403 `cross_tenant_link_forbidden` with identical bodies. A line with `novaProductId` (no relationship) gives the same.
  - `after the relationship ends the client keeps the history and new links are refused`: admin ends `relThoId`; thometzki still reads 1 shared order; koordinator's new THO-linked PO → 403 `cross_tenant_link_forbidden`.
  - `teardown`.
- [ ] **Step 2: Run and confirm it fails.** `cd supabase/functions && deno task test:http`: FAIL on the new file.
- [ ] **Step 3: Implement the helpers.** Fix any leak found in the DB task that owns it.
- [ ] **Step 4: Run and confirm it passes.** `deno task check && deno task test:http`: PASS.
- [ ] **Step 5: Commit** with `test(http): attack suite for shared provider rows`.

### Task 11: Performance under the R10 budget

**Files:**
- Modify:
  - `supabase/perf/field_security_perf_load.sql`: a provider tenant with 2 clients, 2,000 shared lines per client and 2,000 own lines;
  - `supabase/perf/field_security_perf.sql`: new cases `client: shared_purchase_order_line list 50`, `client: shared_shipment list 50`, and `provider mixed scope: purchase_order_line list 50 with client_tenant_id filter`. The client baselines are the same rows read from the base table as postgres;
  - `supabase/functions/scripts/field_perf_http.ts`: the client case over HTTP.

- [ ] **Step 1: Add the cases.** Budget: restricted max(+40%, +10 ms) for client cases; internal max(+15%, +5 ms) for provider cases; writes +15 ms (R10 as amended 2026-11-09).
- [ ] **Step 2: Run.** `cd app && pnpm perf:fields` and `cd supabase/functions && deno task perf:http`. Expected: no `budget:` error. `private.shared_client_tenants` appears only in InitPlans: add an `EXPLAIN` assertion to `072_shared_views.test.sql` using `private.field_calls_only_in_initplans` (053), plan +1.
- [ ] **Step 3: If over budget,** fix in 068/072 (index `idx_<t>_client`, fenced CTE) and re-run.
- [ ] **Step 4: Run** `pnpm test:db` and confirm it PASSES.
- [ ] **Step 5: Commit** with `perf(fields): shared views within the R10 budget`.

### Task 12: App: product sourcing on the provider side

**Files:**
- Create: `app/src/api/product/sourcing.ts`, `app/src/views/pages/ops/product/tabs/Sourcing.vue`, `app/tests/views/productSourcing.test.ts`.
- Modify:
  - `app/src/views/pages/ops/product/tabs/Cost.vue` (deleted; its route becomes `ops-product-manage-sourcing`);
  - `app/src/router/routes/ops.ts`;
  - `app/src/views/pages/ops/product/Index.vue` and `ProductCard.vue` (price columns from the embed);
  - `app/src/api/product/index.ts`, `app/src/api/product/csv.ts` (`moesa_fiyat_eur` → `satis_fiyati_eur`), `app/src/api/product/import.ts`;
  - `app/tests/api/product.test.ts`, `app/tests/api/productCsv.test.ts`, `app/tests/views/productForm.test.ts`;
  - i18n.
- Create: `app/tests/constants/operatorName.test.ts`.

**Interfaces:**
- Produces:
  - `productSourcingApi`, a `defineResource` on `api.product_sourcing`;
  - `useProductSourcing(productId: Ref<string>, productTenantId: Ref<string>)`, returning `{ rows, upsertInActiveTenant(values: ProductSourcingForm): Promise<void> }`. It creates the active tenant's row when absent, with `client_tenant_id` = the product's tenant when that tenant ≠ the active tenant.
  - The product list select is `*, product_sourcing(tenant_id, purchase_price, purchase_currency, landed_cost_eur, company_price_eur)`.

- [ ] **Step 1: Write the failing tests.**
  - `productSourcing.test.ts`: `it('creates the active tenant sourcing row for a client product with client_tenant_id')` asserts the POST body `{ client_tenant_id: THO, product_id, product_tenant_id: THO, purchase_price: 4.2 }`; `it('shows one row per procuring tenant in scope')`.
  - `productCsv.test.ts`: `it('maps satis_fiyati_eur to company_price_eur')` and `it('rejects moesa_fiyat_eur as unknown')`.
  - `operatorName.test.ts`: reads every file under `src` (via `import.meta.glob('/src/**/*.{ts,vue,json}', { as: 'raw', eager: true })`). It asserts that no content matches `/moesa/i` once the product name `Moesa Panel` is removed, and that `/MOESA/` (upper case) appears nowhere.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint`: PASS.
- [ ] **Step 5: Commit** with `feat(app): product sourcing per procuring tenant`.

### Task 13: App: provider-procured orders and shipments

**Files:**
- Modify:
  - `app/src/lib/supabase.ts`: add `scopedFrom(table: string, tenantIds: string[])`, a query builder whose request carries `x-tenant-ids` = the given tenants plus the active one. The active tenant (`x-tenant-id`) is unchanged.
  - `app/src/views/pages/ops/purchase-order/Manage.vue`, `tabs/General.vue`, `ProjectSelect.vue`, `ProductSelect.vue`, `LineUpsert.vue`, `usePurchaseOrderForm.ts`;
  - `app/src/views/pages/ops/shipment/Manage.vue`, `useShipmentForm.ts`, the warehouse select;
  - `app/src/api/purchaseOrder/index.ts`, `app/src/api/shipment/index.ts`.
- Create: `app/src/api/relationship/index.ts`, `app/src/components/service-components/client-select/ClientSelect.vue`.
- Test: `app/tests/views/purchaseOrderForm.test.ts`, `purchaseOrderLineUpsert.test.ts`, `shipmentForm.test.ts`, `app/tests/api/relationship.test.ts`.

**Interfaces:**
- Produces:
  - `relationshipApi` (`api.provider_relationship`, select `*, client_name`);
  - `useProviderClients()`: the active tenant's relationships with `status = 'active'` and `procurement_model = 'provider'`;
  - `ClientSelect` (`v-model: string | null`, a `client_tenant_id`);
  - PO and shipment forms: a "Client" field, editable only on create, plus a project, product or warehouse picker that reads the chosen client's rows through `scopedFrom(table, [clientTenantId])` and sends `x_tenant_id` = the client;
  - line form: a `company_price_eur` field.

- [ ] **Step 1: Write the failing tests.**
  - `purchaseOrderForm.test.ts`: `it('lists the chosen client\'s projects with the client in x-tenant-ids')` asserts the request header `x-tenant-ids` contains the client id; `it('sends client_tenant_id and project_tenant_id on create')`; `it('locks the client after create')`.
  - `purchaseOrderLineUpsert.test.ts`: `it('picks the client product and sends product_tenant_id')`.
  - `shipmentForm.test.ts`: `it('lists the client warehouses')`.
  - `relationship.test.ts`: `it('filters active provider-procured clients')` asserts the URL contains `status=eq.active&procurement_model=eq.provider`.
- [ ] **Step 2: Run and confirm it fails.** `pnpm test`: FAIL.
- [ ] **Step 3: Implement.** New error codes get `NAMED_ERRORS` entries and `errors.*` in `en`/`tr`.
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint && pnpm build`: PASS.
- [ ] **Step 5: Commit** with `feat(app): orders and shipments for a client of the provider`.

### Task 14: Final gate for Plan 2

**Files:**
- Modify: `supabase/CHANGELOG.md`, `supabase/README.md` (the sharing model in one paragraph; the seeded users `narrow@` and `kernhaus@`).

- [ ] **Step 1: Run everything.**
  - `cd app && pnpm test:db && pnpm test && pnpm typecheck && pnpm lint && pnpm build && pnpm test:scripts && pnpm dev:supabase-reset && pnpm perf:fields`;
  - `cd supabase/functions && deno task check && deno task test && deno task test:http`.

  Expected: all PASS.
- [ ] **Step 2: Run** `git grep -n "MOESA" -- supabase/migrations app/src supabase/functions ':!supabase/functions/http-tests' ':!*.test.*'`. Expected: hits only in the comments of test fixture functions (`field_test_fixtures`, `share_test_fixtures`). The Task 2 pgTAP assertion pins function bodies.
- [ ] **Step 3: Commit** with `docs(tenancy): plan 2 done, provider sharing`.
