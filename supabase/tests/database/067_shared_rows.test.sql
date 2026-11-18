CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Sharing (Plan 2): a provider row with client_tenant_id = C is readable by C's members, never
-- writable by them, and stays readable after the relationship ends (decision 13).
--
-- Sections, in this order (F5): rows (Task 2), masking (Task 3), writes (Task 4), history (Task 2:
-- the procurement switch, the added line and the end come last, so earlier sections see the
-- relationship active with one line on po_c).
--
-- Signing in (F4): `RESET ROLE; SELECT private.impersonate_scope(user, active, scope);` (the
-- active tenant is the scope's first); signing out: `RESET ROLE; SELECT private.unimpersonate();`.
BEGIN;

SELECT plan(67);

SELECT private.create_test_helpers();

-- Fixture, built here as postgres (ids 0000000067xx):
--   P  ...6701  provider (code SPV)
--   C  ...6702  client, provider procures (rel_c ...6721: notes REL-NOTE, drive URL, deposit 30)
--   D  ...6703  another provider-procures client of P (rel_d ...6722)
--   pc          ...6711  P coordinator (every purchase order, shipment and product right, every field);
--                        invited into C with select on product (the line's client link passes)
--   co          ...6712  C owner
--   cv          ...6713  C member, role viewer (select on purchase_order, its lines, shipment, sourcing,
--                        provider_relationship)
--   cn          ...6714  C member, role without select on purchase_order (product only)
--   pc_invited  ...6715  P coordinator without field rights; in C with a role holding every right
--   pm          ...6716  P management (every right, every field); invited into C (product reader)
--   pu          ...6717  P member only (the coordinator role), not in C
--   dw          ...6718  D owner
--   sup ...6781 (P's supplier); products in C: client_product ...6741, line product ...6743; in D ...6742
--   sourcing src_c ...6744 (P for C: sell 9.90, art no ART-1, supplier, purchase price 1.10, S-NOTE), src_d ...6745 (P for D)
--   orders po_c ...6751 (client C: pi_total 1234.56, notes P-NOTE, USD), po_d ...6752 (client D),
--          po_own ...6753 (no client); lines line_c ...6761 (po_c: unit 2.50, sell 9.90), line_d ...6762
--   payment pay_c ...6791 on po_c
--   shipments shp_c ...6771 (client C, linked to po_c, one line ...6774, one event ...6773; provider-only
--             sentinels FWD-/CB-/DEM-SECRET, SH-NOTE, the event's CH-/FROM-/TO-SECRET and EV-NOTE),
--             shp_own ...6772 (no client); warehouses ...6775 (C), ...6776 (P)
INSERT INTO public.plan (display_name, is_active) VALUES ('Shared rows test plan', TRUE);

INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000006701', 'Shared Provider', 'SPV'),
   ('00000000-0000-4000-8000-000000006702', 'Shared Client', 'SCL'),
   ('00000000-0000-4000-8000-000000006703', 'Shared Other', 'SOC');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000006711', 'pc@shared.test'),
   ('00000000-0000-4000-8000-000000006712', 'co@shared.test'),
   ('00000000-0000-4000-8000-000000006713', 'cv@shared.test'),
   ('00000000-0000-4000-8000-000000006714', 'cn@shared.test'),
   ('00000000-0000-4000-8000-000000006715', 'pc-invited@shared.test'),
   ('00000000-0000-4000-8000-000000006716', 'pm@shared.test'),
   ('00000000-0000-4000-8000-000000006717', 'pu@shared.test'),
   ('00000000-0000-4000-8000-000000006718', 'dw@shared.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000006712', '00000000-0000-4000-8000-000000006702'),
   ('00000000-0000-4000-8000-000000006718', '00000000-0000-4000-8000-000000006703');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000006711', '00000000-0000-4000-8000-000000006701'),
   ('00000000-0000-4000-8000-000000006711', '00000000-0000-4000-8000-000000006702'),
   ('00000000-0000-4000-8000-000000006712', '00000000-0000-4000-8000-000000006702'),
   ('00000000-0000-4000-8000-000000006713', '00000000-0000-4000-8000-000000006702'),
   ('00000000-0000-4000-8000-000000006714', '00000000-0000-4000-8000-000000006702'),
   ('00000000-0000-4000-8000-000000006715', '00000000-0000-4000-8000-000000006701'),
   ('00000000-0000-4000-8000-000000006715', '00000000-0000-4000-8000-000000006702'),
   ('00000000-0000-4000-8000-000000006716', '00000000-0000-4000-8000-000000006701'),
   ('00000000-0000-4000-8000-000000006716', '00000000-0000-4000-8000-000000006702'),
   ('00000000-0000-4000-8000-000000006717', '00000000-0000-4000-8000-000000006701'),
   ('00000000-0000-4000-8000-000000006718', '00000000-0000-4000-8000-000000006703');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000006731', '00000000-0000-4000-8000-000000006701', 'Coordinator'),
   ('00000000-0000-4000-8000-000000006732', '00000000-0000-4000-8000-000000006701', 'Coordinator without fields'),
   ('00000000-0000-4000-8000-000000006733', '00000000-0000-4000-8000-000000006701', 'Management'),
   ('00000000-0000-4000-8000-000000006734', '00000000-0000-4000-8000-000000006702', 'viewer'),
   ('00000000-0000-4000-8000-000000006735', '00000000-0000-4000-8000-000000006702', 'Product reader'),
   ('00000000-0000-4000-8000-000000006736', '00000000-0000-4000-8000-000000006702', 'Everything');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES ('00000000-0000-4000-8000-000000006731'::UUID), ('00000000-0000-4000-8000-000000006732'::UUID)) AS r (id)
CROSS JOIN public.permission p
WHERE p.group_name IN ('purchase_order', 'shipment', 'product', 'client');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES ('00000000-0000-4000-8000-000000006733'::UUID), ('00000000-0000-4000-8000-000000006736'::UUID)) AS r (id)
CROSS JOIN public.permission p;

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000006734', p.id
FROM public.permission p
WHERE p.command = 'select'
  AND p.resource_name IN ('public.purchase_order', 'public.purchase_order_line', 'public.shipment', 'public.sourcing',
                          'public.provider_relationship');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000006735', p.id
FROM public.permission p
WHERE p.command = 'select' AND p.resource_name = 'public.product';

INSERT INTO public.user_role (user_id, role_id) VALUES
   ('00000000-0000-4000-8000-000000006711', '00000000-0000-4000-8000-000000006731'),
   ('00000000-0000-4000-8000-000000006711', '00000000-0000-4000-8000-000000006735'),
   ('00000000-0000-4000-8000-000000006713', '00000000-0000-4000-8000-000000006734'),
   ('00000000-0000-4000-8000-000000006714', '00000000-0000-4000-8000-000000006735'),
   ('00000000-0000-4000-8000-000000006715', '00000000-0000-4000-8000-000000006732'),
   ('00000000-0000-4000-8000-000000006715', '00000000-0000-4000-8000-000000006736'),
   ('00000000-0000-4000-8000-000000006716', '00000000-0000-4000-8000-000000006733'),
   ('00000000-0000-4000-8000-000000006716', '00000000-0000-4000-8000-000000006735'),
   ('00000000-0000-4000-8000-000000006717', '00000000-0000-4000-8000-000000006731');

SELECT private.grant_all_fields(r)
FROM unnest(ARRAY['00000000-0000-4000-8000-000000006731', '00000000-0000-4000-8000-000000006733',
                  '00000000-0000-4000-8000-000000006736']::UUID[]) AS r;

INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, procurement_model,
                                          notes, restricted_drive_url, deposit_rate) VALUES
   ('00000000-0000-4000-8000-000000006721', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006702',
    'SCL', 'Shared Client', 'provider', 'REL-NOTE', 'https://drive/secret', 30),
   ('00000000-0000-4000-8000-000000006722', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006703',
    'SOC', 'Shared Other', 'provider', NULL, NULL, NULL);

INSERT INTO public.product (id, tenant_id, sku, display_name) VALUES
   ('00000000-0000-4000-8000-000000006741', '00000000-0000-4000-8000-000000006702', 'SCL-MOP', 'Mop'),
   ('00000000-0000-4000-8000-000000006743', '00000000-0000-4000-8000-000000006702', 'SCL-BKT', 'Bucket'),
   ('00000000-0000-4000-8000-000000006742', '00000000-0000-4000-8000-000000006703', 'SOC-CUP', 'Cup');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, default_incoterm, deposit_rate, status) VALUES
   ('00000000-0000-4000-8000-000000006781', '00000000-0000-4000-8000-000000006701', 'SU1', 'Supplier One', 'Türkiye', 'EXW', 30, 'approved');

