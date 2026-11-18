-- 068: provider order links (Plan 2). A client's incident or change request may cite a provider's
-- order or shipment shared with it.
--
-- Section 1, links (Task 5). Section 2, provider-guarded cost (Task 6, its own header below; it adds
-- cost_link_forbidden to provider_order_link_guard here).
--
-- incident.entity_tenant_id         The tenant of the linked record when it is a provider's order or
--                                   shipment; NULL when it is the incident's own tenant (an own-tenant
--                                   value is stored as NULL). Only with entity_type purchase_order or
--                                   shipment (incident_entity_tenant_kind). No foreign key: the link
--                                   is polymorphic, like entity_id.
-- change_request.purchase_order_id  The order the request is about, of order_tenant_id: the request's
-- change_request.order_tenant_id    own tenant (filled in when omitted, F8) or its provider's. The
--                                   composite key empties purchase_order_id only when the order is
--                                   deleted (ON DELETE SET NULL (purchase_order_id)), so the order
--                                   tenant stays as history (change_request_order_tenant).
-- change_request.guard_tenant_id    coalesce(order_tenant_id, tenant_id): the rights column of the
--                                   provider-only cost fields (Task 6). Writers compute it from the
--                                   base columns, never read it (F1).
--
-- private.provider_order_link_guard (trigger ae_provider_order_link_guard, before the tables' guards
-- and after aa_field_write_guard), for a link into another tenant x, on INSERT or when the link
-- changes:
--   relationship_inactive    x is not a provider of the row's tenant (no relationship). An ended
--                            relationship still allows a link to a row shared under it (Q4: the
--                            client may open incidents on existing shared orders after the end);
--                            a row cannot become shared after the end, so nothing new is reachable.
--   provider_link_forbidden  the caller may not read orders (or shipments) in the row's tenant, or
--                            the target is not x's row shared with the row's tenant
--                            (client_tenant_id), or is not an order or a shipment. An unknown id
--                            gets the same message.
-- A kept link is not checked again (history); a link emptied (the order deleted, F7) has nothing to
-- check. A link into the row's own tenant keeps the same-tenant rules (incident_guard, the foreign
-- key). Under private.rules_bypassed() only the stored tenant is normalized.
--
-- Restated (F12, pinned in 052_guard_restatements.test.sql): incident_guard (035's body) plus only
-- this delta: the linked record is looked up in coalesce(entity_tenant_id, tenant_id), also when only
-- entity_tenant_id changes.

ALTER TABLE public.incident
ADD COLUMN entity_tenant_id UUID,
ADD CONSTRAINT incident_entity_tenant_kind CHECK (
   entity_tenant_id IS NULL
   OR coalesce(entity_type IN ('purchase_order', 'shipment'), FALSE)
);

ALTER TABLE public.change_request
ADD COLUMN purchase_order_id UUID,
ADD COLUMN order_tenant_id UUID,
ADD COLUMN guard_tenant_id UUID GENERATED ALWAYS AS (coalesce(order_tenant_id, tenant_id)) STORED,
ADD CONSTRAINT change_request_order_tenant CHECK (
   purchase_order_id IS NULL
   OR order_tenant_id IS NOT NULL
),
ADD CONSTRAINT change_request_purchase_order_fkey FOREIGN KEY (purchase_order_id, order_tenant_id) REFERENCES public.purchase_order (id, tenant_id) ON DELETE SET NULL (purchase_order_id);

CREATE INDEX IF NOT EXISTS idx_change_request_purchase_order ON public.change_request (purchase_order_id, order_tenant_id);

CREATE INDEX IF NOT EXISTS idx_incident_entity_tenant ON public.incident (entity_tenant_id, entity_type, entity_id)
WHERE
   entity_tenant_id IS NOT NULL;

-- TG_ARGV: the link id column, its tenant column, and (incident) the column naming the target table;
-- without it the target is public.purchase_order (change_request).
CREATE OR REPLACE FUNCTION private.provider_order_link_guard () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    new_row CONSTANT JSONB := to_jsonb(NEW);
    old_row CONSTANT JSONB := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) END;
    id_column CONSTANT TEXT := TG_ARGV[0];
    tenant_column CONSTANT TEXT := TG_ARGV[1];
    by_kind CONSTANT BOOLEAN := TG_NARGS > 2;
    own CONSTANT UUID := (new_row ->> 'tenant_id')::UUID;
    link_id CONSTANT UUID := (new_row ->> id_column)::UUID;
    target_table CONSTANT TEXT := CASE WHEN by_kind THEN new_row ->> TG_ARGV[2] ELSE 'purchase_order' END;
    old_table CONSTANT TEXT := CASE WHEN by_kind THEN old_row ->> TG_ARGV[2] ELSE 'purchase_order' END;
    target_tenant UUID := (new_row ->> tenant_column)::UUID;
    shared BOOLEAN;
