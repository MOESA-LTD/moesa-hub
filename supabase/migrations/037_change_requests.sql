-- Change requests (S08, M10): a change asked of a running product or project, what it changes,
-- what it costs and delays, who decided it and the document it produced.
--
-- change_request          One request of the tenant it lives in (the company the product or project
--                         belongs to). Its code is CR, the tenant's code, the year and the
--                         tenant's next request number (CR-THO-2026-001, private.next_code under
--                         private.code_scope(tenant_id, NULL)), whatever the client sends; the code
--                         never changes. It may name the project, the gate it touches
--                         (affected_gate_code), the document it changes (affected_document_id, a
--                         document of its own tenant) and the other documents it touches (free
--                         text). The kinds of change are those of M10 and S08 §C (spec, design,
--                         packaging, price, deadline, supplier, content); at least one. Change
--                         requests are never deleted.
-- change_request_product  The products the request touches (S08 A), of the request's tenant. They
--                         go with their request (ON DELETE CASCADE).
--
-- Decision due  decision_due_on, recomputed on every write: urgent the day after the request was
--               made (24 hours), normal five business days later (S08 A "Normal (5 iş günü) / Acil
--               (24 saat)"). Business days are Monday to Friday, with no holiday calendar
--               (public.add_business_days); every date is UTC.
-- Status flow   open → approved | rejected; approved → applied; rejected and applied are final.
--               Approving records the company's date and approver (company_approved_on, company_approved_by:
--               today and the caller, whatever the client sends). When the request names a gate of its project that is already passed
--               and needs the customer's approval, approving needs the customer's approval date and
--               written approval (S08 §4): a signed or approved document of this request.
--               Rejecting needs the reason (decision_note). Applying a request that changes a
--               document needs that document's new version (result_document_id: the same record
--               and type, a higher version; M10 "CR applied olunca ilgili belge yeni sürüm alır").
--               Rejecting or applying closes it (closed_on, today); the client never sets it.
--               Once approved, the customer's approval date and document may still be entered,
--               but an entered one no longer changes or clears.
--
-- Each rule is a violation whose message is the rule's code (check_violation unless stated):
--   change_request_scope_missing               the tenant has no code to number the request under
--   change_request_immutable_field             the code or created_at changed, or
--                                              the entered customer's approval of an approved
--                                              request changed or cleared, or the documents,
--                                              project or gate of an applied or rejected request
--                                              changed
--   change_request_document_invalid            the affected or resulting document is not there in
--                                              the request's tenant
--   change_request_approval_document_invalid   the customer's approval is not a signed or approved
--                                              document of this request
--   change_request_status_order                not an allowed transition
--   change_request_customer_approval_required  approving after a passed gate that needs the
--                                              customer's approval, without it
--   change_request_decision_note_required      rejecting without the reason
--   change_request_new_version_required        applying without the changed document's new version
-- and the constraint the UI names: change_request_kinds_required (at least one kind of change).
--
-- Every reference to a tenant-scoped table includes tenant_id, so the project, the products and the
-- documents are the request's own tenant's. Projects, products and documents are not deleted while
-- a request names them (ON DELETE RESTRICT); users are (ON DELETE SET NULL). A provider's order is
-- not linked here (a later sharing step).
--
-- The decision-due trigger runs as the caller and calls no private function. The code trigger is
-- SECURITY DEFINER (private.code_scope is revoked from callers) and gets the code from
-- private.next_code. The guard is SECURITY DEFINER (it reads the documents and the gate whatever the
-- caller may read) and filters on the row's own tenant_id. The guard sorts after the
-- other BEFORE triggers (<table>_z_guard); its immutability rule ignores private.rules_bypassed()
-- (030_purchase_order_rules.sql), the other rules return at once when it holds.
--
-- Roles: the module is granted to every existing role that may change products
-- (private.grant_group_to_product_editors); private.seed_ops_roles gives it to the demo company's
-- roles.

CREATE TYPE public.change_request_status AS ENUM ('open', 'approved', 'rejected', 'applied');

-- S08 A: who asked for the change.
CREATE TYPE public.change_request_source AS ENUM ('customer', 'supplier', 'company', 'regulation');

CREATE TYPE public.change_request_urgency AS ENUM ('normal', 'urgent');

-- M10 and S08 §C (supplier and content).
CREATE TYPE public.change_kind AS ENUM ('spec', 'design', 'packaging', 'price', 'deadline', 'supplier', 'content');

