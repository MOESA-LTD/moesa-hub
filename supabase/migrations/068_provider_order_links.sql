-- 068: provider order links (Plan 2). A client's incident or change request may cite a provider's
-- order or shipment shared with it.
--
-- Section 1, links (Task 5). Section 2, provider-guarded cost (Task 6, its own header below; it adds
-- cost_link_forbidden to provider_order_link_guard here). Section 3, provider-guarded incident cost and
-- the revert's rights tenant (Task 6 fix round 1; it adds incident_entity_tenant_immutable here).
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

    -- Section 3: a set incident entity tenant never changes, so its logs' cost stays under the
    -- provider's rights (no unlink, no relink to an own record).
    IF by_kind AND TG_OP = 'UPDATE' AND (old_row ->> tenant_column) IS NOT NULL
       AND target_tenant IS DISTINCT FROM (old_row ->> tenant_column)::UUID THEN
        RAISE EXCEPTION 'incident_entity_tenant_immutable' USING ERRCODE = 'check_violation';
    END IF;

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

-- 058's incident_overview; 068: a provider link's label (the order's or shipment's code, client-visible)
-- is looked up in coalesce(entity_tenant_id, tenant_id), through the masked api views.
CREATE OR REPLACE VIEW api.incident_overview WITH (security_invoker = true) AS
SELECT i.id,
    i.tenant_id,
    i.code,
    i.family,
    i.incident_type,
    i.severity,
    i.status,
    i.owner_id,
    i.title,
    i.what_happened,
    i.reported_by,
    i.current_state,
    i.immediate_action,
    i.entity_type,
    i.entity_id,
    i.opened_at,
    i.affected_parties,
    i.management_notified_at,
    i.customer_notice_due_at,
    i.customer_notified_at,
    i.outcome,
    i.root_cause,
    i.root_cause_note,
    i.impact_note,
    i.lessons,
    i.preventive_action,
    i.customer_closure_notified_on,
    i.closed_on,
    i.closed_by,
    i.created_at,
    i.updated_at,
    CASE i.entity_type
        WHEN 'project'::public.document_entity THEN pj.code
        WHEN 'purchase_order'::public.document_entity THEN po.code
        WHEN 'shipment'::public.document_entity THEN s.code
        WHEN 'product'::public.document_entity THEN pr.sku
        WHEN 'market_cell'::public.document_entity THEN (((mp.sku || ' · '::TEXT) || m.platform_id) || '_'::TEXT) || m.country
        ELSE NULL::TEXT
    END AS entity_label,
    d.next_deadline_at,
    d.overdue_deadline_count,
    (EXISTS (
        SELECT 1
        FROM api.incident r
        WHERE r.tenant_id = i.tenant_id AND r.incident_type = i.incident_type AND r.id <> i.id
          AND r.opened_at < i.opened_at AND r.opened_at >= (i.opened_at - '90 days'::INTERVAL)
    )) AS is_repeat
FROM api.incident i
LEFT JOIN api.project pj ON i.entity_type = 'project'::public.document_entity AND pj.id = i.entity_id AND pj.tenant_id = i.tenant_id
LEFT JOIN api.purchase_order po ON i.entity_type = 'purchase_order'::public.document_entity AND po.id = i.entity_id AND po.tenant_id = coalesce(i.entity_tenant_id, i.tenant_id)
LEFT JOIN api.shipment s ON i.entity_type = 'shipment'::public.document_entity AND s.id = i.entity_id AND s.tenant_id = coalesce(i.entity_tenant_id, i.tenant_id)
LEFT JOIN api.product pr ON i.entity_type = 'product'::public.document_entity AND pr.id = i.entity_id AND pr.tenant_id = i.tenant_id
LEFT JOIN api.market_cell m ON i.entity_type = 'market_cell'::public.document_entity AND m.id = i.entity_id AND m.tenant_id = i.tenant_id
LEFT JOIN api.product mp ON mp.id = m.product_id AND mp.tenant_id = m.tenant_id
LEFT JOIN LATERAL (
    SELECT min(dl.due_at) AS next_deadline_at,
        count(*) FILTER (WHERE dl.due_at < now())::INTEGER AS overdue_deadline_count
    FROM api.incident_deadline dl
    WHERE dl.incident_id = i.id AND dl.tenant_id = i.tenant_id AND dl.met_at IS NULL
) d ON TRUE;

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
    -- 067: the tenants of the request's scope where the user may select the table, once per view,
    -- for the open provider-only columns.
    IF private.is_shared_table(p_table) THEN
        entries := entries || format($e$(SELECT coalesce(private.permitted_tenants(%L, 'select'), '{}')) AS s$e$, resource);
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

