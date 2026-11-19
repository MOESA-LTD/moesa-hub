-- Products (M3): the product master, the single source every purchase order, shipment and listing
-- refers to. A product belongs to the tenant it lives in, and its SKU is unique within that tenant.
--
-- product            The product card: identity (SKU, GTIN), status, compliance, dimensions and
--                    weights from unit to pallet. Products are archived (status), never deleted by
--                    users: there is no delete permission. parent_id groups a variant under its
--                    parent product.
-- product_evidence   Per product, the evidence behind it: whether it has a signed or approved spec
--                    sheet (the highest such version among its documents), and whether its
--                    compliance is complete.
-- sourcing           How a product is procured, in the procuring tenant (tenant_id): the supplier
--                    and its product code, the purchase price, currency and incoterm, the landed
--                    and target costs, and the selling price (sell_price_eur, the provider's price
--                    to the client) with its price list. One row per procuring tenant and product.
--                    When the procuring tenant is a provider and the product the client's,
--                    client_tenant_id names the client: the row refers to a product in another
--                    tenant, which only an active provider-procures relationship allows
--                    (018_tenant_relations.sql). product_sku and product_name keep the product's
--                    identity as it was when linked, so the row stays meaningful when the client
--                    deletes the product (product_id is then set to NULL) or removes the provider's
--                    staff. The snapshot is not refreshed afterwards (no sync).
--
-- A GTIN is checked against its GS1 check digit (private.gtin_valid), and is unique among the
-- products that are not archived, across all tenants: a GTIN identifies one product in the world.
--
-- Now that public.product exists, documents with entity_type 'product' are checked against it
-- (private.document_check_entity, 016_documents.sql).
--
-- Every reference to a tenant-scoped table includes tenant_id (see 018_tenant_relations.sql).
-- Suppliers and products are never deleted by users, so the product's references are ON DELETE
-- RESTRICT.
--
-- Rows that may name a client tenant (sourcing here; purchase orders, their lines and shipments
-- later) share these rules:
--   - client_tenant_id is set on insert and never changed (client_tenant_immutable).
--   - The row refers to the product (or project, warehouse) in coalesce(client_tenant_id,
--     tenant_id): <resource>_tenant_id, a plain column the link guard fills and a CHECK ties to
--     that expression, so the foreign key (x_id, x_tenant_id) can be ON DELETE SET NULL (x_id). A
--     generated column cannot be in such a key.
--   - private.client_link_guard checks the client and every link the row sets or changes, and
--     writes the snapshot of each linked row.
--   - BEFORE triggers fire in name order, so their names carry the order they must run in:
--       aa_field_write_guard          the field write rights (051)
--       ab_client_tenant_immutable    client_tenant_id unchanged
--       ac_inherit_client_tenant      a child takes its parent's client
--       ad_client_link_guard          the relationship, the links and their snapshot
--       ae_sell_price_default         a line's selling price from sourcing
--
-- Each rule is a check_violation whose message is the rule's code:
--   client_tenant_immutable  client_tenant_id changed after insert
--   relationship_inactive    a new provider-procured row for a client without an active
--                            provider-procures relationship, or a link set or changed on a client's
--                            row while the relationship is not active
--   client_link_forbidden    a link to a row the caller may not read in the client tenant, or to no
--                            row of the tenant the link points into (the same message for both, so
--                            ids cannot be probed)

CREATE TYPE public.product_status AS ENUM ('concept', 'development', 'approved', 'ordering', 'on_sale', 'paused', 'archived');

CREATE TYPE public.compliance_status AS ENUM ('none', 'partial', 'complete');

-- GTIN-8, -12, -13 or -14: digits only, and the last digit is the GS1 mod-10 check digit (the
-- other digits weighted 3, 1, 3, … from the right).
CREATE OR REPLACE FUNCTION private.gtin_valid (gtin TEXT) RETURNS BOOLEAN LANGUAGE sql IMMUTABLE STRICT
SET
   search_path = '' AS $$
    SELECT CASE
        WHEN gtin !~ '^([0-9]{8}|[0-9]{12,14})$' THEN FALSE
        ELSE (
            SELECT (10 - sum(substr(gtin, length(gtin) - i, 1)::INT * CASE WHEN i % 2 = 1 THEN 3 ELSE 1 END) % 10) % 10
            FROM generate_series(1, length(gtin) - 1) AS i
        ) = substr(gtin, length(gtin), 1)::INT
    END;
