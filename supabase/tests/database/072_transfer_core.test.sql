CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- The tenant transfer core (Plan 3 Task 12, 072): the registry, the transfer record and its flag, the
-- revert guard, the rights gate (private.transfer_refusal, rules 1-8 in order) and the rehearsal
-- (public.transfer_products with rehearse => TRUE: counts and ids only). Ported from M21's 040 and 042
-- tests (055b03b), product-only path; the customer, project, order, shipment, incident and change
-- request cases are gone with the customer root.
--
-- Sections: registry and record; the flag cannot be raised by a client; revert guard; the gate; the
-- rehearsal; options and the real run's checks (the run itself is 073).
--
-- Signing in (F10): `SELECT private.impersonate_scope(user, active, scope);` then
-- `RESET ROLE; SELECT private.unimpersonate();`. t.transfer_refusal_as(user, source, target, mode)
-- calls the gate with that user's claims, as postgres.
BEGIN;

SELECT plan(114);

SELECT private.create_test_helpers();

-- Fixture (ids 00000000-0000-4000-8000-0000000720xx), on the seed:
--   P = MOESA LTD, C = THO (client of P, provider-procured), E = MOESA Europe (branch of P),
--   K = Kuzey Holding, X = Eski Ticaret (expired: read-only).
--   akif: management in P, E and C (seed); thomas: owner of C; baris: owner of P (and so of E); admin:
--   super admin, no company.
--   Users with one full role in P and in C (every permission of every module, every field), but:
--     nodel  ...07211  in C no market_cell delete             (akif_no_delete)
--     nocost ...07212  in C cost read but no cost write       (koordinator_no_cost_in_C)
--     noread ...07213  in P no cost read (nor write)
--     rowrt  ...07214  in P cost read but no cost write
--     notr   ...07215  in C no public.transfer insert
--     nosel  ...07216  in P no media_link select and no product insert
--     inx    ...07217  full in P and X too
--     noupdp ...07218  in C no product update        (a move retires products by update)
--     noupdd ...07219  in C no document update       (and documents)
--     notsel ...07220  in P no product select        (a target the caller cannot read, L3)
--   L ...07271: a client of P that procures for itself (active relationship held by P).
--   P product zp ...07231 'ZZ-P-1' with P's sourcing ...07232 (fixture supplier ZS1 ...07239, price
--   987654.32), ZS1's contact ...07233 and certificate ...07234, a market cell ...07235, a file ...07236
--   linked ...07237.
--   C: a fixture product zc ...07245 'ZZ-C-1' with a signed spec sheet ...07246, its variant ...07244, a
--   market cell ...07241, a file ...07242 linked ...07243; the counts are asserted on fixture products
--   only, so they hold on the story seed too (L6). The mop THO-MOP40-2P (seed, GTIN, in the pilot
--   project) carries the link cases: P's provider order ...07251 for C with a line ...07252 on it (F19).
SELECT set_config('test.' || x.k, x.v::TEXT, TRUE)
FROM (VALUES
    ('p', (SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD')),
    ('c', (SELECT id FROM public.tenant WHERE code = 'THO')),
    ('e', (SELECT id FROM public.tenant WHERE display_name = 'MOESA Europe')),
    ('k', (SELECT id FROM public.tenant WHERE display_name = 'Kuzey Holding')),
    ('x', (SELECT id FROM public.tenant WHERE display_name = 'Eski Ticaret')),
    ('akif', (SELECT id FROM public.user WHERE email = 'akif@moesa-panel.test')),
    ('thomas', (SELECT id FROM public.user WHERE email = 'thomas@moesa-panel.test')),
    ('baris', (SELECT id FROM public.user WHERE email = 'baris@moesa-panel.test')),
    ('admin', (SELECT id FROM public.user WHERE email = 'admin@moesa-panel.test')),
    ('mop', (SELECT id FROM public.product WHERE sku = 'THO-MOP40-2P')),
    ('tr1', (SELECT id FROM public.supplier WHERE code = 'TR1' AND tenant_id = (SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD'))),
    ('pilot', (SELECT id FROM public.project WHERE display_name = 'Mop ailesi çok ülke pilotu')),
    ('nodel', '00000000-0000-4000-8000-000000072011'),
    ('nocost', '00000000-0000-4000-8000-000000072012'),
    ('noread', '00000000-0000-4000-8000-000000072013'),
    ('rowrt', '00000000-0000-4000-8000-000000072014'),
    ('notr', '00000000-0000-4000-8000-000000072015'),
    ('nosel', '00000000-0000-4000-8000-000000072016'),
    ('inx', '00000000-0000-4000-8000-000000072017'),
    ('noupdp', '00000000-0000-4000-8000-000000072018'),
    ('noupdd', '00000000-0000-4000-8000-000000072019'),
    ('notsel', '00000000-0000-4000-8000-000000072020'),
    ('l', '00000000-0000-4000-8000-000000072071'),
    ('zp', '00000000-0000-4000-8000-000000072031'),
    ('zs1', '00000000-0000-4000-8000-000000072039'),
    ('zc', '00000000-0000-4000-8000-000000072045'),
    ('variant', '00000000-0000-4000-8000-000000072044')
) AS x (k, v);

-- A member of a tenant with one role: every permission of every module but those p_skip names (a
-- predicate on permission p), and every field of what it holds unless p_fields is FALSE.
CREATE FUNCTION pg_temp.member (p_user UUID, p_tenant UUID, p_role UUID, p_skip TEXT DEFAULT 'FALSE', p_fields BOOLEAN DEFAULT TRUE)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO public.tenant_user (user_id, tenant_id) VALUES (p_user, p_tenant) ON CONFLICT DO NOTHING;
    INSERT INTO public.role (id, tenant_id, display_name) VALUES (p_role, p_tenant, 'Transfer 072 ' || p_role);
    EXECUTE format(
        'INSERT INTO public.role_permission (role_id, permission_id) SELECT %L, p.id FROM public.permission p '
        'WHERE p.group_name IN (SELECT m.id FROM public.module m) AND NOT (%s)', p_role, p_skip);
    INSERT INTO public.user_role (user_id, role_id) VALUES (p_user, p_role);
    IF p_fields THEN
        PERFORM private.grant_all_fields(p_role);
    END IF;
END;
$$;

INSERT INTO public.user (id, email)
SELECT ('00000000-0000-4000-8000-0000000720' || n)::UUID, 'u' || n || '@transfer072.test'
FROM unnest(ARRAY['11', '12', '13', '14', '15', '16', '17', '18', '19', '20']) AS n;

SELECT pg_temp.member(current_setting('test.nodel')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072111');
SELECT pg_temp.member(current_setting('test.nodel')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000072112',
                      $s$p.resource_name = 'public.market_cell' AND p.command = 'delete'$s$);
SELECT pg_temp.member(current_setting('test.nocost')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072121');
SELECT pg_temp.member(current_setting('test.nocost')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000072122');
UPDATE public.role_field_permission SET can_write = FALSE
WHERE role_id = '00000000-0000-4000-8000-000000072122'
  AND (resource_name, field) IN (SELECT resource_name, field FROM public.field_class WHERE group_name = 'cost');
SELECT pg_temp.member(current_setting('test.noread')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072131');
SELECT pg_temp.member(current_setting('test.noread')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000072132');
UPDATE public.role_field_permission SET can_read = FALSE, can_write = FALSE
WHERE role_id = '00000000-0000-4000-8000-000000072131'
  AND (resource_name, field) IN (SELECT resource_name, field FROM public.field_class WHERE group_name = 'cost');
SELECT pg_temp.member(current_setting('test.rowrt')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072141');
SELECT pg_temp.member(current_setting('test.rowrt')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000072142');
UPDATE public.role_field_permission SET can_write = FALSE
WHERE role_id = '00000000-0000-4000-8000-000000072141'
  AND (resource_name, field) IN (SELECT resource_name, field FROM public.field_class WHERE group_name = 'cost');
SELECT pg_temp.member(current_setting('test.notr')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072151');
SELECT pg_temp.member(current_setting('test.notr')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000072152',
                      $s$p.resource_name = 'public.transfer' AND p.command = 'insert'$s$);
SELECT pg_temp.member(current_setting('test.nosel')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072161',
                      $s$p.resource_name = 'public.media_link' AND p.command = 'select'
                         OR p.resource_name = 'public.product' AND p.command = 'insert'$s$);
SELECT pg_temp.member(current_setting('test.nosel')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000072162');
SELECT pg_temp.member(current_setting('test.noupdp')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072185');
SELECT pg_temp.member(current_setting('test.noupdp')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000072186',
                      $s$p.resource_name = 'public.product' AND p.command = 'update'$s$);
SELECT pg_temp.member(current_setting('test.noupdd')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072187');
SELECT pg_temp.member(current_setting('test.noupdd')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000072188',
                      $s$p.resource_name = 'public.document' AND p.command = 'update'$s$);
SELECT pg_temp.member(current_setting('test.notsel')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072189',
                      $s$p.resource_name = 'public.product' AND p.command = 'select'$s$);
SELECT pg_temp.member(current_setting('test.notsel')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000072190');
SELECT pg_temp.member(current_setting('test.inx')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072171');
-- X is read-only: its membership goes in with the super admin's claims (the plan check passes them).
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('test.admin'), 'role', 'authenticated')::TEXT, TRUE);
SELECT pg_temp.member(current_setting('test.inx')::UUID, current_setting('test.x')::UUID, '00000000-0000-4000-8000-000000072172', 'FALSE', FALSE);
SELECT private.unimpersonate();
SELECT private.grant_all_fields('00000000-0000-4000-8000-000000072172');

-- The rows, written as postgres under the fixture bypass.
SELECT set_config('moesa.rules_bypass', '1', TRUE);

INSERT INTO storage.objects (bucket_id, name, metadata)
SELECT 'media', f.tenant || '/' || f.id || '/' || f.name, '{"mimetype": "image/png", "size": 1000}'::JSONB
FROM (VALUES (current_setting('test.p'), '00000000-0000-4000-8000-000000072036', 'zp.png'),
             (current_setting('test.c'), '00000000-0000-4000-8000-000000072042', 'mop.png')) AS f (tenant, id, name);

INSERT INTO public.tenant (id, display_name, code) VALUES (current_setting('test.l')::UUID, 'Self Client 072', 'LSC');
INSERT INTO public.provider_relationship (tenant_id, client_tenant_id, client_code, client_name, procurement_model)
VALUES (current_setting('test.p')::UUID, current_setting('test.l')::UUID, 'LSC', 'Self Client 072', 'client');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, status)
VALUES (current_setting('test.zs1')::UUID, current_setting('test.p')::UUID, 'ZS1', 'Supplier 072', 'Türkiye', 'approved');
INSERT INTO public.product (id, tenant_id, sku, display_name, status)
VALUES (current_setting('test.zp')::UUID, current_setting('test.p')::UUID, 'ZZ-P-1', 'Provider product 072', 'development'),
       (current_setting('test.zc')::UUID, current_setting('test.c')::UUID, 'ZZ-C-1', 'Client product 072', 'on_sale');
INSERT INTO public.document (id, tenant_id, entity_type, entity_id, type, version, status, url, file_name,
                             is_signed, is_stamped, sent_from_official_email, issued_on)
VALUES ('00000000-0000-4000-8000-000000072046', current_setting('test.c')::UUID, 'product', current_setting('test.zc')::UUID, 'spec_sheet', 1,
        'signed', 'https://example.test/zc-spec.pdf', 'ZZ-C-1_SPEC', TRUE, TRUE, TRUE, '2026-10-15');
INSERT INTO public.sourcing (id, tenant_id, product_tenant_id, product_id, product_sku, product_name, supplier_id, purchase_price, purchase_currency)
VALUES ('00000000-0000-4000-8000-000000072032', current_setting('test.p')::UUID, current_setting('test.p')::UUID, current_setting('test.zp')::UUID,
        'ZZ-P-1', 'Provider product 072', current_setting('test.zs1')::UUID, 987654.32, 'USD');
INSERT INTO public.supplier_contact (id, tenant_id, supplier_id, name)
VALUES ('00000000-0000-4000-8000-000000072033', current_setting('test.p')::UUID, current_setting('test.zs1')::UUID, 'Kutlu satış 072');
INSERT INTO public.document (id, tenant_id, entity_type, entity_id, type, status, url)
VALUES ('00000000-0000-4000-8000-000000072034', current_setting('test.p')::UUID, 'supplier', current_setting('test.zs1')::UUID, 'certificate',
        'approved', 'https://example.test/tr1-072.pdf');
INSERT INTO public.market_cell (id, tenant_id, product_id, platform_id, country)
VALUES ('00000000-0000-4000-8000-000000072035', current_setting('test.p')::UUID, current_setting('test.zp')::UUID, 'amazon', 'PL'),
       ('00000000-0000-4000-8000-000000072041', current_setting('test.c')::UUID, current_setting('test.zc')::UUID, 'amazon', 'PL');
INSERT INTO public.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
VALUES ('00000000-0000-4000-8000-000000072036', current_setting('test.p')::UUID,
        current_setting('test.p') || '/00000000-0000-4000-8000-000000072036/zp.png', 'zp.png', 'image/png', 1000),
       ('00000000-0000-4000-8000-000000072042', current_setting('test.c')::UUID,
        current_setting('test.c') || '/00000000-0000-4000-8000-000000072042/mop.png', 'mop.png', 'image/png', 1000);
INSERT INTO public.media_link (id, tenant_id, media_id, entity_type, entity_id, role)
VALUES ('00000000-0000-4000-8000-000000072037', current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072036', 'product',
        current_setting('test.zp')::UUID, 'gallery'),
       ('00000000-0000-4000-8000-000000072043', current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000072042', 'product',
        current_setting('test.zc')::UUID, 'gallery');
INSERT INTO public.product (id, tenant_id, parent_id, sku, display_name, status)
VALUES (current_setting('test.variant')::UUID, current_setting('test.c')::UUID, current_setting('test.zc')::UUID, 'ZZ-C-1-V',
        'Mop variant 072', 'development');

-- F19: MOESA LTD's order for THO, a line on THO's mop.
INSERT INTO public.purchase_order (id, tenant_id, client_tenant_id, project_tenant_id, supplier_id, currency, incoterm, deposit_rate)
VALUES ('00000000-0000-4000-8000-000000072051', current_setting('test.p')::UUID, current_setting('test.c')::UUID, current_setting('test.c')::UUID,
        current_setting('test.tr1')::UUID, 'USD', 'EXW', 30);
INSERT INTO public.purchase_order_line (id, tenant_id, purchase_order_id, position, product_id, product_tenant_id, product_sku, product_name,
                                        quantity, unit_price)
VALUES ('00000000-0000-4000-8000-000000072052', current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072051', 1,
        current_setting('test.mop')::UUID, current_setting('test.c')::UUID, 'THO-MOP40-2P', 'Pamuk mop bezi 40 cm, 2''li', 100, 1.90);

SELECT set_config('moesa.rules_bypass', '', TRUE);

-- The gate as a user, called as postgres with that user's claims (F10).
CREATE FUNCTION t.transfer_refusal_as (p_user UUID, p_source UUID, p_target UUID, p_mode TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    refusal TEXT;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::TEXT, TRUE);
    PERFORM set_config('request.headers', json_build_object('x-tenant-id', p_source, 'x-tenant-ids', concat_ws(',', p_source, p_target))::TEXT, TRUE);
    PERFORM set_config('access.permitted_tenants', '', TRUE);
    refusal := private.transfer_refusal(p_source, p_target, p_mode);
    PERFORM private.unimpersonate();
    RETURN refusal;
END;
$$;

-- The guards are SECURITY DEFINER, called by the user: so is this probe.
CREATE FUNCTION t.rules_bypassed_probe () RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = '' AS $$ SELECT private.rules_bypassed(); $$;

GRANT EXECUTE ON FUNCTION t.rules_bypassed_probe () TO authenticated;

-- ---------------------------------------------------------------------------------------------
-- 1. Registry and record.

SELECT is(
    ARRAY(SELECT table_name FROM private.transfer_registry ORDER BY position),
    ARRAY['supplier', 'supplier_contact', 'product', 'sourcing', 'market_cell', 'media', 'media_link', 'document'],
    'the registry carries products and what hangs from them, suppliers first'
);
SELECT is(
    ARRAY(SELECT table_name FROM private.transfer_registry WHERE copy_only ORDER BY table_name),
    ARRAY['media', 'supplier', 'supplier_contact'],
    'suppliers, their contacts and files are only ever copied'
);
SELECT is(
    (SELECT reset_columns FROM private.transfer_registry WHERE table_name = 'market_cell'),
    ARRAY['listing_state', 'listing_checked_at', 'listing_match'],
    'a copied market cell starts without the listing state'
);
SELECT throws_ok(
    $$ INSERT INTO private.transfer_registry (table_name, position, root) VALUES ('zz', 999, 'customer') $$,
    '23514', NULL, 'the customer root is gone'
);
SELECT ok(
    NOT has_table_privilege('authenticated', 'private.transfer_registry', 'SELECT')
    AND NOT has_table_privilege('anon', 'private.transfer_registry', 'SELECT')
    AND NOT has_table_privilege('service_role', 'private.transfer_registry', 'SELECT'),
    'no API role reads the registry'
);
SELECT ok((SELECT is_core FROM public.module WHERE id = 'transfer'), 'the transfer module is core (F22)');
SELECT is(
    ARRAY(SELECT r.display_name FROM public.role r
          JOIN public.role_permission rp ON rp.role_id = r.id
          JOIN public.permission p ON p.id = rp.permission_id
          WHERE r.tenant_id = current_setting('test.p')::UUID AND p.resource_name = 'public.transfer' AND p.command = 'insert'
            AND r.display_name NOT LIKE 'Transfer 072%'
          ORDER BY r.display_name),
    ARRAY['Branch manager', 'management'],
    'the roles that may change the settings start a transfer, the coordinator does not'
);
SELECT ok(
    (SELECT bool_and(r.display_name = 'owner') FROM public.role r
     JOIN public.role_permission rp ON rp.role_id = r.id JOIN public.permission p ON p.id = rp.permission_id
     WHERE r.tenant_id IS NULL AND p.resource_name = 'public.transfer'),
    'the built-in owner role holds the transfer rights'
);

-- Users never write a transfer row.
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT throws_like(
    $$ INSERT INTO api.transfer (tenant_id, source_tenant_id, product_ids, mode, started_by, report)
       VALUES (current_setting('test.p')::UUID, current_setting('test.c')::UUID, '{}', 'copy', current_setting('test.akif')::UUID, '{}') $$,
    '%',
    'a user cannot insert a transfer row through api'
);
SELECT throws_ok(
    $$ INSERT INTO public.transfer (tenant_id, source_tenant_id, product_ids, mode, started_by, report)
       VALUES (current_setting('test.p')::UUID, current_setting('test.c')::UUID, '{}', 'copy', current_setting('test.akif')::UUID, '{}') $$,
    '42501', NULL, 'nor into the table'
);
RESET ROLE;
SELECT private.unimpersonate();

-- ---------------------------------------------------------------------------------------------
-- 2. The flag, and that a client cannot raise it.

SELECT is(private.transferring(), FALSE, 'no flag, no transfer');
SELECT is(private.rules_bypassed(), FALSE, 'outside a transfer the rules are not bypassed');

INSERT INTO public.transfer (id, tenant_id, source_tenant_id, product_ids, mode, started_by, report)
VALUES ('00000000-0000-4000-8000-000000072001', current_setting('test.p')::UUID, current_setting('test.c')::UUID, '{}', 'copy',
        current_setting('test.akif')::UUID, '{}');
INSERT INTO public.transfer (id, tenant_id, source_tenant_id, product_ids, mode, started_by, report, xact_id)
VALUES ('00000000-0000-4000-8000-000000072002', current_setting('test.p')::UUID, current_setting('test.c')::UUID, '{}', 'copy',
        current_setting('test.akif')::UUID, '{}', '1'::XID8);

SELECT is(private.rules_bypassed(), FALSE, 'a transfer row alone raises nothing');

SELECT set_config('moesa.transfer_id', '00000000-0000-4000-8000-000000072001', TRUE);
SELECT is(private.transferring(), TRUE, 'a transfer row of this transaction raises the flag');

SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT is(t.rules_bypassed_probe(), TRUE, 'the rules are bypassed during a transfer, for the user too');
RESET ROLE;
SELECT private.unimpersonate();

SELECT set_config('moesa.transfer_id', gen_random_uuid()::TEXT, TRUE);
SELECT is(private.transferring(), FALSE, 'an unknown transfer id does not raise the flag');
SELECT set_config('moesa.transfer_id', '00000000-0000-4000-8000-000000072002', TRUE);
SELECT is(private.transferring(), FALSE, 'a transfer id of another transaction does not raise the flag');
SELECT set_config('moesa.transfer_id', 'not-a-uuid', TRUE);
SELECT is(private.transferring(), FALSE, 'a malformed transfer id does not raise the flag');
SELECT set_config('moesa.transfer_id', '', TRUE);

-- As a client: set_config, SET LOCAL and the request settings PostgREST fills from headers and claims.
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT set_config('moesa.transfer_id', '00000000-0000-4000-8000-000000072002', TRUE);
SELECT is(t.rules_bypassed_probe(), FALSE, 'a client''s set_config of the transfer id raises nothing');
SET LOCAL moesa.transfer_id = '00000000-0000-4000-8000-000000072002';
SELECT is(private.transferring(), FALSE, 'nor does SET LOCAL');
SET LOCAL moesa.rules_bypass = '1';
SELECT is(t.rules_bypassed_probe(), FALSE, 'nor the fixture bypass under an API role');
SET LOCAL moesa.rules_bypass = '';
SET LOCAL moesa.transfer_id = '';
SELECT set_config('request.headers', json_build_object('x-tenant-id', current_setting('test.p'), 'moesa.transfer_id', '00000000-0000-4000-8000-000000072001',
                                                        'moesa.rules_bypass', '1')::TEXT, TRUE);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('test.akif'), 'role', 'authenticated',
                                                           'moesa.transfer_id', '00000000-0000-4000-8000-000000072001')::TEXT, TRUE);
SELECT ok(NOT private.transferring() AND NOT t.rules_bypassed_probe(), 'headers and claims naming a transfer raise nothing');
RESET ROLE;
SELECT private.unimpersonate();

SELECT results_eq(
    $$ SELECT format('%s.%s', n.nspname, p.proname) COLLATE "default", m[1] COLLATE "default"
       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       CROSS JOIN LATERAL regexp_matches(p.prosrc, 'set_config\s*\(\s*([^,]+),', 'g') AS m
       WHERE n.nspname IN ('public', 'api')
         AND (has_function_privilege('authenticated', p.oid, 'EXECUTE') OR has_function_privilege('anon', p.oid, 'EXECUTE'))
       ORDER BY 1, 2 $$,
    -- 073/074: the run sets the flag for its own row (a row of this transaction, written by the run
    -- itself, so no client can name one) and clears it; it and the file check open and restore their
    -- own audit transactions. Nothing else.
    $$ VALUES ('public.revert_audit_transaction', '''audit.reverts'''),
              ('public.transfer_check_files', '''audit.depth'''),
              ('public.transfer_check_files', '''audit.tenant_id'''),
              ('public.transfer_check_files', '''audit.transaction_id'''),
              ('public.transfer_check_files', '''audit.transaction_id'''),
              ('public.transfer_products', '''audit.depth'''),
              ('public.transfer_products', '''audit.tenant_id'''),
              ('public.transfer_products', '''audit.transaction_id'''),
              ('public.transfer_products', '''audit.transaction_id'''),
              ('public.transfer_products', '''moesa.transfer_id'''),
              ('public.transfer_products', '''moesa.transfer_id''') $$,
    'no RPC sets a setting a client names; only the run sets the transfer flag'
);
SELECT results_eq(
    $$ SELECT p.proname::TEXT COLLATE "default" FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname IN ('public', 'api') AND p.prosrc ~ 'moesa\.(transfer_id|rules_bypass)'
         AND (has_function_privilege('authenticated', p.oid, 'EXECUTE') OR has_function_privilege('anon', p.oid, 'EXECUTE')) $$,
    $$ VALUES ('transfer_products'::TEXT) $$,
    'no RPC but the run names the transfer flag, and none the fixture bypass'
);
SELECT ok(
    has_function_privilege('authenticated', 'private.transferring()', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'private.transferring()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.transfer_refusal(uuid,uuid,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.transfer_collect(uuid,uuid[],text[])', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.transfer_report(uuid,uuid,text,jsonb,uuid[],text[])', 'EXECUTE'),
    'the flag is read by the rules as the user; the transfer internals are out of reach'
);
SELECT is(private.rules_bypassed(), FALSE, 'and the rules are not bypassed after the attempts');

-- ---------------------------------------------------------------------------------------------
-- 3. The revert guard, and who reads transfers.

SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
INSERT INTO api.supplier (tenant_id, code, display_name, country) VALUES (current_setting('test.p')::UUID, 'ZT1', 'Zed Transfer', 'Türkiye');
SELECT set_config('test.tx1', current_setting('audit.transaction_id'), TRUE);
SELECT set_config('audit.transaction_id', '', TRUE);
RESET ROLE;
SELECT private.unimpersonate();

UPDATE public.transfer SET audit_transaction_ids = ARRAY[current_setting('test.tx1')::UUID] WHERE id = '00000000-0000-4000-8000-000000072001';
SELECT set_config('test.tx2', current_setting('audit.transaction_id'), TRUE);
SELECT set_config('audit.transaction_id', '', TRUE);

SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT throws_like(
    format('SELECT public.revert_audit_transaction(%L)', current_setting('test.tx1')),
    '%audit_transfer_not_revertable%',
    'a transfer''s audit transactions cannot be reverted'
);
SELECT throws_like(
    format('SELECT public.revert_audit_transaction(%L)', current_setting('test.tx2')),
    '%audit_transfer_not_revertable%',
    'a change of a transfer row cannot be reverted'
);
SELECT is((SELECT count(*) FROM api.transfer WHERE id IN ('00000000-0000-4000-8000-000000072001', '00000000-0000-4000-8000-000000072002')),
          2::BIGINT, 'the target''s management reads its transfers');
RESET ROLE;
SELECT private.impersonate_scope(current_setting('test.thomas')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT is((SELECT count(*) FROM api.transfer), 0::BIGINT, 'the source sees none of the target''s transfers');
RESET ROLE;
SELECT private.unimpersonate();

-- ---------------------------------------------------------------------------------------------
-- 4. The gate, rule by rule (first failure wins).

SELECT is(t.transfer_refusal_as(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID, 'copy'),
          NULL, 'rights in both tenants allow a copy');
SELECT is(t.transfer_refusal_as(current_setting('test.nocost')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID, 'copy'),
          'transfer_field_rights_required', 'missing cost write in the target refuses');
SELECT is(t.transfer_refusal_as(current_setting('test.nodel')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'move'),
          'transfer_permissions_required', 'a move needs delete in the source');
SELECT is(t.transfer_refusal_as(current_setting('test.thomas')::UUID, current_setting('test.c')::UUID, current_setting('test.k')::UUID, 'copy'),
          'transfer_forbidden', 'a tenant the caller is not in');
SELECT is(t.transfer_refusal_as(current_setting('test.admin')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'copy'),
          'transfer_forbidden', 'no super-admin bypass');

-- 1, 2.
SELECT is(t.transfer_refusal_as(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID, 'clone'),
          'transfer_mode_invalid', 'the mode is copy or move');
SELECT is(t.transfer_refusal_as(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID, NULL),
          'transfer_mode_invalid', 'a mode is required');
SELECT is(t.transfer_refusal_as(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, current_setting('test.p')::UUID, 'copy'),
          'transfer_same_tenant', 'the target differs from the source');
-- 3.
SELECT is(t.transfer_refusal_as(NULL, current_setting('test.p')::UUID, current_setting('test.c')::UUID, 'copy'),
          'transfer_forbidden', 'no user, no transfer');
SELECT is(t.transfer_refusal_as(current_setting('test.baris')::UUID, current_setting('test.p')::UUID, current_setting('test.e')::UUID, 'copy'),
          NULL, 'the owner of a company copies into its branch (owned, not a member)');
SELECT is(t.transfer_refusal_as(current_setting('test.baris')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID, 'copy'),
          'transfer_forbidden', 'the provider''s owner is not in the client tenant');
-- 4.
SELECT is(t.transfer_refusal_as(current_setting('test.inx')::UUID, current_setting('test.p')::UUID, current_setting('test.x')::UUID, 'copy'),
          'transfer_target_unavailable', 'nothing is transferred into a read-only target');
-- No savepoint: a rolled-back one would drop pgTAP's record of the case.
UPDATE public.module SET is_core = FALSE WHERE id = 'product';
SELECT is(t.transfer_refusal_as(current_setting('test.akif')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'copy'),
          'transfer_target_unavailable', 'the target''s plan has the product module');
UPDATE public.module SET is_core = TRUE WHERE id = 'product';
-- 5.
SELECT is(t.transfer_refusal_as(current_setting('test.notr')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID, 'copy'),
          'transfer_permissions_required', 'the transfer right is needed in the target');
SELECT is(t.transfer_refusal_as(current_setting('test.notr')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'copy'),
          'transfer_permissions_required', 'and in the source');
SELECT is(t.transfer_refusal_as(current_setting('test.nosel')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID, 'copy'),
          'transfer_permissions_required', 'every registry table is read in the source');
SELECT is(t.transfer_refusal_as(current_setting('test.nosel')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'copy'),
          'transfer_permissions_required', 'and written in the target');
SELECT is(t.transfer_refusal_as(current_setting('test.nodel')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'copy'),
          NULL, 'a copy needs no delete');
SELECT is(t.transfer_refusal_as(current_setting('test.akif')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'move'),
          NULL, 'management moves (products and documents: update, as users never delete them)');
SELECT is(t.transfer_refusal_as(current_setting('test.noupdp')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'move'),
          'transfer_permissions_required', 'a move retires the source''s products: product update in the source');
SELECT is(t.transfer_refusal_as(current_setting('test.noupdd')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'move'),
          'transfer_permissions_required', 'and its documents: document update in the source');
SELECT is(t.transfer_refusal_as(current_setting('test.noupdp')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'copy'),
          NULL, 'a copy needs neither');
SELECT is(t.transfer_refusal_as(current_setting('test.notsel')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'copy'),
          'transfer_permissions_required', 'a target table written is also read there, so no conflict reveals a row the caller cannot read');
-- 6.
SELECT is(t.transfer_refusal_as(current_setting('test.noread')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID, 'copy'),
          'transfer_field_rights_required', 'a field the caller cannot read in the source is never copied');
SELECT is(t.transfer_refusal_as(current_setting('test.rowrt')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID, 'copy'),
          NULL, 'reading the source and writing the target is enough for a copy');
SELECT is(t.transfer_refusal_as(current_setting('test.rowrt')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID, 'move'),
          'transfer_field_rights_required', 'a move also writes the source');

-- A super admin who is a member of both, with every table right and no field right.
INSERT INTO public.tenant_user (user_id, tenant_id) VALUES (current_setting('test.admin')::UUID, current_setting('test.p')::UUID),
                                                           (current_setting('test.admin')::UUID, current_setting('test.c')::UUID);
SELECT pg_temp.member(current_setting('test.admin')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000072181', 'FALSE', FALSE);
SELECT pg_temp.member(current_setting('test.admin')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000072182', 'FALSE', FALSE);
SELECT is(t.transfer_refusal_as(current_setting('test.admin')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'copy'),
          'transfer_field_rights_required', 'a super admin member holds only the field rights its roles give it');

-- A sensitive field added to the catalog is covered without a code change.
ALTER TABLE public.product ADD COLUMN zz_secret_072 TEXT;
INSERT INTO public.field_class (resource_name, field, class, group_name) VALUES ('public.product', 'zz_secret_072', 'sensitive', 'cost');
SELECT is(t.transfer_refusal_as(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID, 'copy'),
          'transfer_field_rights_required', 'a new sensitive field needs its rights too');
DELETE FROM public.field_class WHERE resource_name = 'public.product' AND field = 'zz_secret_072';
ALTER TABLE public.product DROP COLUMN zz_secret_072;
-- 7.
SELECT is(t.transfer_refusal_as(current_setting('test.inx')::UUID, current_setting('test.x')::UUID, current_setting('test.p')::UUID, 'move'),
          'transfer_source_read_only', 'a read-only source is not moved from');
SELECT is(t.transfer_refusal_as(current_setting('test.inx')::UUID, current_setting('test.x')::UUID, current_setting('test.p')::UUID, 'copy'),
          NULL, 'but may be copied from');
-- 8.
INSERT INTO public.transfer (id, tenant_id, source_tenant_id, product_ids, mode, started_by, report, files_status)
VALUES ('00000000-0000-4000-8000-000000072003', current_setting('test.p')::UUID, current_setting('test.c')::UUID, '{}', 'copy',
        current_setting('test.akif')::UUID, '{}', 'partial');
SELECT is(t.transfer_refusal_as(current_setting('test.akif')::UUID, current_setting('test.c')::UUID, current_setting('test.p')::UUID, 'copy'),
          'transfer_files_pending', 'a target still copying an earlier transfer''s files waits');
DELETE FROM public.transfer WHERE id = '00000000-0000-4000-8000-000000072003';

-- ---------------------------------------------------------------------------------------------
-- 5. The rehearsal.

SELECT set_config('test.transfers', (SELECT count(*)::TEXT FROM public.transfer), TRUE);

-- As akif with C and P in scope (the brief's report assertion).
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.c')::UUID,
                                 ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
SELECT ok((public.transfer_products(current_setting('test.c')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.mop')::UUID],
                                    'move', NULL, TRUE) -> 'left_behind_links' ->> 'purchase_order_line')::INT >= 1,
          'report lists cross-tenant links left behind');
SELECT set_config('test.r_move', public.transfer_products(current_setting('test.c')::UUID, current_setting('test.p')::UUID,
                                                          ARRAY[current_setting('test.mop')::UUID], 'move')::TEXT, TRUE);
SELECT set_config('test.r_copy', public.transfer_products(current_setting('test.c')::UUID, current_setting('test.p')::UUID,
                                                          ARRAY[current_setting('test.zc')::UUID], 'copy')::TEXT, TRUE);
SELECT set_config('test.r_mop', public.transfer_products(current_setting('test.c')::UUID, current_setting('test.p')::UUID,
                                                         ARRAY[current_setting('test.mop')::UUID], 'copy')::TEXT, TRUE);
SELECT throws_ok($$ SELECT count(*) FROM pg_temp.transfer_rows $$, '42501', NULL,
                 'the caller cannot read the collected package after a rehearsal');
RESET ROLE;
SELECT private.unimpersonate();

SELECT ok((current_setting('test.r_move')::JSONB -> 'left_behind_links' ->> 'sourcing')::INT >= 1,
          'the provider''s sourcing of the product is a link left behind too');
SELECT ok(
    current_setting('test.r_move')::JSONB -> 'left_behind' @> jsonb_build_array(jsonb_build_object(
        'table', 'project_product', 'column', 'product_id', 'refers_to', 'product', 'refers_to_id', current_setting('test.mop'),
        'blocks', TRUE
    )),
    'the project link that stays in the source is left behind and blocks a move'
);
SELECT is(
    current_setting('test.r_copy')::JSONB -> 'counts',
    '{"product": 2, "market_cell": 1, "media": 1, "media_link": 1, "document": 1}'::JSONB,
    'the product, its variant, its cell, spec sheet, file and link'
);
SELECT is(current_setting('test.r_copy')::JSONB -> 'excluded', '[]'::JSONB, 'a client copying into its provider leaves nothing out');
SELECT is(
    ARRAY(SELECT c ->> 'kind' FROM jsonb_array_elements(current_setting('test.r_mop')::JSONB -> 'conflicts') c
          WHERE c ->> 'source_id' = current_setting('test.mop') ORDER BY 1),
    ARRAY['gtin'],
    'a copy cannot keep the mop''s active GTIN'
);
SELECT is(
    (SELECT c -> 'actions' FROM jsonb_array_elements(current_setting('test.r_mop')::JSONB -> 'conflicts') c
     WHERE c ->> 'key' = 'gtin:' || current_setting('test.mop')),
    '["clear_gtin", "skip"]'::JSONB, 'clear it or skip the product'
);
SELECT ok(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(current_setting('test.r_move')::JSONB -> 'conflicts') c WHERE c ->> 'kind' = 'gtin'),
          'a move keeps its GTIN');
SELECT is(
    current_setting('test.r_copy')::JSONB -> 'settings_gaps',
    jsonb_build_array(jsonb_build_object('rule', 'spec_sheet_required', 'table', 'product', 'source_id', current_setting('test.variant'))),
    'the variant has no signed spec sheet; the product has'
);
SELECT is((SELECT count(*)::TEXT FROM public.transfer), current_setting('test.transfers'), 'a rehearsal leaves no transfer row');
SELECT is((SELECT count(*) FROM public.product WHERE tenant_id = current_setting('test.p')::UUID AND (sku LIKE 'THO-MOP%' OR sku LIKE 'ZZ-C-%')), 0::BIGINT,
          'a rehearsal writes nothing to the target');

-- F5: into the provider's client, the procurement tables stay home.
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.c')::UUID, current_setting('test.e')::UUID]);
SELECT set_config('test.r_pc', public.transfer_products(current_setting('test.p')::UUID, current_setting('test.c')::UUID,
                                                        ARRAY[current_setting('test.zp')::UUID], 'copy')::TEXT, TRUE);
SELECT set_config('test.r_pe', public.transfer_products(current_setting('test.p')::UUID, current_setting('test.e')::UUID,
                                                        ARRAY[current_setting('test.zp')::UUID], 'copy')::TEXT, TRUE);
SELECT throws_like(
    $$ SELECT public.transfer_products(current_setting('test.p')::UUID, current_setting('test.e')::UUID, ARRAY[current_setting('test.mop')::UUID], 'copy') $$,
    '%transfer_products_invalid%',
    'a product of another tenant is not in the source'
);
SELECT throws_like(
    $$ SELECT public.transfer_products(current_setting('test.p')::UUID, current_setting('test.e')::UUID, '{}'::UUID[], 'copy') $$,
    '%transfer_products_invalid%',
    'products are required'
);
SELECT throws_like(
    $$ SELECT public.transfer_products(current_setting('test.p')::UUID, current_setting('test.e')::UUID, ARRAY[current_setting('test.zp')::UUID], 'clone') $$,
    '%transfer_mode_invalid%',
    'the entry point refuses with the gate''s code'
);
RESET ROLE;
SELECT private.unimpersonate();

SELECT is(current_setting('test.r_pc')::JSONB -> 'excluded', '["supplier", "supplier_contact", "sourcing"]'::JSONB,
          'the report lists the tables left out of a copy into a client');
SELECT is(
    current_setting('test.r_pc')::JSONB -> 'counts',
    '{"product": 1, "market_cell": 1, "media": 1, "media_link": 1}'::JSONB,
    'no sourcing, supplier or contact goes into the client'
);
SELECT is(
    current_setting('test.r_pe')::JSONB -> 'counts',
    '{"supplier": 1, "supplier_contact": 1, "product": 1, "sourcing": 1, "market_cell": 1, "media": 1, "media_link": 1, "document": 1}'::JSONB,
    'into the provider''s branch the sourcing, its supplier, contact and certificate come along'
);
SELECT ok(
    current_setting('test.r_pc')::JSONB -> 'left_behind' @> jsonb_build_array(jsonb_build_object(
        'table', 'sourcing', 'column', 'product_id', 'refers_to_id', current_setting('test.zp'), 'blocks', FALSE
    )),
    'the sourcing left home is reported'
);

-- F5 decides on the target's relationships: K procures for itself from MOESA Trading (ended).
SELECT set_config('test.trading', (SELECT id::TEXT FROM public.tenant WHERE display_name = 'MOESA Trading GmbH'), TRUE);
SELECT set_config('moesa.rules_bypass', '1', TRUE);
INSERT INTO public.provider_relationship (tenant_id, client_tenant_id, client_code, client_name, procurement_model, status, ended_at)
VALUES (current_setting('test.trading')::UUID, current_setting('test.k')::UUID, 'KZY', 'Kuzey Holding', 'client', 'ended', now());
SELECT set_config('moesa.rules_bypass', '', TRUE);
SELECT is(private.transfer_excluded(current_setting('test.trading')::UUID, current_setting('test.k')::UUID),
          ARRAY['supplier', 'supplier_contact', 'sourcing'], 'a client of the source, even after the relationship ended');
SELECT is(private.transfer_excluded(current_setting('test.p')::UUID, current_setting('test.k')::UUID), '{}'::TEXT[],
          'another provider''s client that procures for itself takes the procurement data');
SELECT is(private.transfer_excluded(current_setting('test.e')::UUID, current_setting('test.c')::UUID),
          ARRAY['supplier', 'supplier_contact', 'sourcing'], 'a tenant a provider procures for never takes it, from whomever');
SELECT is(private.transfer_excluded(current_setting('test.p')::UUID, current_setting('test.l')::UUID),
          ARRAY['supplier', 'supplier_contact', 'sourcing'], 'an active client of the source that procures for itself (M2)');
SELECT is(private.transfer_excluded(current_setting('test.e')::UUID, current_setting('test.l')::UUID),
          ARRAY['supplier', 'supplier_contact', 'sourcing'], 'nor from a branch of the provider''s company (I1)');
SELECT ok(private.transfer_excluded(current_setting('test.p')::UUID, current_setting('test.e')::UUID) = '{}'
          AND private.transfer_excluded(current_setting('test.e')::UUID, current_setting('test.l')::UUID) <> '{}',
          'two steps through the branch: P to E carries it, E to the client does not');

-- The package as collected: the source's own rows, no shared one, no client link.
SELECT private.transfer_collect(current_setting('test.p')::UUID, ARRAY[current_setting('test.mop')::UUID]);
SELECT is((SELECT count(*) FROM pg_temp.transfer_rows), 0::BIGINT,
          'the provider''s sourcing of a client product is never collected from the provider');
SELECT private.transfer_collect(current_setting('test.p')::UUID, ARRAY[current_setting('test.zp')::UUID]);
SELECT ok(
    (SELECT bool_and(r.row ->> 'tenant_id' = current_setting('test.p') AND r.row ->> 'client_tenant_id' IS NULL) FROM pg_temp.transfer_rows r)
    AND NOT EXISTS (SELECT 1 FROM pg_temp.transfer_rows r JOIN public.sourcing s ON s.id = r.source_id WHERE s.client_tenant_id IS NOT NULL),
    'every collected row is the source''s own and carries no client link'
);
SELECT is(
    (SELECT jsonb_object_agg(right(r.source_id::TEXT, 2), r.copy_only) FROM pg_temp.transfer_rows r
     WHERE r.source_id::TEXT LIKE '00000000-0000-4000-8000-0000000720%'),
    '{"31": false, "32": false, "33": true, "34": true, "35": false, "36": true, "37": false, "39": true}'::JSONB,
    'the supplier''s contact and certificate and the file are copy_only'
);

-- The report holds counts and ids only: never a value of a row.
SELECT is_empty(
    format($q$
        WITH RECURSIVE n (v) AS (
            SELECT %L::JSONB
            UNION ALL
            SELECT c.v FROM n CROSS JOIN LATERAL (
                SELECT value FROM jsonb_each(CASE WHEN jsonb_typeof(n.v) = 'object' THEN n.v END)
                UNION ALL
                SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(n.v) = 'array' THEN n.v END)
            ) AS c (v)
        )
        SELECT v #>> '{}' FROM n
        WHERE jsonb_typeof(v) = 'string'
          AND NOT (v #>> '{}' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   OR v #>> '{}' ~ '^[0-9a-f]{64}$' OR v #>> '{}' ~ '^[a-z_]+$') $q$,
        current_setting('test.r_pe')),
    'every text in the report is an id, a name of the schema or a code'
);
SELECT ok(
    strpos(current_setting('test.r_pe'), '987654') = 0 AND strpos(current_setting('test.r_pe'), 'Kutlu') = 0
    AND strpos(current_setting('test.r_pe'), 'ZZ-P-1') = 0 AND strpos(current_setting('test.r_pe'), 'zp.png') = 0,
    'no price, name, SKU or file name reaches the report'
);

-- A caller without the cost read in the source gets no report at all.
SELECT private.impersonate_scope(current_setting('test.noread')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.c')::UUID]);
SELECT is(
    t.error_of($$ SELECT public.transfer_products(current_setting('test.p')::UUID, current_setting('test.c')::UUID,
                                                  ARRAY[current_setting('test.zp')::UUID], 'copy') $$) ~ 'transfer_field_rights_required'
    AND strpos(t.error_of($$ SELECT public.transfer_products(current_setting('test.p')::UUID, current_setting('test.c')::UUID,
                                                             ARRAY[current_setting('test.zp')::UUID], 'copy') $$), '987654') = 0,
    TRUE,
    'without the cost read in the source the rehearsal is refused, the cost nowhere in the answer'
);
RESET ROLE;
SELECT private.unimpersonate();

-- Conflicts in MOESA Europe: its own ZZ-P-1 and ZS1.
SELECT set_config('moesa.rules_bypass', '1', TRUE);
INSERT INTO public.product (id, tenant_id, sku, display_name) VALUES ('00000000-0000-4000-8000-000000072061', current_setting('test.e')::UUID, 'ZZ-P-1', 'Europe copy');
INSERT INTO public.supplier (id, tenant_id, code, display_name, country)
VALUES ('00000000-0000-4000-8000-000000072062', current_setting('test.e')::UUID, 'ZS1', 'ZS1 Europa', 'Türkiye');
SELECT set_config('moesa.rules_bypass', '', TRUE);

CREATE FUNCTION pg_temp.pe (p_mode TEXT, p_decisions JSONB DEFAULT NULL, p_rehearse BOOLEAN DEFAULT TRUE) RETURNS JSONB LANGUAGE sql AS $$
    SELECT public.transfer_products(current_setting('test.p')::UUID, current_setting('test.e')::UUID, ARRAY[current_setting('test.zp')::UUID],
                                    p_mode, p_decisions, p_rehearse);
$$;

SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.e')::UUID]);
SELECT set_config('test.r', pg_temp.pe('copy')::TEXT, TRUE);
SELECT ok(
    current_setting('test.r')::JSONB -> 'conflicts' @> jsonb_build_array(
        jsonb_build_object('key', 'supplier:' || current_setting('test.zs1'), 'kind', 'supplier_code',
                           'existing_id', '00000000-0000-4000-8000-000000072062', 'actions', '["map", "new_code"]'::JSONB),
        jsonb_build_object('key', 'sku:' || current_setting('test.zp'), 'kind', 'sku',
                           'existing_id', '00000000-0000-4000-8000-000000072061', 'actions', '["rename", "skip"]'::JSONB)
    ),
    'ZS1 and ZZ-P-1 are taken in Europe'
);
SELECT is((current_setting('test.r')::JSONB ->> 'unresolved')::INT, 2, 'two conflicts wait for a decision');
SELECT is(
    (SELECT c -> 'skip_drops' FROM jsonb_array_elements(current_setting('test.r')::JSONB -> 'conflicts') c WHERE c ->> 'kind' = 'sku'),
    '{"sourcing": 1, "market_cell": 1, "media_link": 1}'::JSONB,
    'skipping the product drops what hangs from it'
);
SELECT ok(
    pg_temp.pe('move') -> 'conflicts' @> jsonb_build_array(jsonb_build_object('kind', 'sku', 'actions', '["rename"]'::JSONB)),
    'a move offers no skip'
);
SELECT set_config('test.d', jsonb_build_object(
    'supplier:' || current_setting('test.zs1'), jsonb_build_object('action', 'map', 'target_id', '00000000-0000-4000-8000-000000072062'),
    'sku:' || current_setting('test.zp'), '{"action": "rename", "suffix": "-EU"}'::JSONB
)::TEXT, TRUE);
SELECT set_config('test.rd', pg_temp.pe('copy', current_setting('test.d')::JSONB)::TEXT, TRUE);
SELECT is((current_setting('test.rd')::JSONB ->> 'unresolved')::INT, 0, 'a map and a rename settle them');
SELECT is(
    current_setting('test.rd')::JSONB -> 'counts',
    '{"product": 1, "sourcing": 1, "market_cell": 1, "media": 1, "media_link": 1}'::JSONB,
    'a mapped supplier is not copied, nor its contact and certificate'
);
SELECT is(
    pg_temp.pe('copy', jsonb_build_object('sku:' || current_setting('test.zp'), '{"action": "skip"}'::JSONB)) -> 'counts',
    '{"supplier": 1, "supplier_contact": 1, "document": 1}'::JSONB,
    'a skipped product takes its rows and its file along'
);
SELECT is(pg_temp.pe('copy') ->> 'report_hash', pg_temp.pe('copy') ->> 'report_hash', 'two identical rehearsals give one hash');
SELECT isnt(pg_temp.pe('copy') ->> 'report_hash', current_setting('test.rd')::JSONB ->> 'report_hash', 'decisions change the hash');

-- The real run's checks (the run itself is 073).
SELECT throws_like($$ SELECT pg_temp.pe('copy', NULL, FALSE) $$, '%transfer_decision_required%', 'every conflict needs a decision');
SELECT throws_like(
    $$ SELECT pg_temp.pe('copy', jsonb_build_object('sku:' || current_setting('test.zp'), '{"action": "map"}'::JSONB), FALSE) $$,
    '%transfer_decision_invalid%', 'an action the conflict does not offer'
);
SELECT throws_like(
    $$ SELECT pg_temp.pe('copy', '{"sku:00000000-0000-4000-8000-000000072099": {"action": "skip"}}'::JSONB, FALSE) $$,
    '%transfer_decision_invalid%', 'a decision names a conflict'
);
SELECT throws_like(
    $$ SELECT pg_temp.pe('copy', jsonb_build_object('supplier:' || current_setting('test.zs1'), '{"action": "new_code", "code": "tr9"}'::JSONB), FALSE) $$,
    '%transfer_code_invalid%', 'a new supplier code is two capitals and digits'
);
SELECT throws_like(
    $$ SELECT pg_temp.pe('copy', jsonb_build_object('sku:' || current_setting('test.zp'), '{"action": "rename", "suffix": "has space"}'::JSONB), FALSE) $$,
    '%transfer_code_invalid%', 'a rename suffix is a short code'
);
SELECT throws_like(
    $$ SELECT pg_temp.pe('copy', jsonb_build_object('supplier:' || current_setting('test.zs1'),
                                                    jsonb_build_object('action', 'map', 'target_id', current_setting('test.zs1'))), FALSE) $$,
    '%transfer_decision_invalid%', 'a supplier is mapped onto a supplier of the target'
);
-- 073 replaced the 501 transfer_apply_unavailable with the run (its own tests are 073's).
SELECT is(pg_temp.pe('copy', current_setting('test.d')::JSONB
                             || jsonb_build_object('report_hash', pg_temp.pe('copy', current_setting('test.d')::JSONB) ->> 'report_hash'), FALSE)
          ->> 'tenant_id', current_setting('test.e'),
          'a settled run, bound to its rehearsal''s hash, is applied');
RESET ROLE;
SELECT private.unimpersonate();

SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.c')::UUID,
                                 ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
SELECT throws_like(
    $$ SELECT public.transfer_products(current_setting('test.c')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.mop')::UUID],
                                       'move', NULL, FALSE) $$,
    '%transfer_product_in_use%', 'a product in a project that stays is not moved'
);
RESET ROLE;
SELECT private.unimpersonate();

-- A package file an earlier transfer into the source has not copied yet.
INSERT INTO public.transfer (id, tenant_id, source_tenant_id, product_ids, mode, started_by, report, files, files_status)
VALUES ('00000000-0000-4000-8000-000000072004', current_setting('test.c')::UUID, current_setting('test.p')::UUID, '{}', 'copy',
        current_setting('test.akif')::UUID, '{}', '[{"media_id": "00000000-0000-4000-8000-000000072042", "to": "x"}]', 'pending');
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.c')::UUID,
                                 ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
SELECT throws_like(
    $$ SELECT public.transfer_products(current_setting('test.c')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.zc')::UUID], 'copy') $$,
    '%transfer_files_pending%', 'a file still being copied into the source is not transferred on'
);
RESET ROLE;
SELECT private.unimpersonate();
DELETE FROM public.transfer WHERE id = '00000000-0000-4000-8000-000000072004';

-- ---------------------------------------------------------------------------------------------
-- 6. Options.

SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT ok(
    public.transfer_options(current_setting('test.c')::UUID) -> 'targets'
        @> jsonb_build_array(jsonb_build_object('id', current_setting('test.p'), 'refusal', NULL)),
    'akif may copy from THO into MOESA LTD'
);
SELECT is(public.transfer_options(current_setting('test.k')::UUID), '{"source_writable": false, "targets": []}'::JSONB,
          'nothing out of a tenant the caller is not in');
RESET ROLE;
SELECT private.impersonate_scope(current_setting('test.nocost')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT ok(
    public.transfer_options(current_setting('test.p')::UUID) -> 'targets'
        @> jsonb_build_array(jsonb_build_object('id', current_setting('test.c'), 'refusal', 'transfer_field_rights_required')),
    'each target carries its refusal'
);
RESET ROLE;
SELECT private.unimpersonate();

SELECT is(
    ARRAY(SELECT p.proname::TEXT FROM pg_proc p WHERE p.pronamespace = 'public'::REGNAMESPACE
          AND p.proname IN ('transfer_options', 'transfer_products') AND p.prosecdef AND p.proconfig @> ARRAY['search_path=""']
          AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
          ORDER BY 1),
    ARRAY['transfer_options', 'transfer_products'],
    'the entry points are definers with an empty search_path, for signed-in users only'
);

SELECT * FROM finish();

ROLLBACK;