-- The provider's rows, written without a user (bypass), as a provider would through the app.
SELECT set_config('moesa.rules_bypass', '1', TRUE);

INSERT INTO public.sourcing (id, tenant_id, client_tenant_id, product_id, sell_price_eur, supplier_id, supplier_product_code,
                            manufacturer_art_no, purchase_price, purchase_currency, notes) VALUES
   ('00000000-0000-4000-8000-000000006744', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006702',
    '00000000-0000-4000-8000-000000006743', 9.90, '00000000-0000-4000-8000-000000006781', 'SPC-SECRET', 'ART-1', 1.10, 'USD', 'S-NOTE'),
   ('00000000-0000-4000-8000-000000006745', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006703',
    '00000000-0000-4000-8000-000000006742', 4.00, NULL, NULL, NULL, NULL, NULL, NULL);

INSERT INTO public.purchase_order (id, tenant_id, client_tenant_id, supplier_id, currency, incoterm, deposit_rate, pi_total, notes) VALUES
   ('00000000-0000-4000-8000-000000006751', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006702',
    '00000000-0000-4000-8000-000000006781', 'USD', 'EXW', 30, 1234.56, 'P-NOTE'),
   ('00000000-0000-4000-8000-000000006752', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006703',
    '00000000-0000-4000-8000-000000006781', 'USD', 'EXW', 30, NULL, NULL),
   ('00000000-0000-4000-8000-000000006753', '00000000-0000-4000-8000-000000006701', NULL,
    '00000000-0000-4000-8000-000000006781', 'USD', 'EXW', 30, NULL, NULL);

INSERT INTO public.purchase_order_line (id, tenant_id, purchase_order_id, product_id, quantity, unit_price, sell_price_eur) VALUES
   ('00000000-0000-4000-8000-000000006761', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006751',
    '00000000-0000-4000-8000-000000006743', 10, 2.50, 9.90),
   ('00000000-0000-4000-8000-000000006762', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006752',
    '00000000-0000-4000-8000-000000006742', 10, 1.00, 4.00);

INSERT INTO public.purchase_order_payment (id, tenant_id, purchase_order_id, kind, amount, currency) VALUES
   ('00000000-0000-4000-8000-000000006791', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006751',
    'deposit', 370.37, 'USD');

INSERT INTO public.warehouse (id, tenant_id, display_name, city, country) VALUES
   ('00000000-0000-4000-8000-000000006775', '00000000-0000-4000-8000-000000006702', 'Client DC', 'Rosbach', 'DE'),
   ('00000000-0000-4000-8000-000000006776', '00000000-0000-4000-8000-000000006701', 'Provider DC', 'Istanbul', 'TR');

INSERT INTO public.shipment (id, tenant_id, client_tenant_id, mode, delivery_warehouse_id, warehouse_tenant_id, forwarder, customs_broker,
                             demurrage_note, notes, is_insured, free_days_port, eta) VALUES
   ('00000000-0000-4000-8000-000000006771', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006702',
    'road', '00000000-0000-4000-8000-000000006775', '00000000-0000-4000-8000-000000006702', 'FWD-SECRET', 'CB-SECRET', 'DEM-SECRET',
    'SH-NOTE', TRUE, 7, '2026-12-24'),
   ('00000000-0000-4000-8000-000000006772', '00000000-0000-4000-8000-000000006701', NULL,
    'road', '00000000-0000-4000-8000-000000006776', '00000000-0000-4000-8000-000000006701', NULL, NULL, NULL, NULL, FALSE, NULL, NULL);

