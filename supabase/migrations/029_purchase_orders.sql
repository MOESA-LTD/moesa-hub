-- Purchase orders (M6): what the procuring tenant orders from a supplier, for itself or for a client
-- tenant, its lines, payments and production updates.
--
-- purchase_order          One order to one supplier, in the procuring tenant (tenant_id). An order
--                         for a client tenant names it (client_tenant_id, set on insert, never
--                         changed), which needs an active provider-procures relationship of the
--                         pair (018_tenant_relations.sql). The order may name a project of the
--                         tenant it serves: project_tenant_id = coalesce(client_tenant_id,
--                         tenant_id), and project_code keeps the project's code as it was when
--                         linked. Its code (PO-THO-2026-001) comes from public.next_code under
--                         private.code_scope (the tenant's code, or the client_code of the
--                         relationship) and never changes; nor does its supplier. The terms
--                         (currency, Incoterm, deposit rate, ready date, tolerance, penalty, packing
--                         instruction) and the supplier's PI (number, document, amounts, the S09
--                         checklist in pi_check) sit on the order. Orders are cancelled (status),
--                         never deleted.
-- purchase_order_line     The products ordered: quantity × unit price (line_total, computed), and
--                         the PI's own line total, all on the purchase side. A product is on an
--                         order once, and it is a product of the tenant the order serves
--                         (product_tenant_id); the line takes the order's client whatever is sent
--                         (private.inherit_client_tenant). product_sku and product_name keep the
--                         product's identity as it was when linked, so the line stays meaningful
--                         when the client deletes the product (product_id is then set to NULL).
--                         sell_price_eur is the provider's selling price per line, by default the
--                         selling price of the product's sourcing row in the order's tenant.
-- purchase_order_payment  The deposit, the balance and other payments, planned and paid, and who
--                         paid. Never shared with a client tenant (no client column).
-- purchase_order_update   Dated production notes. Production photos go to the order's Media tab
--                         (media_link role evidence_photo). No client column either.
--
-- Defaults (private.purchase_order_defaults, before the code trigger by name): an order without an
-- Incoterm takes the supplier's default_incoterm when it is one of the eleven Incoterms 2020 codes
-- (private.incoterm_valid); one without a deposit rate takes the supplier's, else the company's
-- setting deposit_rate_default (private.company_setting, read on the root tenant), else 30. The
-- deposit is what the procuring tenant pays its supplier, never a client term. The code trigger
-- (private.purchase_order_set_code) sets the code and the draft status.
--
-- The client and the links follow the shared rules of 019_products.sql (client_tenant_immutable,
-- private.client_link_guard, the trigger name order ab_ … ae_): the order's project and the
-- lines' products are links into coalesce(client_tenant_id, tenant_id); a link that becomes NULL
-- because its row is gone (ON DELETE SET NULL) is never refused, by the link guard or by the order
-- rules (030), so the client's delete is not blocked. Every other reference to a tenant-scoped
-- table includes tenant_id. Suppliers and documents are never deleted, so the references to them
-- are ON DELETE RESTRICT; the lines, payments and updates go with their order. An order or line
-- naming a client refers to the pair's relationship, which is not deleted while they name it.
--
-- Each rule is a violation whose message is the rule's code:
--   purchase_order_scope_missing     (check_violation) no code scope: the tenant has no code
--   purchase_order_immutable_field   (check_violation) the order's code or supplier changed
--   client_tenant_immutable, relationship_inactive, client_link_forbidden  (019_products.sql)
-- and the constraints the UI names (errors.<code>):
--   purchase_order_incoterm_valid       incoterm_invalid           not an Incoterms 2020 code
--   purchase_order_pi_check_valid       pi_check_invalid           an unknown S09 item or answer
--   unique_purchase_order_line_product  po_line_product_duplicate  the product is already on it
--
-- public.product_evidence's last_po_code is now the code of the product's newest order that is not
-- cancelled, among the orders the caller may read.
--
-- Roles: the module is granted to every existing role that may change products
-- (private.grant_group_to_product_editors, 027_media_roles.sql made generic); private.seed_ops_roles
-- gives it to the demo company's roles.

