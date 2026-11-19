CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- The media library (M19) on companies built in the test: the private bucket and its types,
-- the media_max_mb setting (a branch uses its company's), the file rules of public.media (the
-- file must be uploaded; Storage gives its type and size; no SVG, nothing over the limit, the path
-- in the media's own folder, the file fixed), the bucket's policies (upload into one's own tenant
-- only, a file whose row exists is kept, one whose row is gone is deleted) and the tenant
-- isolation of the rows and the files. What it writes is rolled back.
BEGIN;

SELECT plan(19);

-- Fixture, built here as postgres (the seed is not on the new model yet): a company with an owner
-- and a coordinator (media, no file deletion), and another company with a branch of a branch.
INSERT INTO public.plan (display_name, is_active) VALUES ('Media test plan', TRUE);

INSERT INTO public.tenant (id, display_name, parent_id) VALUES
    ('00000000-0000-4000-8000-000000000321', 'Media Co', NULL),
    ('00000000-0000-4000-8000-000000000322', 'Other Co', NULL);

INSERT INTO public.tenant (id, display_name, parent_id) VALUES
    ('00000000-0000-4000-8000-000000000323', 'Other Branch', '00000000-0000-4000-8000-000000000322');

INSERT INTO public.tenant (id, display_name, parent_id) VALUES
    ('00000000-0000-4000-8000-000000000324', 'Other Sub Branch', '00000000-0000-4000-8000-000000000323');

INSERT INTO public.user (id, email) VALUES
    ('00000000-0000-4000-8000-000000000325', 'owner@media.test'),
    ('00000000-0000-4000-8000-000000000326', 'coordinator@media.test'),
    ('00000000-0000-4000-8000-000000000327', 'other@media.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000000325', '00000000-0000-4000-8000-000000000321'),
    ('00000000-0000-4000-8000-000000000327', '00000000-0000-4000-8000-000000000322');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000000325', '00000000-0000-4000-8000-000000000321'),
    ('00000000-0000-4000-8000-000000000326', '00000000-0000-4000-8000-000000000321'),
    ('00000000-0000-4000-8000-000000000327', '00000000-0000-4000-8000-000000000322');

INSERT INTO public.role (id, display_name, tenant_id)
VALUES ('00000000-0000-4000-8000-000000000328', 'Coordinator', '00000000-0000-4000-8000-000000000321');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000000328', p.id
FROM public.permission p
WHERE p.group_name = 'media' AND NOT (p.resource_name = 'public.media' AND p.command = 'delete');

INSERT INTO public.user_role (user_id, role_id)
VALUES ('00000000-0000-4000-8000-000000000326', '00000000-0000-4000-8000-000000000328');

SELECT set_config('test.moesa', '00000000-0000-4000-8000-000000000321', TRUE);
SELECT set_config('test.atlas', '00000000-0000-4000-8000-000000000322', TRUE);
SELECT set_config('test.atlas_moda', '00000000-0000-4000-8000-000000000324', TRUE);
SELECT set_config('test.koordinator', '00000000-0000-4000-8000-000000000326', TRUE);
SELECT set_config('test.akif', '00000000-0000-4000-8000-000000000325', TRUE);
SELECT set_config('test.ayse', '00000000-0000-4000-8000-000000000327', TRUE);
SELECT set_config('test.m241', '00000000-0000-4000-8000-000000000241', TRUE);
SELECT set_config('test.m242', '00000000-0000-4000-8000-000000000242', TRUE);
SELECT set_config('test.m243', '00000000-0000-4000-8000-000000000243', TRUE);
SELECT set_config('test.m244', '00000000-0000-4000-8000-000000000244', TRUE);
SELECT set_config('test.m245', '00000000-0000-4000-8000-000000000245', TRUE);

SELECT has_table('public', 'media', 'media table');

SELECT hasnt_column('public', 'media', 'customer_id', 'media has no customer');

SELECT is(
    (SELECT allowed_mime_types FROM storage.buckets WHERE id = 'media'),
    ARRAY['image/png', 'image/jpeg', 'image/webp', 'application/pdf', 'video/mp4'],
    'media bucket types, no SVG'
);

SELECT is((SELECT public FROM storage.buckets WHERE id = 'media'), FALSE, 'media bucket is private');

SELECT is(
    (SELECT count(*)::INT FROM public.setting WHERE key = 'media_max_mb' AND value = '25'::JSONB),
    (SELECT count(*)::INT FROM public.tenant WHERE parent_id IS NULL),
    'every company has media_max_mb 25'
);

-- The sub branch is a branch of a branch of the other company.
UPDATE public.setting SET value = '30' WHERE key = 'media_max_mb' AND tenant_id = current_setting('test.atlas')::UUID;

SELECT is(
    private.media_max_bytes(current_setting('test.atlas_moda')::UUID),
    31457280::BIGINT,
    'a branch uses its company''s limit'
);

-- The uploaded files, as Storage records them.
INSERT INTO storage.objects (bucket_id, name, metadata)
VALUES
    ('media', current_setting('test.moesa') || '/' || current_setting('test.m241') || '/a.png',
     '{"mimetype": "image/png", "size": 1000}'::JSONB),
    ('media', current_setting('test.moesa') || '/' || current_setting('test.m242') || '/x.svg',
     '{"mimetype": "image/svg+xml", "size": 1000}'::JSONB),
    ('media', current_setting('test.moesa') || '/' || current_setting('test.m243') || '/big.png',
     '{"mimetype": "image/png", "size": 26214401}'::JSONB);

SELECT private.impersonate(current_setting('test.koordinator')::UUID, current_setting('test.moesa')::UUID);

SELECT throws_ok(
    $$
        INSERT INTO api.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
        VALUES (current_setting('test.m244')::UUID, current_setting('test.moesa')::UUID,
                current_setting('test.moesa') || '/' || current_setting('test.m244') || '/none.png', 'none.png', 'image/png', 1)
    $$,
    '23503',
    'media_file_missing',
    'a row needs its uploaded file'
);

-- The client claims another type and size; Storage's win.
INSERT INTO api.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
VALUES (current_setting('test.m241')::UUID, current_setting('test.moesa')::UUID,
        current_setting('test.moesa') || '/' || current_setting('test.m241') || '/a.png', 'a.png', 'video/mp4', 5);

SELECT is(
    (SELECT mime_type || ':' || size_bytes FROM api.media WHERE id = current_setting('test.m241')::UUID),
    'image/png:1000',
    'type and size come from Storage'
);

SELECT throws_ok(
    $$
        INSERT INTO api.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
        VALUES (current_setting('test.m242')::UUID, current_setting('test.moesa')::UUID,
                current_setting('test.moesa') || '/' || current_setting('test.m242') || '/x.svg', 'x.svg', 'image/png', 1000)
    $$,
    '23514',
    'media_type_not_allowed',
    'SVG is refused'
);

SELECT throws_ok(
    $$
        INSERT INTO api.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
        VALUES (current_setting('test.m243')::UUID, current_setting('test.moesa')::UUID,
                current_setting('test.moesa') || '/' || current_setting('test.m243') || '/big.png', 'big.png', 'image/png', 1000)
    $$,
    '23514',
    'media_too_large',
    'over 25 MB is refused'
);

SELECT throws_ok(
    $$
        INSERT INTO api.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
        VALUES (current_setting('test.m245')::UUID, current_setting('test.moesa')::UUID,
                current_setting('test.moesa') || '/' || current_setting('test.m241') || '/a.png', 'a.png', 'image/png', 1000)
    $$,
    '23514',
    NULL,
    'the path must be in the media''s own folder'
);

SELECT throws_ok(
    $$ UPDATE api.media SET storage_path = storage_path || 'x' WHERE id = current_setting('test.m241')::UUID $$,
    '23514',
    'media_file_immutable',
    'the file is fixed'
);

SELECT lives_ok(
    $$ INSERT INTO storage.objects (bucket_id, name) VALUES ('media', current_setting('test.moesa') || '/' || gen_random_uuid() || '/b.png') $$,
    'a coordinator uploads into the company folder'
);

SELECT throws_ok(
    $$ INSERT INTO storage.objects (bucket_id, name) VALUES ('media', current_setting('test.atlas') || '/' || gen_random_uuid() || '/b.png') $$,
    '42501',
    NULL,
    'not into another tenant''s folder'
);

DELETE FROM storage.objects
WHERE bucket_id = 'media' AND name = current_setting('test.moesa') || '/' || current_setting('test.m241') || '/a.png';

SELECT is(
    (SELECT count(*)::INT FROM storage.objects
     WHERE name = current_setting('test.moesa') || '/' || current_setting('test.m241') || '/a.png'),
    1,
    'a file whose row exists is not deleted'
);

RESET ROLE;

SELECT private.impersonate(current_setting('test.ayse')::UUID, current_setting('test.atlas')::UUID);

SELECT is(
    (SELECT count(*)::INT FROM api.media WHERE id = current_setting('test.m241')::UUID),
    0,
    'another tenant cannot read the media'
);

SELECT is(
    (SELECT count(*)::INT FROM storage.objects
     WHERE bucket_id = 'media' AND name LIKE current_setting('test.moesa') || '/%'),
    0,
    'another tenant cannot read the files either'
);

RESET ROLE;

SELECT private.impersonate(current_setting('test.koordinator')::UUID, current_setting('test.moesa')::UUID);

SELECT ok(
    (SELECT count(*) FROM storage.objects
     WHERE bucket_id = 'media' AND name LIKE current_setting('test.moesa') || '/%') > 0,
    'the company reads its own files'
);

RESET ROLE;

-- Management deletes a file: the row first, then its object, which the policy now lets go.
SELECT private.impersonate(current_setting('test.akif')::UUID, current_setting('test.moesa')::UUID);

DELETE FROM api.media WHERE id = current_setting('test.m241')::UUID;

SELECT results_eq(
    $$
        WITH removed AS (
            DELETE FROM storage.objects
            WHERE bucket_id = 'media'
              AND name = current_setting('test.moesa') || '/' || current_setting('test.m241') || '/a.png'
            RETURNING 1
        )
        SELECT count(*)::INT FROM removed
    $$,
    ARRAY[1],
    'once its row is gone, management deletes the file'
);

SELECT * FROM finish();

ROLLBACK;
