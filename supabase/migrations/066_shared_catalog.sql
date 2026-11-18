-- Sharing, the catalog part: which fields of a provider-procured row reach its client tenant.
--
-- private.is_shared_table(t)  TRUE when public.<t> carries client_tenant_id under the foreign key
--                             (tenant_id, client_tenant_id) -> provider_relationship (tenant_id,
--                             client_tenant_id), and for provider_relationship itself (its
--                             client_tenant_id is the pair).
-- field_class.client_visible  The fixed client-visible set: status, dates, quantities, products, the
--                             selling price per line, shipment ETA and tracking, the relationship's
--                             terms. Every other column of a shared table is provider-only: costs,
--                             suppliers, payments, the deposit and balance (decision 15), internal
--                             notes. Raw purchase_order.status stays provider-only: its values reveal
--                             supplier-payment progress, and the client sees a derived client_status
--                             (Q1). sourcing.manufacturer_art_no is client-visible (Q3).
--                             client_visible only on a shared table: a CHECK cannot read the catalog
--                             of other tables, so 066_shared_catalog.test.sql asserts it.
-- field_class.rights_column   The column whose tenant's rights decide a field (Task 6 adds the rows).

CREATE OR REPLACE FUNCTION private.is_shared_table (p_table TEXT) RETURNS BOOLEAN LANGUAGE sql STABLE
SET
   search_path = '' AS $$
    SELECT p_table = 'provider_relationship'
        OR EXISTS (
            SELECT 1
            FROM pg_catalog.pg_constraint k
            JOIN pg_catalog.pg_class c ON c.oid = k.conrelid
            WHERE c.relnamespace = 'public'::REGNAMESPACE
              AND c.relname = p_table
              AND k.contype = 'f'
              AND k.confrelid = 'public.provider_relationship'::REGCLASS
              AND ARRAY(
                    SELECT a.attname::TEXT
                    FROM unnest(k.conkey) WITH ORDINALITY AS u (attnum, i)
                    JOIN pg_catalog.pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.attnum
                    ORDER BY u.i
                  ) = ARRAY['tenant_id', 'client_tenant_id']
              AND ARRAY(
                    SELECT a.attname::TEXT
                    FROM unnest(k.confkey) WITH ORDINALITY AS u (attnum, i)
                    JOIN pg_catalog.pg_attribute a ON a.attrelid = k.confrelid AND a.attnum = u.attnum
                    ORDER BY u.i
                  ) = ARRAY['tenant_id', 'client_tenant_id']
        );
$$;

ALTER TABLE public.field_class
ADD COLUMN client_visible BOOLEAN NOT NULL DEFAULT FALSE,
ADD COLUMN rights_column TEXT;

-- The two new columns of field_class are catalog fields like the others (049 completeness).
INSERT INTO
   public.field_class (resource_name, field, class)
VALUES
   ('public.field_class', 'client_visible', 'open'),
   ('public.field_class', 'rights_column', 'open');

UPDATE public.field_class f
SET
   client_visible = TRUE
FROM
   (
      SELECT
         'public.provider_relationship' AS resource_name,
         unnest(
            ARRAY[
               'id', 'tenant_id', 'client_tenant_id', 'client_code', 'client_name', 'provider_name',
               'procurement_model', 'status', 'accepted_at', 'ended_at', 'commercial_model', 'packages',
               'contract_status', 'contract_accepted_on', 'start_on', 'deposit_rate', 'extra_cost_rule',
               'eu_responsible_person', 'created_at', 'updated_at'
            ]
         ) AS field
      UNION ALL
      SELECT
         'public.sourcing',
         unnest(
            ARRAY[
               'id', 'tenant_id', 'client_tenant_id', 'product_tenant_id', 'product_id', 'product_sku',
               'product_name', 'sell_price_eur', 'price_list_version', 'manufacturer_art_no', 'created_at',
               'updated_at'
            ]
         )
      UNION ALL
      SELECT
         'public.purchase_order',
         unnest(
            ARRAY[
               'id', 'tenant_id', 'client_tenant_id', 'code', 'project_id', 'project_tenant_id', 'project_code',
               'ready_on', 'created_at', 'updated_at'
            ]
         )
      UNION ALL
      SELECT
         'public.purchase_order_line',
         unnest(
            ARRAY[
               'id', 'tenant_id', 'client_tenant_id', 'purchase_order_id', 'position', 'product_id',
               'product_tenant_id', 'product_sku', 'product_name', 'quantity', 'sell_price_eur', 'created_at',
               'updated_at'
            ]
         )
      UNION ALL
      SELECT
         'public.shipment',
         unnest(
            ARRAY[
               'id', 'tenant_id', 'client_tenant_id', 'code', 'status', 'mode', 'carrier', 'container_no',
               'seal_no', 'delivery_warehouse_id', 'warehouse_tenant_id', 'delivery_address', 'ready_on',
               'booking_confirmed_on', 'etd', 'eta', 'customs_cleared_on', 'planned_delivery_on', 'delivered_at',
               'carton_count', 'pallet_count', 'volume_m3', 'gross_kg', 'accepted_on', 'quantity_matches',
               'has_damage', 'dispute_deadline_at', 'created_at', 'updated_at'
            ]
         )
      UNION ALL
      SELECT
         'public.shipment_event',
         unnest(
            ARRAY[
               'id', 'tenant_id', 'client_tenant_id', 'shipment_id', 'happened_at', 'step', 'created_at',
               'updated_at'
            ]
         )
      UNION ALL
      SELECT
         c.resource_name,
         c.field
      FROM
         public.field_class c
      WHERE
         c.resource_name IN ('public.shipment_line', 'public.shipment_purchase_order')
   ) v
WHERE
   f.resource_name = v.resource_name
   AND f.field = v.field;

-- Every listed field exists in the catalog: a renamed column must fail here, not shrink the set.
DO $$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n FROM public.field_class
    WHERE client_visible AND resource_name NOT IN ('public.shipment_line', 'public.shipment_purchase_order');
    IF n <> 92 THEN
        RAISE EXCEPTION 'client-visible set has % listed fields, expected 92', n;
    END IF;
END;
$$;

-- api.field_class gains the two columns (read-only, as in 057).
SELECT private.enable_field_security ('field_class', TRUE);
