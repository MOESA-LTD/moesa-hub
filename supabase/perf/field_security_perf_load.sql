-- The field-security performance load (Task 20, R10), as the spike's 50_perf_objects.sql: 100 000
-- products and 100 000 sourcing rows (the cost, supplier and sell price) in MOESA LTD and in Nova
-- Yazılım, plus 20 000 purchase orders (one line each) in each, then ANALYZE. Every tenant works on
-- its own products and procurement (client_tenant_id NULL); Plan 2 re-measures with sharing. No
-- transaction control here: field_security_perf.sql runs it inside BEGIN … ROLLBACK,
-- field_perf_http.ts inside BEGIN … COMMIT (and the caller resets the database afterwards). Run as
-- postgres; triggers are skipped for the bulk load only (session_replication_role), so the columns
-- the triggers fill (product_tenant_id and the snapshots) are written here.
SET LOCAL session_replication_role = replica;

CREATE TEMP TABLE perf_ids ON COMMIT DROP AS
SELECT
    (SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD') AS moesa,
    (SELECT id FROM public.tenant WHERE display_name = 'Nova Yazılım') AS nova,
    ARRAY(SELECT s.id FROM public.supplier s JOIN public.tenant t ON t.id = s.tenant_id
          WHERE t.display_name = 'MOESA LTD' ORDER BY s.code) AS moesa_suppliers;

DO $$
BEGIN
    IF (SELECT moesa IS NULL OR nova IS NULL OR cardinality(moesa_suppliers) = 0 FROM perf_ids) THEN
        RAISE EXCEPTION 'perf load: MOESA LTD, Nova Yazılım or the suppliers of MOESA LTD are missing (run supabase db reset)';
    END IF;
END $$;

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, deposit_rate)
SELECT 'feed0000-0000-4000-8000-0000000000a1', nova, 'PN1', 'Nova perf supplier', 'CN', 30 FROM perf_ids;

-- Products (MOESA LTD and Nova each own theirs) and a sourcing row per product: MOESA LTD with every
-- cost field, a supplier and a note; Nova with a price and a note.
INSERT INTO public.product (id, tenant_id, sku, display_name, status, notes, unit_net_g, created_at)
SELECT ('feed0001-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, p.moesa,
       'L-' || lpad(i::TEXT, 6, '0'), 'Product ' || i, (enum_range(NULL::public.product_status))[1 + i % 7],
       'note ' || i, i % 500, now() - i * INTERVAL '1 minute'
FROM perf_ids p, generate_series(1, 100000) i;
INSERT INTO public.product (id, tenant_id, sku, display_name, notes, created_at)
SELECT ('feed0002-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, p.nova,
       'N-' || lpad(i::TEXT, 6, '0'), 'Nova ' || i, 'n', now() - i * INTERVAL '1 minute'
FROM perf_ids p, generate_series(1, 100000) i;
INSERT INTO public.sourcing (id, tenant_id, product_tenant_id, product_id, product_sku, product_name, supplier_id, purchase_price,
    purchase_currency, purchase_incoterm, landed_cost_eur, landed_cost_on, target_price_eur, sell_price_eur, supplier_product_code,
    notes, created_at)
SELECT ('feed0005-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, p.moesa, p.moesa,
       ('feed0001-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, 'L-' || lpad(i::TEXT, 6, '0'), 'Product ' || i,
       p.moesa_suppliers[1 + i % cardinality(p.moesa_suppliers)], round((random() * 100)::NUMERIC, 4), 'USD', 'FOB',
       round((random() * 120)::NUMERIC, 4), DATE '2026-01-01', round((random() * 150)::NUMERIC, 4),
       round((random() * 150)::NUMERIC, 2), 'SUP-' || i, 'note ' || i, now() - i * INTERVAL '1 minute'
FROM perf_ids p, generate_series(1, 100000) i;
INSERT INTO public.sourcing (id, tenant_id, product_tenant_id, product_id, product_sku, product_name, supplier_id, purchase_price,
    notes, created_at)
SELECT ('feed0006-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, p.nova, p.nova,
       ('feed0002-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, 'N-' || lpad(i::TEXT, 6, '0'), 'Nova ' || i,
       'feed0000-0000-4000-8000-0000000000a1', round((random() * 100)::NUMERIC, 4), 'n', now() - i * INTERVAL '1 minute'
FROM perf_ids p, generate_series(1, 100000) i;

-- Purchase orders with one line each (the overview's figures come from the lines).
INSERT INTO public.purchase_order (id, tenant_id, project_tenant_id, supplier_id, code, currency, incoterm, deposit_rate, pi_number,
    pi_total, notes, created_at)
SELECT ('feed0003-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, p.moesa, p.moesa,
       p.moesa_suppliers[1 + i % cardinality(p.moesa_suppliers)],
       'PERF-' || lpad(i::TEXT, 6, '0'), 'USD', 'FOB', 30, 'PI-' || i, 1000 + i % 1000, 'po note ' || i,
       now() - i * INTERVAL '5 minutes'
FROM perf_ids p, generate_series(1, 20000) i;
INSERT INTO public.purchase_order (id, tenant_id, project_tenant_id, supplier_id, code, currency, incoterm, deposit_rate, notes, created_at)
SELECT ('feed0004-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, p.nova, p.nova,
       'feed0000-0000-4000-8000-0000000000a1', 'PERF-' || lpad(i::TEXT, 6, '0'), 'USD', 'FOB', 30, 'n',
       now() - i * INTERVAL '5 minutes'
FROM perf_ids p, generate_series(1, 20000) i;
INSERT INTO public.purchase_order_line (tenant_id, purchase_order_id, product_tenant_id, product_id, product_sku, product_name, quantity,
    unit_price, pi_line_total)
SELECT p.moesa, ('feed0003-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, p.moesa,
       ('feed0001-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, 'L-' || lpad(i::TEXT, 6, '0'), 'Product ' || i, 10 + i % 90, round((random() * 50)::NUMERIC, 4), 1000 + i % 1000
FROM perf_ids p, generate_series(1, 20000) i;
INSERT INTO public.purchase_order_line (tenant_id, purchase_order_id, product_tenant_id, product_id, product_sku, product_name, quantity,
    unit_price)
SELECT p.nova, ('feed0004-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, p.nova,
       ('feed0002-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::UUID, 'N-' || lpad(i::TEXT, 6, '0'), 'Nova ' || i, 10, 5
FROM perf_ids p, generate_series(1, 20000) i;

SET LOCAL session_replication_role = origin;
ANALYZE public.product;
ANALYZE public.sourcing;
ANALYZE public.supplier;
ANALYZE public.purchase_order;
ANALYZE public.purchase_order_line;
