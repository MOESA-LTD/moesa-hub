CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

CREATE EXTENSION IF NOT EXISTS pgrowlocks WITH SCHEMA extensions;

-- The tenant transfer run (Plan 3 Task 13, 073): a real run of public.transfer_products copies the
-- package into the target with new ids, a move removes it from the source first. Ported from M21's
-- 043 copy and lock tests (055b03b), product registry only.
--
-- Sections: A a copy MOESA Europe → MOESA LTD (decisions, users rule, files, the flag cleared, the
-- revert lock, the locks); B a copy into a provider-procured client (F5 at apply); C a move of THO's
-- THO-MOP40-2P into MOESA LTD (a provider's order line keeps its snapshot, a signed spec sheet, an
-- active GTIN); D the run trusts no rehearsal (a fresh report, the gate again); E who reads the stored
-- description (L4); F the internals; G a copy inside the company carries everything, and a copied file
-- keeps its source restriction (final review C1, I1).
--
-- Signing in (F10): `SELECT private.impersonate_scope(user, active, scope);` then
-- `RESET ROLE; SELECT private.unimpersonate();`. Fixtures by current_setting, rows read as postgres.
BEGIN;

SELECT plan(94);

SELECT private.create_test_helpers();

-- Fixture (ids 00000000-0000-4000-8000-0000000730xx), on the seed:
--   P = MOESA LTD, C = THO (client of P, provider-procured), E = MOESA Europe (branch of P); akif:
--   management in all three (seed).
--   tonly ...07311: one full role in P alone (reads P's transfers, nothing of E). nonmem ...07312: a
--   user of no tenant (an author in E). gate ...07313: full roles in E and P. noterms ...07314: a full
--   role in C without the supplier_terms field group. noupd ...07315: full roles in E and P, but no
--   product update in P. nomdel ...07316: full roles in C and P, but no media delete in C.
--   E: product ze ...07301 'ZZ-E-1' (GTIN, notes) with its variant ...07309, supplier ZS7 ...07302 and
--   its contact ...07303, E's sourcing ...07304, a market cell ...07305 (listing checked), a file
--   ...07306 with a thumbnail (uploaded by nonmem) linked as the primary image ...07307, a signed spec
--   sheet ...07308 (written by nonmem); product ze2 ...07320 'ZZ-E-2' with a cell ...07323; product zf
--   ...07351 'ZZ-E-3'. P already has 'ZZ-E-1' ...07310, 'ZZ-E-2' ...07321 and supplier ZS7 ...07322.
--   P: product zp ...07331 'ZZ-P-3' with P's sourcing ...07332 of supplier ZS9 ...07333 (contact ...07334).
--   C: the seed's THO-MOP40-2P keeps its rows under another SKU, and the fixture's own THO-MOP40-2P zm
--   ...07341 (GTIN, F19) carries a signed spec sheet ...07342 on a file ...07343 and a market cell
--   ...07344; P's provider order ...07345 for C has a line ...07346 on it, and P's sourcing ...07347
--   for C names it. zm also has a pi document ...07350 on its own file ...07348 (supplier_terms), and a
--   gallery file ...07349 the seed's mop uses too.
--   P (final review C1, I1): zp has an internal note, a market cell ...07352 with a note, a pi document
--   ...07354 (with a note) on its own file ...07353, a test report ...07357 with a note, a gallery file
--   ...07355, and a gallery file ...07356 that is also the file of a packing list ...07358 on P's
--   provider order (supplier_identity: the reviewer's dual use).
SELECT set_config('test.' || x.k, x.v::TEXT, TRUE)
FROM (VALUES
    ('p', (SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD')),
    ('c', (SELECT id FROM public.tenant WHERE code = 'THO')),
    ('e', (SELECT id FROM public.tenant WHERE display_name = 'MOESA Europe')),
    ('akif', (SELECT id FROM public.user WHERE email = 'akif@moesa-panel.test')),
    ('tr1', (SELECT id FROM public.supplier WHERE code = 'TR1' AND tenant_id = (SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD'))),
    ('tonly', '00000000-0000-4000-8000-000000073011'),
    ('nonmem', '00000000-0000-4000-8000-000000073012'),
    ('gate', '00000000-0000-4000-8000-000000073013'),
    ('ze', '00000000-0000-4000-8000-000000073001'),
    ('zs', '00000000-0000-4000-8000-000000073002'),
    ('variant', '00000000-0000-4000-8000-000000073009'),
    ('ze2', '00000000-0000-4000-8000-000000073020'),
    ('zf', '00000000-0000-4000-8000-000000073051'),
    ('zp', '00000000-0000-4000-8000-000000073031'),
    ('zm', '00000000-0000-4000-8000-000000073041'),
    ('zm_doc', '00000000-0000-4000-8000-000000073042'),
    ('zm_file', '00000000-0000-4000-8000-000000073043'),
    ('provider_line', '00000000-0000-4000-8000-000000073046'),
    ('provider_sourcing', '00000000-0000-4000-8000-000000073047'),
    ('noterms', '00000000-0000-4000-8000-000000073014'),
    ('noupd', '00000000-0000-4000-8000-000000073015'),
    ('nomdel', '00000000-0000-4000-8000-000000073016'),
    ('pi_file', '00000000-0000-4000-8000-000000073048'),
    ('shared_file', '00000000-0000-4000-8000-000000073049'),
    ('zp_pi', '00000000-0000-4000-8000-000000073053'),
    ('zp_img', '00000000-0000-4000-8000-000000073055'),
    ('zp_dual', '00000000-0000-4000-8000-000000073056')
) AS x (k, v);

-- A member of a tenant with one role: every permission of every module, every field.
CREATE FUNCTION pg_temp.member (p_user UUID, p_tenant UUID, p_role UUID) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO public.tenant_user (user_id, tenant_id) VALUES (p_user, p_tenant) ON CONFLICT DO NOTHING;
    INSERT INTO public.role (id, tenant_id, display_name) VALUES (p_role, p_tenant, 'Transfer 073 ' || p_role);
    INSERT INTO public.role_permission (role_id, permission_id)
    SELECT p_role, p.id FROM public.permission p WHERE p.group_name IN (SELECT m.id FROM public.module m);
    INSERT INTO public.user_role (user_id, role_id) VALUES (p_user, p_role);
    PERFORM private.grant_all_fields(p_role);
END;
$$;

INSERT INTO public.user (id, email)
SELECT ('00000000-0000-4000-8000-0000000730' || n)::UUID, 'u' || n || '@transfer073.test'
FROM unnest(ARRAY['11', '12', '13', '14', '15', '16']) AS n;

SELECT pg_temp.member(current_setting('test.tonly')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000073111');
SELECT pg_temp.member(current_setting('test.gate')::UUID, current_setting('test.e')::UUID, '00000000-0000-4000-8000-000000073131');
SELECT pg_temp.member(current_setting('test.gate')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000073132');
SELECT pg_temp.member(current_setting('test.noterms')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000073141');
UPDATE public.role_field_permission SET can_read = FALSE, can_write = FALSE
WHERE role_id = '00000000-0000-4000-8000-000000073141'
  AND (resource_name, field) IN (SELECT resource_name, field FROM public.field_class WHERE group_name = 'supplier_terms');
SELECT pg_temp.member(current_setting('test.nomdel')::UUID, current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000073161');
SELECT pg_temp.member(current_setting('test.nomdel')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000073162');
DELETE FROM public.role_permission
WHERE role_id = '00000000-0000-4000-8000-000000073161'
  AND permission_id = (SELECT id FROM public.permission WHERE resource_name = 'public.media' AND command = 'delete');
SELECT pg_temp.member(current_setting('test.noupd')::UUID, current_setting('test.e')::UUID, '00000000-0000-4000-8000-000000073151');
SELECT pg_temp.member(current_setting('test.noupd')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000073152');
DELETE FROM public.role_permission
WHERE role_id = '00000000-0000-4000-8000-000000073152'
  AND permission_id = (SELECT id FROM public.permission WHERE resource_name = 'public.product' AND command = 'update');

-- The rows, written as postgres under the fixture bypass.
SELECT set_config('moesa.rules_bypass', '1', TRUE);

INSERT INTO storage.objects (bucket_id, name, metadata)
VALUES ('media', current_setting('test.e') || '/00000000-0000-4000-8000-000000073006/ze.png', '{"mimetype": "image/png", "size": 1000}'),
       ('media', current_setting('test.e') || '/00000000-0000-4000-8000-000000073006/thumb/thumb.webp', '{"mimetype": "image/webp", "size": 100}'),
       ('media', current_setting('test.c') || '/00000000-0000-4000-8000-000000073043/zm.pdf', '{"mimetype": "application/pdf", "size": 2000}'),
       ('media', current_setting('test.c') || '/00000000-0000-4000-8000-000000073048/pi.pdf', '{"mimetype": "application/pdf", "size": 3000}'),
       ('media', current_setting('test.c') || '/00000000-0000-4000-8000-000000073049/zm.png', '{"mimetype": "image/png", "size": 4000}');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, status)
VALUES (current_setting('test.zs')::UUID, current_setting('test.e')::UUID, 'ZS7', 'Supplier E 073', 'Türkiye', 'approved'),
       ('00000000-0000-4000-8000-000000073022', current_setting('test.p')::UUID, 'ZS7', 'Supplier P 073', 'Türkiye', 'approved'),
       ('00000000-0000-4000-8000-000000073033', current_setting('test.p')::UUID, 'ZS9', 'Supplier P9 073', 'Türkiye', 'approved');
INSERT INTO public.supplier_contact (id, tenant_id, supplier_id, name)
VALUES ('00000000-0000-4000-8000-000000073003', current_setting('test.e')::UUID, current_setting('test.zs')::UUID, 'Contact E 073'),
       ('00000000-0000-4000-8000-000000073034', current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000073033', 'Contact P9 073');
INSERT INTO public.product (id, tenant_id, sku, display_name, status, gtin, notes)
VALUES (current_setting('test.ze')::UUID, current_setting('test.e')::UUID, 'ZZ-E-1', 'Europe product 073', 'development', '4006381333931', 'Note 073'),
       (current_setting('test.ze2')::UUID, current_setting('test.e')::UUID, 'ZZ-E-2', 'Europe product two 073', 'development', NULL, NULL),
       (current_setting('test.zf')::UUID, current_setting('test.e')::UUID, 'ZZ-E-3', 'Europe product three 073', 'development', NULL, NULL),
       ('00000000-0000-4000-8000-000000073010', current_setting('test.p')::UUID, 'ZZ-E-1', 'Taken 073', 'development', NULL, NULL),
       ('00000000-0000-4000-8000-000000073021', current_setting('test.p')::UUID, 'ZZ-E-2', 'Taken two 073', 'development', NULL, NULL),
       (current_setting('test.zp')::UUID, current_setting('test.p')::UUID, 'ZZ-P-3', 'Provider product 073', 'development', NULL, NULL);
INSERT INTO public.product (id, tenant_id, parent_id, sku, display_name, status)
VALUES (current_setting('test.variant')::UUID, current_setting('test.e')::UUID, current_setting('test.ze')::UUID, 'ZZ-E-1-V', 'Variant 073', 'development');
INSERT INTO public.sourcing (id, tenant_id, product_tenant_id, product_id, product_sku, product_name, supplier_id, purchase_price, purchase_currency)
VALUES ('00000000-0000-4000-8000-000000073004', current_setting('test.e')::UUID, current_setting('test.e')::UUID, current_setting('test.ze')::UUID,
        'ZZ-E-1', 'Europe product 073', current_setting('test.zs')::UUID, 12.34, 'USD'),
       ('00000000-0000-4000-8000-000000073032', current_setting('test.p')::UUID, current_setting('test.p')::UUID, current_setting('test.zp')::UUID,
        'ZZ-P-3', 'Provider product 073', '00000000-0000-4000-8000-000000073033', 5.55, 'USD');
INSERT INTO public.market_cell (id, tenant_id, product_id, platform_id, country, listing_checked_at)
VALUES ('00000000-0000-4000-8000-000000073005', current_setting('test.e')::UUID, current_setting('test.ze')::UUID, 'amazon', 'DE', now()),
       ('00000000-0000-4000-8000-000000073023', current_setting('test.e')::UUID, current_setting('test.ze2')::UUID, 'amazon', 'DE', NULL);
INSERT INTO public.media (id, tenant_id, storage_path, thumbnail_path, file_name, mime_type, size_bytes, uploaded_by)
VALUES ('00000000-0000-4000-8000-000000073006', current_setting('test.e')::UUID,
        current_setting('test.e') || '/00000000-0000-4000-8000-000000073006/ze.png',
        current_setting('test.e') || '/00000000-0000-4000-8000-000000073006/thumb/thumb.webp',
        'ze.png', 'image/png', 1000, current_setting('test.nonmem')::UUID);
INSERT INTO public.media_link (id, tenant_id, media_id, entity_type, entity_id, role)
VALUES ('00000000-0000-4000-8000-000000073007', current_setting('test.e')::UUID, '00000000-0000-4000-8000-000000073006', 'product',
        current_setting('test.ze')::UUID, 'primary_image');
INSERT INTO public.document (id, tenant_id, entity_type, entity_id, type, version, status, url, file_name,
                             is_signed, is_stamped, sent_from_official_email, issued_on, created_by)
VALUES ('00000000-0000-4000-8000-000000073008', current_setting('test.e')::UUID, 'product', current_setting('test.ze')::UUID, 'spec_sheet', 1,
        'signed', 'https://example.test/ze-spec.pdf', 'ZE_SPEC', TRUE, TRUE, TRUE, '2026-10-15', current_setting('test.nonmem')::UUID);

-- C: the seed's mop under another SKU; the fixture's THO-MOP40-2P (F19).
UPDATE public.product SET sku = 'THO-MOP40-2P-S073' WHERE tenant_id = current_setting('test.c')::UUID AND sku = 'THO-MOP40-2P';
INSERT INTO public.product (id, tenant_id, sku, display_name, status, gtin)
VALUES (current_setting('test.zm')::UUID, current_setting('test.c')::UUID, 'THO-MOP40-2P', 'Pamuk mop bezi 40 cm, 2''li', 'on_sale', '5901234123457');
INSERT INTO public.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
VALUES (current_setting('test.zm_file')::UUID, current_setting('test.c')::UUID,
        current_setting('test.c') || '/00000000-0000-4000-8000-000000073043/zm.pdf', 'zm.pdf', 'application/pdf', 2000);
INSERT INTO public.document (id, tenant_id, entity_type, entity_id, type, version, status, media_id, file_name,
                             is_signed, is_stamped, sent_from_official_email, issued_on)
VALUES (current_setting('test.zm_doc')::UUID, current_setting('test.c')::UUID, 'product', current_setting('test.zm')::UUID, 'spec_sheet', 1,
        'signed', current_setting('test.zm_file')::UUID, 'THO-MOP40-2P_SPEC', TRUE, TRUE, TRUE, '2026-10-01');
INSERT INTO public.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
VALUES (current_setting('test.pi_file')::UUID, current_setting('test.c')::UUID,
        current_setting('test.c') || '/00000000-0000-4000-8000-000000073048/pi.pdf', 'pi.pdf', 'application/pdf', 3000),
       (current_setting('test.shared_file')::UUID, current_setting('test.c')::UUID,
        current_setting('test.c') || '/00000000-0000-4000-8000-000000073049/zm.png', 'zm.png', 'image/png', 4000);
INSERT INTO public.document (id, tenant_id, entity_type, entity_id, type, status, media_id, file_name)
VALUES ('00000000-0000-4000-8000-000000073050', current_setting('test.c')::UUID, 'product', current_setting('test.zm')::UUID, 'pi',
        'approved', current_setting('test.pi_file')::UUID, 'ZM_PI');
INSERT INTO public.media_link (tenant_id, media_id, entity_type, entity_id, role)
VALUES (current_setting('test.c')::UUID, current_setting('test.shared_file')::UUID, 'product', current_setting('test.zm')::UUID, 'gallery'),
       (current_setting('test.c')::UUID, current_setting('test.shared_file')::UUID, 'product',
        (SELECT id FROM public.product WHERE tenant_id = current_setting('test.c')::UUID AND sku = 'THO-MOP40-2P-S073'), 'gallery');
INSERT INTO public.market_cell (id, tenant_id, product_id, platform_id, country)
VALUES ('00000000-0000-4000-8000-000000073044', current_setting('test.c')::UUID, current_setting('test.zm')::UUID, 'amazon', 'PL');
INSERT INTO public.purchase_order (id, tenant_id, client_tenant_id, project_tenant_id, supplier_id, currency, incoterm, deposit_rate)
VALUES ('00000000-0000-4000-8000-000000073045', current_setting('test.p')::UUID, current_setting('test.c')::UUID, current_setting('test.c')::UUID,
        current_setting('test.tr1')::UUID, 'USD', 'EXW', 30);
INSERT INTO public.purchase_order_line (id, tenant_id, purchase_order_id, position, product_id, product_tenant_id, product_sku, product_name,
                                        quantity, unit_price)
VALUES (current_setting('test.provider_line')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000073045', 1,
        current_setting('test.zm')::UUID, current_setting('test.c')::UUID, 'THO-MOP40-2P', 'Pamuk mop bezi 40 cm, 2''li', 100, 1.90);
INSERT INTO public.sourcing (id, tenant_id, client_tenant_id, product_tenant_id, product_id, product_sku, product_name, supplier_id, purchase_price,
                             purchase_currency)
VALUES (current_setting('test.provider_sourcing')::UUID, current_setting('test.p')::UUID, current_setting('test.c')::UUID,
        current_setting('test.c')::UUID, current_setting('test.zm')::UUID, 'THO-MOP40-2P', 'Pamuk mop bezi 40 cm, 2''li',
        current_setting('test.tr1')::UUID, 1.10, 'USD');

-- P: zp's notes, documents and files (C1, I1).
UPDATE public.product SET notes = 'Provider note 073' WHERE id = current_setting('test.zp')::UUID;
INSERT INTO storage.objects (bucket_id, name, metadata)
VALUES ('media', current_setting('test.p') || '/00000000-0000-4000-8000-000000073053/zp-pi.pdf', '{"mimetype": "application/pdf", "size": 3100}'),
       ('media', current_setting('test.p') || '/00000000-0000-4000-8000-000000073055/zp.png', '{"mimetype": "image/png", "size": 500}'),
       ('media', current_setting('test.p') || '/00000000-0000-4000-8000-000000073056/zp-dual.png', '{"mimetype": "image/png", "size": 600}');
INSERT INTO public.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
VALUES (current_setting('test.zp_pi')::UUID, current_setting('test.p')::UUID,
        current_setting('test.p') || '/00000000-0000-4000-8000-000000073053/zp-pi.pdf', 'zp-pi.pdf', 'application/pdf', 3100),
       (current_setting('test.zp_img')::UUID, current_setting('test.p')::UUID,
        current_setting('test.p') || '/00000000-0000-4000-8000-000000073055/zp.png', 'zp.png', 'image/png', 500),
       (current_setting('test.zp_dual')::UUID, current_setting('test.p')::UUID,
        current_setting('test.p') || '/00000000-0000-4000-8000-000000073056/zp-dual.png', 'zp-dual.png', 'image/png', 600);
INSERT INTO public.market_cell (id, tenant_id, product_id, platform_id, country, notes)
VALUES ('00000000-0000-4000-8000-000000073052', current_setting('test.p')::UUID, current_setting('test.zp')::UUID, 'amazon', 'FR', 'Cell note 073');
INSERT INTO public.document (id, tenant_id, entity_type, entity_id, type, status, media_id, file_name, notes)
VALUES ('00000000-0000-4000-8000-000000073054', current_setting('test.p')::UUID, 'product', current_setting('test.zp')::UUID, 'pi',
        'approved', current_setting('test.zp_pi')::UUID, 'ZP_PI', 'supplier price 4.20 USD'),
       ('00000000-0000-4000-8000-000000073058', current_setting('test.p')::UUID, 'purchase_order', '00000000-0000-4000-8000-000000073045',
        'packing_list', 'approved', current_setting('test.zp_dual')::UUID, 'ZP_PL', NULL);
INSERT INTO public.document (id, tenant_id, entity_type, entity_id, type, status, url, file_name, notes)
VALUES ('00000000-0000-4000-8000-000000073057', current_setting('test.p')::UUID, 'product', current_setting('test.zp')::UUID, 'test_report',
        'approved', 'https://example.test/zp-test.pdf', 'ZP_TEST', 'Doc note 073');
INSERT INTO public.media_link (tenant_id, media_id, entity_type, entity_id, role)
VALUES (current_setting('test.p')::UUID, current_setting('test.zp_img')::UUID, 'product', current_setting('test.zp')::UUID, 'gallery'),
       (current_setting('test.p')::UUID, current_setting('test.zp_dual')::UUID, 'product', current_setting('test.zp')::UUID, 'gallery');

SELECT set_config('moesa.rules_bypass', '', TRUE);

-- The guards are SECURITY DEFINER, called by the user: so is this probe.
CREATE FUNCTION t.rules_bypassed_probe_073 () RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = '' AS $$ SELECT private.rules_bypassed(); $$;

GRANT EXECUTE ON FUNCTION t.rules_bypassed_probe_073 () TO authenticated;

-- The target id of a source row in a transfer's map, read as postgres.
CREATE FUNCTION pg_temp.mapped (p_transfer JSONB, p_table TEXT, p_source TEXT) RETURNS UUID LANGUAGE sql AS $$
    SELECT ((SELECT t.id_map FROM public.transfer t WHERE t.id = (p_transfer ->> 'id')::UUID) -> p_table ->> current_setting('test.' || p_source))::UUID;
$$;

-- The objects a user's DELETE removes (the Storage policy filters what it may).
CREATE FUNCTION pg_temp.remove_object (p_name TEXT) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    n BIGINT;
BEGIN
    DELETE FROM storage.objects WHERE bucket_id = 'media' AND name = p_name;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- The rows of a table locked FOR UPDATE by this transaction.
CREATE FUNCTION pg_temp.locked (tbl TEXT) RETURNS SETOF TID LANGUAGE sql AS $$
    SELECT l.locked_row FROM extensions.pgrowlocks(tbl) l
    WHERE 'For Update' = ANY (l.modes) AND txid_current()::TEXT::XID = ANY (l.xids);
$$;

CREATE FUNCTION pg_temp.ep (p_mode TEXT, p_decisions JSONB DEFAULT NULL, p_rehearse BOOLEAN DEFAULT TRUE) RETURNS JSONB LANGUAGE sql AS $$
    SELECT public.transfer_products(current_setting('test.e')::UUID, current_setting('test.p')::UUID,
                                    ARRAY[current_setting('test.ze')::UUID, current_setting('test.ze2')::UUID], p_mode, p_decisions, p_rehearse);
$$;

-- ---------------------------------------------------------------------------------------------
-- A. A copy from MOESA Europe into MOESA LTD.

SELECT set_config('test.d', jsonb_build_object(
    'sku:' || current_setting('test.ze'), '{"action": "rename", "suffix": "-P"}'::JSONB,
    'sku:' || current_setting('test.ze2'), '{"action": "skip"}'::JSONB,
    'gtin:' || current_setting('test.ze'), '{"action": "clear_gtin"}'::JSONB,
    'supplier:' || current_setting('test.zs'), '{"action": "new_code", "code": "ZS8"}'::JSONB
)::TEXT, TRUE);

SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
SELECT is((pg_temp.ep('copy', current_setting('test.d')::JSONB) ->> 'unresolved')::INT, 0, 'the rehearsal settles every conflict');
RESET ROLE;
SELECT private.unimpersonate();

SELECT is((SELECT count(*) FROM pg_temp.locked('public.product')), 0::BIGINT, 'a rehearsal locks no package row');

SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
-- L1: the run is bound to the rehearsal: its hash rides in the decisions.
SELECT throws_like($$ SELECT pg_temp.ep('copy', current_setting('test.d')::JSONB, FALSE) $$, '%transfer_report_stale%',
                   'a run without the rehearsal''s hash is refused');
SELECT throws_like($$ SELECT pg_temp.ep('copy', current_setting('test.d')::JSONB || '{"report_hash": "0000"}', FALSE) $$,
                   '%transfer_report_stale%', 'and so is a run whose package or decisions changed since');
SELECT set_config('test.d', (current_setting('test.d')::JSONB
                             || jsonb_build_object('report_hash', pg_temp.ep('copy', current_setting('test.d')::JSONB) ->> 'report_hash'))::TEXT, TRUE);
SELECT is(pg_temp.ep('copy', current_setting('test.d')::JSONB) ->> 'report_hash', current_setting('test.d')::JSONB ->> 'report_hash',
          'the hash in the decisions is not a decision: the rehearsal gives the same hash with it');
RESET ROLE;
SELECT private.unimpersonate();

-- C1: copying a media link needs the update right on its entity in the target.
SELECT private.impersonate_scope(current_setting('test.noupd')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
SELECT throws_like($$ SELECT pg_temp.ep('copy', current_setting('test.d')::JSONB) $$, '%transfer_permissions_required%',
                   'without product update in the target, a package with media links is refused at the gate');
SELECT lives_ok(
    $$ SELECT public.transfer_products(current_setting('test.e')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.zf')::UUID], 'copy') $$,
    'a package without media links is not'
);
RESET ROLE;
SELECT private.unimpersonate();

SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
SELECT set_config('test.ra', pg_temp.ep('copy', current_setting('test.d')::JSONB, FALSE)::TEXT, TRUE);
-- L5: in the same transaction, right after the call.
SELECT is(current_setting('moesa.transfer_id', TRUE), '', 'the transfer flag is cleared when the run returns');
SELECT is(t.rules_bypassed_probe_073(), FALSE, 'and the rules are not bypassed for the user after the run');
RESET ROLE;
SELECT private.unimpersonate();
SELECT is(private.rules_bypassed(), FALSE, 'nor in a later statement of the transaction');
SELECT is(private.transferring(), FALSE, 'the run''s row raises no flag once the run is over');

SELECT is(
    (SELECT row(r ->> 'tenant_id', r ->> 'source_tenant_id', r ->> 'mode', r ->> 'files_status', r ->> 'started_by')
     FROM (SELECT current_setting('test.ra')::JSONB AS r) s),
    row(current_setting('test.p'), current_setting('test.e'), 'copy'::TEXT, 'pending'::TEXT, current_setting('test.akif')),
    'the run returns its transfer row: into MOESA LTD, files pending'
);
SELECT ok(
    current_setting('test.ra')::JSONB -> 'report' ->> 'report_hash' IS NOT NULL
    AND current_setting('test.ra')::JSONB -> 'decisions' = current_setting('test.d')::JSONB - 'report_hash',
    'the row keeps the fresh report and the decisions'
);
SELECT set_eq(
    $$ SELECT ctid AS row_ctid FROM public.product WHERE id IN (current_setting('test.ze')::UUID, current_setting('test.ze2')::UUID,
                                                    current_setting('test.variant')::UUID) $$,
    $$ SELECT l AS row_ctid FROM pg_temp.locked('public.product') l $$,
    'the run locks the source''s package products'
);

SELECT set_config('test.new_ze', pg_temp.mapped(current_setting('test.ra')::JSONB, 'product', 'ze')::TEXT, TRUE);
SELECT is(
    (SELECT row(tenant_id::TEXT, sku, gtin, status::TEXT, notes) FROM public.product WHERE id = current_setting('test.new_ze')::UUID),
    row(current_setting('test.p'), 'ZZ-E-1-P'::TEXT, NULL::TEXT, 'development'::TEXT, 'Note 073'::TEXT),
    'the product lands in the target renamed, its GTIN cleared, the rest kept'
);
SELECT is(
    (SELECT row(p.tenant_id::TEXT, p.parent_id::TEXT, p.sku) FROM public.product p
     WHERE p.id = pg_temp.mapped(current_setting('test.ra')::JSONB, 'product', 'variant')),
    row(current_setting('test.p'), current_setting('test.new_ze'), 'ZZ-E-1-V'::TEXT),
    'the variant follows its parent'
);
SELECT results_eq(
    $$ SELECT tenant_id, client_tenant_id FROM public.sourcing WHERE product_id = current_setting('test.new_ze')::UUID $$,
    $$ VALUES (current_setting('test.p')::UUID, NULL::UUID) $$,
    'copied sourcing lands in the target without a client link'
);
SELECT is(
    (SELECT row(s.product_tenant_id::TEXT, s.purchase_price, s.product_sku, sp.tenant_id::TEXT, sp.code)
     FROM public.sourcing s JOIN public.supplier sp ON sp.id = s.supplier_id
     WHERE s.product_id = current_setting('test.new_ze')::UUID),
    row(current_setting('test.p'), 12.34::NUMERIC, 'ZZ-E-1-P'::TEXT, current_setting('test.p'), 'ZS8'::TEXT),
    'the sourcing names the copied product and the supplier copied under its new code'
);
SELECT is(
    (SELECT count(*) FROM public.supplier_contact c
     WHERE c.tenant_id = current_setting('test.p')::UUID AND c.name = 'Contact E 073'
       AND c.supplier_id = pg_temp.mapped(current_setting('test.ra')::JSONB, 'supplier', 'zs')),
    1::BIGINT,
    'the supplier''s contact comes along'
);
SELECT is(
    (SELECT row(c.tenant_id::TEXT, c.listing_checked_at, c.project_id) FROM public.market_cell c
     WHERE c.product_id = current_setting('test.new_ze')::UUID),
    row(current_setting('test.p'), NULL::TIMESTAMPTZ, NULL::UUID),
    'the market cell is copied without its listing state'
);
SELECT set_config('test.new_file', (SELECT media_id::TEXT FROM public.media_link WHERE entity_id = current_setting('test.new_ze')::UUID), TRUE);
SELECT is(
    (SELECT row(m.tenant_id::TEXT, m.storage_path, m.thumbnail_path, m.mime_type, m.size_bytes, m.uploaded_by::TEXT)
     FROM public.media m WHERE m.id = current_setting('test.new_file')::UUID),
    row(current_setting('test.p'), current_setting('test.p') || '/' || current_setting('test.new_file') || '/ze.png',
        current_setting('test.p') || '/' || current_setting('test.new_file') || '/thumb/thumb.webp', 'image/png'::TEXT, 1000::BIGINT,
        current_setting('test.akif')),
    'the file row is in the target''s folder, uploaded by the caller in place of a non-member'
);
SELECT is(
    (SELECT row(l.tenant_id::TEXT, l.role::TEXT) FROM public.media_link l WHERE l.entity_id = current_setting('test.new_ze')::UUID),
    row(current_setting('test.p'), 'primary_image'::TEXT),
    'the primary image link comes along'
);
SELECT is(
    (SELECT row(d.tenant_id::TEXT, d.type::TEXT, d.status::TEXT, d.created_by::TEXT) FROM public.document d
     WHERE d.entity_type = 'product' AND d.entity_id = current_setting('test.new_ze')::UUID),
    row(current_setting('test.p'), 'spec_sheet'::TEXT, 'signed'::TEXT, current_setting('test.akif')),
    'the signed spec sheet is copied, written by the caller in place of a non-member'
);
SELECT ok(
    NOT (current_setting('test.ra')::JSONB -> 'id_map' -> 'product' ? current_setting('test.ze2'))
    AND (SELECT count(*) FROM public.product WHERE tenant_id = current_setting('test.p')::UUID AND sku LIKE 'ZZ-E-2%') = 1
    AND NOT EXISTS (SELECT 1 FROM public.market_cell c JOIN public.product p ON p.id = c.product_id
                    WHERE c.tenant_id = current_setting('test.p')::UUID AND p.sku = 'ZZ-E-2'),
    'a skipped product is not written, nor its cell'
);
SELECT is(
    (SELECT row(p.tenant_id::TEXT, p.gtin, (SELECT count(*) FROM public.sourcing s WHERE s.product_id = p.id))
     FROM public.product p WHERE p.id = current_setting('test.ze')::UUID),
    row(current_setting('test.e'), '4006381333931'::TEXT, 1::BIGINT),
    'a copy leaves the source as it was'
);
SELECT is(
    (SELECT jsonb_agg(f - 'media_id' ORDER BY f ->> 'to') FROM jsonb_array_elements(current_setting('test.ra')::JSONB -> 'files') f),
    jsonb_build_array(
        jsonb_build_object('from', current_setting('test.e') || '/00000000-0000-4000-8000-000000073006/thumb/thumb.webp',
                           'to', current_setting('test.p') || '/' || current_setting('test.new_file') || '/thumb/thumb.webp', 'keep_source', TRUE),
        jsonb_build_object('from', current_setting('test.e') || '/00000000-0000-4000-8000-000000073006/ze.png',
                           'to', current_setting('test.p') || '/' || current_setting('test.new_file') || '/ze.png', 'keep_source', TRUE)
    ),
    'the files to copy: the file and its thumbnail, into the target''s folder, the source kept'
);
SELECT is(
    (SELECT jsonb_object_agg(k, (SELECT count(*) FROM jsonb_object_keys(current_setting('test.ra')::JSONB -> 'id_map' -> k)))
     FROM jsonb_object_keys(current_setting('test.ra')::JSONB -> 'id_map') AS k),
    '{"supplier": 1, "supplier_contact": 1, "product": 2, "sourcing": 1, "market_cell": 1, "media": 1, "media_link": 1, "document": 1}'::JSONB,
    'the id map names every row written'
);
SELECT is(
    (current_setting('test.ra')::JSONB -> 'report' -> 'counts'),
    '{"supplier": 1, "supplier_contact": 1, "product": 2, "sourcing": 1, "market_cell": 1, "media": 1, "media_link": 1, "document": 1}'::JSONB,
    'the report counts what the run wrote'
);

-- Every row written is the target's, and each one is there.
CREATE FUNCTION pg_temp.misplaced (p_transfer JSONB) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    tbl TEXT;
    n BIGINT;
    total BIGINT := 0;
BEGIN
    FOR tbl IN SELECT jsonb_object_keys((SELECT t.id_map FROM public.transfer t WHERE t.id = (p_transfer ->> 'id')::UUID)) LOOP
        EXECUTE format(
            'SELECT count(*) FROM (SELECT (e.value #>> ''{}'')::UUID AS id FROM jsonb_each($1) e) m '
            'WHERE NOT EXISTS (SELECT 1 FROM public.%I x WHERE x.id = m.id AND x.tenant_id = $2)', tbl)
        INTO n
        USING (SELECT t.id_map -> tbl FROM public.transfer t WHERE t.id = (p_transfer ->> 'id')::UUID), (p_transfer ->> 'tenant_id')::UUID;
        total := total + n;
    END LOOP;
    RETURN total;
END;
$$;

SELECT is(pg_temp.misplaced(current_setting('test.ra')::JSONB), 0::BIGINT, 'every row written carries the target''s tenant_id');
SELECT is(
    (SELECT a.tenant_id::TEXT FROM public.audit_transaction a
     WHERE a.id = (SELECT t.audit_transaction_ids[1] FROM public.transfer t WHERE t.id = (current_setting('test.ra')::JSONB ->> 'id')::UUID)),
    current_setting('test.p'),
    'the run is an audit transaction of the target'
);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT throws_like(
    format('SELECT public.revert_audit_transaction(%L)',
           (SELECT (r -> 'audit_transaction_ids' ->> 0) FROM (SELECT current_setting('test.ra')::JSONB AS r) s)),
    '%audit_transfer_not_revertable%',
    'the copy cannot be reverted from the log'
);
RESET ROLE;
SELECT private.unimpersonate();

-- The files are copied (074 checks them); the next runs into MOESA LTD may start.
UPDATE public.transfer SET files_status = 'done' WHERE id = (current_setting('test.ra')::JSONB ->> 'id')::UUID;

-- ---------------------------------------------------------------------------------------------
-- B. F5 at apply: into THO, which MOESA LTD procures for.

SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.c')::UUID]);
SELECT set_config('test.rb', public.transfer_products(current_setting('test.p')::UUID, current_setting('test.c')::UUID,
                                                      ARRAY[current_setting('test.zp')::UUID], 'copy',
                                                      jsonb_build_object('report_hash', public.transfer_products(
                                                          current_setting('test.p')::UUID, current_setting('test.c')::UUID,
                                                          ARRAY[current_setting('test.zp')::UUID], 'copy') ->> 'report_hash'),
                                                      FALSE)::TEXT, TRUE);
RESET ROLE;
SELECT private.unimpersonate();

SELECT is(current_setting('test.rb')::JSONB -> 'report' -> 'excluded', '["supplier", "supplier_contact", "sourcing"]'::JSONB,
          'the run into a provider-procured client leaves the procurement tables out');
SELECT ok(
    (SELECT NOT (t.id_map ?| ARRAY['supplier', 'supplier_contact', 'sourcing']) AND t.id_map ? 'product'
     FROM public.transfer t WHERE t.id = (current_setting('test.rb')::JSONB ->> 'id')::UUID),
    'it writes the product and no supplier, contact or sourcing'
);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM public.sourcing s WHERE s.tenant_id = current_setting('test.c')::UUID
                  AND s.product_id = pg_temp.mapped(current_setting('test.rb')::JSONB, 'product', 'zp'))
    AND NOT EXISTS (SELECT 1 FROM public.supplier s WHERE s.tenant_id = current_setting('test.c')::UUID AND s.code = 'ZS9')
    AND NOT EXISTS (SELECT 1 FROM public.supplier_contact s WHERE s.tenant_id = current_setting('test.c')::UUID AND s.name = 'Contact P9 073'),
    'no sourcing, supplier or contact lands in THO'
);
SELECT is(
    (SELECT count(*) FROM public.transfer t
     CROSS JOIN LATERAL jsonb_each(t.id_map) m
     CROSS JOIN LATERAL jsonb_each_text(m.value) e
     JOIN information_schema.columns ic ON ic.table_schema = 'public' AND ic.table_name = m.key AND ic.column_name = 'client_tenant_id'
     WHERE t.id IN ((current_setting('test.ra')::JSONB ->> 'id')::UUID, (current_setting('test.rb')::JSONB ->> 'id')::UUID)
       AND EXISTS (SELECT 1 FROM public.sourcing s WHERE s.id = e.value::UUID AND s.client_tenant_id IS NOT NULL)),
    0::BIGINT,
    'no copied row carries a client_tenant_id'
);
SELECT is(pg_temp.misplaced(current_setting('test.rb')::JSONB), 0::BIGINT, 'and what it writes is THO''s');
SELECT is((SELECT count(*) FROM public.sourcing WHERE id = '00000000-0000-4000-8000-000000073032'), 1::BIGINT,
          'MOESA LTD keeps its sourcing');

-- C1 (final review): nothing a client may not read reaches THO, owner included (decision 7).
SELECT is(current_setting('test.rb')::JSONB -> 'report' -> 'excluded_rows', '{"document": 1, "media": 2, "media_link": 1}'::JSONB,
          'the pi document, its file, and the file a provider order uses with its gallery link are left out, and counted');
SELECT is(current_setting('test.rb')::JSONB -> 'report' -> 'blanked',
          '[{"table": "product", "column": "notes", "rows": 1}, {"table": "market_cell", "column": "notes", "rows": 1},
            {"table": "document", "column": "notes", "rows": 1}]'::JSONB,
          'the internal notes are reset, reported by column');
SELECT ok(
    NOT EXISTS (SELECT 1 FROM public.document d WHERE d.tenant_id = current_setting('test.c')::UUID
                  AND d.entity_id = pg_temp.mapped(current_setting('test.rb')::JSONB, 'product', 'zp') AND d.type = 'pi')
    AND NOT EXISTS (SELECT 1 FROM public.media m WHERE m.tenant_id = current_setting('test.c')::UUID
                      AND m.file_name IN ('zp-pi.pdf', 'zp-dual.png'))
    AND (SELECT array_agg(regexp_replace(f ->> 'from', '^.*/', '')) FROM public.transfer t CROSS JOIN LATERAL jsonb_array_elements(t.files) f
         WHERE t.id = (current_setting('test.rb')::JSONB ->> 'id')::UUID) = ARRAY['zp.png'],
    'the reviewer''s probe: neither the pi document nor its file (nor the order''s file) arrives in THO; only the open gallery file is copied'
);
SELECT is((SELECT p.notes FROM public.product p WHERE p.id = pg_temp.mapped(current_setting('test.rb')::JSONB, 'product', 'zp')), NULL,
          'the product''s internal note is NULL in THO');
SELECT ok(
    (SELECT c.notes IS NULL FROM public.market_cell c
     WHERE c.tenant_id = current_setting('test.c')::UUID AND c.product_id = pg_temp.mapped(current_setting('test.rb')::JSONB, 'product', 'zp'))
    AND (SELECT d.notes IS NULL AND d.file_name = 'ZP_TEST' FROM public.document d
         WHERE d.tenant_id = current_setting('test.c')::UUID AND d.entity_id = pg_temp.mapped(current_setting('test.rb')::JSONB, 'product', 'zp')),
    'the market cell and the test report arrive without their notes'
);
SELECT ok(
    (SELECT count(*) FROM public.media_link l WHERE l.tenant_id = current_setting('test.c')::UUID
       AND l.entity_id = pg_temp.mapped(current_setting('test.rb')::JSONB, 'product', 'zp')) = 1
    AND (SELECT p.notes FROM public.product p WHERE p.id = current_setting('test.zp')::UUID) = 'Provider note 073'
    AND (SELECT count(*) FROM public.document d WHERE d.entity_id = current_setting('test.zp')::UUID) = 2,
    'the open gallery link arrives; MOESA LTD keeps its notes and documents'
);

-- A move into THO would leave the withheld rows naming a removed product: they block it.
UPDATE public.transfer SET files_status = 'done' WHERE id = (current_setting('test.rb')::JSONB ->> 'id')::UUID;
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.c')::UUID]);
SELECT set_config('test.rbm', public.transfer_products(current_setting('test.p')::UUID, current_setting('test.c')::UUID,
                                                       ARRAY[current_setting('test.zp')::UUID], 'move')::TEXT, TRUE);
SELECT ok(
    current_setting('test.rbm')::JSONB -> 'left_behind' @> jsonb_build_array(
        jsonb_build_object('table', 'document', 'column', 'entity_id', 'refers_to', 'product', 'refers_to_id', current_setting('test.zp'),
                           'rows', 1, 'blocks', TRUE),
        jsonb_build_object('table', 'media_link', 'column', 'entity_id', 'refers_to', 'product', 'refers_to_id', current_setting('test.zp'),
                           'rows', 1, 'blocks', TRUE)),
    'a move into the client lists the withheld document and link as blocking'
);
SELECT throws_like(
    format($q$ SELECT public.transfer_products(%L, %L, ARRAY[%L]::UUID[], 'move', %L::JSONB, FALSE) $q$,
           current_setting('test.p'), current_setting('test.c'), current_setting('test.zp'),
           jsonb_build_object('sku:' || current_setting('test.zp'), '{"action": "rename", "suffix": "-M"}'::JSONB)),
    '%transfer_product_in_use%',
    'and the move is refused'
);
RESET ROLE;
SELECT private.unimpersonate();

-- ---------------------------------------------------------------------------------------------
-- C. A move of THO's THO-MOP40-2P into MOESA LTD.

UPDATE public.transfer SET files_status = 'done' WHERE id = (current_setting('test.rb')::JSONB ->> 'id')::UUID;
SELECT set_config('test.zm_snapshot', (SELECT to_jsonb(d) - ARRAY['id', 'tenant_id', 'entity_id', 'media_id', 'created_by', 'created_at', 'updated_at']
                                       FROM public.document d WHERE d.id = current_setting('test.zm_doc')::UUID)::TEXT, TRUE);

-- R5: the move removes THO's files only the moved rows use, so it needs media delete in THO.
SELECT private.impersonate_scope(current_setting('test.nomdel')::UUID, current_setting('test.c')::UUID,
                                 ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
SELECT throws_like(
    $$ SELECT public.transfer_products(current_setting('test.c')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.zm')::UUID], 'move') $$,
    '%transfer_permissions_required%',
    'a move that would remove source files needs media delete in the source'
);
SELECT lives_ok(
    $$ SELECT public.transfer_products(current_setting('test.c')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.zm')::UUID], 'copy') $$,
    'a copy of the same package does not'
);
RESET ROLE;
SELECT private.unimpersonate();

-- I2: a reader of THO without supplier_terms cannot read the pi file.
SELECT set_config('test.pi_path', current_setting('test.c') || '/00000000-0000-4000-8000-000000073048/pi.pdf', TRUE);
SELECT private.impersonate_scope(current_setting('test.noterms')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT is(
    (SELECT count(*) FROM storage.objects WHERE bucket_id = 'media' AND name IN (current_setting('test.pi_path'),
                                                                                  current_setting('test.c') || '/00000000-0000-4000-8000-000000073049/zm.png')),
    1::BIGINT,
    'before the move, a THO reader without supplier_terms sees the gallery file but not the pi file'
);
RESET ROLE;
SELECT private.unimpersonate();

SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.c')::UUID,
                                 ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
SELECT set_config('test.rmc', public.transfer_products(current_setting('test.c')::UUID, current_setting('test.p')::UUID,
                                                       ARRAY[current_setting('test.zm')::UUID], 'move')::TEXT, TRUE);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM jsonb_array_elements(current_setting('test.rmc')::JSONB -> 'left_behind') e WHERE (e ->> 'blocks')::BOOLEAN)
    AND current_setting('test.rmc')::JSONB -> 'left_behind_links' @> '{"purchase_order_line": 1, "sourcing": 1}'::JSONB
    AND current_setting('test.rmc')::JSONB -> 'conflicts' = '[]'::JSONB,
    'the move rehearses with nothing blocking, the provider''s line and sourcing as links left behind, no GTIN conflict'
);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT set_config('test.rm', public.transfer_products(current_setting('test.c')::UUID, current_setting('test.p')::UUID,
                                                      ARRAY[current_setting('test.zm')::UUID], 'move',
                                                      jsonb_build_object('report_hash', current_setting('test.rmc')::JSONB ->> 'report_hash'),
                                                      FALSE)::TEXT, TRUE);
RESET ROLE;
SELECT private.unimpersonate();

SELECT set_config('test.moved_product', pg_temp.mapped(current_setting('test.rm')::JSONB, 'product', 'zm')::TEXT, TRUE);
SELECT ok(NOT EXISTS (SELECT 1 FROM public.product WHERE id = current_setting('test.zm')::UUID), 'a move removes the source product');
SELECT is((SELECT product_sku FROM public.purchase_order_line WHERE id = current_setting('test.provider_line')::UUID), 'THO-MOP40-2P',
          'the provider line keeps its snapshot after the move');
SELECT is(
    (SELECT row(product_id, product_sku) FROM public.sourcing WHERE id = current_setting('test.provider_sourcing')::UUID),
    row(NULL::UUID, 'THO-MOP40-2P'::TEXT),
    'and so does the provider''s sourcing of it'
);
SELECT is(
    (SELECT row(tenant_id::TEXT, sku, gtin, status::TEXT) FROM public.product WHERE id = current_setting('test.moved_product')::UUID),
    row(current_setting('test.p'), 'THO-MOP40-2P'::TEXT, '5901234123457'::TEXT, 'on_sale'::TEXT),
    'the moved product keeps its active GTIN in the target (the source went first)'
);
SELECT is(
    (SELECT to_jsonb(d) - ARRAY['id', 'tenant_id', 'entity_id', 'media_id', 'created_by', 'created_at', 'updated_at']
     FROM public.document d WHERE d.tenant_id = current_setting('test.p')::UUID AND d.entity_id = current_setting('test.moved_product')::UUID
       AND d.type = 'spec_sheet'),
    current_setting('test.zm_snapshot')::JSONB,
    'the signed spec sheet is moved as it was'
);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM public.document WHERE id = current_setting('test.zm_doc')::UUID)
    AND (SELECT m.tenant_id = current_setting('test.p')::UUID AND m.storage_path LIKE current_setting('test.p') || '/%/zm.pdf'
         FROM public.document d JOIN public.media m ON m.id = d.media_id
         WHERE d.entity_id = current_setting('test.moved_product')::UUID AND d.type = 'spec_sheet'),
    'it is gone from THO and cites its file in MOESA LTD'
);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM public.market_cell WHERE id = '00000000-0000-4000-8000-000000073044')
    AND EXISTS (SELECT 1 FROM public.market_cell WHERE product_id = current_setting('test.moved_product')::UUID),
    'the cell moves'
);
-- I2: the files only the moved rows used leave THO; one still used there stays.
SELECT is(
    ARRAY(SELECT id::TEXT FROM public.media
          WHERE id IN (current_setting('test.zm_file')::UUID, current_setting('test.pi_file')::UUID, current_setting('test.shared_file')::UUID)
            AND tenant_id = current_setting('test.c')::UUID),
    ARRAY[current_setting('test.shared_file')],
    'the move removes THO''s file rows only the moved rows used; the one the seed''s mop uses stays'
);
SELECT is(
    (SELECT jsonb_object_agg(regexp_replace(f ->> 'from', '^.*/', ''), f -> 'keep_source')
     FROM public.transfer t CROSS JOIN LATERAL jsonb_array_elements(t.files) f
     WHERE t.id = (current_setting('test.rm')::JSONB ->> 'id')::UUID),
    '{"zm.pdf": false, "pi.pdf": false, "zm.png": true}'::JSONB,
    'the service removes the objects of the removed rows after the copy, and keeps the shared one'
);
SELECT private.impersonate_scope(current_setting('test.noterms')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT is(
    (SELECT count(*) FROM storage.objects WHERE bucket_id = 'media' AND name = current_setting('test.pi_path')),
    0::BIGINT,
    'after the move, the pi file left in Storage is still not readable without supplier_terms'
);
SELECT is(
    (SELECT count(*) FROM storage.objects WHERE bucket_id = 'media'
       AND name = current_setting('test.c') || '/00000000-0000-4000-8000-000000073043/zm.pdf'),
    1::BIGINT,
    'an unrestricted removed file stays as readable as it was until the service removes it'
);
-- R1: until the files are verified, nobody removes the object the service is to remove.
SELECT set_config('test.zm_pdf', current_setting('test.c') || '/00000000-0000-4000-8000-000000073043/zm.pdf', TRUE);
SELECT is(pg_temp.remove_object(current_setting('test.zm_pdf')), 0::BIGINT,
          'while the move''s files are not verified, a source user cannot remove the object the service is to remove');
RESET ROLE;
SELECT private.unimpersonate();
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT is(pg_temp.remove_object(current_setting('test.zm_pdf')), 0::BIGINT, 'nor can the copier');
RESET ROLE;
SELECT private.unimpersonate();
SELECT ok(
    (SELECT bool_and(private.transfer_file_locked(f ->> 'to')) FROM public.transfer t CROSS JOIN LATERAL jsonb_array_elements(t.files) f
     WHERE t.id = (current_setting('test.rm')::JSONB ->> 'id')::UUID),
    'and every target copy is held as well'
);
SELECT is(
    (SELECT array_agg(a.tenant_id::TEXT ORDER BY i)
     FROM public.transfer t
     CROSS JOIN LATERAL unnest(t.audit_transaction_ids) WITH ORDINALITY AS x (tx, i)
     JOIN public.audit_transaction a ON a.id = x.tx
     WHERE t.id = (current_setting('test.rm')::JSONB ->> 'id')::UUID),
    ARRAY[current_setting('test.p'), current_setting('test.c')],
    'the move is two audit transactions: the target''s, and the source''s deletions'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.audit_log l JOIN public.transfer t ON l.transaction_id = t.audit_transaction_ids[2]
            WHERE t.id = (current_setting('test.rm')::JSONB ->> 'id')::UUID
              AND l.table_name = 'document' AND l.operation = 'DELETE' AND l.record_id = current_setting('test.zm_doc')::UUID
              AND l.old_data ->> 'status' = 'signed')
    AND EXISTS (SELECT 1 FROM public.audit_log l JOIN public.transfer t ON l.transaction_id = t.audit_transaction_ids[1]
                WHERE t.id = (current_setting('test.rm')::JSONB ->> 'id')::UUID
                  AND l.table_name = 'document' AND l.operation = 'INSERT' AND l.new_data ->> 'status' = 'signed'
                  AND l.new_data ->> 'entity_id' = current_setting('test.moved_product')),
    'the audit records the signed document deleted in THO and written in MOESA LTD'
);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT throws_like(
    format('SELECT public.revert_audit_transaction(%L)', (SELECT (r -> 'audit_transaction_ids' ->> 1) FROM (SELECT current_setting('test.rm')::JSONB AS r) s)),
    '%audit_transfer_not_revertable%',
    'the source''s deletions cannot be reverted from the log'
);
RESET ROLE;
SELECT private.unimpersonate();
SELECT is(pg_temp.misplaced(current_setting('test.rm')::JSONB), 0::BIGINT, 'what the move writes is MOESA LTD''s');
SELECT is(
    (SELECT jsonb_array_length(t.files) FROM public.transfer t WHERE t.id = (current_setting('test.rm')::JSONB ->> 'id')::UUID),
    3,
    'the spec sheet''s, the pi''s and the gallery file wait to be copied'
);
UPDATE public.transfer SET files_status = 'done' WHERE id = (current_setting('test.rm')::JSONB ->> 'id')::UUID;

-- R1, once verified: the source object goes by a user who may check the transfer (or the service).
SELECT private.impersonate_scope(current_setting('test.noterms')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT is(pg_temp.remove_object(current_setting('test.zm_pdf')), 0::BIGINT,
          'once verified, a source user who may not check the transfer still cannot remove it');
RESET ROLE;
SELECT private.unimpersonate();
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT is(pg_temp.remove_object(current_setting('test.zm_pdf')), 1::BIGINT, 'a user who may check it can');
RESET ROLE;
SELECT private.unimpersonate();

-- L3: a row the write would drop (its entity not written) stops a move, and is only dropped in a copy.
INSERT INTO public.transfer (id, tenant_id, source_tenant_id, product_ids, mode, started_by, report)
VALUES ('00000000-0000-4000-8000-000000073061', current_setting('test.p')::UUID, current_setting('test.c')::UUID, '{}', 'move',
        current_setting('test.akif')::UUID, '{}'),
       ('00000000-0000-4000-8000-000000073062', current_setting('test.p')::UUID, current_setting('test.c')::UUID, '{}', 'copy',
        current_setting('test.akif')::UUID, '{}');
DELETE FROM pg_temp.transfer_rows;
DELETE FROM pg_temp.transfer_map;
INSERT INTO pg_temp.transfer_rows (table_name, source_id, row, copy_only)
VALUES ('document', '00000000-0000-4000-8000-000000073063',
        jsonb_build_object('id', '00000000-0000-4000-8000-000000073063', 'tenant_id', current_setting('test.c'), 'entity_type', 'product',
                           'entity_id', gen_random_uuid(), 'type', 'other', 'status', 'draft', 'url', 'https://example.test/x.pdf'),
        FALSE);
INSERT INTO pg_temp.transfer_map (table_name, source_id, target_id) VALUES ('document', '00000000-0000-4000-8000-000000073063', gen_random_uuid());
SELECT throws_like($$ SELECT private.transfer_write('00000000-0000-4000-8000-000000073061', 'document') $$, '%transfer_package_invalid%',
                   'a move never drops a row it removed from the source');
SELECT is(private.transfer_write('00000000-0000-4000-8000-000000073062', 'document'), '[]'::JSONB, 'a copy drops it with its entity');
-- And a row whose required reference is not written (a link to a file not in the map).
INSERT INTO pg_temp.transfer_rows (table_name, source_id, row, copy_only)
VALUES ('media_link', '00000000-0000-4000-8000-000000073064',
        jsonb_build_object('id', '00000000-0000-4000-8000-000000073064', 'tenant_id', current_setting('test.c'), 'media_id', gen_random_uuid(),
                           'entity_type', 'product', 'entity_id', gen_random_uuid(), 'role', 'gallery'),
        FALSE);
INSERT INTO pg_temp.transfer_map (table_name, source_id, target_id) VALUES ('media_link', '00000000-0000-4000-8000-000000073064', gen_random_uuid());
SELECT throws_like($$ SELECT private.transfer_write('00000000-0000-4000-8000-000000073061', 'media_link') $$, '%transfer_package_invalid%',
                   'a move never drops a row whose required reference is not written');
SELECT is(private.transfer_write('00000000-0000-4000-8000-000000073062', 'media_link'), '[]'::JSONB, 'a copy drops it');

-- ---------------------------------------------------------------------------------------------
-- D. The run trusts no rehearsal.

SELECT private.impersonate_scope(current_setting('test.gate')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
SELECT is(
    (public.transfer_products(current_setting('test.e')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.zf')::UUID], 'copy')
     ->> 'unresolved')::INT,
    0,
    'ZZ-E-3 rehearses without a conflict'
);
RESET ROLE;
SELECT private.unimpersonate();

-- Meanwhile MOESA LTD gets a ZZ-E-3 of its own.
SELECT set_config('moesa.rules_bypass', '1', TRUE);
INSERT INTO public.product (id, tenant_id, sku, display_name) VALUES ('00000000-0000-4000-8000-000000073052', current_setting('test.p')::UUID, 'ZZ-E-3', 'Late 073');
SELECT set_config('moesa.rules_bypass', '', TRUE);

SELECT private.impersonate_scope(current_setting('test.gate')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
SELECT throws_like(
    $$ SELECT public.transfer_products(current_setting('test.e')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.zf')::UUID],
                                       'copy', NULL, FALSE) $$,
    '%transfer_decision_required%',
    'the run builds its report afresh: the new conflict needs a decision'
);
SELECT throws_like(
    format($q$ SELECT public.transfer_products(%L::UUID, %L::UUID, ARRAY[%L::UUID], 'copy', %L::JSONB, FALSE) $q$,
           current_setting('test.e'), current_setting('test.p'), current_setting('test.zf'),
           jsonb_build_object('sku:' || current_setting('test.zf'), '{"action": "rename", "suffix": "-X"}'::JSONB,
                              'sku:' || gen_random_uuid(), '{"action": "rename", "suffix": "-Y"}'::JSONB)),
    '%transfer_decision_invalid%',
    'a decision for no conflict of the fresh report is refused'
);
RESET ROLE;
SELECT private.unimpersonate();

-- The gate is asked again by the run: the transfer right gone since the rehearsal.
DELETE FROM public.role_permission
WHERE role_id = '00000000-0000-4000-8000-000000073132'
  AND permission_id = (SELECT id FROM public.permission WHERE resource_name = 'public.transfer' AND command = 'insert');
SELECT set_config('test.transfers_before', (SELECT count(*)::TEXT FROM public.transfer), TRUE);
SELECT private.impersonate_scope(current_setting('test.gate')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
SELECT throws_like(
    format($q$ SELECT public.transfer_products(%L::UUID, %L::UUID, ARRAY[%L::UUID], 'copy', %L::JSONB, FALSE) $q$,
           current_setting('test.e'), current_setting('test.p'), current_setting('test.zf'),
           jsonb_build_object('sku:' || current_setting('test.zf'), '{"action": "rename", "suffix": "-X"}'::JSONB)),
    '%transfer_permissions_required%',
    'the run asks the gate itself, whatever a rehearsal said'
);
RESET ROLE;
SELECT private.unimpersonate();
SELECT is((SELECT count(*)::TEXT FROM public.transfer), current_setting('test.transfers_before'), 'a refused run writes nothing');

-- ---------------------------------------------------------------------------------------------
-- E. L4: the stored description of the source is read under the source's rights.

-- Asking for the source too changes nothing: tonly is not in it.
SELECT private.impersonate_scope(current_setting('test.tonly')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.e')::UUID]);
SELECT is(
    (SELECT row(t.files_status, t.product_ids, t.report, t.decisions, t.id_map, t.files) FROM api.transfer t
     WHERE t.id = (current_setting('test.ra')::JSONB ->> 'id')::UUID),
    row('done'::TEXT, NULL::UUID[], NULL::JSONB, NULL::JSONB, NULL::JSONB, NULL::JSONB),
    'a reader of the target alone sees the transfer without the source''s products, report, decisions, map or files'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM api.audit_log l
        WHERE l.table_name = 'transfer' AND l.record_id = (current_setting('test.ra')::JSONB ->> 'id')::UUID
          AND EXISTS (
              SELECT 1 FROM unnest(ARRAY['product_ids', 'report', 'decisions', 'id_map', 'files']) AS f (name)
              WHERE coalesce(l.new_data, '{}') -> f.name IS DISTINCT FROM '{"masked": true}'::JSONB
                 OR (coalesce(l.old_data, '{}') ? f.name AND l.old_data -> f.name IS DISTINCT FROM '{"masked": true}'::JSONB)
          )
    )
    AND EXISTS (SELECT 1 FROM api.audit_log l WHERE l.table_name = 'transfer'
                  AND l.record_id = (current_setting('test.ra')::JSONB ->> 'id')::UUID),
    'nor in the audit log'
);
RESET ROLE;
SELECT private.unimpersonate();

-- The rights are read in the request's tenants, as for any rights column: the source is in akif's scope.
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.e')::UUID]);
SELECT ok(
    (SELECT t.report IS NOT NULL AND t.decisions IS NOT NULL AND t.id_map IS NOT NULL AND t.files IS NOT NULL AND t.product_ids IS NOT NULL
     FROM api.transfer t WHERE t.id = (current_setting('test.ra')::JSONB ->> 'id')::UUID),
    'a manager of the source reads all of it'
);
RESET ROLE;
SELECT private.unimpersonate();

SELECT is(
    ARRAY(SELECT field::TEXT FROM public.field_class
          WHERE resource_name = 'public.transfer' AND class = 'sensitive' AND rights_column = 'source_tenant_id' ORDER BY field),
    ARRAY['decisions', 'files', 'id_map', 'product_ids', 'report'],
    'the source''s description is classified under the source'
);

-- ---------------------------------------------------------------------------------------------
-- F. The internals.

SELECT ok(
    NOT has_function_privilege('authenticated', 'private.transfer_build_map(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.transfer_write(uuid,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.transfer_delete_source(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.transfer_apply_copy(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.transfer_apply(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.transfer_lock_rows()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.transfer_row_for(uuid,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.transfer_media_paths(uuid,uuid,text,text)', 'EXECUTE'),
    'the run''s internals are out of the users'' reach'
);
SELECT is(
    ARRAY(SELECT p.proname::TEXT FROM pg_proc p WHERE p.pronamespace = 'private'::REGNAMESPACE
          AND p.proname IN ('transfer_build_map', 'transfer_write', 'transfer_delete_source', 'transfer_apply_copy', 'transfer_apply',
                            'transfer_lock_rows', 'transfer_row_for')
          AND p.prosecdef AND p.proconfig @> ARRAY['search_path=""'] ORDER BY 1),
    ARRAY['transfer_apply', 'transfer_apply_copy', 'transfer_build_map', 'transfer_delete_source', 'transfer_lock_rows', 'transfer_row_for',
          'transfer_write'],
    'they run as their owner with an empty search_path'
);
SELECT throws_ok(
    format($q$ INSERT INTO public.media (tenant_id, storage_path, file_name, mime_type, size_bytes)
               VALUES (%L, %L, 'none.png', 'image/png', 10) $q$,
           current_setting('test.p'), current_setting('test.p') || '/00000000-0000-4000-8000-000000073099/none.png'),
    '23503', 'media_file_missing',
    'outside a transfer a file row still needs its file in Storage'
);
SELECT is(
    (SELECT column_default FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'transfer' AND column_name = 'report'),
    '''{}''::jsonb',
    'a transfer row starts with an empty report'
);
-- C1: every provider-only column a transfer into a client may carry can be reset (to NULL or its
-- default); the tables F5 leaves out whole (transfer_excluded) never reach a client.
SELECT is_empty(
    $$ SELECT f.resource_name || '.' || f.field FROM private.transfer_registry g
       JOIN public.field_class f ON f.resource_name = 'public.' || g.table_name AND f.class = 'sensitive' AND NOT f.client_visible
       JOIN pg_attribute a ON a.attrelid = ('public.' || g.table_name)::REGCLASS AND a.attname = f.field
       WHERE a.attnotnull AND NOT a.atthasdef
         AND NOT g.table_name = ANY (private.transfer_excluded(current_setting('test.p')::UUID, current_setting('test.c')::UUID)) $$,
    'every provider-only column of the registry takes NULL or has a default'
);
-- C1: document_restriction is media_restriction's document arms (the same clauses over the same names).
SELECT is_empty(
    format($q$ SELECT n FROM unnest(%L::TEXT[]) AS n
               WHERE strpos(pg_get_functiondef('private.document_restriction(public.document_type,public.document_entity)'::REGPROCEDURE), n) = 0
                  OR strpos(pg_get_functiondef('private.media_restriction(uuid)'::REGPROCEDURE), n) = 0 $q$,
           ARRAY['''supplier_identity''', '''supplier_terms''', 'd.entity_type IN (''supplier'', ''purchase_order'')',
                 'd.type IN (''pi'', ''commercial_invoice'', ''po'')', 'd.type = ''contract'' AND d.entity_type = ''supplier''']),
    'a document kind is withheld exactly when it would restrict its file'
);
SELECT ok(
    private.document_restriction('pi', 'product') = ARRAY['supplier_terms']
    AND private.document_restriction('packing_list', 'purchase_order') = ARRAY['supplier_identity']
    AND private.document_restriction('contract', 'supplier') = ARRAY['supplier_identity', 'supplier_terms']
    AND private.document_restriction('spec_sheet', 'product') = '{}'
    AND NOT has_function_privilege('authenticated', 'private.transfer_withhold()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'private.transfer_to_client(uuid,uuid)', 'EXECUTE')
    AND (SELECT p.prosecdef AND p.proconfig @> ARRAY['search_path=""'] FROM pg_proc p
         WHERE p.oid = 'private.transfer_withhold()'::REGPROCEDURE),
    'the kinds a client never receives; the withholding is out of the users'' reach'
);

-- ---------------------------------------------------------------------------------------------
-- G. A copy inside the company, MOESA LTD → MOESA Europe: C1 is for clients only, so everything
-- arrives; and a copied file keeps the restriction its source rows gave it (I1).

UPDATE public.transfer SET files_status = 'done';
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.e')::UUID]);
SELECT set_config('test.rg', public.transfer_products(current_setting('test.p')::UUID, current_setting('test.e')::UUID,
                                                      ARRAY[current_setting('test.zp')::UUID], 'copy',
                                                      jsonb_build_object('report_hash', public.transfer_products(
                                                          current_setting('test.p')::UUID, current_setting('test.e')::UUID,
                                                          ARRAY[current_setting('test.zp')::UUID], 'copy') ->> 'report_hash'),
                                                      FALSE)::TEXT, TRUE);
RESET ROLE;
SELECT private.unimpersonate();

SELECT ok(
    current_setting('test.rg')::JSONB -> 'report' -> 'excluded' = '[]'::JSONB
    AND current_setting('test.rg')::JSONB -> 'report' -> 'excluded_rows' = '{}'::JSONB
    AND current_setting('test.rg')::JSONB -> 'report' -> 'blanked' = '[]'::JSONB,
    'a copy inside the company leaves nothing out and resets nothing'
);
SELECT ok(
    (SELECT d.notes = 'supplier price 4.20 USD' FROM public.document d
     WHERE d.tenant_id = current_setting('test.e')::UUID
       AND d.entity_id = pg_temp.mapped(current_setting('test.rg')::JSONB, 'product', 'zp') AND d.type = 'pi')
    AND (SELECT p.notes FROM public.product p WHERE p.id = pg_temp.mapped(current_setting('test.rg')::JSONB, 'product', 'zp')) = 'Provider note 073'
    AND (SELECT c.notes FROM public.market_cell c WHERE c.tenant_id = current_setting('test.e')::UUID
           AND c.product_id = pg_temp.mapped(current_setting('test.rg')::JSONB, 'product', 'zp')) = 'Cell note 073'
    AND pg_temp.mapped(current_setting('test.rg')::JSONB, 'media', 'zp_pi') IS NOT NULL
    AND pg_temp.mapped(current_setting('test.rg')::JSONB, 'media', 'zp_dual') IS NOT NULL,
    'the pi document with its file and note, and the product''s and cell''s notes, arrive in MOESA Europe'
);
SELECT is(private.media_restriction(pg_temp.mapped(current_setting('test.rg')::JSONB, 'media', 'zp_dual')), ARRAY['supplier_identity'],
          'I1: the gallery file a provider order also uses stays supplier_identity-restricted where only its gallery link was copied');
SELECT ok(
    private.media_restriction(pg_temp.mapped(current_setting('test.rg')::JSONB, 'media', 'zp_img')) = '{}'
    AND private.media_restriction(pg_temp.mapped(current_setting('test.rg')::JSONB, 'media', 'zp_pi')) = ARRAY['supplier_terms']
    AND NOT EXISTS (SELECT 1 FROM private.media_restriction_hold h
                    WHERE h.media_id IN (pg_temp.mapped(current_setting('test.rg')::JSONB, 'media', 'zp_img'),
                                         pg_temp.mapped(current_setting('test.rg')::JSONB, 'media', 'zp_pi'))),
    'a file whose copied rows give it its restriction (or none) gets no hold'
);

SELECT * FROM finish();

ROLLBACK;