$$;

GRANT EXECUTE ON FUNCTION private.gtin_valid (TEXT) TO authenticated;

CREATE TABLE IF NOT EXISTS public.product (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   parent_id UUID,
   sku TEXT NOT NULL,
   display_name TEXT,
   variant_label TEXT,
   category TEXT,
   brand TEXT,
   gtin TEXT CHECK (gtin IS NULL OR private.gtin_valid (gtin)),
   gs1_prefix_owner TEXT,
   status public.product_status NOT NULL DEFAULT 'concept',
   golden_sample_on DATE,
   golden_sample_locations TEXT,
   is_hazmat BOOLEAN NOT NULL DEFAULT FALSE,
   compliance_status public.compliance_status NOT NULL DEFAULT 'none',
   eu_responsible_person TEXT,
   hs_code TEXT,
   origin_country TEXT,
   unit_dims_mm TEXT,
   unit_net_g NUMERIC,
   pack_qty INT,
   pack_dims_mm TEXT,
   pack_gross_g NUMERIC,
   carton_pack_qty INT,
   carton_dims_mm TEXT,
   carton_net_kg NUMERIC,
   carton_gross_kg NUMERIC,
   pallet_carton_qty INT,
   pallet_type TEXT,
   lot_rule TEXT,
   notes TEXT,
   created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   CONSTRAINT product_tenant_id_sku_key UNIQUE (tenant_id, sku),
   -- Target of the tenant-scoped foreign keys of the rows that refer to a product.
   CONSTRAINT product_id_tenant_id_key UNIQUE (id, tenant_id),
   CONSTRAINT product_parent_fkey FOREIGN KEY (parent_id, tenant_id) REFERENCES public.product (id, tenant_id) ON DELETE RESTRICT
);

-- Global on purpose: a GTIN is unique in the world, whichever tenant holds the product.
CREATE UNIQUE INDEX IF NOT EXISTS product_gtin_active ON public.product (gtin)
WHERE
   gtin IS NOT NULL
   AND status <> 'archived';

CREATE INDEX IF NOT EXISTS idx_product_tenant_status ON public.product (tenant_id, status);

-- Products are archived, not deleted.
REVOKE DELETE ON public.product FROM anon, authenticated;

CREATE OR REPLACE TRIGGER set_updated_at BEFORE
UPDATE ON public.product FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at ();

SELECT
   private.enable_tenant_level_security ('product');

SELECT
   private.audit_enable ('public.product'::REGCLASS);

-- The evidence behind each product. security_invoker: the caller's own rights on product and
-- document apply, so a tenant sees only its own products and documents.
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
   NULL::TEXT AS last_po_code,
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

COMMENT ON VIEW public.product_evidence IS 'Per product: its highest signed or approved spec sheet and whether its compliance is complete. last_po_code (always NULL) and live_cell_count (always 0) are placeholders until the Phase 2 purchase order and listing tables exist.';

GRANT SELECT ON public.product_evidence TO authenticated;

-- How a product is procured, in the procuring tenant (see the header). product_tenant_id is the
-- tenant of the product (coalesce(client_tenant_id, tenant_id)), filled by the link guard.
CREATE TABLE IF NOT EXISTS public.sourcing (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   client_tenant_id UUID,
   product_tenant_id UUID NOT NULL,
   product_id UUID,
   product_sku TEXT NOT NULL,
   product_name TEXT NOT NULL,
   supplier_id UUID,
   supplier_product_code TEXT,
   manufacturer_art_no TEXT,
   purchase_price NUMERIC(12, 4),
   purchase_currency valid_currency_code,
   purchase_incoterm TEXT,
   landed_cost_eur NUMERIC(12, 4),
   landed_cost_on DATE,
   target_price_eur NUMERIC(12, 4),
   sell_price_eur NUMERIC(12, 2),
   price_list_version TEXT,
   notes TEXT,
   created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   -- Target of the tenant-scoped foreign keys of the rows that refer to a sourcing row.
   CONSTRAINT sourcing_id_tenant_id_key UNIQUE (id, tenant_id),
   CONSTRAINT sourcing_tenant_id_product_id_key UNIQUE (tenant_id, product_id),
   CONSTRAINT sourcing_not_self CHECK (client_tenant_id IS DISTINCT FROM tenant_id),
   CONSTRAINT sourcing_product_tenant CHECK (product_tenant_id = coalesce(client_tenant_id, tenant_id)),
   -- The client's delete of its product is not blocked: the row keeps its snapshot.
   CONSTRAINT sourcing_product_fkey FOREIGN KEY (product_id, product_tenant_id) REFERENCES public.product (id, tenant_id) ON DELETE SET NULL (product_id),
   CONSTRAINT sourcing_supplier_fkey FOREIGN KEY (supplier_id, tenant_id) REFERENCES public.supplier (id, tenant_id) ON DELETE RESTRICT,
   -- A client is named only under a relationship of the pair; the relationship is not deleted while
   -- rows name it.
   CONSTRAINT sourcing_relationship_fkey FOREIGN KEY (tenant_id, client_tenant_id) REFERENCES public.provider_relationship (tenant_id, client_tenant_id)
);