INSERT INTO public.shipment_purchase_order (tenant_id, shipment_id, purchase_order_id) VALUES
   ('00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006771', '00000000-0000-4000-8000-000000006751');

INSERT INTO public.shipment_line (id, tenant_id, shipment_id, purchase_order_id, purchase_order_line_id, quantity) VALUES
   ('00000000-0000-4000-8000-000000006774', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006771',
    '00000000-0000-4000-8000-000000006751', '00000000-0000-4000-8000-000000006761', 4);

INSERT INTO public.shipment_event (id, tenant_id, shipment_id, step, channel, note, from_party, to_party) VALUES
   ('00000000-0000-4000-8000-000000006773', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006771',
    3, 'CH-SECRET', 'EV-NOTE', 'FROM-SECRET', 'TO-SECRET');

SELECT set_config('moesa.rules_bypass', '', TRUE);

-- The shared tables (066) and a key per row (shipment_purchase_order has no id).
CREATE FUNCTION pg_temp.shared_tables () RETURNS TEXT[] LANGUAGE sql IMMUTABLE AS $$
    SELECT ARRAY['provider_relationship', 'sourcing', 'purchase_order', 'purchase_order_line', 'shipment', 'shipment_purchase_order',
                 'shipment_line', 'shipment_event'];
$$;

-- The rows of the shared tables outside p_tenant that the caller reads through api.
CREATE FUNCTION pg_temp.foreign_rows (p_tenant UUID) RETURNS TABLE (tbl TEXT, row_key TEXT) LANGUAGE plpgsql AS $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY pg_temp.shared_tables() LOOP
        RETURN QUERY EXECUTE format(
            $q$ SELECT %L::TEXT, coalesce(j ->> 'id', (j ->> 'shipment_id') || '/' || (j ->> 'purchase_order_id'))
                FROM (SELECT to_jsonb(v) AS j FROM api.%I v WHERE v.tenant_id <> $1) s $q$, t, t)
        USING p_tenant;
    END LOOP;
END;
$$;

-- The provider rows shared with p_client, read from the base tables (as postgres).
CREATE FUNCTION pg_temp.shared_with (p_client UUID) RETURNS TABLE (tbl TEXT, row_key TEXT) LANGUAGE plpgsql AS $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY pg_temp.shared_tables() LOOP
        RETURN QUERY EXECUTE format(
            $q$ SELECT %L::TEXT, coalesce(j ->> 'id', (j ->> 'shipment_id') || '/' || (j ->> 'purchase_order_id'))
                FROM (SELECT to_jsonb(v) AS j FROM public.%I v WHERE v.client_tenant_id = $1 AND v.tenant_id <> $1) s $q$, t, t)
        USING p_client;
    END LOOP;
END;
$$;

-- A write's outcome: the number of rows it reached, or 'refused' (the error is caught and undone).
CREATE FUNCTION pg_temp.write_outcome (p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    n BIGINT;
BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n::TEXT;
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'refused';
END;
$$;

-- The base rows a client's writes must leave alone.
CREATE FUNCTION pg_temp.shared_state () RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT concat_ws('|',
        (SELECT status || ':' || coalesce(notes, '') FROM public.purchase_order WHERE id = '00000000-0000-4000-8000-000000006751'),
        (SELECT count(*) FROM public.purchase_order_line WHERE purchase_order_id = '00000000-0000-4000-8000-000000006751'),
        (SELECT quantity FROM public.purchase_order_line WHERE id = '00000000-0000-4000-8000-000000006761'),
        (SELECT client_name FROM public.provider_relationship WHERE id = '00000000-0000-4000-8000-000000006721'),
        (SELECT count(*) FROM public.shipment_event WHERE shipment_id = '00000000-0000-4000-8000-000000006771'),
        (SELECT mode FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000006771'));
$$;

-- Every write a client member may try on the shared rows, through api.
CREATE FUNCTION pg_temp.client_writes () RETURNS TEXT[] LANGUAGE sql IMMUTABLE AS $$
    SELECT ARRAY[
        $w$ UPDATE api.purchase_order SET notes = 'C-NOTE' WHERE id = '00000000-0000-4000-8000-000000006751' $w$,
        $w$ UPDATE api.purchase_order SET status = 'cancelled' WHERE id = '00000000-0000-4000-8000-000000006751' $w$,
        $w$ DELETE FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000006751' $w$,
        $w$ UPDATE api.purchase_order_line SET quantity = 99 WHERE id = '00000000-0000-4000-8000-000000006761' $w$,
        $w$ DELETE FROM api.purchase_order_line WHERE id = '00000000-0000-4000-8000-000000006761' $w$,
        $w$ INSERT INTO api.purchase_order_line (tenant_id, purchase_order_id, product_id, quantity)
            VALUES ('00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006751', '00000000-0000-4000-8000-000000006741', 1) $w$,
        $w$ UPDATE api.provider_relationship SET client_name = 'Renamed' WHERE id = '00000000-0000-4000-8000-000000006721' $w$,
        $w$ UPDATE api.shipment SET mode = 'air' WHERE id = '00000000-0000-4000-8000-000000006771' $w$,
        $w$ DELETE FROM api.shipment_event WHERE id = '00000000-0000-4000-8000-000000006773' $w$,
        $w$ INSERT INTO api.shipment_event (tenant_id, shipment_id)
            VALUES ('00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006771') $w$
    ];
$$;

-- The outcomes of client_writes that reached a row (each must be '0' or 'refused').
CREATE FUNCTION pg_temp.client_write_hits () RETURNS TEXT[] LANGUAGE plpgsql AS $$
DECLARE
    w TEXT;
    o TEXT;
    hits TEXT[] := '{}';
BEGIN
    FOREACH w IN ARRAY pg_temp.client_writes() LOOP
        o := pg_temp.write_outcome(w);
        IF o NOT IN ('0', 'refused') THEN
            hits := hits || (o || ': ' || w);
        END IF;
    END LOOP;
    RETURN hits;
END;
$$;

CREATE TEMP TABLE expected_c ON COMMIT DROP AS SELECT * FROM pg_temp.shared_with('00000000-0000-4000-8000-000000006702');
CREATE TEMP TABLE state_before ON COMMIT DROP AS SELECT pg_temp.shared_state() AS s;
GRANT SELECT ON expected_c, state_before TO authenticated;

-- ===================================================================================== rows (Task 2)

SELECT is((SELECT count(*)::INT FROM expected_c WHERE tbl <> 'provider_relationship'), 7,
          'fixture: one shared row in each of the seven provider tables');

SELECT throws_ok($$ SELECT private.enable_shared_rows('supplier') $$, 'P0001', 'field_security_unsupported',
                 'enable_shared_rows refuses a table without sharing');
SELECT ok(CASE WHEN to_regprocedure('private.enable_shared_rows(text)') IS NULL THEN FALSE
              ELSE NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                               WHERE p.oid = to_regprocedure('private.enable_shared_rows(text)') AND a.grantee <> p.proowner)
                   AND (SELECT proacl IS NOT NULL FROM pg_proc WHERE oid = to_regprocedure('private.enable_shared_rows(text)'))
                   AND (SELECT pg_get_userbyid(proowner) = 'postgres' FROM pg_proc WHERE oid = to_regprocedure('private.enable_shared_rows(text)'))
         END,
          'enable_shared_rows is executable by its owner only');
SELECT is((SELECT count(*)::INT FROM unnest(pg_temp.shared_tables()) AS t
           WHERE EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = t AND p.policyname = 'shared_select'
                           AND p.permissive = 'PERMISSIVE' AND p.cmd = 'SELECT' AND p.qual LIKE '%client_tenant_id%permitted_tenants%')
             AND EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = t
                           AND p.policyname = 'restrict_selects_to_current_tenant' AND p.qual LIKE '%client_tenant_id%tenant_scope%')),
          8, 'every shared table reads shared rows in the scope');