BEGIN
    -- The stored tenant: none without a link (a change request keeps its order tenant as history);
    -- the own tenant as NULL (incident) or as itself (change request, F8).
    IF link_id IS NULL THEN
        target_tenant := CASE WHEN NOT by_kind AND TG_OP = 'UPDATE' THEN (old_row ->> tenant_column)::UUID END;
    ELSIF target_tenant IS NULL OR target_tenant = own THEN
        target_tenant := CASE WHEN by_kind THEN NULL ELSE own END;
    END IF;
    NEW := jsonb_populate_record(NEW, jsonb_build_object(tenant_column, target_tenant));

    -- Section 2 (Task 6): a change request whose cost is its provider's (guard_tenant_id <> tenant_id)
    -- changes its order only with the right to write that cost there, so a client cannot unlink or
    -- relink out of the provider's rights. Not on a system path, nor when the order is gone (F7).
    IF NOT by_kind AND TG_OP = 'UPDATE'
       AND (old_row ->> 'guard_tenant_id') IS DISTINCT FROM (old_row ->> 'tenant_id')
       AND (link_id IS DISTINCT FROM (old_row ->> id_column)::UUID
            OR target_tenant IS DISTINCT FROM (old_row ->> tenant_column)::UUID)
       AND NOT private.field_guard_bypassed()
       AND NOT (link_id IS NULL AND private.parent_gone('public.purchase_order', (old_row ->> id_column)::UUID))
       AND NOT coalesce((old_row ->> 'guard_tenant_id')::UUID = ANY (private.field_write_tenants('public.change_request', 'cost_impact')), FALSE) THEN
        RAISE EXCEPTION 'cost_link_forbidden' USING ERRCODE = '42501';
    END IF;

    -- Nothing to check: no link, an own-tenant link, a kept link, or the bypass.
    IF link_id IS NULL OR target_tenant IS NULL OR target_tenant = own
       OR TG_OP = 'UPDATE'
          AND link_id IS NOT DISTINCT FROM (old_row ->> id_column)::UUID
          AND target_tenant IS NOT DISTINCT FROM (old_row ->> tenant_column)::UUID
          AND target_table IS NOT DISTINCT FROM old_table
       OR private.rules_bypassed() THEN
        RETURN NEW;
    END IF;

    IF target_table IS NULL OR target_table NOT IN ('purchase_order', 'shipment') THEN
        RAISE EXCEPTION 'provider_link_forbidden' USING ERRCODE = 'check_violation';
    END IF;

    -- 1. The relationship: active, or ended (its shared rows stay citable, Q4).
    IF private.relationship_status(target_tenant, own) IS NULL THEN
        RAISE EXCEPTION 'relationship_inactive' USING ERRCODE = 'check_violation';
    END IF;

    -- 2. The caller's read right on the target's kind in the row's own tenant.
    IF auth.uid() IS NOT NULL
       AND NOT (own = ANY (coalesce(private.tenants_permitting(auth.uid(), ARRAY[own], 'public.' || target_table, 'select'), '{}'))) THEN
        RAISE EXCEPTION 'provider_link_forbidden' USING ERRCODE = 'check_violation';
    END IF;

    -- 3. The target is the provider's row shared with the row's tenant; an unknown id alike.
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I r WHERE r.id = $1 AND r.tenant_id = $2 AND r.client_tenant_id = $3)',
                   target_table)
    INTO shared
    USING link_id, target_tenant, own;
    IF NOT shared THEN
        RAISE EXCEPTION 'provider_link_forbidden' USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.provider_order_link_guard () FROM PUBLIC, anon, authenticated;

