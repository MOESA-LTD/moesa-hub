CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Media links (M19) on a company of its own, as its coordinator: one primary image
-- per record (a new primary demotes the old one, set_primary_media swaps them), only an image is
-- primary, a file links only to records of its own tenant, the record must exist in the
-- tenant (and its table), a link never moves, linking needs the record's update right, the
-- library view and the product list read the links, and linked media is not deleted. What it writes is rolled back.
BEGIN;

SELECT plan(18);

-- Fixture, built here as postgres (the seed is not on the new model yet): a company with an owner and a
-- coordinator (products and media, no file deletion), and another company with a product.
INSERT INTO public.plan (display_name, is_active) VALUES ('Media link test plan', TRUE);

INSERT INTO public.tenant (id, display_name) VALUES
    ('00000000-0000-4000-8000-000000000301', 'Media Link Co'),
    ('00000000-0000-4000-8000-000000000302', 'Other Media Co');

INSERT INTO public.user (id, email) VALUES
    ('00000000-0000-4000-8000-000000000303', 'owner@medialink.test'),
    ('00000000-0000-4000-8000-000000000304', 'coordinator@medialink.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000000303', '00000000-0000-4000-8000-000000000301');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000000303', '00000000-0000-4000-8000-000000000301'),
    ('00000000-0000-4000-8000-000000000304', '00000000-0000-4000-8000-000000000301');

INSERT INTO public.role (id, display_name, tenant_id)
VALUES ('00000000-0000-4000-8000-000000000305', 'Coordinator', '00000000-0000-4000-8000-000000000301');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000000305', p.id
FROM public.permission p
WHERE (p.resource_name IN ('public.product', 'public.supplier') AND p.command IN ('select', 'update'))
   OR (p.group_name = 'media' AND NOT (p.resource_name = 'public.media' AND p.command = 'delete'));

INSERT INTO public.user_role (user_id, role_id)
VALUES ('00000000-0000-4000-8000-000000000304', '00000000-0000-4000-8000-000000000305');

SELECT set_config('test.moesa', '00000000-0000-4000-8000-000000000301', TRUE);
SELECT set_config('test.atlas', '00000000-0000-4000-8000-000000000302', TRUE);
SELECT set_config('test.koordinator', '00000000-0000-4000-8000-000000000304', TRUE);
SELECT set_config('test.akif', '00000000-0000-4000-8000-000000000303', TRUE);
SELECT set_config('test.mop40', '00000000-0000-4000-8000-000000000306', TRUE);
SELECT set_config('test.cones', '00000000-0000-4000-8000-000000000307', TRUE);
SELECT set_config('test.tr1', '00000000-0000-4000-8000-000000000308', TRUE);
SELECT set_config('test.m_png', '00000000-0000-4000-8000-000000000251', TRUE);
SELECT set_config('test.m_png2', '00000000-0000-4000-8000-000000000252', TRUE);
SELECT set_config('test.m_pdf', '00000000-0000-4000-8000-000000000253', TRUE);
SELECT set_config('test.m_shared', '00000000-0000-4000-8000-000000000254', TRUE);
SELECT set_config('test.atlas_product', '00000000-0000-4000-8000-000000000256', TRUE);

INSERT INTO public.product (id, tenant_id, sku, display_name) VALUES
    (current_setting('test.mop40')::UUID, current_setting('test.moesa')::UUID, 'MOP40-2P', 'Mop 40'),
    (current_setting('test.cones')::UUID, current_setting('test.moesa')::UUID, 'CONES-100', 'Cones'),
    (current_setting('test.atlas_product')::UUID, current_setting('test.atlas')::UUID, 'ATL-001', 'Other company product');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country)
VALUES (current_setting('test.tr1')::UUID, current_setting('test.moesa')::UUID, 'TR1', 'Supplier', 'TR');

-- The uploaded files and their rows (all of the first company).
INSERT INTO storage.objects (bucket_id, name, metadata)
VALUES
    ('media', current_setting('test.moesa') || '/' || current_setting('test.m_png') || '/a.png',
     '{"mimetype": "image/png", "size": 1000}'::JSONB),
    ('media', current_setting('test.moesa') || '/' || current_setting('test.m_png2') || '/b.png',
     '{"mimetype": "image/png", "size": 1000}'::JSONB),
    ('media', current_setting('test.moesa') || '/' || current_setting('test.m_pdf') || '/c.pdf',
     '{"mimetype": "application/pdf", "size": 1000}'::JSONB),
    ('media', current_setting('test.moesa') || '/' || current_setting('test.m_shared') || '/d.png',
     '{"mimetype": "image/png", "size": 1000}'::JSONB);

INSERT INTO public.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
SELECT f.id::UUID, current_setting('test.moesa')::UUID,
       current_setting('test.moesa') || '/' || f.id || '/' || f.name, f.name, 'image/png', 1
FROM (VALUES (current_setting('test.m_png'), 'a.png'),
             (current_setting('test.m_png2'), 'b.png'),
             (current_setting('test.m_pdf'), 'c.pdf'),
             (current_setting('test.m_shared'), 'd.png')) AS f (id, name);

SELECT private.impersonate(current_setting('test.koordinator')::UUID, current_setting('test.moesa')::UUID);

SELECT has_table('public', 'media_link', 'media_link table');

SELECT hasnt_column('public', 'media', 'customer_id', 'media has no customer');

SELECT lives_ok(
    $$
        INSERT INTO api.media_link (tenant_id, media_id, entity_type, entity_id, role)
        VALUES (current_setting('test.moesa')::UUID, current_setting('test.m_png')::UUID, 'product',
                current_setting('test.mop40')::UUID, 'primary_image')
    $$,
    'a coordinator links a primary image to a product'
);