CREATE TYPE public.purchase_order_status AS ENUM (
   'draft',
   'sent',
   'pi_received',
   'pi_approved',
   'deposit_paid',
   'in_production',
   'ready',
   'balance_paid',
   'closed',
   'cancelled'
);

CREATE TYPE public.payment_kind AS ENUM ('deposit', 'balance', 'other');

CREATE TYPE public.payment_payer AS ENUM ('company', 'customer');

-- A company's setting: the root tenant's value, NULL when it is missing or JSON null. SECURITY
-- DEFINER: the rules read it whatever settings the caller may read, and branches have no setting
-- rows of their own.
CREATE OR REPLACE FUNCTION private.company_setting (tenant_id UUID, key TEXT) RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    WITH RECURSIVE chain AS (
        SELECT t.id, t.parent_id, 0 AS depth FROM public.tenant t WHERE t.id = company_setting.tenant_id
        UNION ALL
        SELECT t.id, t.parent_id, c.depth + 1
        FROM public.tenant t
        JOIN chain c ON t.id = c.parent_id
        WHERE c.depth < 32
    )
    SELECT nullif(s.value, 'null'::JSONB)
    FROM chain c
    JOIN public.setting s ON s.tenant_id = c.id AND s.key = company_setting.key
    WHERE c.parent_id IS NULL;
$$;

-- The eleven Incoterms 2020 codes (S09 item 12).
CREATE OR REPLACE FUNCTION private.incoterm_valid (code TEXT) RETURNS BOOLEAN LANGUAGE sql IMMUTABLE STRICT
SET
   search_path = '' AS $$
    SELECT incoterm_valid.code IN ('EXW', 'FCA', 'FAS', 'FOB', 'CFR', 'CIF', 'CPT', 'CIP', 'DAP', 'DPU', 'DDP');
$$;

-- The PI checklist (S09): an object whose keys are the item numbers '1'…'30' and whose answers are
-- "ok", "error" or "missing". Unanswered items are simply absent.
CREATE OR REPLACE FUNCTION private.pi_check_valid (p_check JSONB) RETURNS BOOLEAN LANGUAGE sql IMMUTABLE STRICT
SET
   search_path = '' AS $$
    SELECT jsonb_typeof(pi_check_valid.p_check) = 'object'
       AND NOT EXISTS (
            SELECT 1
            FROM jsonb_each(pi_check_valid.p_check) e
            WHERE e.key NOT IN (SELECT g::TEXT FROM generate_series(1, 30) g)
               OR e.value NOT IN ('"ok"'::JSONB, '"error"'::JSONB, '"missing"'::JSONB)
        );
$$;

REVOKE ALL ON FUNCTION private.company_setting (UUID, TEXT) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.incoterm_valid (TEXT) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.pi_check_valid (JSONB) FROM PUBLIC, anon, authenticated;

-- The CHECK constraints call them as the writing user (like private.gtin_valid).
GRANT EXECUTE ON FUNCTION private.incoterm_valid (TEXT) TO authenticated;

GRANT EXECUTE ON FUNCTION private.pi_check_valid (JSONB) TO authenticated;

