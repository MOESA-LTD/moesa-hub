-- 068: provider order links (Plan 2). A client's incident or change request may cite a provider's
-- order or shipment shared with it.
--
-- Section 1, links (Task 5).
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