-- Change requests
CREATE TABLE IF NOT EXISTS public.change_request (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   -- Set by the change_request_set_code trigger; whatever the client sends is replaced.
   code TEXT,
   project_id UUID,
   -- Identity (S08 A). decision_due_on is set by the change_request_due trigger.
   title TEXT NOT NULL,
   source public.change_request_source NOT NULL,
   urgency public.change_request_urgency NOT NULL DEFAULT 'normal',
   status public.change_request_status NOT NULL DEFAULT 'open',
   decision_due_on DATE,
   -- What changes (S08 B, C).
   change_kinds public.change_kind[] NOT NULL,
   current_value TEXT NOT NULL,
   requested_value TEXT NOT NULL,
   reason TEXT NOT NULL,
   affected_gate_code public.gate_code,
   affected_document_id UUID,
   other_documents TEXT,
   -- Impact (S08 D).
   cost_impact TEXT,
   cost_payer public.cost_payer,
   delay_days INT CHECK (delay_days >= 0),
   quality_impact TEXT,
   listing_impact TEXT,
   -- Decision (S08 E, F). company_approved_* and closed_on are set by the guard only.
   decision_note TEXT,
   company_approved_by UUID,
   company_approved_on DATE,
   customer_approved_on DATE,
   customer_approval_document_id UUID,
   result_document_id UUID,
   closed_on DATE,
   created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   CONSTRAINT unique_change_request_code UNIQUE (tenant_id, code),
   -- Target of the tenant-scoped foreign keys of the request's child rows.
   CONSTRAINT change_request_id_tenant_id_key UNIQUE (id, tenant_id),
   CONSTRAINT change_request_project_fkey FOREIGN KEY (project_id, tenant_id) REFERENCES public.project (id, tenant_id) ON DELETE RESTRICT,
   CONSTRAINT change_request_affected_document_fkey FOREIGN KEY (affected_document_id, tenant_id) REFERENCES public.document (id, tenant_id) ON DELETE RESTRICT,
   CONSTRAINT change_request_approval_document_fkey FOREIGN KEY (customer_approval_document_id, tenant_id) REFERENCES public.document (id, tenant_id) ON DELETE RESTRICT,
   CONSTRAINT change_request_result_document_fkey FOREIGN KEY (result_document_id, tenant_id) REFERENCES public.document (id, tenant_id) ON DELETE RESTRICT,
   CONSTRAINT change_request_approver_fkey FOREIGN KEY (company_approved_by) REFERENCES public.user (id) ON DELETE SET NULL,
   CONSTRAINT change_request_kinds_required CHECK (cardinality(change_kinds) > 0)
);

CREATE INDEX IF NOT EXISTS idx_change_request_tenant_status ON public.change_request (tenant_id, status);

CREATE INDEX IF NOT EXISTS idx_change_request_project ON public.change_request (tenant_id, project_id);

-- Change requests are rejected or applied, never deleted.
REVOKE DELETE ON public.change_request FROM anon, authenticated;

CREATE OR REPLACE TRIGGER set_updated_at BEFORE
UPDATE ON public.change_request FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at ();

-- The request's code: CR, the tenant's code, the year and the tenant's next request number; and the
-- open status, whatever the client sends. SECURITY DEFINER, as the other code triggers.
CREATE OR REPLACE FUNCTION private.change_request_set_code () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    scope TEXT := private.code_scope(NEW.tenant_id, NULL);
BEGIN
    IF scope IS NULL THEN
        RAISE EXCEPTION 'change_request_scope_missing' USING ERRCODE = 'check_violation';
    END IF;

    NEW.code := private.next_code(NEW.tenant_id, 'cr', scope);
    NEW.status := 'open';
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER change_request_set_code BEFORE INSERT ON public.change_request FOR EACH ROW
EXECUTE FUNCTION private.change_request_set_code ();

-- When the request is to be decided (see the header), on every write, from when it was made (the
-- stored created_at; now on insert, whatever the client sends), in UTC.
CREATE OR REPLACE FUNCTION private.change_request_due () RETURNS TRIGGER LANGUAGE plpgsql
SET
   search_path = '' AS $$
DECLARE
    made_on DATE;
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_at := now();
        made_on := (now() AT TIME ZONE 'UTC')::DATE;
    ELSE
        made_on := (OLD.created_at AT TIME ZONE 'UTC')::DATE;
    END IF;

    NEW.decision_due_on := CASE NEW.urgency
        WHEN 'urgent' THEN made_on + 1
        ELSE public.add_business_days(made_on, 5)
    END;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER change_request_due BEFORE INSERT