-- Purchase orders. project_tenant_id is the tenant of the project (coalesce(client_tenant_id,
-- tenant_id)), filled by the link guard.
CREATE TABLE IF NOT EXISTS public.purchase_order (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   client_tenant_id UUID,
   supplier_id UUID NOT NULL,
   project_id UUID,
   project_tenant_id UUID NOT NULL,
   -- The project's code when linked (private.client_link_guard); kept when the project is gone.
   project_code TEXT,
   -- Set by the purchase_order_set_code trigger; whatever the client sends is replaced.
   code TEXT,
   status public.purchase_order_status NOT NULL DEFAULT 'draft',
   -- Terms
   currency valid_currency_code NOT NULL,
   incoterm TEXT NOT NULL,
   incoterm_place TEXT,
   deposit_rate NUMERIC(5, 2) NOT NULL CHECK (deposit_rate BETWEEN 0 AND 100),
   ready_on DATE,
   tolerance_pct NUMERIC(5, 2) CHECK (tolerance_pct BETWEEN 0 AND 100),
   penalty_rule TEXT,
   packing_instruction_document_id UUID,
   -- The supplier's proforma invoice (PI)
   pi_document_id UUID,
   pi_number TEXT,
   pi_subtotal NUMERIC(14, 2),
   pi_total NUMERIC(14, 2),
   pi_deposit_amount NUMERIC(14, 2),
   pi_balance_amount NUMERIC(14, 2),
   pi_extra_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
   pi_discount_amount NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (pi_discount_amount >= 0),
   pi_check JSONB NOT NULL DEFAULT '{}',
   pi_checked_by UUID REFERENCES public.user (id) ON DELETE SET NULL,
   pi_checked_at TIMESTAMPTZ,
   notes TEXT,
   created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   -- The counters behind the codes are per tenant (public.code_sequence), so the code is too.
   CONSTRAINT unique_purchase_order_code UNIQUE (tenant_id, code),
   -- Target of the tenant-scoped foreign keys of the order's child rows (which take the order's
   -- client by trigger).
   CONSTRAINT purchase_order_id_tenant_id_key UNIQUE (id, tenant_id),
   CONSTRAINT purchase_order_not_self CHECK (client_tenant_id IS DISTINCT FROM tenant_id),
   CONSTRAINT purchase_order_project_tenant CHECK (project_tenant_id = coalesce(client_tenant_id, tenant_id)),
   -- A client is named only under a relationship of the pair; the relationship is not deleted while
   -- orders name it.
   CONSTRAINT purchase_order_relationship_fkey FOREIGN KEY (tenant_id, client_tenant_id) REFERENCES public.provider_relationship (tenant_id, client_tenant_id),
   CONSTRAINT purchase_order_supplier_fkey FOREIGN KEY (supplier_id, tenant_id) REFERENCES public.supplier (id, tenant_id) ON DELETE RESTRICT,
   -- MATCH SIMPLE: an order without a project passes. The client's delete is not blocked: the order
   -- keeps project_code.
   CONSTRAINT purchase_order_project_fkey FOREIGN KEY (project_id, project_tenant_id) REFERENCES public.project (id, tenant_id) ON DELETE SET NULL (project_id),
   CONSTRAINT purchase_order_pi_document_fkey FOREIGN KEY (pi_document_id, tenant_id) REFERENCES public.document (id, tenant_id) ON DELETE RESTRICT,
   CONSTRAINT purchase_order_packing_document_fkey FOREIGN KEY (packing_instruction_document_id, tenant_id) REFERENCES public.document (id, tenant_id) ON DELETE RESTRICT,
   CONSTRAINT purchase_order_incoterm_valid CHECK (private.incoterm_valid (incoterm)),
   CONSTRAINT purchase_order_pi_check_valid CHECK (private.pi_check_valid (pi_check))
);

CREATE INDEX IF NOT EXISTS purchase_order_client_idx ON public.purchase_order (client_tenant_id, created_at DESC)
WHERE
   client_tenant_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_purchase_order_supplier ON public.purchase_order (tenant_id, supplier_id);

-- A project's orders, in any tenant (gate evidence, 032), and the project's delete (SET NULL).
CREATE INDEX IF NOT EXISTS idx_purchase_order_project ON public.purchase_order (project_id, project_tenant_id);

CREATE INDEX IF NOT EXISTS idx_purchase_order_tenant_status ON public.purchase_order (tenant_id, status);

-- Purchase orders are cancelled, not deleted.
REVOKE DELETE ON public.purchase_order FROM anon, authenticated;

CREATE OR REPLACE TRIGGER set_updated_at BEFORE
UPDATE ON public.purchase_order FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at ();

-- The order's terms the client left out: the Incoterm from the supplier (only a valid code), the
-- deposit rate from the supplier, else the company's setting deposit_rate_default (a value that is
-- not a number counts as missing), else 30. SECURITY DEFINER: it reads the supplier and the setting
-- whatever the caller may read, in the order's own tenant only.
CREATE OR REPLACE FUNCTION private.purchase_order_defaults () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    supplier_incoterm TEXT;
    supplier_deposit NUMERIC;
    setting_value JSONB;
    company_deposit NUMERIC;
