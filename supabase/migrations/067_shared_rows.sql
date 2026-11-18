-- 067: shared rows (Plan 2). A provider row with client_tenant_id = C is read by C's members and
-- written by nobody in C.
--
-- Section 1, rows. The sharing predicate: a client user reads a provider row exactly when the row's
-- client_tenant_id is one of the request's tenants (x-tenant-ids ∩ the user's tenants, so a forged
-- header widens nothing) and the user's roles grant select on that table in that client tenant.
-- client_tenant_id exists only under an accepted relationship (Plan 1's foreign key) and never
-- changes, so nothing else is asked: ending the relationship (or switching who procures) leaves the
-- shared history readable (decision 13).
--
-- private.enable_shared_rows(t), for each shared table (private.is_shared_table, 066):
--   restrict_selects_to_current_tenant  RESTRICTIVE: tenant_id or client_tenant_id in the scope
--   client_select                       PERMISSIVE: client_tenant_id in the tenants of the scope where
--                                       the user may select the table (private.permitted_tenants).
--                                       The permission generator (private.manage_policies) names its
--                                       own policies <command>_public_<table>, so a permission change
--                                       rebuilds those and keeps this one. The name sorts before
--                                       select_public_<table> on purpose (Task 10, R10): PostgreSQL
--                                       ORs the permissive policies in reverse name order, so the
--                                       tenant's own policy is tried first and a provider reading its
--                                       own rows never runs this policy's permitted_tenants InitPlan
--                                       (~0.5 ms a table). The result is the same either way.
--   the write policies                  untouched: their RESTRICTIVE tenant_id = ANY (scope) never
--                                       reaches a row of another tenant, so shared rows are read-only
--                                       (Task 4 tests the forwarders).
--   <table>_client_idx                  ON (client_tenant_id) WHERE client_tenant_id IS NOT NULL,
--                                       unless an index already leads with client_tenant_id (Plan 1
--                                       indexed purchase_order, shipment, sourcing and the
--                                       relationship).
-- Refuses (field_security_unsupported) a table that carries no shared rows. Owner postgres, executable
-- by nobody else.
--
-- private.enable_tenant_level_security (004) is restated with one delta: on a shared table it calls
-- enable_shared_rows after creating the default policies, so a re-run (disable, enable) cannot
-- silently drop sharing. Pinned in 052_guard_restatements.test.sql.

-- ========================================================================================== 1. rows

CREATE OR REPLACE FUNCTION private.enable_shared_rows (p_table TEXT) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    resource TEXT := 'public.' || p_table;
BEGIN
    IF p_table IS NULL OR NOT private.is_shared_table(p_table) THEN
        RAISE EXCEPTION 'field_security_unsupported' USING DETAIL = 'no shared rows: ' || coalesce(p_table, 'NULL');
    END IF;

    EXECUTE format('DROP POLICY IF EXISTS restrict_selects_to_current_tenant ON public.%I', p_table);
    EXECUTE format(
        $f$CREATE POLICY restrict_selects_to_current_tenant ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated
           USING (tenant_id = ANY ((SELECT private.tenant_scope())::UUID[]) OR client_tenant_id = ANY ((SELECT private.tenant_scope())::UUID[]))$f$,
        p_table
    );

    EXECUTE format('DROP POLICY IF EXISTS client_select ON public.%I', p_table);
    EXECUTE format(
        $f$CREATE POLICY client_select ON public.%I FOR SELECT TO authenticated
           USING (client_tenant_id = ANY ((SELECT private.permitted_tenants(%L, 'select'))::UUID[]))$f$,
        p_table, resource
    );

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
        WHERE i.indrelid = resource::REGCLASS
          AND a.attname = 'client_tenant_id'
    ) THEN
        EXECUTE format('CREATE INDEX %I ON public.%I (client_tenant_id) WHERE client_tenant_id IS NOT NULL',
                       p_table || '_client_idx', p_table);
    END IF;
END;
$$;