SELECT is((SELECT count(*)::INT FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = ANY (pg_temp.shared_tables())
             AND p.cmd <> 'SELECT' AND coalesce(p.qual, '') || coalesce(p.with_check, '') LIKE '%client_tenant_id%'), 0,
          'no write policy names client_tenant_id');
SELECT is((SELECT count(*)::INT FROM pg_indexes WHERE schemaname = 'public'
             AND indexname IN ('purchase_order_line_client_idx', 'shipment_event_client_idx', 'shipment_line_client_idx',
                               'shipment_purchase_order_client_idx')), 4, 'the child tables index client_tenant_id');

-- The client owner: exactly the rows shared with C.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006712', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT set_eq($$ SELECT id FROM api.purchase_order $$, ARRAY['00000000-0000-4000-8000-000000006751']::UUID[],
              'client owner sees exactly its shared order');
SELECT set_eq($$ SELECT * FROM pg_temp.foreign_rows('00000000-0000-4000-8000-000000006702') $$, $$ SELECT * FROM expected_c $$,
              'client owner sees exactly the provider rows shared with it, in every shared table');
SELECT is_empty($$ SELECT 1 FROM api.purchase_order_payment $$, 'payments are never shared');
SELECT is_empty($$ SELECT 1 FROM api.supplier $$, 'suppliers are never shared');
SELECT is((SELECT count(*)::INT FROM api.provider_relationship), 1, 'client reads its relationship');
SELECT is(pg_temp.client_write_hits(), '{}'::TEXT[], 'client owner: no write through api reaches a shared row');
RESET ROLE;
SELECT is(pg_temp.shared_state(), (SELECT s FROM state_before), 'the shared rows are unchanged');

-- A forged scope: naming the provider changes nothing; the provider as active tenant reads nothing.
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006712', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702', '00000000-0000-4000-8000-000000006701']::UUID[]);
SELECT set_eq($$ SELECT id FROM api.purchase_order $$, ARRAY['00000000-0000-4000-8000-000000006751']::UUID[],
              'a forged scope naming the provider changes nothing');
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006712', '00000000-0000-4000-8000-000000006701',
                                 ARRAY['00000000-0000-4000-8000-000000006701']::UUID[]);
SELECT is_empty($$ SELECT 1 FROM pg_temp.foreign_rows('00000000-0000-4000-8000-000000006702') $$,
                'a forged active tenant (the provider) reads nothing');

-- The viewer reads the shared rows its role selects; a member without select reads none.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006713', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT set_eq($$ SELECT tbl FROM pg_temp.foreign_rows('00000000-0000-4000-8000-000000006702') $$,
              ARRAY['provider_relationship', 'sourcing', 'purchase_order', 'purchase_order_line', 'shipment'],
              'client viewer reads the shared rows of the tables its role selects, and no others');
SELECT is(pg_temp.client_write_hits(), '{}'::TEXT[], 'client viewer: no write through api reaches a shared row');
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006714', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT is_empty($$ SELECT 1 FROM api.purchase_order $$, 'client without select sees no shared order');

-- Every permission in C widens nothing: still only C's shared rows (no D's, no P's own).
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006715', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT set_eq($$ SELECT * FROM pg_temp.foreign_rows('00000000-0000-4000-8000-000000006702') $$, $$ SELECT * FROM expected_c $$,
              'a client role holding every permission reads only the rows shared with C');
SELECT is(pg_temp.client_write_hits(), '{}'::TEXT[], 'and writes none of them');

-- Another client of the same provider sees its own share only.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006718', '00000000-0000-4000-8000-000000006703',
                                 ARRAY['00000000-0000-4000-8000-000000006703']::UUID[]);
SELECT set_eq($$ SELECT id FROM api.purchase_order $$, ARRAY['00000000-0000-4000-8000-000000006752']::UUID[],
              'another client sees only the order shared with it');

-- The provider keeps its rows, with or without a membership in C.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006711', '00000000-0000-4000-8000-000000006701',
                                 ARRAY['00000000-0000-4000-8000-000000006701']::UUID[]);