OR
UPDATE ON public.change_request FOR EACH ROW
EXECUTE FUNCTION private.change_request_due ();

-- The request's rules (see the header), in this order: the fixed fields (whatever the bypass
-- flag); the server-set columns; the affected and resulting documents; the customer's written approval; the status flow; what
-- approving, rejecting and applying need; closing.
CREATE OR REPLACE FUNCTION private.change_request_guard () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    -- 1. The code and when it was made are fixed; so is the customer's approval
    --    once the request is approved and it is entered (it may still be entered after the company
    --    approves); and a closed (applied or rejected) request keeps its documents, project and
    --    gate.
    IF TG_OP = 'UPDATE' AND (
        NEW.code IS DISTINCT FROM OLD.code
        OR NEW.created_at IS DISTINCT FROM OLD.created_at
        OR OLD.status IN ('approved', 'applied') AND (
            OLD.customer_approved_on IS NOT NULL AND NEW.customer_approved_on IS DISTINCT FROM OLD.customer_approved_on
            OR OLD.customer_approval_document_id IS NOT NULL
               AND NEW.customer_approval_document_id IS DISTINCT FROM OLD.customer_approval_document_id
        )
        OR OLD.status IN ('applied', 'rejected') AND (
            NEW.affected_document_id IS DISTINCT FROM OLD.affected_document_id
            OR NEW.result_document_id IS DISTINCT FROM OLD.result_document_id
            OR NEW.project_id IS DISTINCT FROM OLD.project_id
            OR NEW.affected_gate_code IS DISTINCT FROM OLD.affected_gate_code
        )
    ) THEN
        RAISE EXCEPTION 'change_request_immutable_field' USING ERRCODE = 'check_violation';
    END IF;

    IF private.rules_bypassed() THEN
        RETURN NEW;
    END IF;

    -- Server-set: the company's approval and the closing date are set below on the transition that sets
    -- them; otherwise whatever the client sends is ignored.
    IF TG_OP = 'INSERT' THEN
        NEW.company_approved_on := NULL;
        NEW.company_approved_by := NULL;
        NEW.closed_on := NULL;
    ELSE
        NEW.company_approved_on := OLD.company_approved_on;
        NEW.company_approved_by := OLD.company_approved_by;
        NEW.closed_on := OLD.closed_on;
    END IF;

    -- 2. The affected document and the resulting document are there in the request's own tenant
    --    (a document's record is its tenant's, 016_documents.sql). Another tenant's document and an
    --    unknown id get the same refusal, before the foreign key would name them.
    IF NEW.affected_document_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.document d
        WHERE d.id = NEW.affected_document_id AND d.tenant_id = NEW.tenant_id
    ) OR NEW.result_document_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.document d
        WHERE d.id = NEW.result_document_id AND d.tenant_id = NEW.tenant_id
    ) THEN
        RAISE EXCEPTION 'change_request_document_invalid' USING ERRCODE = 'check_violation';
    END IF;

    -- 3. The customer's written approval is a signed or approved document of this request.
    IF NEW.customer_approval_document_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.document d
        WHERE d.id = NEW.customer_approval_document_id
          AND d.tenant_id = NEW.tenant_id
          AND d.entity_type = 'change_request'
          AND d.entity_id = NEW.id
          AND d.status IN ('signed', 'approved')
    ) THEN
        RAISE EXCEPTION 'change_request_approval_document_invalid' USING ERRCODE = 'check_violation';
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
        -- 4. open → approved | rejected; approved → applied.
        IF NOT (OLD.status = 'open' AND NEW.status IN ('approved', 'rejected')
                OR OLD.status = 'approved' AND NEW.status = 'applied') THEN
            RAISE EXCEPTION 'change_request_status_order' USING ERRCODE = 'check_violation';
        END IF;

        -- 5. Approving: the company's date and approver; the customer's approval after a passed gate of
        --    the project that needs it (S08 §4).
        IF NEW.status = 'approved' THEN
            NEW.company_approved_on := (now() AT TIME ZONE 'UTC')::DATE;
            NEW.company_approved_by := auth.uid();
            IF NEW.project_id IS NOT NULL AND NEW.affected_gate_code IS NOT NULL
               AND EXISTS (
                   SELECT 1 FROM public.project_gate g
                   WHERE g.project_id = NEW.project_id
                     AND g.tenant_id = NEW.tenant_id
                     AND g.code = NEW.affected_gate_code
                     AND g.status = 'passed'
                     AND g.needs_customer_approval
               )
               AND (NEW.customer_approved_on IS NULL OR NEW.customer_approval_document_id IS NULL) THEN
                RAISE EXCEPTION 'change_request_customer_approval_required' USING ERRCODE = 'check_violation';
            END IF;
        END IF;

        -- 6. Rejecting says why.
        IF NEW.status = 'rejected' AND nullif(btrim(NEW.decision_note), '') IS NULL THEN
            RAISE EXCEPTION 'change_request_decision_note_required' USING ERRCODE = 'check_violation';
        END IF;

        -- 7. Applying a request that changes a document needs its new version: the same record and
        --    type, a higher version.
        IF NEW.status = 'applied' AND NEW.affected_document_id IS NOT NULL AND NOT EXISTS (
            SELECT 1
            FROM public.document a
            JOIN public.document r
                ON r.tenant_id = a.tenant_id
               AND r.entity_type = a.entity_type
               AND r.entity_id = a.entity_id
               AND r.type = a.type
               AND r.version > a.version
            WHERE a.id = NEW.affected_document_id
              AND a.tenant_id = NEW.tenant_id
              AND r.id = NEW.result_document_id
        ) THEN
            RAISE EXCEPTION 'change_request_new_version_required' USING ERRCODE = 'check_violation';
        END IF;

        -- 8. Rejecting or applying closes it.
        IF NEW.status IN ('applied', 'rejected') THEN
            NEW.closed_on := (now() AT TIME ZONE 'UTC')::DATE;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- BEFORE triggers fire in name order: the z sorts the guard after change_request_due and