-- ===================================================================================== 3. incident
--
-- Section 3, provider-guarded incident cost and the revert (Task 6, fix round 1). The spec's "Calls
-- made": an incident's cost amount and cost payer are the provider's when the incident is about a
-- provider's order or shipment. incident_log.cost_amount, cost_currency and cost_payer keep their
-- class and group (sensitive, finance, 049) and gain the rights column guard_tenant_id:
--   incident_log.guard_tenant_id  coalesce(incident.entity_tenant_id, incident.tenant_id) of the log's
--                                 incident. A generated column cannot read the parent, so it is kept
--                                 by triggers and never taken from the writer (nullable only so a
--                                 writer need not send it; the trigger always sets it, and a NULL would
--                                 mask and refuse, fail closed):
--   private.incident_log_guard_tenant (trigger a0_incident_log_guard_tenant, before
--                                 aa_field_write_guard) sets it from the parent on every insert and
--                                 update. A log whose cost is its provider's (OLD.guard_tenant_id <>
--                                 tenant_id) leaves those rights (another incident) only with the right
--                                 to write the cost there: cost_link_forbidden (42501); not on a
--                                 system path.
--   private.incident_guard_tenant_sync (trigger incident_guard_tenant_sync, AFTER UPDATE of an
--                                 incident whose entity_tenant_id changed) sets its logs' value. The
--                                 logs' rules still apply (a closed incident's logs refuse it:
--                                 incident_closed, so a closed incident with logs is not relinked).
--   incident_entity_tenant_immutable (23514, provider_order_link_guard, section 1)
--                                 a set entity_tenant_id never changes (an own-tenant link is stored
--                                 as NULL, so citing a provider's record later only narrows): no
--                                 unlink or relink out of the provider's rights. Like order_tenant_id.
--   private.api_forward (067's body, restated, pinned in 052) cannot read such a column from the row it
--                                 forwards, so it leaves a field with one to the base write guard
--                                 (aa_, after a0_ has set the column).
-- No right is lost by the classification (the three fields were sensitive already), so no backfill.
--
-- public.revert_audit_transaction (059's body, restated, pinned in 052): its pre-check reads a
-- sensitive key's rights tenant from the field's rights column in the stored row (the snapshots when
-- the row is gone or out of the caller's reach), the row's tenant otherwise, so a client undoing the
-- provider's change of a guarded field gets audit_revert_field_forbidden before anything is written.

ALTER TABLE public.incident_log
ADD COLUMN guard_tenant_id UUID;

UPDATE public.incident_log l
SET
   guard_tenant_id = coalesce(i.entity_tenant_id, i.tenant_id)
FROM
   public.incident i
WHERE
   i.id = l.incident_id
   AND i.tenant_id = l.tenant_id;

CREATE OR REPLACE FUNCTION private.incident_log_guard_tenant () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    -- The parent's; a missing parent is refused by the foreign key.
    NEW.guard_tenant_id := coalesce(
        (SELECT coalesce(i.entity_tenant_id, i.tenant_id) FROM public.incident i
         WHERE i.id = NEW.incident_id AND i.tenant_id = NEW.tenant_id),
        NEW.tenant_id
    );
    IF TG_OP = 'UPDATE'
       AND NEW.guard_tenant_id IS DISTINCT FROM OLD.guard_tenant_id
       AND OLD.guard_tenant_id <> OLD.tenant_id
       AND NOT private.field_guard_bypassed()
       AND NOT coalesce(OLD.guard_tenant_id = ANY (private.field_write_tenants('public.incident_log', 'cost_amount')), FALSE) THEN
        RAISE EXCEPTION 'cost_link_forbidden' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.incident_log_guard_tenant () FROM PUBLIC, anon, authenticated;

-- a0 sorts before aa_field_write_guard (BEFORE triggers fire in name order).
CREATE OR REPLACE TRIGGER a0_incident_log_guard_tenant BEFORE INSERT
OR
UPDATE ON public.incident_log FOR EACH ROW
EXECUTE FUNCTION private.incident_log_guard_tenant ();

CREATE OR REPLACE FUNCTION private.incident_guard_tenant_sync () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    UPDATE public.incident_log l
    SET guard_tenant_id = coalesce(NEW.entity_tenant_id, NEW.tenant_id)
    WHERE l.incident_id = NEW.id AND l.tenant_id = NEW.tenant_id;
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION private.incident_guard_tenant_sync () FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER incident_guard_tenant_sync
AFTER
UPDATE ON public.incident FOR EACH ROW WHEN (OLD.entity_tenant_id IS DISTINCT FROM NEW.entity_tenant_id)
EXECUTE FUNCTION private.incident_guard_tenant_sync ();

-- 067's api_forward; 068: a rights column kept by triggers is left to the base write guard.
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
                -- 068: a rights column neither tenant_id nor generated is kept by the table's triggers
                -- from other rows (incident_log.guard_tenant_id, from its incident): this row cannot
                -- show it, so the base write guard decides, after those triggers have set it.
                IF rc <> 'tenant_id' AND rc_expr IS NULL THEN
                    cols := cols || col.name;
                    CONTINUE;
                END IF;
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

GRANT CREATE ON SCHEMA private TO api_owner;

ALTER FUNCTION private.api_forward () OWNER TO api_owner;

REVOKE CREATE ON SCHEMA private FROM api_owner;

INSERT INTO
   public.field_class (resource_name, field, class)
VALUES
   ('public.incident_log', 'guard_tenant_id', 'open');

UPDATE public.field_class
SET
   rights_column = 'guard_tenant_id'
WHERE
   resource_name = 'public.incident_log'
   AND field IN ('cost_amount', 'cost_currency', 'cost_payer');

SELECT private.enable_field_security ('incident_log');

-- 059's revert_audit_transaction; 068: a sensitive key is checked in its rights tenant.
CREATE OR REPLACE FUNCTION public.revert_audit_transaction (transaction_id UUID) RETURNS TEXT[] LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    target public.audit_transaction;
    change public.audit_log;
    pending BIGINT[];
    waiting BIGINT[];
    change_id BIGINT;
    relation REGCLASS;
    columns TEXT;
    row_columns TEXT;
    affected INT;
    blocked TEXT;
    forbidden TEXT;
    chk RECORD;
    api_view REGCLASS;
    -- 068
    rights_column TEXT;
    rights_tenant UUID;
BEGIN
    SELECT * INTO target FROM public.audit_transaction t WHERE t.id = revert_audit_transaction.transaction_id;

    IF NOT FOUND THEN
        RAISE SQLSTATE 'PGRST' USING
            MESSAGE = json_build_object('code', 'P0002', 'message', 'audit transaction not found')::TEXT,
            DETAIL = json_build_object('status', 404, 'headers', json_build_object())::TEXT;
    END IF;

    IF target.reverted_at IS NOT NULL THEN
        RAISE SQLSTATE 'PGRST' USING
            MESSAGE = json_build_object('code', 'P0001', 'message', 'audit_already_reverted')::TEXT,
            DETAIL = json_build_object('status', 409, 'headers', json_build_object())::TEXT;
    END IF;

    -- Before anything is written, every change the revert makes must be one the caller could make
    -- through the api: an UPDATE writes back the keys of old_data (UPDATE rows hold only the changed
    -- ones), an INSERT is undone by a delete, a DELETE by inserting its non-NULL values again.
    --   Grants: the column UPDATE/INSERT or table DELETE authenticated holds on api.<table> (they
    --   mirror its base grants and stay after the cutover); no api view, nothing is granted.
    --   C3: a sensitive key must be writable by the caller in the row's tenant (system paths pass, S2).
    FOR chk IN
        SELECT l.table_schema, l.table_name, l.operation, l.tenant_id, k.key, l.record_id, l.old_data, l.new_data,
               coalesce(a.attgenerated = '', FALSE) AS stored
        FROM public.audit_log l
        LEFT JOIN LATERAL (
            SELECT e.key FROM jsonb_each(CASE WHEN l.operation = 'INSERT' THEN l.new_data ELSE l.old_data END) AS e (key, value)
            WHERE l.operation = 'UPDATE' OR e.value <> 'null'::JSONB
        ) AS k ON TRUE
        LEFT JOIN pg_catalog.pg_attribute a
          ON a.attrelid = to_regclass(format('%I.%I', l.table_schema, l.table_name)) AND a.attname = k.key
         AND a.attnum > 0 AND NOT a.attisdropped
        WHERE l.transaction_id = target.id AND l.created_at = target.created_at
        ORDER BY l.id, k.key
    LOOP
        api_view := CASE WHEN chk.table_schema = 'public' THEN to_regclass(format('api.%I', chk.table_name)) END;
        IF api_view IS NULL
           OR (chk.operation = 'INSERT' AND NOT has_table_privilege('authenticated', api_view, 'DELETE')) THEN
            forbidden := chk.table_name;
        ELSIF chk.key IS NULL THEN
            CONTINUE;
        ELSIF chk.stored AND chk.operation = 'UPDATE' AND NOT has_column_privilege('authenticated', api_view, chk.key, 'UPDATE') THEN
            forbidden := chk.table_name || '.' || chk.key;
        ELSIF chk.stored AND chk.operation = 'DELETE' AND NOT has_column_privilege('authenticated', api_view, chk.key, 'INSERT') THEN
            forbidden := chk.table_name || '.' || chk.key;
        ELSIF NOT private.field_guard_bypassed()
              AND private.api_is_sensitive(chk.table_schema || '.' || chk.table_name, chk.key) THEN
            -- 068: in the field's rights tenant: its rights column in the stored row (the snapshots when
            -- the row is gone or out of reach), the row's tenant when the catalog names no other.
            rights_column := private.field_rights_column(chk.table_schema || '.' || chk.table_name, chk.key);
            rights_tenant := NULL;
            IF rights_column <> 'tenant_id' THEN
                EXECUTE format('SELECT (to_jsonb(t) ->> %L)::UUID FROM %I.%I t WHERE t.id = $1', rights_column, chk.table_schema, chk.table_name)
                INTO rights_tenant USING chk.record_id;
                rights_tenant := coalesce(rights_tenant, (chk.new_data ->> rights_column)::UUID, (chk.old_data ->> rights_column)::UUID);
            END IF;
            IF NOT coalesce(coalesce(rights_tenant, chk.tenant_id) = ANY (private.field_write_tenants(chk.table_schema || '.' || chk.table_name, chk.key)), FALSE) THEN
                forbidden := chk.table_name || '.' || chk.key;
            END IF;
        END IF;
        IF forbidden IS NOT NULL THEN
            RAISE EXCEPTION 'audit_revert_field_forbidden' USING ERRCODE = '42501', DETAIL = forbidden;
        END IF;
    END LOOP;

    -- Read by private.audit_begin when this transaction's first write is logged.
    PERFORM set_config('audit.reverts', target.id::TEXT, true);

    pending := ARRAY(
        SELECT l.id FROM public.audit_log l
        WHERE l.transaction_id = target.id AND l.created_at = target.created_at
        ORDER BY l.id DESC
    );

    WHILE cardinality(pending) > 0 LOOP
        waiting := '{}';

        FOREACH change_id IN ARRAY pending LOOP
            SELECT * INTO change FROM public.audit_log l WHERE l.id = change_id AND l.created_at = target.created_at;
            relation := format('%I.%I', change.table_schema, change.table_name)::REGCLASS;

            -- The columns to write back, without generated ones.
            SELECT string_agg(format('%I', a.attname), ', '), string_agg(format('r.%I', a.attname), ', ')
            INTO columns, row_columns
            FROM jsonb_object_keys(coalesce(change.old_data, '{}')) AS k (name)
            JOIN pg_catalog.pg_attribute a ON a.attrelid = relation AND a.attname = k.name
            WHERE a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = '';

            BEGIN
                CASE change.operation
                    WHEN 'INSERT' THEN
                        EXECUTE format('DELETE FROM %s t WHERE t.id = $1 AND to_jsonb(t) = $2', relation)
                        USING change.record_id, change.new_data;
                        GET DIAGNOSTICS affected = ROW_COUNT;

                        -- Already gone (a cascade of this revert, or deleted since) is what undoing
                        -- an insert asks for; only a row that was changed since is a conflict.
                        IF affected = 0 THEN
                            EXECUTE format('SELECT count(*) FROM %s t WHERE t.id = $1', relation)
                            INTO affected USING change.record_id;
                            affected := 1 - affected;
                        END IF;
                    WHEN 'UPDATE' THEN
                        EXECUTE format(
                            'UPDATE %s t SET (%s) = (SELECT %s FROM jsonb_populate_record(NULL::%s, $1) r) '
                            'WHERE t.id = $2 AND NOT EXISTS ('
                            '  SELECT 1 FROM jsonb_object_keys($1) k WHERE to_jsonb(t) -> k IS DISTINCT FROM $3 -> k)',
                            relation, columns, row_columns, relation
                        )
                        USING change.old_data, change.record_id, change.new_data;
                        GET DIAGNOSTICS affected = ROW_COUNT;
                    WHEN 'DELETE' THEN
                        EXECUTE format(
                            'INSERT INTO %s (%s) SELECT %s FROM jsonb_populate_record(NULL::%s, $1) r',
                            relation, columns, row_columns, relation
                        )
                        USING change.old_data;
                        GET DIAGNOSTICS affected = ROW_COUNT;
                END CASE;
            EXCEPTION
                WHEN foreign_key_violation THEN
                    waiting := waiting || change_id;
                    blocked := SQLERRM;
                    CONTINUE;
                -- A deleted row that was created again.
                WHEN unique_violation THEN
                    affected := 0;
                -- A row the table refuses: a conflict, without the DETAIL (it would show the row's values,
                -- read with api_owner's rights).
                WHEN check_violation OR not_null_violation OR exclusion_violation THEN
                    RAISE SQLSTATE 'PGRST' USING
                        MESSAGE = json_build_object('code', 'P0001', 'message', 'audit_conflict')::TEXT,
                        DETAIL = json_build_object('status', 409, 'headers', json_build_object())::TEXT;
            END;

            IF affected = 0 THEN
                RAISE SQLSTATE 'PGRST' USING
                    MESSAGE = json_build_object(
                        'code', 'P0001',
                        'message', 'audit_conflict',
                        'details', format('%s %s was changed after this change', change.table_name, change.record_id)
                    )::TEXT,
                    DETAIL = json_build_object('status', 409, 'headers', json_build_object())::TEXT;
            END IF;
        END LOOP;

        -- Nothing moved: the rows they refer to are gone for good.
        IF cardinality(waiting) = cardinality(pending) THEN
            RAISE SQLSTATE 'PGRST' USING
                MESSAGE = json_build_object('code', 'P0001', 'message', 'audit_conflict', 'details', blocked)::TEXT,
                DETAIL = json_build_object('status', 409, 'headers', json_build_object())::TEXT;
        END IF;
        pending := waiting;
    END LOOP;

    RETURN ARRAY(
        SELECT DISTINCT l.table_name FROM public.audit_log l
        WHERE l.transaction_id = target.id AND l.created_at = target.created_at
    );
END;
$$;

GRANT CREATE ON SCHEMA public TO api_owner;

ALTER FUNCTION public.revert_audit_transaction (UUID) OWNER TO api_owner;

REVOKE CREATE ON SCHEMA public FROM api_owner;

REVOKE ALL ON FUNCTION public.revert_audit_transaction (UUID) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.revert_audit_transaction (UUID) TO authenticated, service_role;