-- BEFORE triggers fire in name order: ae sorts the link guard before <table>_z_guard, so an unknown
-- provider id gets provider_link_forbidden, not the same-tenant incident_entity_invalid.
CREATE OR REPLACE TRIGGER ae_provider_order_link_guard BEFORE INSERT
OR
UPDATE ON public.incident FOR EACH ROW
EXECUTE FUNCTION private.provider_order_link_guard ('entity_id', 'entity_tenant_id', 'entity_type');

CREATE OR REPLACE TRIGGER ae_provider_order_link_guard BEFORE INSERT
OR
UPDATE ON public.change_request FOR EACH ROW
EXECUTE FUNCTION private.provider_order_link_guard ('purchase_order_id', 'order_tenant_id');

-- 035's incident_guard; 068: the linked record is looked up in coalesce(entity_tenant_id, tenant_id)
-- (the link guard has checked a provider's record), also when only entity_tenant_id changes.
CREATE OR REPLACE FUNCTION private.incident_guard () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    linked BOOLEAN;
BEGIN
    -- 1. The code and the family are fixed.
    IF TG_OP = 'UPDATE' AND (
        NEW.code IS DISTINCT FROM OLD.code
        OR NEW.family IS DISTINCT FROM OLD.family
    ) THEN
        RAISE EXCEPTION 'incident_immutable_field' USING ERRCODE = 'check_violation';
    END IF;

    IF private.rules_bypassed() THEN
        RETURN NEW;
    END IF;

    -- 2. The Y10 card is of the incident's family (its format is incident_type_format).
    IF NEW.incident_type IS NOT NULL AND split_part(NEW.incident_type, '-', 1) <> upper(NEW.family::TEXT) THEN
        RAISE EXCEPTION 'incident_type_family' USING ERRCODE = 'check_violation';
    END IF;

    -- 3. The linked record is there in the incident's own tenant, or in the provider's tenant it
    --    names (entity_tenant_id, 068) (its kinds are incident_entity_kind, each a table of that
    --    name), when it is set or changed: a linked candidate market cell may be deleted later.
    --    Another tenant's record and an unknown id get the same refusal.
    IF NEW.entity_type IS NOT NULL AND (
        TG_OP = 'INSERT'
        OR NEW.entity_type IS DISTINCT FROM OLD.entity_type
        OR NEW.entity_id IS DISTINCT FROM OLD.entity_id
        OR NEW.entity_tenant_id IS DISTINCT FROM OLD.entity_tenant_id
    ) THEN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE id = $1 AND tenant_id = $2)', NEW.entity_type::TEXT)
        INTO linked
        USING NEW.entity_id, coalesce(NEW.entity_tenant_id, NEW.tenant_id);
        IF NOT linked THEN
            RAISE EXCEPTION 'incident_entity_invalid' USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- Lowering an s1 or s2 (the enum orders s1 < s2 < s3) needs the management right, so a
    -- downgrade does not get around the management notice or the s1 closure.
    IF TG_OP = 'UPDATE' AND OLD.severity IN ('s1', 's2') AND NEW.severity > OLD.severity
       AND coalesce(cardinality(
           private.tenants_permitting(auth.uid(), ARRAY[NEW.tenant_id], 'public.tenant', 'update')
       ), 0) = 0 THEN
        RAISE EXCEPTION 'incident_severity_downgrade_requires_management' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
        -- 4. open → contained | closed; contained → closed; closed is final.
        IF NOT (OLD.status = 'open' AND NEW.status IN ('contained', 'closed')
                OR OLD.status = 'contained' AND NEW.status = 'closed') THEN
            RAISE EXCEPTION 'incident_status_order' USING ERRCODE = 'check_violation';
        END IF;

        -- 5. An s1 or s2 leaves open only once management was told.
        IF OLD.status = 'open' AND NEW.severity IN ('s1', 's2') AND NEW.management_notified_at IS NULL THEN
            RAISE EXCEPTION 'incident_management_notice_required' USING ERRCODE = 'check_violation';
        END IF;

        -- 6. Closing: the outcome, the root cause and the preventive action; management closes an s1.
        IF NEW.status = 'closed' THEN
            IF NEW.outcome IS NULL OR NEW.root_cause IS NULL OR nullif(btrim(NEW.preventive_action), '') IS NULL THEN
                RAISE EXCEPTION 'incident_closure_incomplete' USING ERRCODE = 'check_violation';
            END IF;
            IF NEW.severity = 's1' AND coalesce(cardinality(
                private.tenants_permitting(auth.uid(), ARRAY[NEW.tenant_id], 'public.tenant', 'update')
            ), 0) = 0 THEN
                RAISE EXCEPTION 'incident_close_management' USING ERRCODE = 'insufficient_privilege';
            END IF;
            NEW.closed_on := current_date;
            NEW.closed_by := auth.uid();
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.incident_guard () FROM PUBLIC, anon, authenticated;