ALTER FUNCTION private.enable_shared_rows (TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.enable_shared_rows (TEXT) FROM PUBLIC, anon, authenticated;

-- 004's body plus the shared-table call at the end.
CREATE OR REPLACE FUNCTION private.enable_tenant_level_security (p_table_name TEXT) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET
    "search_path" = '' AS $$
DECLARE
  t_name text := p_table_name;
  t_schema text := 'public';
  in_scope text;
BEGIN
  IF NOT private.has_table_tenant_id(t_name) THEN
    RAISE NOTICE 'Table "%" does not have tenant_id column. Skipping.', t_name;
    RETURN;
  END IF;

  EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', t_schema, t_name);

  -- The request's tenants (private.tenant_scope): rows outside them are neither read nor written.
  -- Shared rows (tenant_id NULL) only where the column allows them: an OR keeps the index from
  -- narrowing the scan to the tenants, so every tenant's rows would be read and filtered.
  in_scope := 'tenant_id = ANY ((SELECT private.tenant_scope())::UUID[])';

  EXECUTE format(
    $f$CREATE POLICY restrict_selects_to_current_tenant ON %I.%I AS RESTRICTIVE FOR SELECT TO authenticated USING (%s)$f$,
    t_schema, t_name,
    CASE WHEN private.is_tenant_id_nullable(t_name) THEN format('(tenant_id IS NULL OR %s)', in_scope) ELSE in_scope END
  );

  EXECUTE format(
    $f$CREATE POLICY restrict_inserts_to_allowed_tenants ON %I.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (%s)$f$,
    t_schema, t_name, in_scope
  );

  EXECUTE format(
    $f$CREATE POLICY restrict_updates_to_current_tenant ON %I.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (%3$s) WITH CHECK (%3$s)$f$,
    t_schema, t_name, in_scope
  );

  EXECUTE format(
    $f$CREATE POLICY restrict_deletes_to_current_tenant ON %I.%I AS RESTRICTIVE FOR DELETE TO authenticated USING (%s)$f$,
    t_schema, t_name, in_scope
  );

  -- 067: a shared table keeps its shared rows readable by the client tenant.
  IF private.is_shared_table(t_name) THEN
    PERFORM private.enable_shared_rows(t_name);
  END IF;

  RAISE NOTICE 'RLS enabled and policies created for table: %', t_name;
END;
$$;

SELECT private.enable_shared_rows(c.relname::TEXT)
FROM pg_catalog.pg_class c
WHERE c.relnamespace = 'public'::REGNAMESPACE
  AND c.relkind = 'r'
  AND private.is_shared_table(c.relname::TEXT)
ORDER BY c.relname;

-- ======================================================================================= 2. masking
--
-- The api views (053) mask a shared row's columns by the row's own tenant. On a shared table
-- (private.is_shared_table), with n the column's attnum, cv field_class.client_visible and rc
-- field_class.rights_column:
--
--   sensitive and rc IS NOT NULL      CASE WHEN t.<rc> = ANY (m.t<n>) THEN t.<c> END
--   sensitive and shared and cv       CASE WHEN m.a<n> OR t.tenant_id = ANY (m.t<n>) OR t.client_tenant_id = ANY (m.t<n>) THEN t.<c> END
--   sensitive and shared and not cv   CASE WHEN t.tenant_id = ANY (m.t<n>) THEN t.<c> END
--   sensitive otherwise               unchanged: CASE WHEN m.a<n> OR t.tenant_id = ANY (m.t<n>) THEN t.<c> END
--   open and shared and not cv        CASE WHEN t.tenant_id = ANY (m.s) THEN t.<c> ELSE NULL::<type> END
--   open otherwise                    t.<c>
--   JSON-masked on a shared table     refused (field_security_unsupported) unless sensitive and not cv
--
-- A column outside the client-visible set is read only with rights in the row's own tenant (the
-- provider): m.a<n> ("readable in every tenant of the scope") would unmask it for a client owner
-- (the owner bypass), and t.client_tenant_id would let a right the client grants itself (save_role)
-- reach it, so neither appears. Open and system columns too: m.s is the tenants of the request's
-- scope where the user may select the table (private.permitted_tenants(<table>, 'select')), so they
-- read only with the select right in the provider: a provider member whose provider role cannot
-- select the table, reading the row as a client member with both tenants in scope, reads NULL. A
-- client-visible sensitive field is read through either tenant's right; a client role without it
-- reads NULL (the client narrows, never widens). The open mask's ELSE keeps the column's type (a
-- domain, a typmod) as a constant, so the view's column type does not change and nothing is cast per
-- row. The rights tenant of a write is never this generated column (F1): the triggers and the
-- forwarder read base columns.
--
-- api_view_from adds (SELECT coalesce(private.permitted_tenants(<table>, 'select'), '{}')) AS s to m on a shared table (an
-- InitPlan like the rights pairs). api_view_query appends the derived columns of
-- private.api_view_derived_columns after the base columns. api_view_drift reports 'unshared <c>' (a
-- provider-only column of a shared table not gated on t.tenant_id alone) and 'shared without s', and
-- compares a derived column's whole expression like any other.
--
-- Derived column api.purchase_order.client_status (Q1). Raw status is provider-only: pi_received,
-- pi_approved, deposit_paid and balance_paid reveal the provider's supplier-payment progress
-- (decision 15). The client reads the order's stage instead, from the status and the order's
-- shipments (shipment_purchase_order; a cancelled shipment counts for nothing):
--   cancelled       status cancelled
--   delivered       status closed, or at least one shipment and every one of them delivered,
--                   accepted or disputed
--   shipped         a shipment loaded, in transit, at customs or arrived
--   in_production   status in_production, ready or balance_paid
--   pending         status draft or sent (the order is not yet confirmed by the supplier)
--   confirmed       otherwise: pi_received, pi_approved, deposit_paid
-- A planned or booked shipment changes neither pending nor confirmed.
-- The order's live shipments are read through private.purchase_order_live_shipment, a view owned by
-- postgres (the shipments may lie outside what the reader selects; only the stage of an order the
-- reader already reads comes out) and selectable by api_owner alone: api.purchase_order (owned by
-- api_owner) counts them in a LEFT JOIN LATERAL (private.api_view_derived_from), an index lookup per
-- row read, and maps the counts with private.purchase_order_client_stage, a pure function of its
-- arguments that the planner inlines (Task 10, R10: a SECURITY DEFINER call per row cost ~22 µs,
-- +1 ms on a list of 50; a scalar subquery would put a SubLink in the view's whole row, and
-- api.supplier(api.purchase_order) would no longer be inlined).
-- private.purchase_order_client_status(id, tenant, status) is the same mapping for one order
-- (SECURITY DEFINER, executable by authenticated, which has no USAGE on private); 067's test pins the
-- view column to it.
--
-- The derived views (058) read the api twins, so they mask alike. purchase_order_overview gains
-- client_status, and its spec_missing_line_ids is NULL outside the order's own tenant: it would
-- read a masked spec_document_id through the provider's spec setting (F16). dashboard_purchase_order
-- gains client_status and keeps a shared order open by it (its raw status reads NULL), and
-- shipment_overview's psi_missing_po_codes is NULL outside the shipment's own tenant (the client
-- cannot read the provider's PSI documents, so every order would read as missing one).
--
-- Restated (F12, pinned in 052_guard_restatements.test.sql): api_column_expr (059's body),
-- api_view_from (053's), api_view_query (053's), api_view_drift (059's) and enable_field_security
-- (057's: the R4 functions across a provider-only link, which PostgREST no longer sees as a foreign
-- key once masked), each plus only this delta.
--
-- s repeats the select policy's permitted_tenants call (~0.5 ms each, R10). Restated (pinned in 052):
-- private.permitted_tenants (004's body) plus a cache of its results in access.permitted_tenants,
-- one statement long: keyed by the caller, the active tenant, x-tenant-ids (what tenant_scope
-- reads) and statement_timestamp(), so the policies and the view of one query share one lookup.
-- private.notify_access_changed and private.impersonate_scope (050) empty it, as they do
-- access.tenant_scope, so an access change or a new test sign-in never reads a stale result.
--
-- The access caches are signed. A custom setting is writable by whoever runs SQL in the session
-- (set_config), and the cached value is the authorization answer itself, so an entry is read only
-- when its HMAC-SHA256 under private.cache_secret (32 random bytes made here, readable by postgres
-- alone, the owner of both definers) matches; a missing, forged or foreign entry is a miss: computed
-- afresh and overwritten. An entry is '<hex hmac>:<key>=<value>', the HMAC over '<key>=<value>'.
-- The key is a JSON array (no separator a header could forge, a NULL kept as null) of the request
-- settings the answer is read from, as they stand (request.jwt.claim.sub, request.jwt.claims and
-- request.headers: the caller, the active tenant and x-tenant-ids, without parsing them on a hit),
-- plus statement_timestamp() for permitted_tenants. tenant_scope's value is its UUID[]; that of
-- permitted_tenants is one line per lookup, '\n<resource> <command>\t<UUID[]>'. Restated (pinned in
-- 052): private.tenant_scope (004's body) plus only this signing and the array key.
CREATE TABLE private.cache_secret (
    id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    secret BYTEA NOT NULL
);

ALTER TABLE private.cache_secret OWNER TO postgres;

ALTER TABLE private.cache_secret ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE private.cache_secret FROM PUBLIC, anon, authenticated, service_role, api_owner;

INSERT INTO private.cache_secret (secret) VALUES (extensions.gen_random_bytes(32));

-- 004's tenant_scope; 067: the transaction's cache is signed (see above).
CREATE OR REPLACE FUNCTION private.tenant_scope () RETURNS UUID[] LANGUAGE plpgsql SECURITY DEFINER STABLE
SET
    search_path = '' AS $$
DECLARE
    header TEXT;
    requested UUID[];
    scope UUID[];
    -- Policies of every table in a statement ask for it; the transaction keeps it, and
    -- private.notify_access_changed drops it when memberships or ownerships change.
    cache_key TEXT := jsonb_build_array(current_setting('request.jwt.claim.sub', true), current_setting('request.jwt.claims', true),
                                        current_setting('request.headers', true))::TEXT || '=';
    cached TEXT := coalesce(current_setting('access.tenant_scope', true), '');
    secret BYTEA;
    entry TEXT;
BEGIN
    -- Only a signed entry of this key is read: a forged one is a miss.
    IF substr(cached, 65, length(cache_key) + 1) = ':' || cache_key THEN
        secret := (SELECT c.secret FROM private.cache_secret c);
        IF left(cached, 64) = encode(extensions.hmac(convert_to(substr(cached, 66), 'UTF8'), secret, 'sha256'), 'hex') THEN
            RETURN substr(cached, 66 + length(cache_key))::UUID[];
        END IF;
    END IF;

    header := nullif(current_setting('request.headers', true), '')::JSONB ->> 'x-tenant-ids';
    BEGIN
        requested := string_to_array(header, ',')::UUID[];
    EXCEPTION
        WHEN OTHERS THEN
            requested := NULL;
    END;

    -- The allowed tenants once: the active one is in them exactly when tenant_id() would accept it.
    scope := ARRAY(
        SELECT id FROM unnest(coalesce(requested, '{}') || private.requested_tenant()) AS id
        WHERE id IS NOT NULL
        INTERSECT
        SELECT unnest(private.allowed_tenant())
    );
    secret := coalesce(secret, (SELECT c.secret FROM private.cache_secret c));
    entry := cache_key || scope::TEXT;
    PERFORM set_config('access.tenant_scope',
                       encode(extensions.hmac(convert_to(entry, 'UTF8'), secret, 'sha256'), 'hex') || ':' || entry, true);
    RETURN scope;
END;
$$;

-- 004's permitted_tenants; 067: its results are kept, signed, for the statement (see above).
CREATE OR REPLACE FUNCTION private.permitted_tenants (p_resource_name TEXT, p_command TEXT) RETURNS UUID[] LANGUAGE plpgsql SECURITY DEFINER STABLE
SET
    search_path = '' AS $$
DECLARE
    cache_key TEXT := jsonb_build_array(current_setting('request.jwt.claim.sub', true), current_setting('request.jwt.claims', true),
                                        current_setting('request.headers', true), statement_timestamp())::TEXT || '=';
    cached TEXT := coalesce(current_setting('access.permitted_tenants', true), '');
    secret BYTEA;
    lines TEXT := '';
    line TEXT := E'\n' || p_resource_name || ' ' || p_command || E'\t';
    at INT;
    permitted UUID[];
    entry TEXT;
BEGIN
    -- Only a signed entry of this key is read: a forged one is a miss, overwritten below.
    IF substr(cached, 65, length(cache_key) + 1) = ':' || cache_key THEN
        secret := (SELECT c.secret FROM private.cache_secret c);
        IF left(cached, 64) = encode(extensions.hmac(convert_to(substr(cached, 66), 'UTF8'), secret, 'sha256'), 'hex') THEN
            lines := substr(cached, 66 + length(cache_key));
            at := strpos(lines, line);
            IF at > 0 THEN
                RETURN split_part(substr(lines, at + length(line)), E'\n', 1)::UUID[];
            END IF;
        END IF;
    END IF;
    permitted := private.tenants_permitting(auth.uid(), private.tenant_scope(), p_resource_name, p_command);
    secret := coalesce(secret, (SELECT c.secret FROM private.cache_secret c));
    entry := cache_key || lines || line || permitted::TEXT;
    PERFORM set_config('access.permitted_tenants',
                       encode(extensions.hmac(convert_to(entry, 'UTF8'), secret, 'sha256'), 'hex') || ':' || entry, true);
    RETURN permitted;
END;
$$;

CREATE TYPE public.purchase_order_client_status AS ENUM ('pending', 'confirmed', 'in_production', 'shipped', 'delivered', 'cancelled');

-- The live (not cancelled) shipments of each order, as postgres.
CREATE VIEW private.purchase_order_live_shipment AS
SELECT sp.purchase_order_id, sp.tenant_id, sh.status
FROM public.shipment_purchase_order sp
JOIN public.shipment sh ON sh.id = sp.shipment_id AND sh.tenant_id = sp.tenant_id
WHERE sh.status <> 'cancelled';

ALTER VIEW private.purchase_order_live_shipment OWNER TO postgres;
REVOKE ALL ON private.purchase_order_live_shipment FROM PUBLIC, anon, authenticated;
GRANT SELECT ON private.purchase_order_live_shipment TO api_owner;

-- The stage from the raw status and the counts of live, arrived and underway shipments. No SET
-- clause and not SECURITY DEFINER, so the planner inlines it; every name is qualified.
CREATE OR REPLACE FUNCTION private.purchase_order_client_stage (
   p_status public.purchase_order_status,
   p_live BIGINT,
   p_arrived BIGINT,
   p_underway BIGINT
) RETURNS public.purchase_order_client_status LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_status = 'cancelled'::public.purchase_order_status THEN 'cancelled'
        WHEN p_status = 'closed'::public.purchase_order_status OR (p_live > 0 AND p_arrived = p_live) THEN 'delivered'
        WHEN p_underway > 0 THEN 'shipped'
        WHEN p_status = ANY ('{in_production,ready,balance_paid}'::public.purchase_order_status[]) THEN 'in_production'
        WHEN p_status = ANY ('{draft,sent}'::public.purchase_order_status[]) THEN 'pending'
        ELSE 'confirmed'
    END::public.purchase_order_client_status
$$;

REVOKE ALL ON FUNCTION private.purchase_order_client_stage (public.purchase_order_status, BIGINT, BIGINT, BIGINT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION private.purchase_order_client_stage (public.purchase_order_status, BIGINT, BIGINT, BIGINT) TO authenticated;

CREATE OR REPLACE FUNCTION private.purchase_order_client_status (
   p_purchase_order_id UUID,
   p_tenant_id UUID,
   p_status public.purchase_order_status
) RETURNS public.purchase_order_client_status LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT private.purchase_order_client_stage(
               p_status, count(*),
               count(*) FILTER (WHERE s.status IN ('delivered', 'accepted', 'disputed')),
               count(*) FILTER (WHERE s.status IN ('loaded', 'in_transit', 'at_customs', 'delivered', 'accepted', 'disputed')))
    FROM private.purchase_order_live_shipment s
    WHERE s.purchase_order_id = p_purchase_order_id AND s.tenant_id = p_tenant_id;
$$;

REVOKE ALL ON FUNCTION private.purchase_order_client_status (UUID, UUID, public.purchase_order_status) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION private.purchase_order_client_status (UUID, UUID, public.purchase_order_status) TO authenticated;

-- The columns an api view adds after the base columns: (name, select-list entry over t).
CREATE OR REPLACE FUNCTION private.api_view_derived_columns (p_table TEXT) RETURNS TABLE (name TEXT, expr TEXT) LANGUAGE sql STABLE
SET
   search_path = '' AS $$
    SELECT 'client_status', 'private.purchase_order_client_stage(t.status, cs.live, cs.arrived, cs.underway) AS client_status'
    WHERE p_table = 'purchase_order';
$$;

REVOKE ALL ON FUNCTION private.api_view_derived_columns (TEXT) FROM PUBLIC, anon, authenticated;

-- The joins the derived columns read, after the view's FROM. A LEFT JOIN LATERAL of one aggregate
-- row: the planner drops it when no derived column is read (a count, an embed's key), and the whole
-- row of the view stays free of subqueries, so the R4 functions over it (api.supplier(api.purchase_order))
-- are still inlined.
CREATE OR REPLACE FUNCTION private.api_view_derived_from (p_table TEXT) RETURNS TEXT LANGUAGE sql STABLE
SET
   search_path = '' AS $$
    SELECT CASE p_table
        WHEN 'purchase_order' THEN
            ' LEFT JOIN LATERAL (SELECT count(*) AS live, '
            || 'count(*) FILTER (WHERE s.status = ANY (''{delivered,accepted,disputed}''::public.shipment_status[])) AS arrived, '
            || 'count(*) FILTER (WHERE s.status = ANY (''{loaded,in_transit,at_customs,delivered,accepted,disputed}''::public.shipment_status[])) AS underway '
            || 'FROM private.purchase_order_live_shipment s WHERE s.purchase_order_id = t.id AND s.tenant_id = t.tenant_id) cs ON TRUE'
        ELSE ''
    END;
$$;

REVOKE ALL ON FUNCTION private.api_view_derived_from (TEXT) FROM PUBLIC, anon, authenticated;

-- client_status is no column of public.purchase_order, but the classification lists it as an open,
-- client-visible field so the generated client-visible constants (scripts/masked-fields.mjs) name
-- it. Nothing keys on the row beyond that: the api view takes the value from the derived column.
INSERT INTO
   public.field_class (resource_name, field, class, client_visible)
VALUES
   ('public.purchase_order', 'client_status', 'open', TRUE);

-- 059's api_column_expr plus the shared-table rules (see the header).
CREATE OR REPLACE FUNCTION private.api_column_expr (p_table TEXT, p_column TEXT) RETURNS TEXT LANGUAGE plpgsql STABLE
SET
   search_path = '' AS $$
DECLARE
    base REGCLASS := format('public.%I', p_table)::REGCLASS;
    resource TEXT := 'public.' || p_table;
    has_tenant BOOLEAN;
    n INT;
    expr TEXT;
    -- 067
    shared BOOLEAN := private.is_shared_table(p_table);
    sensitive BOOLEAN := private.api_is_sensitive('public.' || p_table, p_column);
    cv BOOLEAN;
    rc TEXT;
    col_type TEXT;
BEGIN
    has_tenant := EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = base AND a.attname = 'tenant_id' AND a.attnum > 0 AND NOT a.attisdropped
    );
    SELECT a.attnum, pg_catalog.format_type(a.atttypid, a.atttypmod) INTO n, col_type
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = base AND a.attname = p_column AND a.attnum > 0 AND NOT a.attisdropped;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'field_security_unsupported' USING DETAIL = 'no such column: ' || resource || '.' || p_column;
    END IF;
    SELECT f.client_visible, f.rights_column INTO cv, rc
    FROM public.field_class f
    WHERE f.resource_name = resource AND f.field = p_column;
    cv := coalesce(cv, FALSE);

    -- 067: a JSON mask reads the caller's rights in t.tenant_id; on a shared table only a provider-only
    -- sensitive column (masked whole by the provider's rights) may carry one.
    IF shared AND EXISTS (SELECT 1 FROM private.api_json_masked j WHERE j.resource_name = resource AND j.field = p_column)
       AND NOT (sensitive AND NOT cv) THEN
        RAISE EXCEPTION 'field_security_unsupported' USING DETAIL = 'JSON masking on a shared table: ' || resource || '.' || p_column;
    END IF;

    IF sensitive THEN
        IF p_table = 'user' THEN
            expr := format('CASE WHEN t.id = auth.uid() OR t.id = ANY (m.u%s) THEN t.%I END', n, p_column);
        ELSIF rc IS NOT NULL THEN
            -- 067: the rights of the tenant rc names.
            expr := format('CASE WHEN t.%1$I = ANY (m.t%2$s) THEN t.%3$I END', rc, n, p_column);
        ELSIF has_tenant AND shared AND cv THEN
            -- 067: client-visible, read through either tenant's right.
            expr := format('CASE WHEN m.a%1$s OR t.tenant_id = ANY (m.t%1$s) OR t.client_tenant_id = ANY (m.t%1$s) THEN t.%2$I END', n, p_column);
        ELSIF has_tenant AND shared THEN
            -- 067: provider-only, read with a right in the row's own tenant only.
            expr := format('CASE WHEN t.tenant_id = ANY (m.t%1$s) THEN t.%2$I END', n, p_column);
        ELSIF has_tenant THEN
            expr := format('CASE WHEN m.a%1$s OR t.tenant_id = ANY (m.t%1$s) THEN t.%2$I END', n, p_column);
        ELSE
            RAISE EXCEPTION 'field_security_unsupported' USING DETAIL = resource || '.' || p_column;
        END IF;
        -- No cast back to the column's type: a per-row typmod or domain cast is paid on every row
        -- before Sort/Limit (R10). The view column keeps the base type without its typmod, and a
        -- domain column its base type (as the generated TS types already map them).
        RETURN format('%s AS %I', expr, p_column);
    END IF;

    -- A JSON column whose keys are masked per row tenant (the maps from m): the audit snapshots by the
    -- row's own table, any other by every table's sensitive fields.
    IF EXISTS (SELECT 1 FROM private.api_json_masked j WHERE j.resource_name = resource AND j.field = p_column) THEN
        IF NOT has_tenant THEN
            RAISE EXCEPTION 'field_security_unsupported' USING DETAIL = 'JSON masking needs tenant_id: ' || resource || '.' || p_column;
        ELSIF p_table = 'audit_log' THEN
            RETURN format('private.mask_audit_data(t.table_name, t.tenant_id, t.%1$I, m.rights, m.sensitive) AS %1$I', p_column);
        END IF;
        RETURN format('private.mask_json_deep(t.%1$I, t.tenant_id, m.rights, m.sensitive) AS %1$I', p_column);
    END IF;
    -- 067: an open (or system) provider-only column of a shared table: members of the row's tenant.
    IF shared AND NOT cv THEN
        RETURN format('CASE WHEN t.tenant_id = ANY (m.s) THEN t.%1$I ELSE NULL::%2$s END AS %1$I', p_column, col_type);
    END IF;
    RETURN format('t.%I', p_column);
END;
$$;

REVOKE ALL ON FUNCTION private.api_column_expr (TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- 053's api_view_from plus the scope entry s of a shared table.
CREATE OR REPLACE FUNCTION private.api_view_from (p_table TEXT) RETURNS TEXT LANGUAGE plpgsql STABLE
SET
   search_path = '' AS $$
DECLARE
    base REGCLASS := format('public.%I', p_table)::REGCLASS;
    resource TEXT := 'public.' || p_table;
    fields TEXT[];
    nums INT[];
    entries TEXT[] := '{}';
    rights TEXT := '';
    i INT;
BEGIN
    SELECT array_agg(a.attname::TEXT ORDER BY a.attnum), array_agg(a.attnum::INT ORDER BY a.attnum) INTO fields, nums
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = base AND a.attnum > 0 AND NOT a.attisdropped AND private.api_is_sensitive(resource, a.attname);
    IF fields IS NOT NULL THEN
        rights := format(
            'WITH r AS MATERIALIZED (SELECT %s AS x) ',
            CASE WHEN p_table = 'user' THEN format('private.field_user_rights(%L::TEXT[])', fields)
                 ELSE format('private.field_read_rights(%L, %L::TEXT[])', resource, fields) END
        );
        FOR i IN 1 .. cardinality(fields) LOOP
            IF p_table = 'user' THEN
                entries := entries || format('(SELECT (r.x[%s]).ids FROM r) AS u%s', i, nums[i]);
            ELSE
                entries := entries || format('(SELECT (r.x[%s]).readable_all FROM r) AS a%s', i, nums[i])
                                   || format('(SELECT (r.x[%s]).ids FROM r) AS t%s', i, nums[i]);
            END IF;
        END LOOP;
    END IF;
    -- Other entries (059: the JSON maps), one of each.
    entries := entries || ARRAY(
        SELECT x.e
        FROM pg_catalog.pg_attribute a,
             unnest(private.api_rights_expr(p_table, a.attname)) WITH ORDINALITY AS x (e, k)
        WHERE a.attrelid = base AND a.attnum > 0 AND NOT a.attisdropped
        GROUP BY x.e
        ORDER BY min(a.attnum * 100 + x.k)
    );
    -- 067: the tenants of the request's scope where the user may select the table, once per view,
    -- for the open provider-only columns.
    IF private.is_shared_table(p_table) THEN
        entries := entries || format($e$(SELECT coalesce(private.permitted_tenants(%L, 'select'), '{}')) AS s$e$, resource);
    END IF;
    IF cardinality(entries) = 0 THEN
        RETURN format('%s t', base);
    END IF;
    RETURN format('%s t CROSS JOIN (%sSELECT %s OFFSET 0) m', base, rights, array_to_string(entries, ', '));
END;
$$;

REVOKE ALL ON FUNCTION private.api_view_from (TEXT) FROM PUBLIC, anon, authenticated;

-- 053's api_view_query plus the derived columns after the base columns, and their joins after the FROM.
CREATE OR REPLACE FUNCTION private.api_view_query (p_table TEXT) RETURNS TEXT LANGUAGE sql STABLE
SET
   search_path = '' AS $$
    SELECT format('SELECT %s%s FROM %s%s',
                  string_agg(private.api_column_expr(p_table, a.attname), ', ' ORDER BY a.attnum),
                  (SELECT coalesce(string_agg(', ' || d.expr, '' ORDER BY d.name), '') FROM private.api_view_derived_columns(p_table) d),
                  private.api_view_from(p_table), private.api_view_derived_from(p_table))
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = format('public.%I', p_table)::REGCLASS AND a.attnum > 0 AND NOT a.attisdropped;
$$;

REVOKE ALL ON FUNCTION private.api_view_query (TEXT) FROM PUBLIC, anon, authenticated;

-- 059's api_view_drift plus the derived columns, 'unshared <c>' and 'shared without s'.
CREATE OR REPLACE FUNCTION private.api_view_drift () RETURNS TABLE (relation TEXT, problem TEXT) LANGUAGE plpgsql VOLATILE
SET
   search_path = '' AS $$
DECLARE
    v RECORD;
    c RECORD;
    resource TEXT;
    expected_ok BOOLEAN;
    anon_oid OID := (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = 'anon');
    -- 067
    shared BOOLEAN;
BEGIN
    FOR v IN
        SELECT b.oid AS base, w.oid AS view, w.reltype, w.reloptions, w.relacl, b.relname::TEXT AS name,
               pg_catalog.pg_get_userbyid(w.relowner)::TEXT AS owner
        FROM pg_catalog.pg_class w
        JOIN pg_catalog.pg_namespace wn ON wn.oid = w.relnamespace AND wn.nspname = 'api'
        JOIN pg_catalog.pg_class b ON b.relname = w.relname AND b.relkind IN ('r', 'p')
        JOIN pg_catalog.pg_namespace bn ON bn.oid = b.relnamespace AND bn.nspname = 'public'
        WHERE w.relkind = 'v'
        ORDER BY b.relname
    LOOP
        resource := 'public.' || v.name;
        relation := v.name;
        shared := private.is_shared_table(v.name);

        -- 067: the base columns, then the derived ones.
        IF ARRAY(SELECT a.attname::TEXT FROM pg_catalog.pg_attribute a WHERE a.attrelid = v.base AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum)
           || ARRAY(SELECT d.name FROM private.api_view_derived_columns(v.name) d ORDER BY d.name)
           IS DISTINCT FROM
           ARRAY(SELECT a.attname::TEXT FROM pg_catalog.pg_attribute a WHERE a.attrelid = v.view AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum) THEN
            problem := 'columns';
            RETURN NEXT;
        ELSE
            -- What the generator would produce, deparsed the same way as the live view.
            expected_ok := TRUE;
            IF to_regclass('pg_temp.api_drift_expected') IS NOT NULL THEN
                EXECUTE 'DROP VIEW pg_temp.api_drift_expected';
            END IF;
            BEGIN
                EXECUTE 'CREATE TEMPORARY VIEW api_drift_expected AS ' || private.api_view_query(v.name);
            EXCEPTION WHEN OTHERS THEN
                expected_ok := FALSE;
                problem := 'expected: ' || SQLERRM;
                RETURN NEXT;
            END;

            FOR c IN
                SELECT a.attname::TEXT AS name, s.expr, e.expr AS expected,
                       -- m's pairs are numbered by the base column's attnum (the view's skips dropped ones).
                       (SELECT b.attnum FROM pg_catalog.pg_attribute b WHERE b.attrelid = v.base AND b.attname = a.attname) AS n,
                       private.api_is_sensitive(resource, a.attname) AS sensitive,
                       EXISTS (SELECT 1 FROM private.api_json_masked j WHERE j.resource_name = resource AND j.field = a.attname) AS json_masked,
                       -- 067
                       NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute b WHERE b.attrelid = v.base AND b.attname = a.attname
                                     AND b.attnum > 0 AND NOT b.attisdropped) AS derived,
                       coalesce((SELECT f.client_visible FROM public.field_class f WHERE f.resource_name = resource AND f.field = a.attname), FALSE) AS cv,
                       (SELECT f.rights_column FROM public.field_class f WHERE f.resource_name = resource AND f.field = a.attname) AS rc
                FROM pg_catalog.pg_attribute a
                JOIN private.api_view_select_list(v.view) s ON s.n = a.attnum
                LEFT JOIN private.api_view_select_list(CASE WHEN expected_ok THEN to_regclass('pg_temp.api_drift_expected') END) e ON e.n = a.attnum
                WHERE a.attrelid = v.view AND a.attnum > 0
                ORDER BY a.attnum
            LOOP
                IF c.derived THEN
                    -- 067: a derived column is compared whole (below) with the generator's.
                    NULL;
                ELSIF c.sensitive THEN
                    -- The mask reads its own pair of the rights subquery m, and m holds the view's rights call.
                    IF (v.name = 'user' AND (c.expr !~ format('\mm\.u%s\M', c.n)
                                             OR strpos(pg_catalog.pg_get_viewdef(v.view), 'private.field_user_rights(') = 0))
                       OR (v.name <> 'user' AND (c.expr !~ format('\mm\.t%s\M', c.n)
                                                 OR strpos(replace(pg_catalog.pg_get_viewdef(v.view), '::text', ''), format('private.field_read_rights(%L', resource)) = 0)) THEN
                        problem := 'unmasked ' || c.name;
                        RETURN NEXT;
                    END IF;
                ELSIF c.expr <> format('t.%I', c.name) AND NOT (c.json_masked AND (strpos(c.expr, 'mask_json_deep(') > 0 OR strpos(c.expr, 'mask_audit_data(') > 0))
                      AND NOT (shared AND NOT c.cv) THEN
                    problem := 'masked ' || c.name;
                    RETURN NEXT;
                END IF;
                -- 067: a provider-only column of a shared table reads only through the row's own tenant:
                -- its rights pair (sensitive) or s (open: the select right's tenants), nothing else in the condition.
                IF shared AND NOT c.derived AND NOT c.cv AND c.rc IS NULL
                   AND c.expr !~ format('^CASE\s+WHEN \(t\.tenant_id = ANY \(m\.%1$s\)\) THEN (t\.%2$s|\(t\.%2$s\)::[^\s]+)\s+ELSE [^\n]+\s+END$',
                                        CASE WHEN c.sensitive THEN 't' || c.n ELSE 's' END, quote_ident(c.name)) THEN
                    problem := 'unshared ' || c.name;
                    RETURN NEXT;
                END IF;
                -- The whole expression, so `true OR ...` or a THEN naming another column is caught.
                IF expected_ok AND c.expr IS DISTINCT FROM c.expected THEN
                    problem := 'expression ' || c.name;
                    RETURN NEXT;
                END IF;
            END LOOP;
            -- 067: a shared view's m carries s, the tenants where the user may select the table.
            IF shared AND pg_catalog.pg_get_viewdef(v.view) !~ format('\(\s*SELECT COALESCE\(private\.permitted_tenants\(''public\.%s''::text, ''select''::text\), ''\{\}''::uuid\[\]\) AS "coalesce"\)\s+AS s\M', v.name) THEN
                problem := 'shared without s';
                RETURN NEXT;
            END IF;
            -- The whole query (FROM, WHERE, ...), deparsed under the same search_path ''.
            IF expected_ok AND pg_catalog.pg_get_viewdef(v.view) IS DISTINCT FROM pg_catalog.pg_get_viewdef(to_regclass('pg_temp.api_drift_expected')) THEN
                problem := 'definition';
                RETURN NEXT;
            END IF;
            IF to_regclass('pg_temp.api_drift_expected') IS NOT NULL THEN
                EXECUTE 'DROP VIEW pg_temp.api_drift_expected';
            END IF;
        END IF;

        IF v.owner <> 'api_owner' THEN
            problem := 'owner';
            RETURN NEXT;
        END IF;

        IF NOT coalesce('security_invoker=false' = ANY (v.reloptions), FALSE) THEN
            problem := 'security_invoker';
            RETURN NEXT;
        END IF;

        -- Read-only is a view authenticated may not write; any other needs the forwarder.
        IF (has_table_privilege('authenticated', v.view, 'INSERT') OR has_table_privilege('authenticated', v.view, 'DELETE')
            OR has_any_column_privilege('authenticated', v.view, 'UPDATE'))
           AND NOT EXISTS (
               SELECT 1 FROM pg_catalog.pg_trigger t
               WHERE t.tgrelid = v.view AND t.tgname = 'api_forward' AND t.tgenabled = 'O'
                 AND t.tgfoid = 'private.api_forward()'::REGPROCEDURE
           ) THEN
            problem := 'trigger';
            RETURN NEXT;
        END IF;

        IF EXISTS (SELECT 1 FROM aclexplode(v.relacl) x WHERE x.grantee IN (0, anon_oid))
           OR EXISTS (
               SELECT 1 FROM pg_catalog.pg_attribute a, aclexplode(a.attacl) x
               WHERE a.attrelid = v.view AND x.grantee IN (0, anon_oid)
           ) THEN
            problem := 'anon or public privilege';
            RETURN NEXT;
        END IF;

        -- The R4 functions over this view: no ACL means EXECUTE for PUBLIC.
        FOR c IN
            SELECT p.proname::TEXT AS name
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace pn ON pn.oid = p.pronamespace AND pn.nspname = 'api'
            WHERE (v.reltype = ANY (p.proargtypes::OID[]) OR p.prorettype = v.reltype)
              AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee IN (0, anon_oid)))
            ORDER BY p.proname
        LOOP
            problem := 'anon or public execute ' || c.name;
            RETURN NEXT;
        END LOOP;

        IF (EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid = v.base AND a.attname = 'tenant_id' AND a.attnum > 0 AND NOT a.attisdropped)
            OR EXISTS (SELECT 1 FROM public.field_class f WHERE f.resource_name = resource AND f.class = 'sensitive'))
           AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t WHERE t.tgrelid = v.base AND t.tgname = 'aa_field_write_guard' AND t.tgenabled = 'O') THEN
            problem := 'guard';
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION private.api_view_drift () FROM PUBLIC, anon, authenticated;

-- 057's enable_field_security plus the R4 functions across a provider-only link of a shared table
-- (purchase_order_line.spec_document, purchase_order.packing_instruction_document): masked by the
-- scope, the link is no foreign key PostgREST can see, so the app embeds it through the function.
CREATE OR REPLACE FUNCTION private.enable_field_security (p_table TEXT, p_read_only BOOLEAN DEFAULT FALSE) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    base REGCLASS := format('public.%I', p_table)::REGCLASS;
    resource TEXT := 'public.' || p_table;
    expr TEXT;
    priv TEXT;
    update_cols TEXT;
    fk RECORD;
    fk_col TEXT;
    link TEXT;
    forward_fn TEXT;
    reverse_fn TEXT;
    view_name TEXT := format('api.%I', p_table);
    existed BOOLEAN := to_regclass(format('api.%I', p_table)) IS NOT NULL;
    prior TEXT[] := '{}';
    prior_cols TEXT[] := '{}';
BEGIN
    -- What authenticated may already write through the view: table-level, then column-level UPDATE.
    IF existed THEN
        prior := ARRAY(
            SELECT p FROM unnest(ARRAY['INSERT', 'UPDATE', 'DELETE']) AS p
            WHERE has_table_privilege('authenticated', view_name, p)
        );
        prior_cols := ARRAY(
            SELECT a.attname::TEXT FROM pg_catalog.pg_attribute a
            WHERE a.attrelid = view_name::REGCLASS AND a.attnum > 0 AND NOT a.attisdropped
              AND has_column_privilege('authenticated', view_name::REGCLASS, a.attnum, 'UPDATE')
        );
    END IF;

    -- 1. The view.
    EXECUTE format('CREATE OR REPLACE VIEW api.%I WITH (security_invoker = false) AS %s',
                   p_table, private.api_view_query(p_table));

    -- 2. Ownership and grants. The write privileges mirror authenticated's on the base, never more
    -- (a default privilege on the schema does not count); those the view already had are kept, so a
    -- re-run after the cutover (Task 19 revokes the base) loses nothing.
    EXECUTE format('ALTER VIEW api.%I OWNER TO api_owner', p_table);
    IF NOT existed THEN
        prior := '{}';
    END IF;
    SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum) INTO update_cols
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = base AND a.attnum > 0 AND NOT a.attisdropped
      AND (has_column_privilege('authenticated', base, a.attnum, 'UPDATE')
           OR (existed AND a.attname::TEXT = ANY (prior_cols)));
    EXECUTE format('REVOKE ALL ON api.%I FROM PUBLIC, anon, authenticated', p_table);
    EXECUTE format('GRANT SELECT ON api.%I TO authenticated', p_table);
    IF NOT p_read_only THEN
        FOREACH priv IN ARRAY ARRAY['INSERT', 'DELETE'] LOOP
            IF has_table_privilege('authenticated', base, priv) OR priv = ANY (prior) THEN
                EXECUTE format('GRANT %s ON api.%I TO authenticated', priv, p_table);
            END IF;
        END LOOP;
        IF has_table_privilege('authenticated', base, 'UPDATE') OR 'UPDATE' = ANY (prior) THEN
            EXECUTE format('GRANT UPDATE ON api.%I TO authenticated', p_table);
        ELSIF update_cols IS NOT NULL THEN
            EXECUTE format('GRANT UPDATE (%s) ON api.%I TO authenticated', update_cols, p_table);
        END IF;
    END IF;
    IF p_read_only THEN
        -- A read-only view never writes its base: api_owner keeps SELECT only (and loses any write an earlier run gave it).
        EXECUTE format('GRANT SELECT ON %s TO api_owner', base);
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %s FROM api_owner', base);
    ELSE
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %s TO api_owner', base);
    END IF;

    -- 3. The forwarder.
    IF p_read_only THEN
        EXECUTE format('DROP TRIGGER IF EXISTS api_forward ON api.%I', p_table);
    ELSE
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER api_forward INSTEAD OF INSERT OR UPDATE OR DELETE ON api.%I FOR EACH ROW EXECUTE FUNCTION private.api_forward ()',
            p_table
        );
    END IF;

    -- 4. R4: embeds across a sensitive link, once the target has its view.
    FOR fk IN
        SELECT tc.relname::TEXT AS target, c.conkey, c.confkey, c.conrelid, c.confrelid
        FROM pg_catalog.pg_constraint c
        JOIN pg_catalog.pg_class tc ON tc.oid = c.confrelid
        JOIN pg_catalog.pg_namespace tn ON tn.oid = tc.relnamespace
        WHERE c.conrelid = base AND c.contype = 'f' AND tn.nspname = 'public'
          AND to_regclass(format('api.%I', tc.relname)) IS NOT NULL
        ORDER BY c.conname
    LOOP
        FOR fk_col IN
            SELECT a.attname::TEXT
            FROM unnest(fk.conkey) AS k (attnum)
            JOIN pg_catalog.pg_attribute a ON a.attrelid = fk.conrelid AND a.attnum = k.attnum
            -- 067: a provider-only link of a shared table is masked too (an open one by the scope), so
            -- PostgREST no longer infers its foreign key; it gets the R4 functions like a sensitive one.
            WHERE (private.api_is_sensitive(resource, a.attname)
                   OR (private.is_shared_table(p_table)
                       AND NOT coalesce((SELECT f.client_visible FROM public.field_class f
                                         WHERE f.resource_name = resource AND f.field = a.attname), FALSE)))
              AND a.attname LIKE '%\_id'
        LOOP
            link := left(fk_col, -3);
            forward_fn := link;
            reverse_fn := p_table || '_by_' || link;
            IF octet_length(reverse_fn) > 63 THEN
                RAISE EXCEPTION 'field_security_unsupported' USING DETAIL = 'name too long: ' || reverse_fn;
            END IF;
            -- The pairs of the key, as written in the constraint.
            expr := (
                SELECT string_agg(format('x.%I = $1.%I', ta.attname, sa.attname), ' AND ' ORDER BY k.n)
                FROM unnest(fk.conkey, fk.confkey) WITH ORDINALITY AS k (src, dst, n)
                JOIN pg_catalog.pg_attribute sa ON sa.attrelid = fk.conrelid AND sa.attnum = k.src
                JOIN pg_catalog.pg_attribute ta ON ta.attrelid = fk.confrelid AND ta.attnum = k.dst
            );
            EXECUTE format(
                'CREATE OR REPLACE FUNCTION api.%1$I (api.%2$I) RETURNS SETOF api.%3$I ROWS 1 STABLE LANGUAGE sql SECURITY INVOKER AS %4$L',
                forward_fn, p_table, fk.target, format('SELECT x.* FROM api.%I x WHERE %s', fk.target, expr)
            );
            expr := (
                SELECT string_agg(format('x.%I = $1.%I', sa.attname, ta.attname), ' AND ' ORDER BY k.n)
                FROM unnest(fk.conkey, fk.confkey) WITH ORDINALITY AS k (src, dst, n)
                JOIN pg_catalog.pg_attribute sa ON sa.attrelid = fk.conrelid AND sa.attnum = k.src
                JOIN pg_catalog.pg_attribute ta ON ta.attrelid = fk.confrelid AND ta.attnum = k.dst
            );
            EXECUTE format(
                'CREATE OR REPLACE FUNCTION api.%1$I (api.%2$I) RETURNS SETOF api.%3$I STABLE LANGUAGE sql SECURITY INVOKER AS %4$L',
                reverse_fn, fk.target, p_table, format('SELECT x.* FROM api.%I x WHERE %s', p_table, expr)
            );
            EXECUTE format('REVOKE ALL ON FUNCTION api.%I (api.%I) FROM PUBLIC, anon', forward_fn, p_table);
            EXECUTE format('REVOKE ALL ON FUNCTION api.%I (api.%I) FROM PUBLIC, anon', reverse_fn, fk.target);
            EXECUTE format('GRANT EXECUTE ON FUNCTION api.%I (api.%I) TO authenticated', forward_fn, p_table);
            EXECUTE format('GRANT EXECUTE ON FUNCTION api.%I (api.%I) TO authenticated', reverse_fn, fk.target);
        END LOOP;
    END LOOP;

    -- 5. The base write guard, the second line.
    PERFORM private.enable_field_write_guard(p_table);
END;
$$;

REVOKE ALL ON FUNCTION private.enable_field_security (TEXT, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- The views over the restated generator: every shared table (and, as the brief lists them, incident,
-- change_request and the read-only audit trail) is regenerated; the R4 functions follow.
SELECT private.enable_field_security (c.relname::TEXT)
FROM pg_catalog.pg_class c
WHERE c.relnamespace = 'public'::REGNAMESPACE
  AND c.relkind = 'r'
  AND private.is_shared_table(c.relname::TEXT)
ORDER BY c.relname;

SELECT private.enable_field_security (t)
FROM unnest(ARRAY['incident', 'change_request']) AS t;

SELECT private.enable_field_security ('audit_log', TRUE);

-- 058's purchase_order_overview plus client_status (appended) and spec_missing_line_ids NULL outside
-- the order's own tenant.
CREATE OR REPLACE VIEW api.purchase_order_overview WITH (security_invoker = true) AS
SELECT po.id,
    po.tenant_id,
    po.client_tenant_id,
    po.supplier_id,
    po.project_id,
    po.project_tenant_id,
    po.project_code,
    po.code,
    po.status,
    po.currency,
    po.incoterm,
    po.incoterm_place,
    po.deposit_rate,
    po.ready_on,
    po.tolerance_pct,
    po.penalty_rule,
    po.packing_instruction_document_id,
    po.pi_document_id,
    po.pi_number,
    po.pi_subtotal,
    po.pi_total,
    po.pi_deposit_amount,
    po.pi_balance_amount,
    po.pi_extra_amount,
    po.pi_discount_amount,
    po.pi_check,
    po.pi_checked_by,
    po.pi_checked_at,
    po.notes,
    po.created_at,
    po.updated_at,
    r.client_code,
    s.code AS supplier_code,
    l.line_count,
    l.total_quantity,
    l.product_ids,
    -- 067: outside the order's own tenant the spec is masked, so the provider's spec setting would decide (F16).
    CASE WHEN po.tenant_id = ANY (private.tenant_scope()) THEN l.spec_missing_line_ids END AS spec_missing_line_ids,
    f.subtotal AS system_subtotal,
    f.total AS system_total,
    f.deposit AS system_deposit,
    f.balance AS system_balance,
    pay.deposit_planned_on,
    pay.deposit_paid_on,
    pay.balance_planned_on,
    pay.balance_paid_on,
    (EXISTS (
        SELECT 1
        FROM api.document d
        WHERE d.tenant_id = po.tenant_id AND d.entity_type = 'purchase_order'::public.document_entity AND d.entity_id = po.id
          AND d.type = 'psi_report'::public.document_type AND d.status = 'approved'::public.document_status
    )) AS has_approved_psi,
    po.client_status
FROM api.purchase_order po
LEFT JOIN api.provider_relationship r ON r.tenant_id = po.tenant_id AND r.client_tenant_id = po.client_tenant_id
LEFT JOIN api.supplier s ON s.id = po.supplier_id AND s.tenant_id = po.tenant_id
LEFT JOIN LATERAL (
    SELECT count(*)::INTEGER AS line_count,
        coalesce(sum(ln.quantity), 0::BIGINT)::INTEGER AS total_quantity,
        coalesce(array_agg(ln.product_id ORDER BY ln.position, ln.created_at, ln.id), '{}'::UUID[]) AS product_ids,
        coalesce(array_agg(ln.id ORDER BY ln.position, ln.created_at, ln.id)
                 FILTER (WHERE ln.spec_document_id IS NULL AND private.po_line_needs_spec(ln.product_id, ln.tenant_id)), '{}'::UUID[]) AS spec_missing_line_ids
    FROM api.purchase_order_line ln
    WHERE ln.purchase_order_id = po.id AND ln.tenant_id = po.tenant_id
) l ON TRUE
LEFT JOIN LATERAL private.purchase_order_figures(po.id, po.tenant_id) f (subtotal, total, deposit, balance) ON TRUE
LEFT JOIN LATERAL (
    SELECT min(p.planned_on) FILTER (WHERE p.kind = 'deposit'::public.payment_kind AND p.paid_on IS NULL) AS deposit_planned_on,
        max(p.paid_on) FILTER (WHERE p.kind = 'deposit'::public.payment_kind) AS deposit_paid_on,
        min(p.planned_on) FILTER (WHERE p.kind = 'balance'::public.payment_kind AND p.paid_on IS NULL) AS balance_planned_on,
        max(p.paid_on) FILTER (WHERE p.kind = 'balance'::public.payment_kind) AS balance_paid_on
    FROM api.purchase_order_payment p
    WHERE p.purchase_order_id = po.id AND p.tenant_id = po.tenant_id
) pay ON TRUE;

-- 058's dashboard_purchase_order plus client_status (appended). An order is open by its raw status;
-- a shared order, whose raw status reads NULL outside its own tenant (Q1), by client_status.
CREATE OR REPLACE VIEW api.dashboard_purchase_order WITH (security_invoker = true) AS
SELECT o.id AS purchase_order_id,
    o.code,
    o.client_tenant_id,
    o.client_code,
    o.supplier_code,
    o.tenant_id,
    o.status,
    o.ready_on,
    o.ready_on - CURRENT_DATE AS days_to_ready,
    o.deposit_planned_on,
    o.balance_planned_on,
    o.system_total,
    o.currency,
    o.client_status
FROM api.purchase_order_overview o
WHERE CASE WHEN o.status IS NULL
           THEN o.client_status <> ALL (ARRAY['delivered'::public.purchase_order_client_status, 'cancelled'::public.purchase_order_client_status])
           ELSE o.status <> ALL (ARRAY['draft'::public.purchase_order_status, 'closed'::public.purchase_order_status, 'cancelled'::public.purchase_order_status])
      END;

-- 058's shipment_overview with psi_missing_po_codes NULL outside the shipment's own tenant.
CREATE OR REPLACE VIEW api.shipment_overview WITH (security_invoker = true) AS
SELECT s.id,
    s.tenant_id,
    s.client_tenant_id,
    s.code,
    s.status,
    s.mode,
    s.delivery_warehouse_id,
    s.warehouse_tenant_id,
    s.delivery_address,
    s.forwarder,
    s.customs_broker,
    s.carrier,
    s.incoterm_buy,
    s.incoterm_sell,
    s.is_insured,
    s.ready_on,
    s.booking_confirmed_on,
    s.etd,
    s.eta,
    s.customs_cleared_on,
    s.planned_delivery_on,
    s.delivered_at,
    s.container_no,
    s.seal_no,
    s.free_days_port,
    s.free_days_detention,
    s.demurrage_note,
    s.carton_count,
    s.pallet_count,
    s.volume_m3,
    s.gross_kg,
    s.accepted_by,
    s.accepted_on,
    s.quantity_matches,
    s.has_damage,
    s.dispute_deadline_at,
    s.notes,
    s.created_at,
    s.updated_at,
    r.client_code,
    w.display_name AS warehouse_name,
    o.purchase_order_ids,
    o.purchase_order_codes,
    -- 067: the provider's documents are not the client's, so outside the shipment's own tenant every order
    -- would read as missing its PSI.
    CASE WHEN s.tenant_id = ANY (private.tenant_scope()) THEN o.psi_missing_po_codes END AS psi_missing_po_codes,
    ln.product_ids
FROM api.shipment s
LEFT JOIN api.provider_relationship r ON r.tenant_id = s.tenant_id AND r.client_tenant_id = s.client_tenant_id
LEFT JOIN api.warehouse w ON w.id = s.delivery_warehouse_id AND w.tenant_id = s.warehouse_tenant_id
LEFT JOIN LATERAL (
    SELECT coalesce(array_agg(po.id ORDER BY po.code, po.id), '{}'::UUID[]) AS purchase_order_ids,
        coalesce(array_agg(po.code ORDER BY po.code, po.id), '{}'::TEXT[]) AS purchase_order_codes,
        coalesce(array_agg(po.code ORDER BY po.code, po.id) FILTER (WHERE NOT (EXISTS (
            SELECT 1
            FROM api.document d
            WHERE d.tenant_id = po.tenant_id AND d.entity_type = 'purchase_order'::public.document_entity AND d.entity_id = po.id
              AND d.type = 'psi_report'::public.document_type AND d.status = 'approved'::public.document_status
        ))), '{}'::TEXT[]) AS psi_missing_po_codes
    FROM api.shipment_purchase_order sp
    JOIN api.purchase_order po ON po.id = sp.purchase_order_id AND po.tenant_id = sp.tenant_id
    WHERE sp.shipment_id = s.id AND sp.tenant_id = s.tenant_id
) o ON TRUE
LEFT JOIN LATERAL (
    SELECT coalesce(array_agg(DISTINCT pol.product_id), '{}'::UUID[]) AS product_ids
    FROM api.shipment_line l
    JOIN api.purchase_order_line pol ON pol.id = l.purchase_order_line_id AND pol.tenant_id = l.tenant_id
    WHERE l.shipment_id = s.id AND l.tenant_id = s.tenant_id
) ln ON TRUE;

-- ======================================================================================== 3. writes
--
-- A shared row stays read-only for the client: the write policies keep their RESTRICTIVE tenant_id =
-- ANY (scope), so an update or delete through api reaches no row of the provider, an insert into the
-- provider tenant is refused by RLS, and a client child cannot hang under a provider row (the
-- composite foreign keys carry tenant_id). A provider-only field is refused before that: the
-- forwarder checks a written sensitive field in the row's rights tenant, never the client's.
--
-- Rights column (field_class.rights_column, Tasks 5 and 6: incident, change_request). A field is
-- written under the tenant in column private.field_rights_column(resource, field), tenant_id unless
-- the catalog names another. The writers compute that tenant from base columns (F1): when the rights
-- column is generated (change_request.guard_tenant_id = coalesce(order_tenant_id, tenant_id)), from
-- its generation expression (private.field_rights_generated), never from the column itself: Postgres
-- fills a generated column only after BEFORE triggers (NULL in the guard), and the view row a client
-- sends may carry any value for it (the forwarder never writes a generated column).
--   private.api_forward             a written sensitive field passes when its rights tenant, in NEW
--                                   on INSERT, in the masked OLD and in NEW on UPDATE (both must
--                                   allow: no unlinking out of the provider's rights), is one of
--                                   private.field_write_tenants(resource, field).
--   private.enable_field_write_guard  the generated check: NEW.<rc> = ANY (...) on INSERT, and on
--                                   UPDATE OLD.<rc> = ANY (...) AND NEW.<rc> = ANY (...); a generated
--                                   <rc> becomes (SELECT <expression> FROM (SELECT NEW.*) x).
-- Restated (F12, pinned in 052_guard_restatements.test.sql): api_forward (053's body) and
-- enable_field_write_guard (051's), each plus only this delta. Every guard is regenerated.
--
-- api.purchase_order.pi_checked_by: masking drops its foreign key from what PostgREST sees, and the
-- R4 generator names functions after *_id links only, so the purchase_order → user embed through
-- pi_checked_by is gone. The app reads the raw column (Pi.vue resolves it against the members) and
-- never embeds it, so no R4 is added.

CREATE OR REPLACE FUNCTION private.field_rights_column (p_resource TEXT, p_field TEXT) RETURNS TEXT LANGUAGE sql STABLE
SET
   search_path = '' AS $$
    SELECT coalesce(
        (SELECT f.rights_column FROM public.field_class f WHERE f.resource_name = p_resource AND f.field = p_field),
        'tenant_id'
    );
$$;

REVOKE ALL ON FUNCTION private.field_rights_column (TEXT, TEXT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION private.field_rights_column (TEXT, TEXT) TO api_owner;

-- The rights tenant as an expression over the base columns when the rights column is generated
-- (parenthesized, unqualified column names), else NULL (the column is read as it is).
CREATE OR REPLACE FUNCTION private.field_rights_generated (p_resource TEXT, p_field TEXT) RETURNS TEXT LANGUAGE sql STABLE
SET
   search_path = '' AS $$
    SELECT '(' || pg_catalog.pg_get_expr(d.adbin, d.adrelid) || ')'
    FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE a.attrelid = pg_catalog.to_regclass(p_resource)
      AND a.attname = private.field_rights_column(p_resource, p_field)
      AND a.attgenerated = 's' AND a.attnum > 0 AND NOT a.attisdropped;
$$;

REVOKE ALL ON FUNCTION private.field_rights_generated (TEXT, TEXT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION private.field_rights_generated (TEXT, TEXT) TO api_owner;

-- 053's api_forward; 067: a sensitive field's rights tenant comes from its rights column, read from
-- base columns, in NEW (INSERT) or in the masked OLD and NEW (UPDATE).
CREATE OR REPLACE FUNCTION private.api_forward () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    base REGCLASS := pg_catalog.format('public.%I', TG_TABLE_NAME)::REGCLASS;
    resource TEXT := 'public.' || TG_TABLE_NAME;
    is_user BOOLEAN := TG_TABLE_NAME = 'user';
    has_tenant BOOLEAN;
    pk TEXT[];
    new_j JSONB;
    old_j JSONB;
    row_j JSONB;
    key_j JSONB;
    col RECORD;
    cols TEXT[] := '{}';
    allowed BOOLEAN;
    reread RECORD;
    n BIGINT;
    cast_sql TEXT;
    rc TEXT;
    rc_expr TEXT;
    rc_tenants UUID[];
    rc_row JSONB;
    rc_tenant UUID;
    rec_def TEXT;
BEGIN
    pk := ARRAY(
        SELECT a.attname::TEXT
        FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey::INT2[])
        WHERE i.indrelid = base AND i.indisprimary
        ORDER BY pg_catalog.array_position(i.indkey::INT2[], a.attnum)
    );
    IF cardinality(pk) = 0 THEN
        RAISE EXCEPTION 'field_security_unsupported' USING DETAIL = 'no primary key: ' || resource;
    END IF;

    IF TG_OP = 'DELETE' THEN
        EXECUTE pg_catalog.format(
            'DELETE FROM %s b WHERE %s', base,
            (SELECT pg_catalog.string_agg(pg_catalog.format('b.%1$I = ($1).%1$I', k), ' AND ') FROM unnest(pk) AS k)
        ) USING OLD;
        GET DIAGNOSTICS n = ROW_COUNT;
        IF n = 0 THEN
            RETURN NULL;
        END IF;
        RETURN OLD;
    END IF;

    has_tenant := EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = base AND a.attname = 'tenant_id' AND a.attnum > 0 AND NOT a.attisdropped
    );
    -- S1 compares at the column type: the view's columns carry no typmod and no domain (a per-row cast
    -- would cost on every read), so each side is cast to the base column's type (a domain: its base type
    -- and typmod, so a NULL never trips a NOT NULL domain) before the comparison. 12.50000 or 12.50004 for
    -- a numeric(12,4) 12.5000, or 'EUR ' for a char(3) 'EUR', is then the stored value: a no-op, as the
    -- base write would store the same. Per written row only.
    cast_sql := pg_catalog.format(
        'SELECT pg_catalog.to_jsonb(x) FROM (SELECT %s) x',
        (SELECT pg_catalog.string_agg(
                    pg_catalog.format('($1).%1$I::%2$s AS %1$I', a.attname,
                        CASE WHEN ty.typtype = 'd' THEN pg_catalog.format_type(ty.typbasetype, ty.typtypmod)
                             ELSE pg_catalog.format_type(a.atttypid, a.atttypmod) END),
                    ', ' ORDER BY a.attnum)
         FROM pg_catalog.pg_attribute a
         JOIN pg_catalog.pg_type ty ON ty.oid = a.atttypid
         WHERE a.attrelid = base AND a.attnum > 0 AND NOT a.attisdropped)
    );
    EXECUTE cast_sql INTO new_j USING NEW;
    -- The row whose rights apply: the stored (masked) row on UPDATE, the sent one on INSERT.
    IF TG_OP = 'UPDATE' THEN
        EXECUTE cast_sql INTO old_j USING OLD;
        row_j := old_j;
    ELSE
        row_j := new_j;
    END IF;

    FOR col IN
        SELECT a.attname::TEXT AS name, private.api_is_sensitive(resource, a.attname) AS sensitive
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = base AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
        ORDER BY a.attnum
    LOOP
        IF TG_OP = 'UPDATE' THEN
            CONTINUE WHEN NOT (new_j -> col.name IS DISTINCT FROM old_j -> col.name);
        ELSE
            CONTINUE WHEN coalesce(new_j -> col.name, 'null'::JSONB) = 'null'::JSONB;
        END IF;

        IF col.sensitive THEN
            IF is_user THEN
                allowed := (row_j ->> 'id')::UUID = auth.uid()
                        OR (row_j ->> 'id')::UUID = ANY (private.field_user_ids(col.name, TRUE));
            ELSIF has_tenant THEN
                -- 067: the rights tenant, from base columns (F1): the rights column as sent or stored, or a
                -- generated one's expression over the other columns (its own value is never read).
                rc := private.field_rights_column(resource, col.name);
                rc_expr := private.field_rights_generated(resource, col.name);
                rc_tenants := private.field_write_tenants(resource, col.name);
                IF rc_expr IS NOT NULL AND rec_def IS NULL THEN
                    -- The base columns at the types new_j and old_j were cast to (a domain's base type).
                    rec_def := (
                        SELECT pg_catalog.string_agg(
                                   pg_catalog.format('%I %s', a.attname,
                                       CASE WHEN ty.typtype = 'd' THEN pg_catalog.format_type(ty.typbasetype, ty.typtypmod)
                                            ELSE pg_catalog.format_type(a.atttypid, a.atttypmod) END),
                                   ', ' ORDER BY a.attnum)
                        FROM pg_catalog.pg_attribute a
                        JOIN pg_catalog.pg_type ty ON ty.oid = a.atttypid
                        WHERE a.attrelid = base AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
                    );
                END IF;
                allowed := TRUE;
                FOREACH rc_row IN ARRAY CASE WHEN TG_OP = 'UPDATE' THEN ARRAY[old_j, new_j] ELSE ARRAY[new_j] END LOOP
                    IF rc_expr IS NULL THEN
                        rc_tenant := (rc_row ->> rc)::UUID;
                    ELSE
                        EXECUTE pg_catalog.format('SELECT %s::UUID FROM pg_catalog.jsonb_to_record($1) AS x (%s)', rc_expr, rec_def)
                        INTO rc_tenant USING rc_row;
                    END IF;
                    allowed := allowed AND coalesce(rc_tenant = ANY (rc_tenants), FALSE);
                END LOOP;
            ELSE
                allowed := FALSE;
            END IF;
            IF NOT coalesce(allowed, FALSE) THEN
                RAISE EXCEPTION 'field_write_forbidden' USING ERRCODE = '42501', DETAIL = TG_TABLE_NAME || '.' || col.name;
            END IF;
        END IF;

        cols := cols || col.name;
    END LOOP;

    IF TG_OP = 'UPDATE' THEN
        -- One pass per project per statement (project_gate_guard): the forwarder writes one row at a time, each
        -- its own base statement, so the guard's flag is cleared between rows. Rows of one view statement share
        -- the statement timestamp; a second pass of a project under the same one is refused.
        IF TG_TABLE_NAME = 'project_gate' AND new_j ->> 'status' = 'passed' AND old_j ->> 'status' IS DISTINCT FROM 'passed' THEN
            IF pg_catalog.current_setting('moesa.api_gate_pass_' || replace(new_j ->> 'project_id', '-', '_'), TRUE) = pg_catalog.statement_timestamp()::TEXT THEN
                RAISE EXCEPTION 'gate_one_at_a_time' USING ERRCODE = 'check_violation';
            END IF;
            PERFORM pg_catalog.set_config('moesa.api_gate_pass_' || replace(new_j ->> 'project_id', '-', '_'), pg_catalog.statement_timestamp()::TEXT, TRUE);
        END IF;
        IF cardinality(cols) = 0 THEN
            -- Nothing to write, but RLS still decides: FOR UPDATE applies the UPDATE policies (a
            -- caller without update is refused as by a real UPDATE). Not a no-op UPDATE, which would
            -- bump updated_at and log an audit row.
            EXECUTE pg_catalog.format(
                'SELECT to_jsonb(b) FROM %s b WHERE %s FOR UPDATE', base,
                (SELECT pg_catalog.string_agg(pg_catalog.format('b.%1$I = ($1).%1$I', k), ' AND ') FROM unnest(pk) AS k)
            ) INTO key_j USING OLD;
            GET DIAGNOSTICS n = ROW_COUNT;
            IF n = 0 THEN
                RETURN NULL;
            END IF;
        ELSE
            EXECUTE pg_catalog.format(
                'UPDATE %s b SET (%s) = ROW (%s) WHERE %s RETURNING to_jsonb(b)', base,
                (SELECT pg_catalog.string_agg(pg_catalog.format('%I', c), ', ') FROM unnest(cols) AS c),
                (SELECT pg_catalog.string_agg(pg_catalog.format('($1).%I', c), ', ') FROM unnest(cols) AS c),
                (SELECT pg_catalog.string_agg(pg_catalog.format('b.%1$I = ($2).%1$I', k), ' AND ') FROM unnest(pk) AS k)
            ) INTO key_j USING NEW, OLD;
            GET DIAGNOSTICS n = ROW_COUNT;
            IF n = 0 THEN
                RETURN NULL;
            END IF;
        END IF;
    ELSIF cardinality(cols) = 0 THEN
        EXECUTE pg_catalog.format('INSERT INTO %s AS b DEFAULT VALUES RETURNING to_jsonb(b)', base) INTO key_j;
    ELSE
        EXECUTE pg_catalog.format(
            'INSERT INTO %s AS b (%s) VALUES (%s) RETURNING to_jsonb(b)', base,
            (SELECT pg_catalog.string_agg(pg_catalog.format('%I', c), ', ') FROM unnest(cols) AS c),
            (SELECT pg_catalog.string_agg(pg_catalog.format('($1).%I', c), ', ') FROM unnest(cols) AS c)
        ) INTO key_j USING NEW;
    END IF;

    -- The row as the caller may see it.
    EXECUTE pg_catalog.format(
        'SELECT v.* FROM api.%I v WHERE %s', TG_TABLE_NAME,
        (SELECT pg_catalog.string_agg(pg_catalog.format('v.%1$I = (jsonb_populate_record(NULL::%2$s, $1)).%1$I', k, base), ' AND ') FROM unnest(pk) AS k)
    ) INTO reread USING key_j;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN
        NEW := reread;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.api_forward () FROM PUBLIC, anon, authenticated;

-- Changing a function's owner needs the new owner's CREATE on its schema; api_owner keeps only USAGE.
GRANT CREATE ON SCHEMA private TO api_owner;

ALTER FUNCTION private.api_forward () OWNER TO api_owner;

REVOKE CREATE ON SCHEMA private FROM api_owner;

-- 051's enable_field_write_guard; 067: a tenant-checked field is checked in its rights tenant (NEW on
-- INSERT, OLD and NEW on UPDATE), a generated rights column through its expression.
CREATE OR REPLACE FUNCTION private.enable_field_write_guard (p_table TEXT) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    rel REGCLASS := format('public.%I', p_table)::REGCLASS;
    resource TEXT := 'public.' || p_table;
    fn TEXT := p_table || '_field_write_guard';
    has_tenant BOOLEAN;
    is_user BOOLEAN := p_table = 'user';
    col RECORD;
    allowed TEXT;
    raise_forbidden TEXT;
    on_update TEXT := '';
    on_insert TEXT := '';
    n_fields INT := 0;
    rc TEXT;
    rc_expr TEXT;
    allowed_update TEXT;
    allowed_insert TEXT;
BEGIN
    -- Postgres would truncate a longer name silently, and two tables could then share one guard.
    IF octet_length(fn) > 63 THEN
        RAISE EXCEPTION 'field_security_unsupported' USING DETAIL = 'guard name too long: ' || fn;
    END IF;

    has_tenant := EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = rel AND a.attname = 'tenant_id' AND a.attnum > 0 AND NOT a.attisdropped
    );

    IF has_tenant THEN
        on_update := on_update || $s$
        IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
            RAISE EXCEPTION 'tenant_move_forbidden' USING ERRCODE = '42501';
        END IF;$s$;
    END IF;

    FOR col IN
        SELECT a.attname::TEXT AS field,
               CASE
                   WHEN d.adbin IS NULL THEN 'NULL'
                   -- Constant: no node that reads state or calls a function that is not immutable.
                   WHEN d.adbin::TEXT !~ '\{(SUBLINK|NEXTVALEXPR|SQLVALUEFUNCTION|COERCEVIAIO|PARAM|VAR|CURRENTOFEXPR) '
                    AND NOT EXISTS (
                        SELECT 1
                        FROM regexp_matches(d.adbin::TEXT, ':(funcid|opfuncid|opno) (\d+)', 'g') AS m
                        JOIN pg_catalog.pg_proc p ON p.oid = CASE m[1]
                            WHEN 'opno' THEN (SELECT o.oprcode::OID FROM pg_catalog.pg_operator o WHERE o.oid = m[2]::OID)
                            ELSE m[2]::OID
                        END
                        WHERE p.provolatile <> 'i'
                    ) THEN '(' || pg_catalog.pg_get_expr(d.adbin, d.adrelid) || ')'
                   ELSE 'NULL'
               END AS default_expr
        FROM public.field_class f
        JOIN pg_catalog.pg_attribute a ON a.attrelid = rel AND a.attname = f.field AND a.attnum > 0 AND NOT a.attisdropped
        LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE f.resource_name = resource AND f.class = 'sensitive' AND a.attgenerated = ''
        ORDER BY a.attnum
    LOOP
        n_fields := n_fields + 1;
        IF is_user THEN
            -- <row> is OLD on UPDATE (the user the stored row describes), NEW on INSERT.
            allowed := format('<row>.id = auth.uid() OR <row>.id = ANY (private.field_user_ids(%L, TRUE))', col.field);
            allowed_update := replace(allowed, '<row>', 'OLD');
            allowed_insert := replace(allowed, '<row>', 'NEW');
        ELSIF has_tenant THEN
            -- 067: <row>.<rc>, the rights tenant (F1: a generated rights column is NULL in a BEFORE
            -- trigger, so its expression is evaluated over the row instead).
            rc := private.field_rights_column(resource, col.field);
            rc_expr := private.field_rights_generated(resource, col.field);
            IF rc_expr IS NULL THEN
                allowed := format('<row>.%I = ANY (private.field_write_tenants(%L, %L))', rc, resource, col.field);
            ELSE
                allowed := format('(SELECT %s FROM (SELECT <row>.*) x) = ANY (private.field_write_tenants(%L, %L))',
                                  rc_expr, resource, col.field);
            END IF;
            allowed_update := replace(allowed, '<row>', 'OLD') || ' AND ' || replace(allowed, '<row>', 'NEW');
            allowed_insert := replace(allowed, '<row>', 'NEW');
        ELSE
            RAISE EXCEPTION 'field_security_unsupported' USING DETAIL = resource;
        END IF;

        raise_forbidden := format(
            $s$
            IF NOT coalesce(%s, FALSE) THEN
                RAISE EXCEPTION 'field_write_forbidden' USING ERRCODE = '42501', DETAIL = %L;
            END IF;$s$,
            '<allowed>', p_table || '.' || col.field
        );
        on_update := on_update || format(E'\n        IF NEW.%1$I IS DISTINCT FROM OLD.%1$I THEN%2$s\n        END IF;', col.field,
                                         replace(raise_forbidden, '<allowed>', allowed_update));
        on_insert := on_insert || format(E'\n        IF NEW.%1$I IS DISTINCT FROM %2$s THEN%3$s\n        END IF;', col.field, col.default_expr,
                                         replace(raise_forbidden, '<allowed>', allowed_insert));
    END LOOP;

    EXECUTE format(
        $f$
CREATE OR REPLACE FUNCTION private.%1$I () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $g$
BEGIN
    IF private.field_guard_bypassed() THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' THEN%2$s
    ELSE%3$s
        NULL;
    END IF;
    RETURN NEW;
END;
$g$
        $f$,
        fn, on_update, on_insert
    );
    EXECUTE format('ALTER FUNCTION private.%I () OWNER TO postgres', fn);
    EXECUTE format('REVOKE ALL ON FUNCTION private.%I () FROM PUBLIC, anon, authenticated', fn);
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER aa_field_write_guard BEFORE INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION private.%I ()',
        rel, fn
    );
END;
$$;

REVOKE ALL ON FUNCTION private.enable_field_write_guard (TEXT) FROM PUBLIC, anon, authenticated;

-- Every guard regenerated over the restated generator (051's set: every public table with tenant_id
-- or a sensitive field; a partitioned table carries the trigger for its partitions).
DO $$
DECLARE
    t TEXT;
BEGIN
    FOR t IN
        SELECT c.relname
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND (
              EXISTS (
                  SELECT 1 FROM pg_catalog.pg_attribute a
                  WHERE a.attrelid = c.oid AND a.attname = 'tenant_id' AND a.attnum > 0 AND NOT a.attisdropped
              )
              OR EXISTS (
                  SELECT 1 FROM public.field_class f WHERE f.resource_name = 'public.' || c.relname AND f.class = 'sensitive'
              )
          )
        ORDER BY c.relname
    LOOP
        PERFORM private.enable_field_write_guard(t);
    END LOOP;
END;
$$;