SELECT set_eq($$ SELECT id FROM api.purchase_order $$,
              ARRAY['00000000-0000-4000-8000-000000006751', '00000000-0000-4000-8000-000000006752', '00000000-0000-4000-8000-000000006753']::UUID[],
              'provider sees its own rows');
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006717', '00000000-0000-4000-8000-000000006701',
                                 ARRAY['00000000-0000-4000-8000-000000006701']::UUID[]);
SELECT set_eq($$ SELECT id FROM api.shipment $$,
              ARRAY['00000000-0000-4000-8000-000000006771', '00000000-0000-4000-8000-000000006772']::UUID[],
              'a provider member outside C sees the provider''s rows');

-- Re-running the generators (permission rows changed, tenant security re-applied) keeps sharing.
RESET ROLE;
SELECT private.unimpersonate();
UPDATE public.permission SET error_message = error_message
WHERE resource_name = ANY (ARRAY(SELECT 'public.' || t FROM unnest(pg_temp.shared_tables()) AS t));
SELECT private.disable_tenant_level_security(t) FROM unnest(pg_temp.shared_tables()) AS t;
SELECT private.enable_tenant_level_security(t) FROM unnest(pg_temp.shared_tables()) AS t;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006712', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT set_eq($$ SELECT * FROM pg_temp.foreign_rows('00000000-0000-4000-8000-000000006702') $$, $$ SELECT * FROM expected_c $$,
              'after the generators re-run the client still reads exactly its shared rows');
SELECT is(pg_temp.client_write_hits(), '{}'::TEXT[], 'and still writes none of them');
RESET ROLE;
SELECT private.unimpersonate();

-- ================================================================================== masking (Task 3)
--
-- On a shared row a column outside the client-visible set (066) is read only with rights in the
-- row's own tenant (the provider): never through the owner shortcut, never through a right in the
-- client tenant, open columns included. A client-visible column is read by the client's members,
-- narrowed (never widened) by the client's own roles. The helpers below compare the api views with
-- the base rows, so every column of every shared table is covered without naming it.