CREATE INDEX IF NOT EXISTS sourcing_client_idx ON public.sourcing (client_tenant_id);

CREATE INDEX IF NOT EXISTS sourcing_product_idx ON public.sourcing (product_id);

CREATE INDEX IF NOT EXISTS sourcing_supplier_idx ON public.sourcing (tenant_id, supplier_id);

-- The test fixture bypass, as in 030_purchase_order_rules.sql (which keeps its definition): the link
-- guard below runs before that migration.
CREATE OR REPLACE FUNCTION private.rules_bypassed () RETURNS BOOLEAN LANGUAGE sql STABLE
SET
   search_path = '' AS $$
    SELECT coalesce(
        current_setting('moesa.rules_bypass', TRUE) = '1'
        AND current_setting('role') = 'none'
        AND session_user IN ('postgres', 'supabase_admin'),
        FALSE
    );
$$;

REVOKE ALL ON FUNCTION private.rules_bypassed () FROM PUBLIC, anon, authenticated;

-- client_tenant_id is set on insert and never changed, whatever the bypass; nor is the tenant of a
-- row naming a client, which would put the row under a pair no relationship was checked for.
CREATE OR REPLACE FUNCTION private.client_tenant_immutable () RETURNS TRIGGER LANGUAGE plpgsql
SET
   search_path = '' AS $$
BEGIN
    IF NEW.client_tenant_id IS DISTINCT FROM OLD.client_tenant_id
       OR (OLD.client_tenant_id IS NOT NULL AND NEW.tenant_id IS DISTINCT FROM OLD.tenant_id) THEN
        RAISE EXCEPTION 'client_tenant_immutable' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.client_tenant_immutable () FROM PUBLIC, anon, authenticated;

-- The links of a row that may name a client tenant. TG_ARGV holds pairs (<id column>, <resource>),
-- e.g. ('product_id', 'public.product'). A link points into coalesce(client_tenant_id, tenant_id).
--
-- 1. The relationship, once per row, when the row names a client (not for the test bypass): a new
--    purchase order, shipment or sourcing row needs an active provider-procures relationship; any
--    other new row naming the client (a child of an existing shared row), or a link set or changed
--    on such a row, needs the relationship still active (after a switch to client-procures the
--    provider may finish its open orders; after the end, nothing changes). A link that becomes
--    NULL because its row is gone (ON DELETE SET NULL) is not a change: the client's delete is
--    never blocked.
-- 2. Each link set or changed: the caller must read <resource> in the tenant the link points into
--    (in a client tenant, an invitation with that right; in its own tenant, its own right, so a
--    link cannot reveal a row's identity the caller may not read); then the row must exist there.
--    Both refusals are client_link_forbidden, so ids cannot be probed. The read right is not asked
--    for the test bypass, nor for an own-tenant link written without a user (the seed, a service).
--    The snapshot columns of the link are written from that row: product_sku, product_name
--    (product); project_code (project); delivery_address (warehouse). They follow the link and are
--    never written by the caller: a row inserted without the link has them NULL; a link kept
--    keeps them; a link emptied while its row still exists clears them; a link emptied because
--    its row is gone (ON DELETE SET NULL) keeps them as history, and so does every later update of
--    that row.
-- 3. <resource>_tenant_id, where the row has it, is set to the tenant the links point into.
--
-- SECURITY DEFINER: it reads the target rows whatever the caller may see, and calls the private
-- relationship functions.
CREATE OR REPLACE FUNCTION private.client_link_guard () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    new_row CONSTANT JSONB := to_jsonb(NEW);
    old_row CONSTANT JSONB := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) END;
    provider CONSTANT UUID := (new_row ->> 'tenant_id')::UUID;
    client CONSTANT UUID := (new_row ->> 'client_tenant_id')::UUID;
    target_tenant CONSTANT UUID := coalesce(client, provider);
    bypassed CONSTANT BOOLEAN := private.rules_bypassed();
    checked CONSTANT BOOLEAN := client IS NOT NULL AND NOT bypassed;
    read_checked CONSTANT BOOLEAN := NOT bypassed AND (client IS NOT NULL OR auth.uid() IS NOT NULL);
    snapshot_columns TEXT[];
    relinked BOOLEAN := FALSE;
    patch JSONB := '{}';
    id_column TEXT;
    resource TEXT;
    link_id UUID;
    old_id UUID;
    gone BOOLEAN;
    keep_snapshot BOOLEAN;
    target JSONB;