-- The new columns are catalog fields (049 completeness, F10), open; the api views gain them.
INSERT INTO
   public.field_class (resource_name, field, class)
VALUES
   ('public.incident', 'entity_tenant_id', 'open'),
   ('public.change_request', 'purchase_order_id', 'open'),
   ('public.change_request', 'order_tenant_id', 'open'),
   ('public.change_request', 'guard_tenant_id', 'open');

SELECT private.enable_field_security (t)
FROM unnest(ARRAY['incident', 'change_request']) AS t;

-- ====================================================================================== 2. guarded
--
-- Section 2, provider-guarded cost (Task 6). The cost of a change request on a provider's order is
-- the provider's (spec, "Calls made"): change_request.cost_impact and cost_payer become sensitive
-- (group cost) with rights_column guard_tenant_id, so they are read and written under the rights of
-- coalesce(order_tenant_id, tenant_id): the provider's for a provider order, the row's own otherwise.
-- A client right on the cost (an owner's, or one granted through save_role) never reaches them on a
-- provider order. incident.affected_parties stays as it is (F6).
--
-- The rights tenant cannot be escaped:
--   private.change_request_order_tenant (trigger a0_change_request_order_tenant, before
--   aa_field_write_guard) settles order_tenant_id before any guard reads it:
--     no order          none on INSERT; kept on UPDATE (an unlink, or the order deleted (F7): history)
--     omitted           the order's tenant when the order is the row's own or shared with it, else
--                       the row's own (F8; the foreign key then refuses a foreign id). So a client
--                       that leaves the order tenant out of a provider order still writes under the
--                       provider's rights.
--     order_tenant_immutable (23514)  a set order tenant never changes. The order's delete only empties
--                       purchase_order_id (ON DELETE SET NULL (purchase_order_id)), so that path
--                       keeps it too.
--   private.provider_order_link_guard (section 1) adds, for a change request whose guard_tenant_id is
--   not its tenant_id, on an UPDATE that changes the order:
--     cost_link_forbidden (42501)  the caller may not write the cost in OLD.guard_tenant_id
--                       (private.field_write_tenants). Not on a system path (field_guard_bypassed) nor
--                       when the order is gone (F7).
--   The forwarder and the write guard (067) check OLD and NEW rights tenants from base columns (F1).
--
-- The audit trail: private.rights_columns_map() is {"<table>": {"<field>": "<rights column>"}} from
-- field_class; private.mask_audit_data takes it (p_rcols) and reads a field's rights tenant from the
-- snapshot's rights column, from p_row (the row's new_data: an UPDATE's old_data holds only the changed
-- keys) when the snapshot lacks it, else the row's tenant (a snapshot older than the column). It
-- replaces the five-argument version. api.audit_log's m gains rcols.
--
-- Restated (F12, pinned in 052_guard_restatements.test.sql): api_column_expr and api_view_from (067's
-- bodies) and mask_audit_data (059's), each plus only this delta. Field security is re-run for
-- change_request and for the read-only audit_log (F9).

UPDATE public.field_class
SET
   class = 'sensitive',
   group_name = 'cost',
   rights_column = 'guard_tenant_id'
WHERE
   resource_name = 'public.change_request'
   AND field IN ('cost_impact', 'cost_payer');

-- R1 (049): no role loses what it had. The built-in profiles get their cost defaults
-- (private.field_default), any other tenant role the two fields as its change request rights reach
-- them (read with select, write with insert or update; as private.grant_all_fields). A row already
-- there is kept.
INSERT INTO
   public.role_field_permission (role_id, resource_name, field, can_read, can_write)
SELECT
   r.id,
   f.resource_name,
   f.field,
   d.can_read,
   d.can_write
FROM
   public.role r
   JOIN private.field_default d ON d.profile = r.display_name
   AND d.group_name = 'cost'
   JOIN public.field_class f ON f.resource_name = 'public.change_request'
   AND f.field IN ('cost_impact', 'cost_payer')
WHERE
   r.tenant_id IS NOT NULL
   AND r.display_name IN ('management', 'coordinator')
ON CONFLICT (role_id, resource_name, field) DO NOTHING;

INSERT INTO
   public.role_field_permission (role_id, resource_name, field, can_read, can_write)
SELECT
   r.id,
   f.resource_name,
   f.field,
   h.can_read,
   h.can_read AND h.can_write
FROM
   public.role r
   JOIN public.field_class f ON f.resource_name = 'public.change_request'
   AND f.field IN ('cost_impact', 'cost_payer')
   CROSS JOIN LATERAL (
      SELECT
         coalesce(bool_or(p.command = 'select'), FALSE) AS can_read,
         coalesce(bool_or(p.command IN ('insert', 'update')), FALSE) AS can_write
      FROM
         public.role_permission rp
         JOIN public.permission p ON p.id = rp.permission_id
      WHERE
         rp.role_id = r.id
         AND p.resource_name = 'public.change_request'
   ) h
WHERE
   r.tenant_id IS NOT NULL
   AND r.display_name NOT IN ('management', 'coordinator')
   AND h.can_read
ON CONFLICT (role_id, resource_name, field) DO NOTHING;

-- {"<table>": {"<field>": "<rights column>"}}: every field read under another column's tenant.
CREATE OR REPLACE FUNCTION private.rights_columns_map () RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    RETURN coalesce((
        SELECT jsonb_object_agg(x.tbl, x.fields)
        FROM (
            SELECT split_part(f.resource_name, '.', 2) AS tbl, jsonb_object_agg(f.field, f.rights_column) AS fields
            FROM public.field_class f
            WHERE f.rights_column IS NOT NULL
            GROUP BY 1
        ) x
    ), '{}'::JSONB);
END;
$$;

REVOKE ALL ON FUNCTION private.rights_columns_map () FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION private.rights_columns_map () TO authenticated;

-- 059's mask_audit_data; 068: a field with a rights column is read under the tenant that column names
-- in the snapshot (or in p_row), not the row's tenant.
CREATE OR REPLACE FUNCTION private.mask_audit_data (
   p_table TEXT,
   p_tenant UUID,
   p_data JSONB,
   p_readable JSONB,
   p_sensitive JSONB,
   p_rcols JSONB,
   p_row JSONB DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    hidden TEXT[];
    result JSONB;
BEGIN
    IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' THEN
        RETURN p_data;
    END IF;
    hidden := ARRAY(
        SELECT f.field
        FROM jsonb_array_elements_text(coalesce(p_sensitive -> p_table, '[]'::JSONB)) AS f (field)
        -- 068: the rights tenant of the field.
        CROSS JOIN LATERAL (
            SELECT coalesce(p_data ->> rc.name, p_row ->> rc.name, p_tenant::TEXT) AS tenant
            FROM (SELECT (p_rcols -> p_table) ->> f.field AS name) rc
        ) r
        WHERE p_tenant IS NULL
           OR NOT coalesce((p_readable -> r.tenant) ? (p_table || '.' || f.field), FALSE)
    );
    result := coalesce((
        SELECT jsonb_object_agg(e.key, CASE WHEN e.key = ANY (hidden) THEN '{"masked": true}'::JSONB ELSE e.value END)
        FROM jsonb_each(p_data) AS e
    ), '{}'::JSONB);
    RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION private.mask_audit_data (TEXT, UUID, JSONB, JSONB, JSONB, JSONB, JSONB) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION private.mask_audit_data (TEXT, UUID, JSONB, JSONB, JSONB, JSONB, JSONB) TO authenticated;

-- R8 (059): the masking definers are owned by api_owner.
GRANT CREATE ON SCHEMA private TO api_owner;

ALTER FUNCTION private.mask_audit_data (TEXT, UUID, JSONB, JSONB, JSONB, JSONB, JSONB) OWNER TO api_owner;

REVOKE CREATE ON SCHEMA private FROM api_owner;

-- 067's api_column_expr; 068: the audit snapshots' mask takes the rights columns and new_data.
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
            -- 068: a field's rights tenant is its rights column in the snapshot (in new_data when the
            -- old_data of an update holds only the changed keys).
            RETURN format('private.mask_audit_data(t.table_name, t.tenant_id, t.%1$I, m.rights, m.sensitive, m.rcols, t.new_data) AS %1$I', p_column);
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

-- 067's api_view_from; 068: audit_log's m gains the rights columns map.
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
    -- 067: the request's tenant scope, once per view, for the open provider-only columns.
    IF private.is_shared_table(p_table) THEN
        entries := entries || $e$(SELECT coalesce(private.tenant_scope(), '{}')) AS s$e$::TEXT;
    END IF;
    -- 068: the rights columns, for the audit snapshots' masking.
    IF p_table = 'audit_log' THEN
        entries := entries || '(SELECT private.rights_columns_map()) AS rcols'::TEXT;
    END IF;
    IF cardinality(entries) = 0 THEN
        RETURN format('%s t', base);
    END IF;
    RETURN format('%s t CROSS JOIN (%sSELECT %s OFFSET 0) m', base, rights, array_to_string(entries, ', '));
END;
$$;

REVOKE ALL ON FUNCTION private.api_view_from (TEXT) FROM PUBLIC, anon, authenticated;

-- The order tenant, settled before the write guard reads the rights tenant (see the header).
CREATE OR REPLACE FUNCTION private.change_request_order_tenant () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF NEW.purchase_order_id IS NULL THEN
        NEW.order_tenant_id := CASE WHEN TG_OP = 'UPDATE' THEN OLD.order_tenant_id END;
    ELSIF NEW.order_tenant_id IS NULL THEN
        NEW.order_tenant_id := coalesce(
            (SELECT po.tenant_id FROM public.purchase_order po
             WHERE po.id = NEW.purchase_order_id
               AND (po.tenant_id = NEW.tenant_id OR po.client_tenant_id = NEW.tenant_id)),
            NEW.tenant_id
        );
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.order_tenant_id IS NOT NULL AND NEW.order_tenant_id IS DISTINCT FROM OLD.order_tenant_id THEN
        RAISE EXCEPTION 'order_tenant_immutable' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.change_request_order_tenant () FROM PUBLIC, anon, authenticated;

-- a0 sorts before aa_field_write_guard (BEFORE triggers fire in name order).
CREATE OR REPLACE TRIGGER a0_change_request_order_tenant BEFORE INSERT
OR
UPDATE ON public.change_request FOR EACH ROW
EXECUTE FUNCTION private.change_request_order_tenant ();

-- The views and the guards over the new classes (F9: the audit trail stays read-only), then the old
-- mask, which nothing calls any more.
SELECT private.enable_field_security ('change_request');

SELECT private.enable_field_security ('audit_log', TRUE);

DROP FUNCTION private.mask_audit_data (TEXT, UUID, JSONB, JSONB, JSONB);