-- The client-visible set, plus the derived client_status of api.purchase_order (Q1).
CREATE TEMP TABLE cv_fields ON COMMIT DROP AS
SELECT substr(f.resource_name, 8) AS tbl, f.field AS col
FROM public.field_class f
WHERE f.client_visible AND substr(f.resource_name, 8) = ANY (pg_temp.shared_tables())
UNION ALL
SELECT 'purchase_order', 'client_status';
-- save_role's arguments: C's viewer role, its permissions, every sensitive field (read and write;
-- public.user's personal data aside, which no owner grants);
-- and the same without the read of the selling prices.
CREATE TEMP TABLE viewer_grant ON COMMIT DROP AS
SELECT '{"id": "00000000-0000-4000-8000-000000006734", "display_name": "viewer"}'::JSONB AS role_data,
       ARRAY(SELECT rp.permission_id FROM public.role_permission rp WHERE rp.role_id = '00000000-0000-4000-8000-000000006734') AS permission_ids,
       (SELECT jsonb_agg(jsonb_build_object('resource_name', f.resource_name, 'field', f.field, 'can_read', TRUE, 'can_write', TRUE))
        FROM public.field_class f WHERE f.class = 'sensitive' AND f.resource_name <> 'public.user') AS all_fields,
       (SELECT jsonb_agg(jsonb_build_object('resource_name', f.resource_name, 'field', f.field,
                                            'can_read', f.field <> 'sell_price_eur', 'can_write', f.field <> 'sell_price_eur'))
        FROM public.field_class f WHERE f.class = 'sensitive' AND f.resource_name <> 'public.user') AS all_but_sell_price;
GRANT SELECT ON cv_fields, viewer_grant TO authenticated;

-- Every (table, row, column, value) of the rows of the shared tables outside p_tenant: through api
-- (p_api) or from the base (as postgres, rows shared with p_tenant). p_cv: the client-visible columns
-- only (TRUE), the others only (FALSE), or all (NULL); NULL values are left out.
CREATE FUNCTION pg_temp.cells (p_tenant UUID, p_api BOOLEAN, p_cv BOOLEAN) RETURNS TABLE (tbl TEXT, row_key TEXT, col TEXT, val TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY pg_temp.shared_tables() LOOP
        RETURN QUERY EXECUTE format(
            $q$ SELECT %1$L::TEXT, coalesce(s.j ->> 'id', (s.j ->> 'shipment_id') || '/' || (s.j ->> 'purchase_order_id')), e.key, e.value::TEXT
                FROM (SELECT to_jsonb(v) AS j FROM %2$s.%1$I v WHERE v.tenant_id <> $1 AND (%3$L OR v.client_tenant_id = $1)) s,
                     jsonb_each(s.j) e
                WHERE e.value <> 'null'::JSONB
                  AND ($2 IS NULL OR $2 = EXISTS (SELECT 1 FROM cv_fields f WHERE f.tbl = %1$L AND f.col = e.key)) $q$,
            t, CASE WHEN p_api THEN 'api' ELSE 'public' END, p_api)
        USING p_tenant, p_cv;
    END LOOP;
END;
$$;

-- The forward R4 functions of the shared views across a provider-only link that return a row for a
-- shared row (each must return none).
CREATE FUNCTION pg_temp.r4_hits (p_tenant UUID) RETURNS TEXT[] LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    n INT;
    hits TEXT[] := '{}';
BEGIN
    FOR r IN
        SELECT p.proname::TEXT AS fn, c.relname::TEXT AS tbl
        FROM pg_proc p
        JOIN pg_type ty ON ty.oid = p.proargtypes[0]
        JOIN pg_class c ON c.oid = ty.typrelid AND c.relnamespace = 'api'::REGNAMESPACE
        WHERE p.pronamespace = 'api'::REGNAMESPACE AND p.pronargs = 1 AND p.proretset
          AND c.relname = ANY (pg_temp.shared_tables())
          AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = ('public.' || quote_ident(c.relname))::REGCLASS
                        AND a.attname = p.proname || '_id')
          AND NOT EXISTS (SELECT 1 FROM cv_fields f WHERE f.tbl = c.relname AND f.col = p.proname || '_id')
    LOOP
        EXECUTE format('SELECT count(*) FROM api.%I v, api.%I(v) x WHERE v.tenant_id <> $1', r.tbl, r.fn) INTO n USING p_tenant;
        IF n > 0 THEN
            hits := hits || (r.tbl || '.' || r.fn);
        END IF;
    END LOOP;
    RETURN hits;
END;
$$;

-- The relations among p_rels whose rows show a provider-only sentinel of the fixture.
CREATE FUNCTION pg_temp.sentinel_hits (p_rels TEXT[]) RETURNS TEXT[] LANGUAGE plpgsql AS $$
DECLARE
    rel TEXT;
    hit BOOLEAN;
    hits TEXT[] := '{}';
BEGIN
    FOREACH rel IN ARRAY p_rels LOOP
        EXECUTE format($q$ SELECT EXISTS (SELECT 1 FROM api.%I x WHERE x::TEXT ~ '1234\.56|P-NOTE|S-NOTE|SH-NOTE|EV-NOTE|REL-NOTE|drive/secret|SECRET|USD|Supplier One|SU1') $q$, rel)
        INTO hit;
        IF hit THEN
            hits := hits || rel;
        END IF;
    END LOOP;
    RETURN hits;
END;
$$;

-- Test support only, granted inside this transaction.
GRANT EXECUTE ON FUNCTION private.field_calls_only_in_initplans (TEXT) TO authenticated;

-- client_status (Q1): the raw status collapsed, shipments first.
SELECT results_eq(
   $$ SELECT s::TEXT, private.purchase_order_client_status('00000000-0000-4000-8000-000000006799', '00000000-0000-4000-8000-000000006701', s)::TEXT
      FROM unnest(enum_range(NULL::public.purchase_order_status)) WITH ORDINALITY AS u (s, k) ORDER BY u.k $$,
   $$ VALUES ('draft', 'confirmed'), ('sent', 'confirmed'), ('pi_received', 'confirmed'), ('pi_approved', 'confirmed'),
             ('deposit_paid', 'confirmed'), ('in_production', 'in_production'), ('ready', 'in_production'),
             ('balance_paid', 'in_production'), ('closed', 'delivered'), ('cancelled', 'cancelled') $$,
   'client_status: an order without shipments maps its status');
SELECT set_config('moesa.rules_bypass', '1', TRUE);
CREATE FUNCTION pg_temp.status_with_shipment (p_shipment public.shipment_status, p_order public.purchase_order_status) RETURNS TEXT
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE public.shipment SET status = p_shipment WHERE id = '00000000-0000-4000-8000-000000006771';
    RETURN private.purchase_order_client_status('00000000-0000-4000-8000-000000006751', '00000000-0000-4000-8000-000000006701', p_order)::TEXT;
END;
$$;
SELECT results_eq(
   $$ SELECT pg_temp.status_with_shipment(x.s::public.shipment_status, x.o::public.purchase_order_status)
      FROM (VALUES (1, 'planned', 'deposit_paid'), (2, 'booked', 'ready'), (3, 'loaded', 'deposit_paid'), (4, 'in_transit', 'balance_paid'),
                   (5, 'at_customs', 'ready'), (6, 'delivered', 'balance_paid'), (7, 'accepted', 'ready'), (8, 'disputed', 'ready'),
                   (9, 'cancelled', 'ready'), (10, 'delivered', 'cancelled')) AS x (k, s, o) ORDER BY x.k $$,
   $$ VALUES ('confirmed'), ('in_production'), ('shipped'), ('shipped'), ('shipped'), ('delivered'), ('delivered'), ('delivered'),
             ('in_production'), ('cancelled') $$,
   'client_status: a loaded shipment ships the order, every live shipment arrived delivers it, a cancelled one counts for nothing');
UPDATE public.shipment SET status = 'planned' WHERE id = '00000000-0000-4000-8000-000000006771';
SELECT set_config('moesa.rules_bypass', '', TRUE);
CREATE TEMP TABLE base_cells ON COMMIT DROP AS SELECT * FROM pg_temp.cells('00000000-0000-4000-8000-000000006702', FALSE, NULL);
GRANT SELECT ON base_cells TO authenticated;

-- The client viewer before any field right: the client-visible set, its selling prices narrowed.
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006713', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT results_eq($$ SELECT (SELECT sell_price_eur FROM api.purchase_order_line WHERE id = '00000000-0000-4000-8000-000000006761'),
                            (SELECT sell_price_eur FROM api.sourcing WHERE id = '00000000-0000-4000-8000-000000006744'),
                            (SELECT manufacturer_art_no FROM api.sourcing WHERE id = '00000000-0000-4000-8000-000000006744') $$,
                  $$ VALUES (NULL::NUMERIC, NULL::NUMERIC, NULL::TEXT) $$,
                  'a client role without the selling price narrows the client-visible set');
SELECT is_empty($$ SELECT * FROM pg_temp.cells('00000000-0000-4000-8000-000000006702', TRUE, FALSE) $$,
                'client viewer: every provider-only column of every shared table is NULL');

-- The client owner: the client-visible set, nothing else, whatever the query asks.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006712', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT results_eq($$ SELECT pi_total, notes, supplier_id, currency::TEXT, status::TEXT, client_status::TEXT, code IS NOT NULL
                     FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000006751' $$,
                  $$ VALUES (NULL::NUMERIC, NULL::TEXT, NULL::UUID, NULL::TEXT, NULL::TEXT, 'confirmed', TRUE) $$,
                  'client owner: provider-only order fields NULL (raw status included), client_status and code visible');
SELECT results_eq($$ SELECT unit_price, sell_price_eur, quantity FROM api.purchase_order_line WHERE id = '00000000-0000-4000-8000-000000006761' $$,
                  $$ VALUES (NULL::NUMERIC, 9.90::NUMERIC, 10) $$, 'client owner: purchase price NULL, sell price and quantity visible');
SELECT results_eq($$ SELECT notes, restricted_drive_url, deposit_rate FROM api.provider_relationship $$,
                  $$ VALUES (NULL::TEXT, NULL::TEXT, 30::NUMERIC) $$, 'client reads contract terms, not notes or drive URL');
