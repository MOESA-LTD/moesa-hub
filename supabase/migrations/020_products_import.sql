-- Product import (S10): the rows of a product spreadsheet, saved in one call, in the active tenant
-- (the client sends its active tenant alone, see forTenant). The client maps the
-- S10 CSV to the column names of the product and of its sourcing; a row is
--   {sku, supplier_code?, parent_sku?, …product columns…, …sourcing columns…}.
--
-- Every row is checked first, and the rows are written only when none has an error: a file is
-- imported whole or not at all. A row whose SKU exists in the tenant updates that product (the
-- columns the row names; the others stay), any other row inserts one. The sourcing columns and the
-- supplier go to the tenant's own sourcing row of the product (no client tenant), made when the row
-- names one of them and the product has none yet. Variants are linked to their parents last, so a
-- variant may come before its parent in the file.
--
-- SECURITY INVOKER: the caller's own permissions and tenant policies apply to every read and write,
-- and the tables' constraints still hold (a write they reject fails the whole call). The active
-- tenant is read as private.requested_tenant reads it (the x-tenant-id header, else the token's
-- current tenant), since the caller cannot call into schema private; a tenant the caller may not
-- use is outside its tenant scope, so the policies show none of its rows and refuse every write.
CREATE OR REPLACE FUNCTION public.import_products (rows JSONB) RETURNS JSONB LANGUAGE plpgsql SECURITY INVOKER
SET
   search_path = '' AS $$
DECLARE
    -- The product columns a row may set, in table order. The parent comes as parent_sku.
    product_columns CONSTANT TEXT[] := ARRAY[
        'display_name', 'variant_label', 'category', 'brand', 'gtin', 'gs1_prefix_owner', 'status',
        'golden_sample_on', 'golden_sample_locations', 'is_hazmat', 'compliance_status',
        'eu_responsible_person', 'hs_code', 'origin_country', 'unit_dims_mm', 'unit_net_g', 'pack_qty',
        'pack_dims_mm', 'pack_gross_g', 'carton_pack_qty', 'carton_dims_mm', 'carton_net_kg',
        'carton_gross_kg', 'pallet_carton_qty', 'pallet_type', 'lot_rule', 'notes'
    ];
    -- The sourcing columns a row may set, in table order. The supplier comes as supplier_code.
    sourcing_columns CONSTANT TEXT[] := ARRAY[
        'supplier_product_code', 'manufacturer_art_no', 'purchase_price', 'purchase_currency',
        'purchase_incoterm', 'landed_cost_eur', 'landed_cost_on', 'target_price_eur', 'sell_price_eur',
        'price_list_version'
    ];
    -- Columns that cannot be empty: an empty value keeps the product's own (or the default).
    not_null_columns CONSTANT TEXT[] := ARRAY['status', 'is_hazmat', 'compliance_status'];
    sourcing_written CONSTANT TEXT[] := sourcing_columns || ARRAY['supplier_id'];
    defaults CONSTANT JSONB := '{"status": "concept", "is_hazmat": false, "compliance_status": "none"}';
    tenant CONSTANT UUID := coalesce(
        nullif(nullif(current_setting('request.headers', TRUE), '')::JSONB ->> 'x-tenant-id', '')::UUID,
        (nullif(current_setting('request.jwt.claims', TRUE), '')::JSONB -> 'user_metadata' ->> 'current_tenant_id')::UUID
    );
    errors JSONB := '[]';
    sku_duplicates BIGINT[];
    gtin_duplicates BIGINT[];
    item JSONB;
    n BIGINT;
    row_values JSONB;
    sourcing_values JSONB;
    product UUID;
    holder TEXT;
    column_name TEXT;
    written INT;
    inserted INT := 0;
    updated INT := 0;
