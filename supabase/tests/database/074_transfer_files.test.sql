CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- The transfer file check (Plan 3 Task 13, 074), ported from M21's 045 test (055b03b), on a real run:
-- akif copies a product with a file and its thumbnail from MOESA Europe into MOESA LTD. Nothing
-- copied: partial. Objects planted at the copied paths by a member who may only upload (a PDF where a
-- PNG belongs, a thumbnail over the cap): partial, reported as mismatches, and the target still takes
-- no transfer (I1). Nobody but a copier may upload into a folder whose row exists, so nothing is
-- planted (R2); a wrong copy is removed by the service alone (R3). The right objects: done, and done
-- stays done (L2). A file row always has a size A file row always has a size
-- (N2: size_bytes is NOT NULL, so the copy's size is always the one the object must match). The check cannot be reverted from
-- the log; who may check; what the answer shows a reader of the target alone (L4). Rolled back.
--
-- Signing in (F10): `SELECT private.impersonate_scope(user, active, scope);` then
-- `RESET ROLE; SELECT private.unimpersonate();`. Fixtures by current_setting, rows read as postgres.
BEGIN;

SELECT plan(24);

SELECT private.create_test_helpers();

-- Fixture (ids 00000000-0000-4000-8000-0000000740xx), on the seed: P = MOESA LTD, E = MOESA Europe;
-- akif: management in both (seed). tonly ...07411: one full role in P alone. norights ...07412: a member
-- of P whose role holds everything but the transfer rights. gone ...07413: no tenant at all. planter
-- ...07414: a member of P holding media select and insert only.
-- E: product ze ...07421 with a file ...07422 (and its thumbnail) linked to it. Transfers t2 ...07402 started by norights and t3 ...07403 started by gone.
SELECT set_config('test.' || x.k, x.v::TEXT, TRUE)
FROM (VALUES
    ('p', (SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD')),
    ('e', (SELECT id FROM public.tenant WHERE display_name = 'MOESA Europe')),
    ('akif', (SELECT id FROM public.user WHERE email = 'akif@moesa-panel.test')),
    ('tonly', '00000000-0000-4000-8000-000000074011'),
    ('norights', '00000000-0000-4000-8000-000000074012'),
    ('gone', '00000000-0000-4000-8000-000000074013'),
    ('planter', '00000000-0000-4000-8000-000000074014'),
    ('t2', '00000000-0000-4000-8000-000000074002'),
    ('t3', '00000000-0000-4000-8000-000000074003'),
    ('ze', '00000000-0000-4000-8000-000000074021')
) AS x (k, v);

CREATE FUNCTION pg_temp.member (p_user UUID, p_tenant UUID, p_role UUID, p_keep TEXT DEFAULT 'TRUE') RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO public.tenant_user (user_id, tenant_id) VALUES (p_user, p_tenant) ON CONFLICT DO NOTHING;
    INSERT INTO public.role (id, tenant_id, display_name) VALUES (p_role, p_tenant, 'Transfer 074 ' || p_role);
    EXECUTE format(
        'INSERT INTO public.role_permission (role_id, permission_id) SELECT %L, p.id FROM public.permission p '
        'WHERE p.group_name IN (SELECT m.id FROM public.module m) AND (%s)', p_role, p_keep);
    INSERT INTO public.user_role (user_id, role_id) VALUES (p_user, p_role);
    PERFORM private.grant_all_fields(p_role);
END;
$$;

INSERT INTO public.user (id, email)
SELECT ('00000000-0000-4000-8000-0000000740' || n)::UUID, 'u' || n || '@transfer074.test'
FROM unnest(ARRAY['11', '12', '13', '14']) AS n;

SELECT pg_temp.member(current_setting('test.tonly')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000074111');
SELECT pg_temp.member(current_setting('test.norights')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000074121',
                      $s$p.resource_name <> 'public.transfer'$s$);
SELECT pg_temp.member(current_setting('test.planter')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000074141',
                      $s$p.resource_name = 'public.media' AND p.command IN ('select', 'insert')$s$);

INSERT INTO public.transfer (id, tenant_id, source_tenant_id, product_ids, mode, started_by, report, files, files_status)
VALUES (current_setting('test.t2')::UUID, current_setting('test.p')::UUID, current_setting('test.e')::UUID, '{}', 'copy',
        current_setting('test.norights')::UUID, '{}', '[]', 'done'),
       (current_setting('test.t3')::UUID, current_setting('test.p')::UUID, current_setting('test.e')::UUID, '{}', 'copy',
        current_setting('test.gone')::UUID, '{}', '[]', 'done');

SELECT set_config('moesa.rules_bypass', '1', TRUE);
INSERT INTO storage.objects (bucket_id, name, metadata)
VALUES ('media', current_setting('test.e') || '/00000000-0000-4000-8000-000000074022/ze.png', '{"mimetype": "image/png", "size": 1000}'),
       ('media', current_setting('test.e') || '/00000000-0000-4000-8000-000000074022/thumb/thumb.webp', '{"mimetype": "image/webp", "size": 100}');
INSERT INTO public.product (id, tenant_id, sku, display_name, status)
VALUES (current_setting('test.ze')::UUID, current_setting('test.e')::UUID, 'ZZ-E-74', 'Europe product 074', 'development');
INSERT INTO public.media (id, tenant_id, storage_path, thumbnail_path, file_name)
VALUES ('00000000-0000-4000-8000-000000074022', current_setting('test.e')::UUID,
        current_setting('test.e') || '/00000000-0000-4000-8000-000000074022/ze.png',
        current_setting('test.e') || '/00000000-0000-4000-8000-000000074022/thumb/thumb.webp', 'ze.png');
INSERT INTO public.media_link (tenant_id, media_id, entity_type, entity_id, role)
VALUES (current_setting('test.e')::UUID, '00000000-0000-4000-8000-000000074022', 'product', current_setting('test.ze')::UUID, 'primary_image');
SELECT set_config('moesa.rules_bypass', '', TRUE);

-- The run.
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
SELECT set_config('test.run', public.transfer_products(
    current_setting('test.e')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.ze')::UUID], 'copy',
    jsonb_build_object('report_hash', public.transfer_products(current_setting('test.e')::UUID, current_setting('test.p')::UUID,
                                                               ARRAY[current_setting('test.ze')::UUID], 'copy') ->> 'report_hash'),
    FALSE)::TEXT, TRUE);
SELECT set_config('test.t1', current_setting('test.run')::JSONB ->> 'id', TRUE);
RESET ROLE;
SELECT private.unimpersonate();

-- The copied paths, in list order: the file, its thumbnail.
SELECT set_config('test.paths', (SELECT jsonb_agg(f ->> 'to' ORDER BY n) FROM jsonb_array_elements(current_setting('test.run')::JSONB -> 'files')
                                 WITH ORDINALITY AS x (f, n))::TEXT, TRUE);
SELECT is(
    (SELECT jsonb_agg(regexp_replace(p #>> '{}', '^[^/]+/[^/]+/', '')) FROM jsonb_array_elements(current_setting('test.paths')::JSONB) p),
    '["ze.png", "thumb/thumb.webp"]'::JSONB,
    'the run lists the file and its thumbnail'
);
SELECT col_not_null('public', 'media', 'size_bytes', 'a file row always has a size, which the copied object must match (N2)');

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

CREATE FUNCTION pg_temp.check_as (p_user TEXT, p_scope UUID[]) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    result JSONB;
BEGIN
    PERFORM private.impersonate_scope(current_setting('test.' || p_user)::UUID, current_setting('test.p')::UUID, p_scope);
    result := to_jsonb(public.transfer_check_files(current_setting('test.t1')::UUID));
    RESET ROLE;
    PERFORM private.unimpersonate();
    RETURN result;
END;
$$;

-- 1–3. Nothing copied yet: partial, every path missing; the caller's audit settings come back; the
-- check cannot be reverted.
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT set_config('test.check', pg_temp.check_as('akif', ARRAY[current_setting('test.p')::UUID])::TEXT, TRUE);
SELECT is(
    (SELECT row(c ->> 'files_status', c -> 'missing_files') FROM (SELECT current_setting('test.check')::JSONB AS c) s),
    row('partial'::TEXT, current_setting('test.paths')::JSONB),
    'with no file copied, the transfer is partial and every path missing'
);
SELECT is(current_setting('audit.transaction_id', TRUE), '', 'the caller''s audit settings come back after the check');
SELECT set_config('test.check_tx', (SELECT audit_transaction_ids[cardinality(audit_transaction_ids)]::TEXT FROM public.transfer
                                    WHERE id = current_setting('test.t1')::UUID), TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT throws_like(
    format('SELECT public.revert_audit_transaction(%L)', current_setting('test.check_tx')),
    '%audit_transfer_not_revertable%',
    'the file check cannot be reverted'
);
RESET ROLE;
SELECT private.unimpersonate();

-- 4–7. R2: nobody plants an object at a copied path; an ordinary upload (object first, then its row,
-- as app/src/api/media/upload.ts does) still works, and its folder takes nothing once the row is in.
SELECT private.impersonate_scope(current_setting('test.planter')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT throws_ok(
    $$ INSERT INTO storage.objects (bucket_id, name, metadata)
       VALUES ('media', current_setting('test.paths')::JSONB ->> 0, '{"mimetype": "image/png", "size": 1000}') $$,
    '42501', NULL,
    'a member who may only upload cannot put an object at a copied path, even with the row''s type and size'
);
SELECT lives_ok(
    format($q$ INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('media', %L, '{"mimetype": "image/png", "size": 10}');
               INSERT INTO api.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
               VALUES ('00000000-0000-4000-8000-000000074031', %L, %L, 'own.png', 'image/png', 10) $q$,
           current_setting('test.p') || '/00000000-0000-4000-8000-000000074031/own.png', current_setting('test.p'),
           current_setting('test.p') || '/00000000-0000-4000-8000-000000074031/own.png'),
    'an ordinary upload still works: the object, then its row'
);
SELECT throws_ok(
    format($q$ INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('media', %L, '{"mimetype": "image/webp", "size": 10}') $q$,
           current_setting('test.p') || '/00000000-0000-4000-8000-000000074031/thumb/thumb.webp'),
    '42501', NULL,
    'and once its row is in, its folder takes no other object'
);
RESET ROLE;
SELECT private.unimpersonate();

-- 8–10. I1: a copier allowed to upload puts wrong files: one only its size differs, a thumbnail over the cap.
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.e')::UUID]);
INSERT INTO storage.objects (bucket_id, name, metadata)
VALUES ('media', current_setting('test.paths')::JSONB ->> 0, '{"mimetype": "image/png", "size": 999}'),
       ('media', current_setting('test.paths')::JSONB ->> 1, '{"mimetype": "image/webp", "size": 52000000}');
-- R3: a mismatched copy is not removed with a user's rights (the service role removes it).
SELECT is(
    pg_temp.remove_object(current_setting('test.paths')::JSONB ->> 0),
    0::BIGINT,
    'a mismatched copy cannot be removed by a user'
);
RESET ROLE;
SELECT private.unimpersonate();
SELECT is(
    pg_temp.check_as('akif', ARRAY[current_setting('test.p')::UUID]) -> 'missing_files',
    (SELECT jsonb_agg('mismatch:' || (p #>> '{}')) FROM jsonb_array_elements(current_setting('test.paths')::JSONB) p),
    'a file of the right type but another size, and a thumbnail over the cap, are mismatches, not copies'
);
SELECT is((SELECT files_status FROM public.transfer WHERE id = current_setting('test.t1')::UUID), 'partial', 'the transfer stays partial');
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
SELECT ok(
    public.transfer_options(current_setting('test.e')::UUID) -> 'targets'
        @> jsonb_build_array(jsonb_build_object('id', current_setting('test.p'), 'refusal', 'transfer_files_pending')),
    'and MOESA LTD takes no other transfer meanwhile'
);
RESET ROLE;
SELECT private.unimpersonate();

-- The wrong objects removed by the service, the right ones copied: done.
DELETE FROM storage.objects WHERE bucket_id = 'media' AND name IN (SELECT p #>> '{}' FROM jsonb_array_elements(current_setting('test.paths')::JSONB) p);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.e')::UUID]);
INSERT INTO storage.objects (bucket_id, name, metadata)
VALUES ('media', current_setting('test.paths')::JSONB ->> 0, '{"mimetype": "image/png", "size": 1000}'),
       ('media', current_setting('test.paths')::JSONB ->> 1, '{"mimetype": "image/webp", "size": 100}');
RESET ROLE;
SELECT private.unimpersonate();
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT set_config('test.done', pg_temp.check_as('akif', ARRAY[current_setting('test.p')::UUID, current_setting('test.e')::UUID])::TEXT, TRUE);
SELECT is(
    (SELECT row(c ->> 'files_status', c -> 'missing_files') FROM (SELECT current_setting('test.done')::JSONB AS c) s),
    row('done'::TEXT, '[]'::JSONB),
    'with the right files in, the transfer is done'
);
SELECT ok(current_setting('test.done')::JSONB -> 'report' IS NOT NULL, 'a manager of the source reads the report in the answer');

-- 10. L2: done is final.
DELETE FROM storage.objects WHERE bucket_id = 'media' AND name = current_setting('test.paths')::JSONB ->> 0;
SELECT is(pg_temp.check_as('akif', ARRAY[current_setting('test.p')::UUID]) ->> 'files_status', 'done',
          'a file removed after the transfer was done does not reopen it');

-- 11. L4: a holder of the target's transfer right alone may check, and sees no description of the source.
SELECT is(
    (SELECT row(c ->> 'files_status', c -> 'report', c -> 'files', c -> 'decisions', c -> 'id_map', c -> 'product_ids')
     FROM (SELECT pg_temp.check_as('tonly', ARRAY[current_setting('test.p')::UUID, current_setting('test.e')::UUID]) AS c) s),
    row('done'::TEXT, 'null'::JSONB, 'null'::JSONB, 'null'::JSONB, 'null'::JSONB, 'null'::JSONB),
    'a reader of the target alone gets the state, not the source''s report, files, decisions, map or products'
);

-- 12–15. Who finds a transfer.
SELECT private.impersonate_scope(current_setting('test.norights')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT throws_like(
    $$ SELECT public.transfer_check_files(current_setting('test.t1')::UUID) $$,
    '%transfer_not_found%',
    'a user who may not transfer does not find someone else''s transfer'
);
SELECT is((public.transfer_check_files(current_setting('test.t2')::UUID)).files_status, 'done', 'the starter still in the target checks their own');
RESET ROLE;
SELECT private.unimpersonate();
SELECT private.impersonate_scope(current_setting('test.gone')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT throws_like(
    $$ SELECT public.transfer_check_files(current_setting('test.t3')::UUID) $$,
    '%transfer_not_found%',
    'a starter no longer in the target does not'
);
SELECT throws_like(
    $$ SELECT public.transfer_check_files(gen_random_uuid()) $$,
    '%transfer_not_found%',
    'nor does anyone find a transfer that does not exist'
);
RESET ROLE;
SELECT private.unimpersonate();

-- 16. Done, MOESA LTD takes transfers again.
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
SELECT ok(
    public.transfer_options(current_setting('test.e')::UUID) -> 'targets'
        @> jsonb_build_array(jsonb_build_object('id', current_setting('test.p'), 'refusal', NULL)),
    'once done, MOESA LTD takes transfers again'
);
RESET ROLE;
SELECT private.unimpersonate();

-- 17–18. The function.
SELECT is(
    ARRAY(SELECT p.proname::TEXT FROM pg_proc p
          WHERE p.proname = 'transfer_check_files' AND p.pronamespace = 'public'::REGNAMESPACE
            AND p.prosecdef AND p.proconfig @> ARRAY['search_path=""']
            AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
            AND p.prorettype = 'api.transfer'::REGTYPE),
    ARRAY['transfer_check_files'],
    'the check is a definer with an empty search_path, for signed-in users only, answering an api.transfer row'
);
SELECT throws_like(
    $$ SELECT public.transfer_check_files(current_setting('test.t1')::UUID) $$,
    '%transfer_not_found%',
    'without a signed-in user there is nothing to find'
);

-- 19. PostgREST runs with pg-safeupdate, which refuses a DELETE or UPDATE with no WHERE; pgTAP does not
-- load it, so the check is on the source: no exposed transfer function holds a DELETE with no WHERE
-- (private helpers are covered by the HTTP suite) (found over HTTP: the temp table's DELETE was refused as 21000).
SELECT is(
    ARRAY(SELECT p.proname::TEXT FROM pg_proc p
          WHERE p.pronamespace = 'public'::REGNAMESPACE AND p.proname LIKE 'transfer\_%'
            AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
            AND p.prosrc ~* 'DELETE\s+FROM\s+[a-z_."]+\s*;'),
    ARRAY[]::TEXT[],
    'no exposed transfer function runs a DELETE with no WHERE (pg-safeupdate)'
);

SELECT * FROM finish();

ROLLBACK;