SELECT results_eq($$ SELECT s.forwarder, s.customs_broker, s.demurrage_note, s.notes, s.is_insured, s.free_days_port, e.channel, e.note, s.eta
                     FROM api.shipment s JOIN api.shipment_event e ON e.shipment_id = s.id
                     WHERE s.id = '00000000-0000-4000-8000-000000006771' $$,
                  $$ VALUES (NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::BOOLEAN, NULL::INT, NULL::TEXT, NULL::TEXT, '2026-12-24'::DATE) $$,
                  'client owner: the open provider-only shipment and event fields are NULL, the ETA visible');
SELECT is_empty($$ SELECT * FROM pg_temp.cells('00000000-0000-4000-8000-000000006702', TRUE, FALSE) $$,
                'client owner: every provider-only column of every shared table is NULL');
SELECT set_eq($$ SELECT * FROM pg_temp.cells('00000000-0000-4000-8000-000000006702', TRUE, TRUE) WHERE col <> 'client_status' $$,
              $$ SELECT * FROM base_cells c WHERE EXISTS (SELECT 1 FROM cv_fields f WHERE f.tbl = c.tbl AND f.col = c.col) $$,
              'client owner: every client-visible column reads its real value');
-- Oracles: a masked value decides nothing.
SELECT is_empty($$ SELECT 1 FROM api.purchase_order WHERE pi_total = 1234.56 OR pi_total > 0 OR notes LIKE 'P-%' OR currency = 'USD'
                   OR status = 'draft' OR supplier_id IS NOT NULL $$, 'filter on a provider-only field finds nothing');
SELECT is_empty($$ SELECT 1 FROM api.purchase_order WHERE notes ~ 'P' OR currency ~ 'U' OR status::TEXT ~ '.' OR pi_total::TEXT ~ '1'
                   OR pi_total::INT IS NOT NULL $$, 'regex and casts on a provider-only field find nothing');
SELECT results_eq($$ SELECT count(pi_total)::INT, count(currency)::INT, count(status)::INT, max(pi_total), sum(pi_total), avg(pi_total),
                            (SELECT sum(unit_price) FROM api.purchase_order_line), (SELECT max(purchase_price) FROM api.sourcing)
                     FROM api.purchase_order $$,
                  $$ VALUES (0, 0, 0, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC) $$,
                  'counts and aggregates over provider-only fields are empty');
SELECT lives_ok($$ SELECT 1 / (pi_total - 1234.56), 1 / (unit_price - 2.50) FROM api.purchase_order, api.purchase_order_line $$,
                'a division by the masked value raises nothing');
SELECT is((SELECT array_agg(pi_total ORDER BY pi_total, notes, currency, status)::TEXT FROM api.purchase_order), '{NULL}',
          'ordering by provider-only fields sorts NULLs only');
SELECT is_empty($$ SELECT 1 FROM api.purchase_order p WHERE row_to_json(p)::TEXT ~ '1234\.56|P-NOTE|USD|draft' $$,
                'row_to_json of a shared order shows no provider-only value');
SELECT is(pg_temp.sentinel_hits(pg_temp.shared_tables()), '{}'::TEXT[], 'no shared api view shows a provider-only sentinel');
SELECT is(pg_temp.r4_hits('00000000-0000-4000-8000-000000006702'), '{}'::TEXT[],
          'R4 embeds across provider-only links (supplier, PI document, ...) are empty');
-- The derived views (058) read the api twins.
SELECT results_eq($$ SELECT status::TEXT, currency::TEXT, pi_total, notes, supplier_code, system_subtotal, system_total, deposit_rate, deposit_paid_on,
                            spec_missing_line_ids, has_approved_psi, client_status::TEXT, line_count, total_quantity
                     FROM api.purchase_order_overview WHERE id = '00000000-0000-4000-8000-000000006751' $$,
                  $$ VALUES (NULL::TEXT, NULL::TEXT, NULL::NUMERIC, NULL::TEXT, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::DATE,
                             NULL::UUID[], FALSE, 'confirmed', 1, 10) $$,
                  'purchase_order_overview: provider-only figures NULL, client_status and quantities visible');
SELECT results_eq($$ SELECT forwarder, customs_broker, demurrage_note, notes, is_insured, eta FROM api.shipment_overview
                     WHERE id = '00000000-0000-4000-8000-000000006771' $$,
                  $$ VALUES (NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::BOOLEAN, '2026-12-24'::DATE) $$,
                  'shipment_overview: provider-only fields NULL');
SELECT is(pg_temp.sentinel_hits(ARRAY['purchase_order_overview', 'dashboard_purchase_order', 'shipment_overview', 'dashboard_shipment']), '{}'::TEXT[],
          'the derived views show no provider-only sentinel');
SELECT ok(private.field_calls_only_in_initplans('SELECT * FROM api.purchase_order ORDER BY created_at DESC LIMIT 50'),
          'the rights and scope of a shared view are InitPlans, never per row');

-- The client owner grants its viewer every field: neither its own nor the viewer's rights unmask.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006712', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT lives_ok($$ SELECT public.save_role(g.role_data, g.permission_ids, g.all_fields) FROM viewer_grant g $$,
                'client owner may grant its viewer role every field');
SELECT is((SELECT pi_total FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000006751'), NULL,
          'self-granted rights do not unmask a shared row');
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006713', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT results_eq($$ SELECT pi_total, status::TEXT, (SELECT purchase_price FROM api.sourcing WHERE id = '00000000-0000-4000-8000-000000006744')
                     FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000006751' $$,
                  $$ VALUES (NULL::NUMERIC, NULL::TEXT, NULL::NUMERIC) $$,
                  'a client role granted pi_total and purchase_price by its owner still reads NULL');
SELECT is_empty($$ SELECT * FROM pg_temp.cells('00000000-0000-4000-8000-000000006702', TRUE, FALSE) $$,
                'granted client viewer: every provider-only column of every shared table is NULL');
