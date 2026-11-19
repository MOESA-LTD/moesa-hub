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
-- private.transfer_may_check   Who may check a transfer (above): the target's transfer insert right, or
--                              the starter still in the target.
--
-- Storage (024's media policies; review of Task 13, R1 and R2). A transfer's files are the only
-- copies in flight, and the check above can only tell a file by its type and size, so:
-- private.transfer_file_locked  An object a transfer still needs cannot be removed: a target copy
--                              (files[].to) or a source object the service is to remove (files[].from
--                              with keep_source FALSE) of a transfer whose files are not done; once it
--                              is done, such a source object only by a caller who may check that
--                              transfer (and the service role, past the policies).
-- private.transfer_upload_allowed  A copy may be uploaded into a folder whose media row the run already
--                              wrote: a files[].to path of a transfer whose files are not done, by a
--                              caller holding public.transfer insert in both its tenants (the gate's
--                              rule 5, no super-admin pass).
-- private.can_write_media_file  Restated: 024's body plus one delta (pinned in 052): a folder whose media
--                              row exists takes no upload (an upload always comes before its row,
--                              media_check_file reads it), but for transfer_upload_allowed. Nobody can
--                              plant an object at a copied path first.
-- private.can_delete_media_file  Restated: 024's body plus one delta (pinned in 052): not an object
--                              transfer_file_locked holds.

-- Who may check a transfer (see the header).
CREATE OR REPLACE FUNCTION private.transfer_may_check (p_user UUID, p_target UUID, p_started_by UUID) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT p_user IS NOT NULL AND (
        p_target = ANY (private.tenants_granting(p_user, ARRAY[p_target], 'public.transfer', 'insert'))
        OR (p_started_by = p_user
            AND (EXISTS (SELECT 1 FROM public.tenant_user tu WHERE tu.user_id = p_user AND tu.tenant_id = p_target)
                 OR p_target = ANY (private.owned_tenants(p_user))))
    );
$$;

REVOKE ALL ON FUNCTION private.transfer_may_check (UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;

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

    IF NOT FOUND OR NOT private.transfer_may_check(caller, run.tenant_id, run.started_by) THEN
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

-- An object a transfer still needs (see the header). SECURITY DEFINER: every transfer row; called by
-- the Storage policies' definers (can_delete_media_file), with the user's claims.
CREATE OR REPLACE FUNCTION private.transfer_file_locked (object_name TEXT) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.transfer t
        CROSS JOIN LATERAL jsonb_array_elements(t.files) f
        WHERE (t.tenant_id = private.storage_tenant(object_name) OR t.source_tenant_id = private.storage_tenant(object_name))
          AND (
              (t.files_status <> 'done'
               AND (f ->> 'to' = object_name OR (f ->> 'from' = object_name AND f -> 'keep_source' = 'false'::JSONB)))
              OR (t.files_status = 'done'
                  AND f ->> 'from' = object_name AND f -> 'keep_source' = 'false'::JSONB
                  AND NOT private.transfer_may_check(auth.uid(), t.tenant_id, t.started_by))
          )
    );
$$;

REVOKE ALL ON FUNCTION private.transfer_file_locked (TEXT) FROM PUBLIC, anon, authenticated;

-- A copy into a folder the run already wrote (see the header).
CREATE OR REPLACE FUNCTION private.transfer_upload_allowed (object_name TEXT) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT auth.uid() IS NOT NULL AND EXISTS (
        SELECT 1
        FROM public.transfer t
        CROSS JOIN LATERAL jsonb_array_elements(t.files) f
        WHERE t.tenant_id = private.storage_tenant(object_name)
          AND t.files_status <> 'done'
          AND f ->> 'to' = object_name
          AND ARRAY[t.tenant_id, t.source_tenant_id]
              <@ private.tenants_granting(auth.uid(), ARRAY[t.tenant_id, t.source_tenant_id], 'public.transfer', 'insert')
    );
$$;

REVOKE ALL ON FUNCTION private.transfer_upload_allowed (TEXT) FROM PUBLIC, anon, authenticated;

-- 024's can_write_media_file (pinned in 052); 074: not into a folder whose row exists, but a transfer's copy.
CREATE OR REPLACE FUNCTION private.can_write_media_file (object_name TEXT) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER STABLE
SET
   search_path = '' AS $$
DECLARE
    tenant UUID := private.storage_tenant(object_name);
BEGIN
    RETURN tenant IS NOT NULL
       AND private.storage_folder_id(object_name) IS NOT NULL
       AND tenant = ANY (private.tenants_permitting(auth.uid(), ARRAY[tenant], 'public.media', 'insert'))
       -- 074
       AND (NOT EXISTS (SELECT 1 FROM public.media m WHERE m.id = private.storage_folder_id(object_name))
            OR private.transfer_upload_allowed(object_name));
END;
$$;

-- 024's can_delete_media_file (pinned in 052); 074: not an object a transfer still needs.
CREATE OR REPLACE FUNCTION private.can_delete_media_file (object_name TEXT) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER STABLE
SET
   search_path = '' AS $$
BEGIN
    RETURN private.can_write_media_file(object_name)
       AND NOT EXISTS (
           SELECT 1 FROM public.media m
           WHERE m.id = private.storage_folder_id(object_name)
             AND m.tenant_id = private.storage_tenant(object_name)
       )
       -- 074
       AND NOT private.transfer_file_locked(object_name);
END;
$$;
