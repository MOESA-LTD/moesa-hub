-- Tenant-to-tenant product transfer (Plan 3, decision 11), the file check. Ported from M21 (055b03b:
-- 045's transfer_check_files; transfer_options is 072's).
--
-- The run (073) writes each copied media row with its path in the target's folder and lists the files
-- to copy in transfer.files ({media_id, from, to, keep_source}); the Storage objects are copied by the
-- app (or a service) with the caller's own Storage rights (read in the source's folder, media insert in
-- the target's), never by the database. A file whose source row a move removed has keep_source FALSE:
-- the service removes the source object once the copy is in. Until every file is in, the transfer is
-- pending, and no other transfer goes into its target (072, rule 8) or takes one of its files on
-- (transfer_files_pending).
--
-- public.transfer_check_files  The files of a transfer against Storage. The run wrote each copied
--                              media row without reading Storage (073), so the check is what ties the
--                              object to the row: a listed path counts as copied only when its object
--                              is in the target's folder and
--                              - for the file: the object's mimetype is the row's, its size the row's
--                                (size_bytes is NOT NULL, N2), the type one of the five and the size
--                                within the target company's cap;
--                              - for the thumbnail: a webp within the cap;
--                              a path whose media row the target has removed since needs nothing.
--                              missing_files lists the paths with no object, and 'mismatch:<path>' for
--                              an object that does not fit (anyone with media insert in the target may
--                              have put it there first; objects are never replaced, so it must be
--                              removed and copied again). files_status 'done' when every file counts,
--                              else 'partial'. A 'done' transfer is never checked again (L2): a file
--                              removed later is the target's own business. 404 transfer_not_found when
--                              the row is missing or the caller neither holds public.transfer insert in
--                              its target (private.tenants_granting: roles and the owner role, no
--                              super-admin pass) nor started it and still belongs to the target.
--                              Returns the row as api.transfer shows it to the caller
--                              (private.transfer_row_for, 073: the source's description masked unless
--                              the caller reads it in the source, L4). SECURITY DEFINER: users never
--                              write public.transfer, and storage.objects is read past its policies.
--                              The writes run under an audit transaction of its own (audit.transaction_id
--                              cleared first), whose id is appended to audit_transaction_ids in the same
--                              transaction: the revert guard (072) refuses it. The caller's audit
--                              settings come back afterwards.

CREATE OR REPLACE FUNCTION public.transfer_check_files (transfer_id UUID) RETURNS api.transfer LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    caller UUID := auth.uid();
    run public.transfer;
    cap BIGINT;
    missing TEXT[];
    saved_transaction TEXT := current_setting('audit.transaction_id', TRUE);
    saved_tenant TEXT := current_setting('audit.tenant_id', TRUE);
    saved_depth TEXT := current_setting('audit.depth', TRUE);
    check_transaction UUID;
BEGIN
    SELECT * INTO run FROM public.transfer t WHERE t.id = transfer_check_files.transfer_id FOR UPDATE;

    IF NOT FOUND
       OR caller IS NULL
       OR NOT (
           run.tenant_id = ANY (private.tenants_granting(caller, ARRAY[run.tenant_id], 'public.transfer', 'insert'))
           OR (run.started_by = caller
               AND (EXISTS (SELECT 1 FROM public.tenant_user tu WHERE tu.user_id = caller AND tu.tenant_id = run.tenant_id)
                    OR run.tenant_id = ANY (private.owned_tenants(caller))))
       ) THEN
        PERFORM private.transfer_raise('transfer_not_found', 404);
    END IF;

    -- L2: done is final.
    IF run.files_status = 'done' THEN
        RETURN private.transfer_row_for(caller, run.id);
    END IF;

    cap := private.media_max_bytes(run.tenant_id);

    -- Each listed file against its row and its object (see the header).
    CREATE TEMP TABLE IF NOT EXISTS transfer_file_check (n BIGINT, path TEXT, state TEXT) ON COMMIT DROP;
    DELETE FROM pg_temp.transfer_file_check;

    INSERT INTO pg_temp.transfer_file_check (n, path, state)
    SELECT f.n, f.value ->> 'to',
           CASE
               WHEN m.id IS NULL THEN 'ok'
               WHEN o.name IS NULL THEN 'missing'
               WHEN f.value ->> 'to' = m.storage_path THEN
                   CASE WHEN o.metadata ->> 'mimetype' = m.mime_type
                             AND o.metadata ->> 'mimetype' IN ('image/png', 'image/jpeg', 'image/webp', 'application/pdf', 'video/mp4')
                             AND o.size IS NOT NULL AND o.size <= cap
                             AND o.size = m.size_bytes
                        THEN 'ok' ELSE 'mismatch' END
               WHEN f.value ->> 'to' = m.thumbnail_path THEN
                   CASE WHEN o.metadata ->> 'mimetype' = 'image/webp' AND o.size IS NOT NULL AND o.size <= cap
                        THEN 'ok' ELSE 'mismatch' END
               ELSE 'mismatch'
           END
    FROM jsonb_array_elements(run.files) WITH ORDINALITY AS f (value, n)
    LEFT JOIN public.media m ON m.id = private.transfer_uuid(f.value ->> 'media_id') AND m.tenant_id = run.tenant_id
    LEFT JOIN LATERAL (
        SELECT x.name, x.metadata, CASE WHEN x.metadata ->> 'size' ~ '^[0-9]{1,18}$' THEN (x.metadata ->> 'size')::BIGINT END AS size
        FROM storage.objects x
        WHERE x.bucket_id = 'media' AND x.name = f.value ->> 'to' AND private.storage_tenant(x.name) = run.tenant_id
    ) o ON TRUE
    WHERE f.value ->> 'to' IS NOT NULL;

    missing := ARRAY(
        SELECT CASE c.state WHEN 'mismatch' THEN 'mismatch:' || c.path ELSE c.path END
        FROM pg_temp.transfer_file_check c WHERE c.state <> 'ok' ORDER BY c.n
    );

    -- The check's own audit transaction.
    PERFORM set_config('audit.transaction_id', '', TRUE);

    UPDATE public.transfer t
    SET missing_files = missing,
        files_status = CASE WHEN cardinality(missing) = 0 THEN 'done' ELSE 'partial' END
    WHERE t.id = run.id;

    check_transaction := nullif(current_setting('audit.transaction_id', TRUE), '')::UUID;

    IF check_transaction IS NOT NULL THEN
        UPDATE public.transfer t
        SET audit_transaction_ids = t.audit_transaction_ids || check_transaction
        WHERE t.id = run.id AND NOT (check_transaction = ANY (t.audit_transaction_ids));
    END IF;

    -- The caller's audit transaction back (none: a later write opens its own).
    PERFORM set_config('audit.transaction_id', coalesce(saved_transaction, ''), TRUE);
    PERFORM set_config('audit.tenant_id', coalesce(saved_tenant, ''), TRUE);
    PERFORM set_config('audit.depth', coalesce(saved_depth, ''), TRUE);

    RETURN private.transfer_row_for(caller, run.id);
END;
$$;

REVOKE ALL ON FUNCTION public.transfer_check_files (UUID) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.transfer_check_files (UUID) TO authenticated;
