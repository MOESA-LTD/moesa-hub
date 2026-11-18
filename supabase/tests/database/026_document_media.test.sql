CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Documents pointing at media (M19) on a company of its own, as its coordinator: a
-- document's file is a Drive link, a media file or both, never neither; the file must be in the
-- document's tenant; and a file a document cites is counted by the library and is not deleted. What it writes is
-- rolled back.
BEGIN;

SELECT plan(8);

-- Fixture, built here as postgres (the seed is not on the new model yet): a company with a
-- coordinator (products, suppliers, documents, media; no file deletion) and an owner, and another company.
INSERT INTO public.plan (display_name, is_active) VALUES ('Document media test plan', TRUE);

INSERT INTO public.tenant (id, display_name) VALUES
    ('00000000-0000-4000-8000-000000000311', 'Document Media Co'),
    ('00000000-0000-4000-8000-000000000312', 'Other Document Co');

INSERT INTO public.user (id, email) VALUES
    ('00000000-0000-4000-8000-000000000313', 'owner@docmedia.test'),
    ('00000000-0000-4000-8000-000000000314', 'coordinator@docmedia.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000000313', '00000000-0000-4000-8000-000000000311');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000000313', '00000000-0000-4000-8000-000000000311'),
    ('00000000-0000-4000-8000-000000000314', '00000000-0000-4000-8000-000000000311');

INSERT INTO public.role (id, display_name, tenant_id)
VALUES ('00000000-0000-4000-8000-000000000315', 'Coordinator', '00000000-0000-4000-8000-000000000311');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000000315', p.id
FROM public.permission p
WHERE (p.resource_name IN ('public.product', 'public.supplier', 'public.document') AND p.command IN ('select', 'insert', 'update'))
   OR (p.group_name = 'media' AND NOT (p.resource_name = 'public.media' AND p.command = 'delete'));

INSERT INTO public.user_role (user_id, role_id)
VALUES ('00000000-0000-4000-8000-000000000314', '00000000-0000-4000-8000-000000000315');

SELECT set_config('test.moesa', '00000000-0000-4000-8000-000000000311', TRUE);
SELECT set_config('test.atlas', '00000000-0000-4000-8000-000000000312', TRUE);
SELECT set_config('test.koordinator', '00000000-0000-4000-8000-000000000314', TRUE);
SELECT set_config('test.akif', '00000000-0000-4000-8000-000000000313', TRUE);
SELECT set_config('test.mop40', '00000000-0000-4000-8000-000000000316', TRUE);
SELECT set_config('test.tr1', '00000000-0000-4000-8000-000000000317', TRUE);
SELECT set_config('test.m_spec', '00000000-0000-4000-8000-000000000261', TRUE);
SELECT set_config('test.m_other', '00000000-0000-4000-8000-000000000262', TRUE);
SELECT set_config('test.m_atlas', '00000000-0000-4000-8000-000000000263', TRUE);

INSERT INTO public.product (id, tenant_id, sku, display_name)
VALUES (current_setting('test.mop40')::UUID, current_setting('test.moesa')::UUID, 'MOP40-2P', 'Mop 40');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country)
VALUES (current_setting('test.tr1')::UUID, current_setting('test.moesa')::UUID, 'TR1', 'Supplier', 'TR');

-- The uploaded files and their rows: two of the company's, and another company's file.
INSERT INTO storage.objects (bucket_id, name, metadata)
VALUES
    ('media', current_setting('test.moesa') || '/' || current_setting('test.m_spec') || '/spec.pdf',
     '{"mimetype": "application/pdf", "size": 1000}'::JSONB),
    ('media', current_setting('test.moesa') || '/' || current_setting('test.m_other') || '/other.pdf',
     '{"mimetype": "application/pdf", "size": 1000}'::JSONB),
    ('media', current_setting('test.atlas') || '/' || current_setting('test.m_atlas') || '/atlas.pdf',
     '{"mimetype": "application/pdf", "size": 1000}'::JSONB);

INSERT INTO public.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
SELECT f.id::UUID, f.tenant::UUID, f.tenant || '/' || f.id || '/' || f.name, f.name, 'application/pdf', 1
FROM (VALUES (current_setting('test.m_spec'), current_setting('test.moesa'), 'spec.pdf'),
             (current_setting('test.m_other'), current_setting('test.moesa'), 'other.pdf'),
             (current_setting('test.m_atlas'), current_setting('test.atlas'), 'atlas.pdf')) AS f (id, tenant, name);

SELECT has_column('public', 'document', 'media_id', 'document.media_id');

SELECT hasnt_column('public', 'document', 'storage_path', 'storage_path is gone');

SELECT hasnt_column('public', 'document', 'customer_id', 'document has no customer');

SELECT private.impersonate(current_setting('test.koordinator')::UUID, current_setting('test.moesa')::UUID);

SELECT lives_ok(
    $$
        INSERT INTO api.document (tenant_id, entity_type, entity_id, type, version, url, media_id)
        VALUES (current_setting('test.moesa')::UUID, 'product',
                current_setting('test.mop40')::UUID, 'spec_sheet', 9, NULL, current_setting('test.m_spec')::UUID)
    $$,
    'a document can be just a file'
);

SELECT throws_ok(
    $$
        INSERT INTO api.document (tenant_id, entity_type, entity_id, type, version, url, media_id)
        VALUES (current_setting('test.moesa')::UUID, 'product',
                current_setting('test.mop40')::UUID, 'spec_sheet', 10, NULL, NULL)
    $$,
    '23514',
    NULL,
    'a document needs a link or a file (document_has_file)'
);

SELECT throws_ok(
    $$
        INSERT INTO api.document (tenant_id, entity_type, entity_id, type, version, media_id)
        VALUES (current_setting('test.moesa')::UUID, 'supplier', current_setting('test.tr1')::UUID,
                'certificate', 9, current_setting('test.m_atlas')::UUID)
    $$,
    '23503',
    'media_missing',
    'not another tenant''s file'
);

SELECT is(
    (SELECT document_count || ':' || link_count FROM api.media_library WHERE id = current_setting('test.m_spec')::UUID),
    '1:0',
    'the library counts the documents citing a file'
);

RESET ROLE;

SELECT private.impersonate(current_setting('test.akif')::UUID, current_setting('test.moesa')::UUID);

SELECT throws_ok(
    $$ DELETE FROM api.media WHERE id = current_setting('test.m_spec')::UUID $$,
    '23503',
    'media_in_use',
    'a document''s file is not deleted'
);

SELECT * FROM finish();

ROLLBACK;