BEGIN
    SELECT s.default_incoterm, s.deposit_rate INTO supplier_incoterm, supplier_deposit
    FROM public.supplier s
    WHERE s.id = NEW.supplier_id AND s.tenant_id = NEW.tenant_id;

    IF NEW.incoterm IS NULL AND private.incoterm_valid(supplier_incoterm) THEN
        NEW.incoterm := supplier_incoterm;
    END IF;

    IF NEW.deposit_rate IS NULL THEN
        IF supplier_deposit IS NULL THEN
            setting_value := private.company_setting(NEW.tenant_id, 'deposit_rate_default');
            IF jsonb_typeof(setting_value) = 'number' THEN
                company_deposit := (setting_value #>> '{}')::NUMERIC;
            ELSIF jsonb_typeof(setting_value) = 'string' AND (setting_value #>> '{}') ~ '^\s*[0-9]+(\.[0-9]+)?\s*$' THEN
                company_deposit := (setting_value #>> '{}')::NUMERIC;
            END IF;
        END IF;
        NEW.deposit_rate := coalesce(supplier_deposit, company_deposit, 30);
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER purchase_order_defaults BEFORE INSERT ON public.purchase_order FOR EACH ROW
EXECUTE FUNCTION private.purchase_order_defaults ();

-- The order's code: PO, the code scope (the tenant's code, or the client_code the provider gave the
-- client), the year and the next number; and the draft status, whatever the client sends. The
-- client's relationship is checked before, by the link guard (ad_client_link_guard sorts first).
-- SECURITY DEFINER, like project_set_code: it calls private.code_scope; it writes only the new row.
CREATE OR REPLACE FUNCTION private.purchase_order_set_code () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    scope TEXT := private.code_scope(NEW.tenant_id, NEW.client_tenant_id);
BEGIN
    IF scope IS NULL THEN
        RAISE EXCEPTION 'purchase_order_scope_missing' USING ERRCODE = 'check_violation';
    END IF;

    NEW.code := public.next_code('po', scope);
    NEW.status := 'draft';
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER purchase_order_set_code BEFORE INSERT ON public.purchase_order FOR EACH ROW
EXECUTE FUNCTION private.purchase_order_set_code ();

-- The code and the supplier the order went to are fixed (the client is fixed by
-- ab_client_tenant_immutable).
CREATE OR REPLACE FUNCTION private.purchase_order_immutable () RETURNS TRIGGER LANGUAGE plpgsql
SET
   search_path = '' AS $$
BEGIN
    IF NEW.code IS DISTINCT FROM OLD.code
       OR NEW.supplier_id IS DISTINCT FROM OLD.supplier_id THEN
        RAISE EXCEPTION 'purchase_order_immutable_field' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER purchase_order_immutable BEFORE
UPDATE ON public.purchase_order FOR EACH ROW
EXECUTE FUNCTION private.purchase_order_immutable ();

-- The shared rules of rows that may name a client (019_products.sql); the names give their order.
CREATE OR REPLACE TRIGGER ab_client_tenant_immutable BEFORE
UPDATE ON public.purchase_order FOR EACH ROW
EXECUTE FUNCTION private.client_tenant_immutable ();

CREATE OR REPLACE TRIGGER ad_client_link_guard BEFORE INSERT
OR
UPDATE ON public.purchase_order FOR EACH ROW
EXECUTE FUNCTION private.client_link_guard ('project_id', 'public.project');

-- Purchase order lines. product_tenant_id is the tenant of the product (coalesce(client_tenant_id,
-- tenant_id)), filled by the link guard.
CREATE TABLE IF NOT EXISTS public.purchase_order_line (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   purchase_order_id UUID NOT NULL,
   -- The order's client, set by ac_inherit_client_tenant whatever is sent.
   client_tenant_id UUID,
   position INT NOT NULL DEFAULT 0,
   product_id UUID,
   product_tenant_id UUID NOT NULL,
   -- The product's identity when linked (private.client_link_guard); kept when the product is gone.
   product_sku TEXT NOT NULL,
   product_name TEXT NOT NULL,
   quantity INT NOT NULL CHECK (quantity > 0),
   unit_price NUMERIC(12, 4) NOT NULL CHECK (unit_price >= 0),
   line_total NUMERIC(16, 4) GENERATED ALWAYS AS (quantity * unit_price) STORED,
   pi_line_total NUMERIC(14, 2),
   -- The provider's selling price of the line (ae_sell_price_default: the sourcing row's by default).
   sell_price_eur NUMERIC(12, 2),
   spec_document_id UUID,
   notes TEXT,
   created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   CONSTRAINT purchase_order_line_id_po_tenant_key UNIQUE (id, purchase_order_id, tenant_id),
   CONSTRAINT unique_purchase_order_line_product UNIQUE (purchase_order_id, product_id),
   CONSTRAINT purchase_order_line_product_tenant CHECK (product_tenant_id = coalesce(client_tenant_id, tenant_id)),
   CONSTRAINT purchase_order_line_po_fkey FOREIGN KEY (purchase_order_id, tenant_id) REFERENCES public.purchase_order (id, tenant_id) ON DELETE CASCADE,
   -- The client's delete of its product is not blocked: the line keeps its snapshot.
   CONSTRAINT purchase_order_line_product_fkey FOREIGN KEY (product_id, product_tenant_id) REFERENCES public.product (id, tenant_id) ON DELETE SET NULL (product_id),
   CONSTRAINT purchase_order_line_relationship_fkey FOREIGN KEY (tenant_id, client_tenant_id) REFERENCES public.provider_relationship (tenant_id, client_tenant_id),
   CONSTRAINT purchase_order_line_spec_fkey FOREIGN KEY (spec_document_id, tenant_id) REFERENCES public.document (id, tenant_id) ON DELETE RESTRICT
);

-- The product's orders (public.product_evidence) and the product's delete (SET NULL).
CREATE INDEX IF NOT EXISTS idx_purchase_order_line_product ON public.purchase_order_line (product_id, product_tenant_id);

CREATE OR REPLACE TRIGGER set_updated_at BEFORE
UPDATE ON public.purchase_order_line FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at ();

-- A child row takes the client of its parent, whatever is sent: TG_ARGV[0] is the parent table,
-- TG_ARGV[1] the child's column holding the parent's id. The parent is read in the child's own
-- tenant; a parent that is not there leaves no client (the foreign key then refuses the row). A
-- table name without a schema is in public. An update that would give the child another client
-- (moving it to a parent of another client) is refused like a client change
-- (client_tenant_immutable). SECURITY DEFINER: it reads the parent whatever the caller may see.
CREATE OR REPLACE FUNCTION private.inherit_client_tenant () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    parent_table CONSTANT TEXT := CASE WHEN strpos(TG_ARGV[0], '.') > 0 THEN TG_ARGV[0] ELSE 'public.' || TG_ARGV[0] END;
    parent_client UUID;
BEGIN
    EXECUTE format('SELECT p.client_tenant_id FROM %s p WHERE p.id = $1 AND p.tenant_id = $2', parent_table)
    INTO parent_client
    USING (to_jsonb(NEW) ->> TG_ARGV[1])::UUID, NEW.tenant_id;

    IF TG_OP = 'UPDATE' AND parent_client IS DISTINCT FROM OLD.client_tenant_id THEN
        RAISE EXCEPTION 'client_tenant_immutable' USING ERRCODE = 'check_violation';
    END IF;

    NEW.client_tenant_id := parent_client;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.inherit_client_tenant () FROM PUBLIC, anon, authenticated;

-- The selling price of a new line, when none is sent: the sourcing row of the order's tenant for
-- the product. SECURITY DEFINER: it reads that row whatever the caller may read, in the line's own
-- tenant only.
CREATE OR REPLACE FUNCTION private.sell_price_default () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF NEW.sell_price_eur IS NULL AND NEW.product_id IS NOT NULL THEN
        SELECT s.sell_price_eur INTO NEW.sell_price_eur
        FROM public.sourcing s
        WHERE s.tenant_id = NEW.tenant_id AND s.product_id = NEW.product_id;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.sell_price_default () FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER ab_client_tenant_immutable BEFORE
UPDATE ON public.purchase_order_line FOR EACH ROW
EXECUTE FUNCTION private.client_tenant_immutable ();

CREATE OR REPLACE TRIGGER ac_inherit_client_tenant BEFORE INSERT
OR
UPDATE ON public.purchase_order_line FOR EACH ROW
EXECUTE FUNCTION private.inherit_client_tenant ('public.purchase_order', 'purchase_order_id');

CREATE OR REPLACE TRIGGER ad_client_link_guard BEFORE INSERT
OR
UPDATE ON public.purchase_order_line FOR EACH ROW
EXECUTE FUNCTION private.client_link_guard ('product_id', 'public.product');

CREATE OR REPLACE TRIGGER ae_sell_price_default BEFORE INSERT ON public.purchase_order_line FOR EACH ROW
EXECUTE FUNCTION private.sell_price_default ();

-- Payments
CREATE TABLE IF NOT EXISTS public.purchase_order_payment (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   purchase_order_id UUID NOT NULL,
   kind public.payment_kind NOT NULL,
   amount NUMERIC(14, 2) NOT NULL CHECK (amount > 0),
   currency valid_currency_code NOT NULL,
   planned_on DATE,
   paid_on DATE,
   paid_by public.payment_payer NOT NULL DEFAULT 'company',
   notes TEXT,
   created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   CONSTRAINT purchase_order_payment_po_fkey FOREIGN KEY (purchase_order_id, tenant_id) REFERENCES public.purchase_order (id, tenant_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_purchase_order_payment_po ON public.purchase_order_payment (tenant_id, purchase_order_id);

CREATE OR REPLACE TRIGGER set_updated_at BEFORE
UPDATE ON public.purchase_order_payment FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at ();

-- Production updates
CREATE TABLE IF NOT EXISTS public.purchase_order_update (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   purchase_order_id UUID NOT NULL,
   happened_on DATE NOT NULL DEFAULT current_date,
   note TEXT NOT NULL,
   created_by UUID DEFAULT auth.uid (),
   created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   CONSTRAINT purchase_order_update_po_fkey FOREIGN KEY (purchase_order_id, tenant_id) REFERENCES public.purchase_order (id, tenant_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_purchase_order_update_po ON public.purchase_order_update (tenant_id, purchase_order_id);

CREATE OR REPLACE TRIGGER set_updated_at BEFORE
UPDATE ON public.purchase_order_update FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at ();

REVOKE ALL ON FUNCTION private.purchase_order_defaults () FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.purchase_order_set_code () FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.purchase_order_immutable () FROM PUBLIC, anon, authenticated;

-- The evidence behind each product (019_products.sql), now with its last order: the code of the
-- newest purchase order that is not cancelled and has a line for the product, in whichever tenant
-- the order is (a provider's order for a client's product), among the orders the caller may read.
CREATE OR REPLACE VIEW public.product_evidence
WITH
   (security_invoker = TRUE) AS
SELECT
   p.id AS product_id,
   p.tenant_id,
   p.sku,
   p.status,
   spec.id IS NOT NULL AS has_signed_spec,
   spec.version AS spec_version,
   spec.id AS spec_document_id,
   p.compliance_status,
   p.compliance_status = 'complete' AS compliance_complete,
   (
      SELECT
         po.code
      FROM
         public.purchase_order_line l
         JOIN public.purchase_order po ON po.id = l.purchase_order_id AND po.tenant_id = l.tenant_id
      WHERE
         l.product_tenant_id = p.tenant_id
         AND l.product_id = p.id
         AND po.status <> 'cancelled'
      ORDER BY
         po.created_at DESC,
         po.code DESC
      LIMIT
         1
   ) AS last_po_code,
   0::INT AS live_cell_count
FROM
   public.product p
   LEFT JOIN LATERAL (
      SELECT
         d.id,
         d.version
      FROM
         public.document d
      WHERE
         d.tenant_id = p.tenant_id
         AND d.entity_type = 'product'
         AND d.entity_id = p.id
         AND d.type = 'spec_sheet'
         AND d.status IN ('signed', 'approved')
      ORDER BY
         d.version DESC
      LIMIT
         1
   ) spec ON TRUE;

COMMENT ON VIEW public.product_evidence IS 'Per product: its highest signed or approved spec sheet, whether its compliance is complete, and last_po_code, the code of its newest purchase order (by created_at) that is not cancelled. live_cell_count (always 0) is a placeholder until the Phase 2 listing tables exist.';

SELECT
   private.enable_tenant_level_security (t_name)
FROM
   unnest(ARRAY['purchase_order', 'purchase_order_line', 'purchase_order_payment', 'purchase_order_update']) AS t_name;

SELECT
   private.audit_enable ('public.purchase_order'::REGCLASS);

SELECT
   private.audit_enable ('public.purchase_order_line'::REGCLASS);

SELECT
   private.audit_enable ('public.purchase_order_payment'::REGCLASS);

SELECT
   private.audit_enable ('public.purchase_order_update'::REGCLASS);

INSERT INTO
   public.module (id, is_core, position)
VALUES
   ('purchase_order', TRUE, 170)
ON CONFLICT (id) DO NOTHING;

-- Permissions. Inserting a permission creates its RLS policies (see private.manage_policies). No
-- delete on orders (cancelled instead).
INSERT INTO
   public.permission (resource_name, group_name, command, kind, bypass, throws_error, resource_condition)
VALUES
   ('public.purchase_order', 'purchase_order', 'select', 'read', FALSE, FALSE, NULL),
   ('public.purchase_order', 'purchase_order', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.purchase_order', 'purchase_order', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.purchase_order_line', 'purchase_order', 'select', 'read', FALSE, FALSE, NULL),
   ('public.purchase_order_line', 'purchase_order', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.purchase_order_line', 'purchase_order', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.purchase_order_line', 'purchase_order', 'delete', 'modify', FALSE, TRUE, NULL),
   ('public.purchase_order_payment', 'purchase_order', 'select', 'read', FALSE, FALSE, NULL),
   ('public.purchase_order_payment', 'purchase_order', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.purchase_order_payment', 'purchase_order', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.purchase_order_payment', 'purchase_order', 'delete', 'modify', FALSE, TRUE, NULL),
   ('public.purchase_order_update', 'purchase_order', 'select', 'read', FALSE, FALSE, NULL),
   ('public.purchase_order_update', 'purchase_order', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.purchase_order_update', 'purchase_order', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.purchase_order_update', 'purchase_order', 'delete', 'modify', FALSE, TRUE, NULL)
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
   AND p.resource_name IN (
      'public.purchase_order',
      'public.purchase_order_line',
      'public.purchase_order_payment',
      'public.purchase_order_update'
   )
ON CONFLICT DO NOTHING;

-- Every permission of a group to each role that may change products (public.product update), as
-- 027_media_roles.sql did for media. It only adds rows, so running it again changes nothing.
CREATE OR REPLACE FUNCTION private.grant_group_to_product_editors (group_name TEXT) RETURNS VOID LANGUAGE sql
SET
   search_path = '' AS $$
    INSERT INTO public.role_permission (role_id, permission_id)
    SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.group_name = grant_group_to_product_editors.group_name
    WHERE EXISTS (
            SELECT 1
            FROM public.role_permission rp
            JOIN public.permission held ON held.id = rp.permission_id
            WHERE rp.role_id = r.id AND held.resource_name = 'public.product' AND held.command = 'update'
        )
    ON CONFLICT DO NOTHING;
$$;

REVOKE ALL ON FUNCTION private.grant_group_to_product_editors (TEXT) FROM PUBLIC, anon, authenticated;

SELECT
   private.grant_group_to_product_editors ('purchase_order');