-- change_request_set_code.
CREATE OR REPLACE TRIGGER change_request_z_guard BEFORE INSERT
OR
UPDATE ON public.change_request FOR EACH ROW
EXECUTE FUNCTION private.change_request_guard ();

-- The products a request touches (S08 A), of the request's tenant.
CREATE TABLE IF NOT EXISTS public.change_request_product (
   change_request_id UUID NOT NULL,
   product_id UUID NOT NULL,
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   PRIMARY KEY (change_request_id, product_id),
   CONSTRAINT change_request_product_cr_fkey FOREIGN KEY (change_request_id, tenant_id) REFERENCES public.change_request (id, tenant_id) ON DELETE CASCADE,
   CONSTRAINT change_request_product_product_fkey FOREIGN KEY (product_id, tenant_id) REFERENCES public.product (id, tenant_id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_change_request_product_product ON public.change_request_product (tenant_id, product_id);

REVOKE ALL ON FUNCTION private.change_request_set_code () FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.change_request_due () FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.change_request_guard () FROM PUBLIC, anon, authenticated;

SELECT
   private.enable_tenant_level_security (t_name)
FROM
   unnest(ARRAY['change_request', 'change_request_product']) AS t_name;

SELECT
   private.audit_enable ('public.change_request'::REGCLASS);

SELECT
   private.audit_enable ('public.change_request_product'::REGCLASS);

INSERT INTO
   public.module (id, is_core, position)
VALUES
   ('change_request', FALSE, 210)
ON CONFLICT (id) DO NOTHING;

-- Permissions. Inserting a permission creates its RLS policies (see private.manage_policies). No
-- delete on change requests (rejected or applied instead); a request's products are removed one
-- by one.
INSERT INTO
   public.permission (resource_name, group_name, command, kind, bypass, throws_error, resource_condition)
VALUES
   ('public.change_request', 'change_request', 'select', 'read', FALSE, FALSE, NULL),
   ('public.change_request', 'change_request', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.change_request', 'change_request', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.change_request_product', 'change_request', 'select', 'read', FALSE, FALSE, NULL),
   ('public.change_request_product', 'change_request', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.change_request_product', 'change_request', 'delete', 'modify', FALSE, TRUE, NULL)
ON CONFLICT ON CONSTRAINT unique_permission_resource_command DO NOTHING;

-- The built-in owner role has every permission (see 008_init_reference_data.sql).
INSERT INTO
   public.role_permission (role_id, permission_id)
SELECT
   r.id,
   p.id
FROM
   public.role r,
   public.permission p
WHERE
   r.display_name = 'owner'
   AND r.tenant_id IS NULL
   AND p.resource_name IN ('public.change_request', 'public.change_request_product')
ON CONFLICT DO NOTHING;

-- Every permission of the group to each role that may change products (029_purchase_orders.sql).
SELECT
   private.grant_group_to_product_editors ('change_request');