BEGIN
    -- The links this update sets or changes, other than one emptied because its row is gone.
    IF TG_OP = 'UPDATE' AND checked THEN
        FOR i IN 0 .. TG_NARGS / 2 - 1 LOOP
            link_id := (new_row ->> TG_ARGV[2 * i])::UUID;
            old_id := (old_row ->> TG_ARGV[2 * i])::UUID;
            CONTINUE WHEN link_id IS NOT DISTINCT FROM old_id;
            IF link_id IS NULL THEN
                EXECUTE format('SELECT NOT EXISTS (SELECT 1 FROM %s WHERE id = $1)', TG_ARGV[2 * i + 1]) INTO gone USING old_id;
                CONTINUE WHEN gone;
            END IF;
            relinked := TRUE;
        END LOOP;
    END IF;

    -- 1. The relationship.
    IF checked AND (TG_OP = 'INSERT' OR relinked) THEN
        IF TG_OP = 'INSERT' AND TG_TABLE_NAME IN ('purchase_order', 'shipment', 'sourcing') THEN
            IF NOT private.relationship_allows(provider, client, TRUE) THEN
                RAISE EXCEPTION 'relationship_inactive' USING ERRCODE = 'check_violation';
            END IF;
        ELSIF private.relationship_status(provider, client) IS DISTINCT FROM 'active' THEN
            RAISE EXCEPTION 'relationship_inactive' USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    FOR i IN 0 .. TG_NARGS / 2 - 1 LOOP
        id_column := TG_ARGV[2 * i];
        resource := TG_ARGV[2 * i + 1];

        -- 3. The tenant the link points into.
        IF new_row ? (split_part(resource, '.', 2) || '_tenant_id') THEN
            patch := patch || jsonb_build_object(split_part(resource, '.', 2) || '_tenant_id', target_tenant);
        END IF;

        link_id := (new_row ->> id_column)::UUID;
        old_id := (old_row ->> id_column)::UUID;
        snapshot_columns := CASE resource
            WHEN 'public.product' THEN ARRAY['product_sku', 'product_name']
            WHEN 'public.project' THEN ARRAY['project_code']
            WHEN 'public.warehouse' THEN ARRAY['delivery_address']
            ELSE '{}'::TEXT[]
        END;

        -- A link kept, or emptied because its row is gone (or already empty, so the snapshot is
        -- history or NULL), keeps the stored snapshot.
        IF TG_OP = 'UPDATE' AND link_id IS NOT DISTINCT FROM old_id THEN
            keep_snapshot := TRUE;
        ELSIF TG_OP = 'UPDATE' AND link_id IS NULL THEN
            EXECUTE format('SELECT NOT EXISTS (SELECT 1 FROM %s WHERE id = $1)', resource) INTO keep_snapshot USING old_id;
        ELSE
            keep_snapshot := FALSE;
        END IF;

        IF keep_snapshot THEN
            patch := patch || coalesce((
                SELECT jsonb_object_agg(c, old_row -> c) FROM unnest(snapshot_columns) AS c WHERE old_row ? c
            ), '{}');
            CONTINUE;
        END IF;

        -- No link (a new row without one, or a link emptied while its row exists): no snapshot.
        IF link_id IS NULL THEN
            patch := patch || coalesce((
                SELECT jsonb_object_agg(c, 'null'::JSONB) FROM unnest(snapshot_columns) AS c WHERE new_row ? c
            ), '{}');
            CONTINUE;
        END IF;

        -- 2. The caller's read right in the tenant the link points into, then the row itself.
        IF read_checked
           AND NOT (target_tenant = ANY (private.tenants_permitting(auth.uid(), ARRAY[target_tenant], resource, 'select'))) THEN
            RAISE EXCEPTION 'client_link_forbidden' USING ERRCODE = 'check_violation';
        END IF;

        EXECUTE format('SELECT to_jsonb(r) FROM %s r WHERE r.id = $1 AND r.tenant_id = $2', resource)
        INTO target
        USING link_id, target_tenant;

        IF target IS NULL THEN
            RAISE EXCEPTION 'client_link_forbidden' USING ERRCODE = 'check_violation';
        END IF;

        patch := patch || CASE resource
            WHEN 'public.product' THEN jsonb_build_object(
                'product_sku', target ->> 'sku',
                'product_name', coalesce(target ->> 'display_name', target ->> 'sku'))
            WHEN 'public.project' THEN jsonb_build_object('project_code', target ->> 'code')
            WHEN 'public.warehouse' THEN jsonb_build_object('delivery_address', concat_ws(', ',
                target ->> 'display_name', target ->> 'address', target ->> 'postal_code', target ->> 'city',
                target ->> 'country'))
            ELSE '{}'::JSONB
        END;
    END LOOP;

    NEW := jsonb_populate_record(NEW, patch);
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.client_link_guard () FROM PUBLIC, anon, authenticated;