BEGIN
    IF jsonb_typeof(import_products.rows) IS DISTINCT FROM 'array' THEN
        RAISE SQLSTATE 'PGRST' USING
            MESSAGE = json_build_object('code', 'P0001', 'message', 'rows_must_be_an_array')::TEXT,
            DETAIL = json_build_object('status', 400, 'headers', json_build_object())::TEXT;
    END IF;

    IF tenant IS NULL THEN
        RAISE SQLSTATE 'PGRST' USING
            MESSAGE = json_build_object('code', 'P0001', 'message', 'tenant_required')::TEXT,
            DETAIL = json_build_object('status', 403, 'headers', json_build_object())::TEXT;
    END IF;

    -- The rows repeating an earlier row's SKU, or an earlier active row's GTIN.
    SELECT array_agg(d.n) INTO sku_duplicates
    FROM (
        SELECT e.n, row_number() OVER (PARTITION BY e.v ->> 'sku' ORDER BY e.n) AS seen
        FROM jsonb_array_elements(import_products.rows) WITH ORDINALITY AS e (v, n)
        WHERE coalesce(e.v ->> 'sku', '') <> ''
    ) d
    WHERE d.seen > 1;

    SELECT array_agg(d.n) INTO gtin_duplicates
    FROM (
        SELECT e.n, row_number() OVER (PARTITION BY e.v ->> 'gtin' ORDER BY e.n) AS seen
        FROM jsonb_array_elements(import_products.rows) WITH ORDINALITY AS e (v, n)
        WHERE e.v ->> 'gtin' IS NOT NULL AND coalesce(e.v ->> 'status', '') <> 'archived'
    ) d
    WHERE d.seen > 1;

    -- 1. Check every row.
    FOR item, n IN SELECT e.v, e.n FROM jsonb_array_elements(import_products.rows) WITH ORDINALITY AS e (v, n) LOOP
        IF coalesce(item ->> 'sku', '') = '' THEN
            errors := errors || jsonb_build_object('row', n, 'field', 'sku', 'code', 'invalid_value');
        ELSIF n = ANY (sku_duplicates) THEN
            errors := errors || jsonb_build_object('row', n, 'field', 'sku', 'code', 'sku_duplicate');
        END IF;

        IF item ->> 'supplier_code' IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.supplier s WHERE s.tenant_id = tenant AND s.code = item ->> 'supplier_code'
        ) THEN
            errors := errors || jsonb_build_object('row', n, 'field', 'supplier_code', 'code', 'supplier_unknown');
        END IF;

        -- The parent is another product of the tenant, already saved or in the file.
        IF item ->> 'parent_sku' IS NOT NULL AND (
            item ->> 'parent_sku' = item ->> 'sku'
            OR NOT (
                EXISTS (SELECT 1 FROM public.product p WHERE p.tenant_id = tenant AND p.sku = item ->> 'parent_sku')
                OR EXISTS (
                    SELECT 1 FROM jsonb_array_elements(import_products.rows) AS e (v)
                    WHERE e.v ->> 'sku' = item ->> 'parent_sku'
                )
            )
        ) THEN
            errors := errors || jsonb_build_object('row', n, 'field', 'parent_sku', 'code', 'parent_unknown');
        END IF;

        IF item ->> 'gtin' IS NOT NULL THEN
            -- The GS1 check of private.gtin_valid, which the caller cannot call (schema private):
            -- 8, 12, 13 or 14 digits, the last the mod-10 check digit of the others weighted 3, 1, …
            IF item ->> 'gtin' !~ '^([0-9]{8}|[0-9]{12,14})$' OR (
                SELECT (10 - sum(substr(item ->> 'gtin', length(item ->> 'gtin') - i, 1)::INT * CASE WHEN i % 2 = 1 THEN 3 ELSE 1 END) % 10) % 10
                FROM generate_series(1, length(item ->> 'gtin') - 1) AS i
            ) <> substr(item ->> 'gtin', length(item ->> 'gtin'), 1)::INT THEN
                errors := errors || jsonb_build_object('row', n, 'field', 'gtin', 'code', 'gtin_invalid');
            ELSIF n = ANY (gtin_duplicates) THEN
                errors := errors || jsonb_build_object('row', n, 'field', 'gtin', 'code', 'gtin_duplicate');
            ELSIF coalesce(item ->> 'status', '') <> 'archived' THEN
                -- Only the caller's own products are visible here; the unique index guards the rest.
                SELECT p.sku INTO holder
                FROM public.product p
                WHERE p.gtin = item ->> 'gtin' AND p.status <> 'archived'
                    AND NOT (p.tenant_id = tenant AND p.sku = item ->> 'sku')
                LIMIT 1;

                IF holder IS NOT NULL THEN
                    errors := errors || jsonb_build_object('row', n, 'field', 'gtin', 'code', 'gtin_in_use', 'sku', holder);
                END IF;
            END IF;
        END IF;

        -- Values the columns cannot hold (enums, numbers, dates, booleans, currency codes): read
        -- as a whole first, then column by column to name the ones that fail. Product columns
        -- first, then sourcing columns.
        row_values := coalesce((SELECT jsonb_object_agg(e.key, e.value) FROM jsonb_each(item) AS e WHERE e.key = ANY (product_columns)), '{}');
        BEGIN
            PERFORM jsonb_populate_record(NULL::public.product, row_values);
        EXCEPTION
            WHEN data_exception OR integrity_constraint_violation THEN
                FOREACH column_name IN ARRAY product_columns LOOP
                    CONTINUE WHEN NOT row_values ? column_name;
                    BEGIN
                        PERFORM jsonb_populate_record(NULL::public.product, jsonb_build_object(column_name, row_values -> column_name));
                    EXCEPTION
                        WHEN data_exception OR integrity_constraint_violation THEN
                            errors := errors || jsonb_build_object('row', n, 'field', column_name, 'code', 'invalid_value');
                    END;
                END LOOP;
        END;

        sourcing_values := coalesce((SELECT jsonb_object_agg(e.key, e.value) FROM jsonb_each(item) AS e WHERE e.key = ANY (sourcing_columns)), '{}');
        BEGIN
            PERFORM jsonb_populate_record(NULL::public.sourcing, sourcing_values);
        EXCEPTION
            WHEN data_exception OR integrity_constraint_violation THEN
                FOREACH column_name IN ARRAY sourcing_columns LOOP
                    CONTINUE WHEN NOT sourcing_values ? column_name;
                    BEGIN
                        PERFORM jsonb_populate_record(NULL::public.sourcing, jsonb_build_object(column_name, sourcing_values -> column_name));
                    EXCEPTION
                        WHEN data_exception OR integrity_constraint_violation THEN
                            errors := errors || jsonb_build_object('row', n, 'field', column_name, 'code', 'invalid_value');
                    END;
                END LOOP;
        END;
    END LOOP;

    IF jsonb_array_length(errors) > 0 THEN
        RETURN jsonb_build_object('ok', FALSE, 'errors', errors);
    END IF;

    -- 2. Write every row: the product of the same SKU is updated, otherwise one is made; then its
    -- sourcing row, when the row names a sourcing column or the supplier.
    FOR item IN SELECT e.v FROM jsonb_array_elements(import_products.rows) AS e (v) LOOP
        row_values := coalesce((
            SELECT jsonb_object_agg(e.key, e.value)
            FROM jsonb_each(item) AS e
            WHERE e.key = ANY (product_columns)
                AND NOT (e.key = ANY (not_null_columns) AND jsonb_typeof(e.value) = 'null')
        ), '{}');

        EXECUTE format(
            'UPDATE public.product p SET (%s) = (SELECT %s FROM jsonb_populate_record(p, $1) AS r) WHERE p.tenant_id = $2 AND p.sku = $3 RETURNING p.id',
            array_to_string(product_columns, ', '),
            'r.' || array_to_string(product_columns, ', r.')
        )
        INTO product
        USING row_values, tenant, item ->> 'sku';
        GET DIAGNOSTICS written = ROW_COUNT;

        IF written > 0 THEN
            updated := updated + 1;
        ELSE
            EXECUTE format(
                'INSERT INTO public.product (tenant_id, sku, %s) SELECT $2, $3, %s FROM jsonb_populate_record(jsonb_populate_record(NULL::public.product, $4), $1) AS r RETURNING id',
                array_to_string(product_columns, ', '),
                'r.' || array_to_string(product_columns, ', r.')
            )
            INTO product
            USING row_values, tenant, item ->> 'sku', defaults;
            inserted := inserted + 1;
        END IF;

        sourcing_values := coalesce((SELECT jsonb_object_agg(e.key, e.value) FROM jsonb_each(item) AS e WHERE e.key = ANY (sourcing_columns)), '{}');

        IF item ? 'supplier_code' THEN
            sourcing_values := sourcing_values || jsonb_build_object('supplier_id', (
                SELECT s.id FROM public.supplier s WHERE s.tenant_id = tenant AND s.code = item ->> 'supplier_code'
            ));
        END IF;

        CONTINUE WHEN sourcing_values = '{}';

        EXECUTE format(
            'UPDATE public.sourcing s SET (%s) = (SELECT %s FROM jsonb_populate_record(s, $1) AS r) WHERE s.tenant_id = $2 AND s.product_id = $3',
            array_to_string(sourcing_written, ', '),
            'r.' || array_to_string(sourcing_written, ', r.')
        )
        USING sourcing_values, tenant, product;
        GET DIAGNOSTICS written = ROW_COUNT;

        IF written = 0 THEN
            -- product_sku and product_name are filled by the link guard (019), from the product.
            EXECUTE format(
                'INSERT INTO public.sourcing (tenant_id, product_id, %s) SELECT $2, $3, %s FROM jsonb_populate_record(NULL::public.sourcing, $1) AS r',
                array_to_string(sourcing_written, ', '),
                'r.' || array_to_string(sourcing_written, ', r.')
            )
            USING sourcing_values, tenant, product;
        END IF;
    END LOOP;

    -- 3. Link the variants to their parents, now that every row of the file is saved. An empty
    -- parent_sku unlinks the product.
    UPDATE public.product c
    SET parent_id = parent.id
    FROM jsonb_array_elements(import_products.rows) AS e (v)
    LEFT JOIN public.product parent ON parent.tenant_id = tenant AND parent.sku = e.v ->> 'parent_sku'
    WHERE e.v ? 'parent_sku'
        AND c.tenant_id = tenant
        AND c.sku = e.v ->> 'sku'
        AND c.parent_id IS DISTINCT FROM parent.id;

    RETURN jsonb_build_object('ok', TRUE, 'inserted', inserted, 'updated', updated);
END;
$$;

REVOKE ALL ON FUNCTION public.import_products (JSONB) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.import_products (JSONB) TO authenticated;