SELECT set_eq($$ SELECT * FROM pg_temp.cells('00000000-0000-4000-8000-000000006702', TRUE, TRUE) WHERE col <> 'client_status' $$,
              $$ SELECT * FROM base_cells c WHERE EXISTS (SELECT 1 FROM cv_fields f WHERE f.tbl = c.tbl AND f.col = c.col)
                   AND c.tbl IN ('provider_relationship', 'sourcing', 'purchase_order', 'purchase_order_line', 'shipment') $$,
              'granted client viewer: every client-visible column of its tables reads its real value');
-- The owner takes the selling price back: the viewer reads NULL again.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006712', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT lives_ok($$ SELECT public.save_role(g.role_data, g.permission_ids, g.all_but_sell_price) FROM viewer_grant g $$,
                'client owner removes the selling price from its viewer');
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006713', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT results_eq($$ SELECT (SELECT sell_price_eur FROM api.purchase_order_line WHERE id = '00000000-0000-4000-8000-000000006761'),
                            (SELECT sell_price_eur FROM api.sourcing WHERE id = '00000000-0000-4000-8000-000000006744'),
                            (SELECT manufacturer_art_no FROM api.sourcing WHERE id = '00000000-0000-4000-8000-000000006744') $$,
                  $$ VALUES (NULL::NUMERIC, NULL::NUMERIC, 'ART-1'::TEXT) $$,
                  'the client narrows a client-visible field: no selling price, the art no stays');

-- A provider coordinator also in C, both tenants in scope and C active: provider-only fields follow
-- its provider role only (no cost read there), never its C role (every field).
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006715', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702', '00000000-0000-4000-8000-000000006701']::UUID[]);
SELECT results_eq($$ SELECT pi_total, (SELECT unit_price FROM api.purchase_order_line WHERE id = '00000000-0000-4000-8000-000000006761'), currency::TEXT, status::TEXT
                     FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000006751' $$,
                  $$ VALUES (NULL::NUMERIC, NULL::NUMERIC, 'USD', 'draft') $$,
                  'client-tenant rights never unmask a provider-only field; the provider membership reads the open ones');
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006716', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702', '00000000-0000-4000-8000-000000006701']::UUID[]);
SELECT results_eq($$ SELECT pi_total, notes FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000006751' $$,
                  $$ VALUES (1234.56::NUMERIC, 'P-NOTE') $$, 'provider management with both tenants sees both sides');
-- Provider staff in the provider tenant read every field their role allows.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006711', '00000000-0000-4000-8000-000000006701',
                                 ARRAY['00000000-0000-4000-8000-000000006701']::UUID[]);
SELECT set_eq($$ SELECT * FROM pg_temp.cells('00000000-0000-4000-8000-000000006702', TRUE, NULL)
                 WHERE col <> 'client_status' AND tbl <> 'provider_relationship' AND tbl <> 'sourcing'
                   AND (tbl, row_key) IN (SELECT b.tbl, b.row_key FROM base_cells b) $$,
              $$ SELECT * FROM base_cells WHERE tbl <> 'provider_relationship' AND tbl <> 'sourcing' $$,
              'provider coordinator reads every field of the rows it shares');
RESET ROLE;
SELECT private.unimpersonate();

-- ================================================================================ history (Task 2)

SELECT lives_ok($$ UPDATE public.provider_relationship SET procurement_model = 'client' WHERE id = '00000000-0000-4000-8000-000000006721' $$,
                'switch to client-procures');
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006711', '00000000-0000-4000-8000-000000006701',
                                 ARRAY['00000000-0000-4000-8000-000000006701']::UUID[]);
SELECT lives_ok($$ INSERT INTO api.purchase_order_line (id, tenant_id, purchase_order_id, product_id, quantity, unit_price)
                   VALUES ('00000000-0000-4000-8000-000000006763', '00000000-0000-4000-8000-000000006701',
                           '00000000-0000-4000-8000-000000006751', '00000000-0000-4000-8000-000000006741', 5, 2.00) $$,
                'provider adds a line after the switch');
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006712', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT set_eq($$ SELECT id FROM api.purchase_order_line WHERE purchase_order_id = '00000000-0000-4000-8000-000000006751' $$,
              ARRAY['00000000-0000-4000-8000-000000006761', '00000000-0000-4000-8000-000000006763']::UUID[],
              'a line added after the switch is shared');
SELECT lives_ok($$ SELECT public.end_provider_relationship('00000000-0000-4000-8000-000000006721') $$, 'the client owner ends the relationship');
SELECT set_eq($$ SELECT id FROM api.purchase_order $$, ARRAY['00000000-0000-4000-8000-000000006751']::UUID[],
              'ended relationship keeps history');
SELECT results_eq($$ SELECT (SELECT pi_total FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000006751'),
                            (SELECT sell_price_eur FROM api.purchase_order_line WHERE id = '00000000-0000-4000-8000-000000006761') $$,
                  $$ VALUES (NULL::NUMERIC, 9.90::NUMERIC) $$, 'after the end the shared history stays masked (F5)');
SELECT is_empty($$ SELECT * FROM pg_temp.cells('00000000-0000-4000-8000-000000006702', TRUE, FALSE) $$,
                'after the end every provider-only column of every shared table is still NULL');
RESET ROLE;
SELECT private.unimpersonate();
DELETE FROM expected_c;
INSERT INTO expected_c SELECT * FROM pg_temp.shared_with('00000000-0000-4000-8000-000000006702');
UPDATE state_before SET s = pg_temp.shared_state();
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006713', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT set_eq($$ SELECT * FROM pg_temp.foreign_rows('00000000-0000-4000-8000-000000006702') $$,
              $$ SELECT * FROM expected_c WHERE tbl IN ('provider_relationship', 'sourcing', 'purchase_order', 'purchase_order_line', 'shipment') $$,
              'after the end the viewer still reads the shared history');
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006712', '00000000-0000-4000-8000-000000006702',
                                 ARRAY['00000000-0000-4000-8000-000000006702']::UUID[]);
SELECT is(pg_temp.client_write_hits(), '{}'::TEXT[], 'after the end the client still writes no shared row');
RESET ROLE;
SELECT is(pg_temp.shared_state(), (SELECT s FROM state_before), 'and the shared rows are unchanged');

SELECT * FROM finish();
ROLLBACK;
