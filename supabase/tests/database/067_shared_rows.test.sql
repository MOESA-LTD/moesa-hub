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

SELECT plan(33);

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
--   sourcing src_c ...6744 (P for C), src_d ...6745 (P for D)
--   orders po_c ...6751 (client C: pi_total 1234.56, notes P-NOTE, USD), po_d ...6752 (client D),
--          po_own ...6753 (no client); lines line_c ...6761 (po_c: unit 2.50, sell 9.90), line_d ...6762
--   payment pay_c ...6791 on po_c
--   shipments shp_c ...6771 (client C, linked to po_c, one line ...6774, one event ...6773),
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

INSERT INTO public.sourcing (id, tenant_id, client_tenant_id, product_id, sell_price_eur) VALUES
   ('00000000-0000-4000-8000-000000006744', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006702',
    '00000000-0000-4000-8000-000000006743', 9.90),
   ('00000000-0000-4000-8000-000000006745', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006703',
    '00000000-0000-4000-8000-000000006742', 4.00);

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

INSERT INTO public.shipment (id, tenant_id, client_tenant_id, mode, delivery_warehouse_id, warehouse_tenant_id) VALUES
   ('00000000-0000-4000-8000-000000006771', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006702',
    'road', '00000000-0000-4000-8000-000000006775', '00000000-0000-4000-8000-000000006702'),
   ('00000000-0000-4000-8000-000000006772', '00000000-0000-4000-8000-000000006701', NULL,
    'road', '00000000-0000-4000-8000-000000006776', '00000000-0000-4000-8000-000000006701');

INSERT INTO public.shipment_purchase_order (tenant_id, shipment_id, purchase_order_id) VALUES
   ('00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006771', '00000000-0000-4000-8000-000000006751');

INSERT INTO public.shipment_line (id, tenant_id, shipment_id, purchase_order_id, purchase_order_line_id, quantity) VALUES
   ('00000000-0000-4000-8000-000000006774', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006771',
    '00000000-0000-4000-8000-000000006751', '00000000-0000-4000-8000-000000006761', 4);

INSERT INTO public.shipment_event (id, tenant_id, shipment_id) VALUES
   ('00000000-0000-4000-8000-000000006773', '00000000-0000-4000-8000-000000006701', '00000000-0000-4000-8000-000000006771');

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