-- While a provider procures for a client (an active provider-procures relationship), the client's
-- procurement data (cost, supplier) is kept in the provider's company, where the client owner does
-- not read it (decisions 7 and 12): no sourcing row is added in the client's own tenant, whoever
-- writes it (sourcing_in_client_forbidden). SECURITY DEFINER: the client side may not read the
-- provider's relationship row.
CREATE OR REPLACE FUNCTION private.sourcing_client_side_guard () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.provider_relationship r
        WHERE r.client_tenant_id = NEW.tenant_id AND r.status = 'active' AND r.procurement_model = 'provider'
    ) THEN
        RAISE EXCEPTION 'sourcing_in_client_forbidden' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.sourcing_client_side_guard () FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER aa_sourcing_client_side_guard BEFORE INSERT ON public.sourcing FOR EACH ROW
EXECUTE FUNCTION private.sourcing_client_side_guard ();

CREATE OR REPLACE TRIGGER ab_client_tenant_immutable BEFORE
UPDATE ON public.sourcing FOR EACH ROW
EXECUTE FUNCTION private.client_tenant_immutable ();

CREATE OR REPLACE TRIGGER ad_client_link_guard BEFORE INSERT
OR
UPDATE ON public.sourcing FOR EACH ROW
EXECUTE FUNCTION private.client_link_guard ('product_id', 'public.product');

CREATE OR REPLACE TRIGGER set_updated_at BEFORE
UPDATE ON public.sourcing FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at ();

SELECT
   private.enable_tenant_level_security ('sourcing');

SELECT
   private.audit_enable ('public.sourcing'::REGCLASS);

-- Module row (from 015_ops_core.sql), kept here should this migration run alone.
INSERT INTO
   public.module (id, is_core, position)
VALUES
   ('product', TRUE, 140)
ON CONFLICT (id) DO NOTHING;

-- Permissions. Inserting a permission creates its RLS policies (see private.manage_policies). No
-- delete on products: they are archived. Sourcing rows are the procuring tenant's own and may be
-- deleted.
INSERT INTO
   public.permission (resource_name, group_name, command, kind, bypass, throws_error, resource_condition)
VALUES
   ('public.product', 'product', 'select', 'read', FALSE, FALSE, NULL),
   ('public.product', 'product', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.product', 'product', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.sourcing', 'product', 'select', 'read', FALSE, FALSE, NULL),
   ('public.sourcing', 'product', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.sourcing', 'product', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.sourcing', 'product', 'delete', 'modify', FALSE, TRUE, NULL)
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
   AND p.resource_name IN ('public.product', 'public.sourcing')
ON CONFLICT DO NOTHING;
