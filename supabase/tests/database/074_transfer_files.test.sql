CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- The transfer file check (Plan 3 Task 13, 074), ported from M21's 045 test (055b03b): a file missing
-- from Storage leaves the transfer partial, and that check cannot be reverted from the log; once every
-- file is in, the transfer is done and the target takes transfers again; who may check (the target's
-- transfer right, or the starter while still in the target), and what the answer shows a reader of the
-- target alone (L4); a real run's files end to end. What it writes is rolled back.
--
-- Signing in (F10): `SELECT private.impersonate_scope(user, active, scope);` then
-- `RESET ROLE; SELECT private.unimpersonate();`. Fixtures by current_setting, rows read as postgres.
BEGIN;

SELECT plan(17);

SELECT private.create_test_helpers();

-- Fixture (ids 00000000-0000-4000-8000-0000000740xx), on the seed: P = MOESA LTD, E = MOESA Europe;
-- akif: management in both (seed). tonly ...07411: one full role in P alone. norights ...07412: a member
-- of P whose role holds everything but the transfer rights. gone ...07413: no tenant at all.
-- Transfer t1 ...07401 E → P by akif with two files; t2 ...07402 started by norights; t3 ...07403
-- started by gone.
SELECT set_config('test.' || x.k, x.v::TEXT, TRUE)
FROM (VALUES
    ('p', (SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD')),
    ('e', (SELECT id FROM public.tenant WHERE display_name = 'MOESA Europe')),
    ('akif', (SELECT id FROM public.user WHERE email = 'akif@moesa-panel.test')),
    ('tonly', '00000000-0000-4000-8000-000000074011'),
    ('norights', '00000000-0000-4000-8000-000000074012'),
    ('gone', '00000000-0000-4000-8000-000000074013'),
    ('t1', '00000000-0000-4000-8000-000000074001'),
    ('t2', '00000000-0000-4000-8000-000000074002'),
    ('t3', '00000000-0000-4000-8000-000000074003'),
    ('ze', '00000000-0000-4000-8000-000000074021')
) AS x (k, v);

SELECT set_config('test.first', current_setting('test.p') || '/00000000-0000-4000-8000-000000074031/x.png', TRUE);
SELECT set_config('test.second', current_setting('test.p') || '/00000000-0000-4000-8000-000000074032/y.png', TRUE);

CREATE FUNCTION pg_temp.member (p_user UUID, p_tenant UUID, p_role UUID, p_skip TEXT DEFAULT 'FALSE') RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO public.tenant_user (user_id, tenant_id) VALUES (p_user, p_tenant) ON CONFLICT DO NOTHING;
    INSERT INTO public.role (id, tenant_id, display_name) VALUES (p_role, p_tenant, 'Transfer 074 ' || p_role);
    EXECUTE format(
        'INSERT INTO public.role_permission (role_id, permission_id) SELECT %L, p.id FROM public.permission p '
        'WHERE p.group_name IN (SELECT m.id FROM public.module m) AND NOT (%s)', p_role, p_skip);
    INSERT INTO public.user_role (user_id, role_id) VALUES (p_user, p_role);
    PERFORM private.grant_all_fields(p_role);
END;
$$;

INSERT INTO public.user (id, email)
SELECT ('00000000-0000-4000-8000-0000000740' || n)::UUID, 'u' || n || '@transfer074.test'
FROM unnest(ARRAY['11', '12', '13']) AS n;

SELECT pg_temp.member(current_setting('test.tonly')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000074111');
SELECT pg_temp.member(current_setting('test.norights')::UUID, current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000074121',
                      $s$p.resource_name = 'public.transfer'$s$);

INSERT INTO public.transfer (id, tenant_id, source_tenant_id, product_ids, mode, started_by, report, files, files_status)
VALUES (current_setting('test.t1')::UUID, current_setting('test.p')::UUID, current_setting('test.e')::UUID, '{}', 'copy',
        current_setting('test.akif')::UUID, '{"counts": {}}',
        jsonb_build_array(jsonb_build_object('from', 'a', 'to', current_setting('test.first'), 'keep_source', TRUE),
                          jsonb_build_object('from', 'b', 'to', current_setting('test.second'), 'keep_source', TRUE)),
        'pending'),
       (current_setting('test.t2')::UUID, current_setting('test.p')::UUID, current_setting('test.e')::UUID, '{}', 'copy',
        current_setting('test.norights')::UUID, '{}', '[]', 'done'),
       (current_setting('test.t3')::UUID, current_setting('test.p')::UUID, current_setting('test.e')::UUID, '{}', 'copy',
        current_setting('test.gone')::UUID, '{}', '[]', 'done');

INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('media', current_setting('test.first'), '{"mimetype": "image/png", "size": 1000}');

-- 1–3. The first file in, the second missing: partial, and the check is a transfer's.
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.e')::UUID]);
SELECT set_config('test.check', to_jsonb(public.transfer_check_files(current_setting('test.t1')::UUID))::TEXT, TRUE);
SELECT is(
    (SELECT row(c ->> 'files_status', c -> 'missing_files') FROM (SELECT current_setting('test.check')::JSONB AS c) s),
    row('partial'::TEXT, jsonb_build_array(current_setting('test.second'))),
    'a missing file leaves the transfer partial'
);
SELECT is(current_setting('audit.transaction_id', TRUE), '', 'the caller''s audit settings come back after the check');
RESET ROLE;
SELECT private.unimpersonate();

SELECT set_config('test.check_tx', (SELECT audit_transaction_ids[cardinality(audit_transaction_ids)]::TEXT FROM public.transfer
                                    WHERE id = current_setting('test.t1')::UUID), TRUE);
SELECT is((SELECT tenant_id::TEXT FROM public.audit_transaction WHERE id = current_setting('test.check_tx')::UUID), current_setting('test.p'),
          'the check is an audit transaction of the target, listed with the transfer');
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT throws_like(
    format('SELECT public.revert_audit_transaction(%L)', current_setting('test.check_tx')),
    '%audit_transfer_not_revertable%',
    'the file check cannot be reverted'
);
RESET ROLE;
SELECT private.unimpersonate();

-- 4–5. The second file in: done, and the answer shows a manager of the source everything.
INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('media', current_setting('test.second'), '{"mimetype": "image/png", "size": 1000}');
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.p')::UUID,
                                 ARRAY[current_setting('test.p')::UUID, current_setting('test.e')::UUID]);
SELECT set_config('test.done', to_jsonb(public.transfer_check_files(current_setting('test.t1')::UUID))::TEXT, TRUE);
RESET ROLE;
SELECT private.unimpersonate();
SELECT is(
    (SELECT row(c ->> 'files_status', c -> 'missing_files') FROM (SELECT current_setting('test.done')::JSONB AS c) s),
    row('done'::TEXT, '[]'::JSONB),
    'with every file in, the transfer is done'
);
SELECT is(current_setting('test.done')::JSONB -> 'report', '{"counts": {}}'::JSONB, 'a manager of the source reads the report in the answer');

-- 6. L4: a holder of the target's transfer right alone may check, and sees no description of the source.
SELECT private.impersonate_scope(current_setting('test.tonly')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT is(
    (SELECT row(t.files_status, t.report, t.files, t.decisions, t.id_map, t.product_ids)
     FROM public.transfer_check_files(current_setting('test.t1')::UUID) t),
    row('done'::TEXT, NULL::JSONB, NULL::JSONB, NULL::JSONB, NULL::JSONB, NULL::UUID[]),
    'a reader of the target alone gets the state, not the source''s report, files, decisions, map or products'
);
RESET ROLE;
SELECT private.unimpersonate();

-- 7–10. Who finds a transfer.
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

-- 11–14. A real run's files, end to end: the target waits for them, the app copies them, the check
-- lets the target take transfers again.
SELECT set_config('moesa.rules_bypass', '1', TRUE);
INSERT INTO storage.objects (bucket_id, name, metadata)
VALUES ('media', current_setting('test.e') || '/00000000-0000-4000-8000-000000074022/ze.png', '{"mimetype": "image/png", "size": 1000}');
INSERT INTO public.product (id, tenant_id, sku, display_name, status)
VALUES (current_setting('test.ze')::UUID, current_setting('test.e')::UUID, 'ZZ-E-74', 'Europe product 074', 'development');
INSERT INTO public.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes)
VALUES ('00000000-0000-4000-8000-000000074022', current_setting('test.e')::UUID,
        current_setting('test.e') || '/00000000-0000-4000-8000-000000074022/ze.png', 'ze.png', 'image/png', 1000);
INSERT INTO public.media_link (tenant_id, media_id, entity_type, entity_id, role)
VALUES (current_setting('test.e')::UUID, '00000000-0000-4000-8000-000000074022', 'product', current_setting('test.ze')::UUID, 'gallery');
SELECT set_config('moesa.rules_bypass', '', TRUE);

SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
SELECT set_config('test.run', public.transfer_products(current_setting('test.e')::UUID, current_setting('test.p')::UUID,
                                                       ARRAY[current_setting('test.ze')::UUID], 'copy', NULL, FALSE)::TEXT, TRUE);
SELECT ok(
    public.transfer_options(current_setting('test.e')::UUID) -> 'targets'
        @> jsonb_build_array(jsonb_build_object('id', current_setting('test.p'), 'refusal', 'transfer_files_pending')),
    'while the run''s file is not copied, MOESA LTD takes no other transfer'
);
RESET ROLE;
SELECT private.unimpersonate();

-- The app copies the file to where the run said.
INSERT INTO storage.objects (bucket_id, name, metadata)
SELECT 'media', f ->> 'to', '{"mimetype": "image/png", "size": 1000}'
FROM jsonb_array_elements(current_setting('test.run')::JSONB -> 'files') f;
SELECT is(
    (SELECT count(*) FROM jsonb_array_elements(current_setting('test.run')::JSONB -> 'files') f
     JOIN public.media m ON m.storage_path = f ->> 'to' AND m.tenant_id = current_setting('test.p')::UUID),
    1::BIGINT,
    'the run lists the file under the path its media row has in the target'
);

SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope(current_setting('test.akif')::UUID, current_setting('test.e')::UUID,
                                 ARRAY[current_setting('test.e')::UUID, current_setting('test.p')::UUID]);
SELECT is((public.transfer_check_files((current_setting('test.run')::JSONB ->> 'id')::UUID)).files_status, 'done',
          'once the app copied it, the check finds the run done');
SELECT ok(
    public.transfer_options(current_setting('test.e')::UUID) -> 'targets'
        @> jsonb_build_array(jsonb_build_object('id', current_setting('test.p'), 'refusal', NULL)),
    'and MOESA LTD takes transfers again'
);
RESET ROLE;
SELECT private.unimpersonate();

-- 15–16. The function.
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

SELECT * FROM finish();

ROLLBACK;