INSERT INTO api.media_link (tenant_id, media_id, entity_type, entity_id, role)
VALUES (current_setting('test.moesa')::UUID, current_setting('test.m_png2')::UUID, 'product',
        current_setting('test.mop40')::UUID, 'primary_image');

SELECT is(
    (SELECT string_agg(m.file_name || ':' || l.role, ',' ORDER BY m.file_name)
     FROM api.media_link l JOIN api.media m ON m.id = l.media_id
     WHERE l.entity_id = current_setting('test.mop40')::UUID),
    'a.png:gallery,b.png:primary_image',
    'a second primary demotes the first'
);

SELECT public.set_primary_media(
    (SELECT l.id FROM api.media_link l WHERE l.media_id = current_setting('test.m_png')::UUID)
);

SELECT is(
    (SELECT string_agg(m.file_name || ':' || l.role, ',' ORDER BY m.file_name)
     FROM api.media_link l JOIN api.media m ON m.id = l.media_id
     WHERE l.entity_id = current_setting('test.mop40')::UUID),
    'a.png:primary_image,b.png:gallery',
    'set_primary_media swaps the primary'
);

SELECT throws_ok(
    $$
        INSERT INTO api.media_link (tenant_id, media_id, entity_type, entity_id, role)
        VALUES (current_setting('test.moesa')::UUID, current_setting('test.m_pdf')::UUID, 'product',
                current_setting('test.cones')::UUID, 'primary_image')
    $$,
    '23514',
    'media_primary_not_image',
    'a PDF cannot be primary'
);

SELECT lives_ok(
    $$
        INSERT INTO api.media_link (tenant_id, media_id, entity_type, entity_id)
        VALUES (current_setting('test.moesa')::UUID, current_setting('test.m_shared')::UUID, 'supplier',
                current_setting('test.tr1')::UUID)
    $$,
    'a file links to any record of its tenant'
);

SELECT throws_ok(
    $$
        INSERT INTO api.media_link (tenant_id, media_id, entity_type, entity_id)
        VALUES (current_setting('test.moesa')::UUID, current_setting('test.m_shared')::UUID, 'product', gen_random_uuid())
    $$,
    '23503',
    'media_link_entity_missing',
    'the record must exist'
);

SELECT throws_ok(
    $$
        INSERT INTO api.media_link (tenant_id, media_id, entity_type, entity_id)
        VALUES (current_setting('test.moesa')::UUID, current_setting('test.m_shared')::UUID, 'product',
                current_setting('test.atlas_product')::UUID)
    $$,
    '23503',
    'media_link_entity_missing',
    'not to another tenant''s product'
);

SELECT throws_ok(
    $$
        INSERT INTO api.media_link (tenant_id, media_id, entity_type, entity_id)
        VALUES (current_setting('test.moesa')::UUID, current_setting('test.m_shared')::UUID, 'shipment', gen_random_uuid())
    $$,
    '23503',
    'media_link_entity_missing',
    'not to a table that does not exist yet'
);

SELECT throws_ok(
    $$ UPDATE api.media_link SET entity_id = current_setting('test.cones')::UUID WHERE media_id = current_setting('test.m_png')::UUID $$,
    '23514',
    'media_link_identity_immutable',
    'a link does not move'
);

SELECT throws_ok(
    $$ DELETE FROM api.media WHERE id = current_setting('test.m_pdf')::UUID $$,
    '42501',
    NULL,
    'a coordinator does not delete media'
);

-- The coordinator loses the right to change products.
RESET ROLE;

DELETE FROM public.role_permission rp
USING public.role r, public.permission p
WHERE rp.role_id = r.id AND rp.permission_id = p.id
  AND r.tenant_id = current_setting('test.moesa')::UUID AND r.display_name = 'Coordinator'
  AND p.resource_name = 'public.product' AND p.command = 'update';

SELECT private.impersonate(current_setting('test.koordinator')::UUID, current_setting('test.moesa')::UUID);

SELECT throws_ok(
    $$
        INSERT INTO api.media_link (tenant_id, media_id, entity_type, entity_id)
        VALUES (current_setting('test.moesa')::UUID, current_setting('test.m_shared')::UUID, 'product',
                current_setting('test.cones')::UUID)
    $$,
    '42501',
    'media_link_forbidden',
    'linking needs the record''s update right'
);

SELECT throws_ok(
    $$ DELETE FROM api.media_link WHERE media_id = current_setting('test.m_png2')::UUID $$,
    '42501',
    'media_link_forbidden',
    'so does unlinking'
);

SELECT is(
    (SELECT link_count || ':' || (linked_entities @> ARRAY['product:' || current_setting('test.mop40')])
     FROM api.media_library WHERE id = current_setting('test.m_png')::UUID),
    '1:true',
    'the library counts links'
);

SELECT is(
    (SELECT primary_image_path FROM api.product_with_evidence WHERE id = current_setting('test.mop40')::UUID),
    current_setting('test.moesa') || '/' || current_setting('test.m_png') || '/a.png',
    'the product list gets the primary image'
);

RESET ROLE;

SELECT private.impersonate(current_setting('test.akif')::UUID, current_setting('test.moesa')::UUID);

SELECT throws_ok(
    $$ DELETE FROM api.media WHERE id = current_setting('test.m_png')::UUID $$,
    '23503',
    'media_in_use',
    'linked media is not deleted'
);

SELECT lives_ok(
    $$ DELETE FROM api.media WHERE id = current_setting('test.m_pdf')::UUID $$,
    'management deletes unlinked media'
);

SELECT * FROM finish();

ROLLBACK;
