-- Tenant-to-tenant product transfer (Plan 3, decisions 11 and 14), the run: a real run of
-- public.transfer_products (072, restated here with its apply branch, F19) writes the transfer row,
-- raises the transfer flag for the apply alone and copies the package into the target with new ids;
-- a move first removes the package from the source. Ported from M21 (055b03b: 043, and the
-- transfer-owned parts of 041) for the product registry of 072; no guard body of 055b03b is restated
-- (F4): the live guards hold for every row written, and the flag (private.rules_bypassed, 072) only
-- lets the business rules (status order, frozen rows, server-only columns) keep the copied values.
--
-- private.media_check_file   Restated: 024's body plus one delta (pinned in 052). A media row a transfer
--                            inserts names a file the app copies after the run (transfer_check_files,
--                            074 follows it), so Storage is not read for it: it keeps the mime_type and
--                            size_bytes of the source row, and the type allowlist and the target
--                            company's size cap still hold, as does the CHECK media_path_in_folder.
--                            Outside a transfer, and for every UPDATE, nothing changes.
-- private.transfer_media_paths  The Storage paths of a media row in the target, in the folder
--                            media_path_in_folder asks for: <target>/<media id>/<file name>, and
--                            <target>/<media id>/thumb/thumb.webp for a thumbnail.
-- private.transfer_lock_rows The package rows FOR UPDATE (a real run locks, collects again and locks
--                            again, so a concurrent edit waits for the run instead of being lost).
-- private.transfer_build_map Fills pg_temp.transfer_map (dropped at commit) with the target id of every
--                            package row the run writes: a new id, or for a supplier the decision maps,
--                            the target's supplier (mapped: TRUE, not written). The rows the decisions
--                            leave out (072: transfer_omitted, a skip and what goes with it, a mapped
--                            supplier's contacts and documents) have no entry, nor have the files only
--                            such rows use (transfer_unused_media).
-- private.transfer_write     Writes the package rows of one table into the target, each taken from the
--                            snapshot (pg_temp.transfer_rows.row) and rewritten: id from the map,
--                            tenant_id the target, and so every other tenant column that named the
--                            source (sourcing.product_tenant_id); a row that is not the source's own, or
--                            carries a client_tenant_id, stops the run (F5: a copied row never has a
--                            client link). A reference to a registry row goes through the map (to an
--                            omitted row: the row is dropped when the reference is NOT NULL, else
--                            cleared); a reference to a tenant's row outside the package (a market
--                            cell's project) is cleared, as the report's `cleared` says; entity_id
--                            through the registry table of entity_type. reset_columns NULL. The users
--                            rule: a user column whose user is neither a member nor an owner of the
--                            target becomes the caller (actor) or NULL (clear). The decisions: a SKU
--                            renamed with its suffix, a GTIN cleared, a supplier's typed new code.
--                            Media get their target paths, and each file (and thumbnail) is returned as
--                            {media_id, from, to, keep_source}. Variants after their parents. The rows
--                            are written as the owner of these functions with the caller's claims, so
--                            every trigger runs: the link guards (client_link_guard's product lookup in
--                            the target, the entity, media and tenant checks, media_link_check's update
--                            right on the entity, sourcing_client_side_guard) hold; the flag lets the
--                            business rules keep the copied values.
-- private.transfer_delete_source  A move removes the source package (every package row that is not
--                            copy_only: the suppliers, their contacts and documents and the files stay,
--                            the links of a file to a moved row go) BEFORE anything is written, so the
--                            moved GTINs are free under the global active-GTIN index; the rows are then
--                            written from the snapshot. Children first (descending registry position),
--                            variants before their parents. A client's row in another tenant that
--                            names a moved product (a provider's order line or sourcing, ON DELETE SET
--                            NULL) keeps its snapshot. The deletions are an audit transaction of the
--                            source tenant: the target's audit settings are saved and cleared, the first
--                            delete opens the source's, then they are restored and the source's id is
--                            appended to the transfer's audit_transaction_ids (revert lock, 072).
-- private.transfer_apply_copy  Every registry table in position order (transfer_write), then the
--                            transfer row's id_map ({table: {source_id: target_id}}), files and
--                            files_status (pending while there are files to copy).
-- private.transfer_apply     The run: the map, in a move the source deletion first, then the copy.
-- private.transfer_row_for   A transfer row as api.transfer shows it to a user: each sensitive field
--                            masked unless the user reads it in its rights tenant (the source, L4).
-- public.transfer_products   072's entry point, restated with the run (F19). A real run locks and
--                            collects again, builds the report afresh (a rehearsal's output is never
--                            trusted), checks the decisions against it (072: unknown keys, wrong
--                            actions, taken or invalid codes are refused) and a move's blocking links,
--                            asks the gate (private.transfer_refusal) again right before writing, then:
--                            the caller's audit settings saved and cleared, the transfer row inserted
--                            (its sensitive fields at their defaults: no field right is needed for an
--                            empty row), the flag raised (set_config local) for that row, the report,
--                            decisions and product ids stored and the audit transaction recorded, the
--                            apply, and the flag cleared at once (L5): after the call, in the same
--                            transaction, the rules are not bypassed. The caller's audit settings come
--                            back, so a later write of the transaction is not the transfer's. Returns
--                            the transfer row (transfer_row_for).
--
-- L4: the stored product_ids, report, decisions, id_map and files describe the source. They are
-- classified sensitive (group internal_note) with the rights column source_tenant_id, so api.transfer
-- and the audit snapshots show them only to a reader of internal notes in the source; a reader of the
-- target alone sees the record without them. Roles get them as 071's backfill does (R1).
--
-- Also (review of Task 13):
--   C1  rule 5 for the package: a media link is copied only by a caller holding update on its entity
--       in the target (media_link_check asks it): transfer_permissions_required, in a rehearsal too.
--   L1  a real run carries the rehearsal's report_hash in its decisions (decisions.report_hash, not a
--       decision: it is taken out before anything reads them); a fresh report with another hash, or
--       none given, is refused with transfer_report_stale (409): the caller rehearses again.
--   R5  a move whose package files would be left unused in the source (and so removed, I2) needs
--       public.media delete in the source: transfer_permissions_required otherwise.
--   L3  in a move, transfer_write raises transfer_package_invalid rather than drop a row the move
--       already removed from the source.
--   I1  (final review) a copied file keeps the read restriction its source rows gave it: the groups
--       private.media_restriction gives the source file (taken by transfer_build_map, before a move
--       removes anything) that the rows copied with it do not give the new file are held for the new
--       file (private.media_restriction_hold, which the restated media_restriction reads), so a file
--       that was also a purchase order's, or a supplier's, stays as restricted in the target.
--   I2  a move removes the source's file rows that only the moved rows used (transfer_delete_source),
--       lists their objects with keep_source FALSE so the service removes them after the copy, and
--       holds the read restriction they had (private.media_restriction_hold, read by the restated
--       private.media_restriction, 060's body plus that delta, pinned in 052): a pi, po or commercial
--       invoice file left in Storage stays as restricted as it was. A file still used in the source
--       stays, with its rows.

-- 024's media_check_file (pinned in 052); 073: a transfer's copy (see the header).
CREATE OR REPLACE FUNCTION private.media_check_file () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    meta JSONB;
    -- 073: a row a transfer copies; its file follows after the run.
    copying CONSTANT BOOLEAN := TG_OP = 'INSERT' AND private.transferring();
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.storage_path IS DISTINCT FROM OLD.storage_path
           OR NEW.mime_type IS DISTINCT FROM OLD.mime_type
           OR NEW.size_bytes IS DISTINCT FROM OLD.size_bytes
           OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
           OR (OLD.thumbnail_path IS NOT NULL AND NEW.thumbnail_path IS DISTINCT FROM OLD.thumbnail_path) THEN
            RAISE EXCEPTION 'media_file_immutable' USING ERRCODE = 'check_violation';
        END IF;
    ELSIF copying THEN
        -- 073: the source row's type and size (NOT NULL); the allowlist and the target's cap hold.
        -- 074 verifies the copied object against them.
        IF NEW.mime_type IS NULL
           OR NEW.mime_type NOT IN ('image/png', 'image/jpeg', 'image/webp', 'application/pdf', 'video/mp4') THEN
            RAISE EXCEPTION 'media_type_not_allowed' USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.size_bytes > private.media_max_bytes(NEW.tenant_id) THEN
            RAISE EXCEPTION 'media_too_large' USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        SELECT o.metadata INTO meta
        FROM storage.objects o
        WHERE o.bucket_id = 'media'
          AND o.name = NEW.storage_path
          AND private.storage_tenant(o.name) = NEW.tenant_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'media_file_missing' USING ERRCODE = 'foreign_key_violation';
        END IF;

        NEW.mime_type := meta ->> 'mimetype';
        NEW.size_bytes := (meta ->> 'size')::BIGINT;

        IF NEW.mime_type IS NULL
           OR NEW.mime_type NOT IN ('image/png', 'image/jpeg', 'image/webp', 'application/pdf', 'video/mp4') THEN
            RAISE EXCEPTION 'media_type_not_allowed' USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.size_bytes > private.media_max_bytes(NEW.tenant_id) THEN
            RAISE EXCEPTION 'media_too_large' USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    IF NOT copying
       AND NEW.thumbnail_path IS NOT NULL
       AND NEW.thumbnail_path IS DISTINCT FROM (CASE WHEN TG_OP = 'UPDATE' THEN OLD.thumbnail_path END)
       AND NOT EXISTS (
           SELECT 1 FROM storage.objects o
           WHERE o.bucket_id = 'media'
             AND o.name = NEW.thumbnail_path
             AND private.storage_tenant(o.name) = NEW.tenant_id
       ) THEN
        RAISE EXCEPTION 'media_file_missing' USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- I2: the read restriction of a source file a move unlinked and removed (its Storage object goes
-- after the run, by the service, from the files list: keep_source FALSE). Until then, and after,
-- the object keeps the groups its links and documents gave it.
CREATE TABLE IF NOT EXISTS private.media_restriction_hold (
   media_id UUID PRIMARY KEY,
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   groups TEXT[] NOT NULL,
   created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE private.media_restriction_hold OWNER TO postgres;

ALTER TABLE private.media_restriction_hold ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON private.media_restriction_hold FROM PUBLIC, anon, authenticated, service_role, api_owner;

-- 060's media_restriction (pinned in 052); 073: the groups held for a file a move removed.
CREATE OR REPLACE FUNCTION private.media_restriction (p_media UUID) RETURNS TEXT[] LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT coalesce(array_agg(DISTINCT g.grp), '{}'::TEXT[])
    FROM (
        SELECT 'supplier_identity' AS grp
        WHERE EXISTS (SELECT 1 FROM public.media_link l WHERE l.media_id = p_media AND l.entity_type IN ('supplier', 'purchase_order'))
           OR EXISTS (SELECT 1 FROM public.document d WHERE d.media_id = p_media AND d.entity_type IN ('supplier', 'purchase_order'))
        UNION ALL
        SELECT 'supplier_terms'
        WHERE EXISTS (
            SELECT 1 FROM public.document d
            WHERE d.media_id = p_media
              AND (d.type IN ('pi', 'commercial_invoice', 'po') OR (d.type = 'contract' AND d.entity_type = 'supplier'))
        )
        -- 073
        UNION ALL
        SELECT h.grp FROM private.media_restriction_hold x CROSS JOIN LATERAL unnest(x.groups) AS h (grp) WHERE x.media_id = p_media
    ) g;
$$;

REVOKE ALL ON FUNCTION private.media_restriction (UUID) FROM PUBLIC, anon, authenticated;

-- The target paths of a media row (see the header).
CREATE OR REPLACE FUNCTION private.transfer_media_paths (
   target UUID,
   media_id UUID,
   storage_path TEXT,
   thumbnail_path TEXT,
   OUT target_storage_path TEXT,
   OUT target_thumbnail_path TEXT
) LANGUAGE sql IMMUTABLE
SET
   search_path = '' AS $$
    SELECT
        transfer_media_paths.target::TEXT || '/' || transfer_media_paths.media_id::TEXT || '/'
            || regexp_replace(transfer_media_paths.storage_path, '^.*/', ''),
        CASE WHEN transfer_media_paths.thumbnail_path IS NOT NULL THEN
            transfer_media_paths.target::TEXT || '/' || transfer_media_paths.media_id::TEXT || '/thumb/thumb.webp'
        END;
$$;

REVOKE ALL ON FUNCTION private.transfer_media_paths (UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- The package rows locked (see the header).
CREATE OR REPLACE FUNCTION private.transfer_lock_rows () RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    reg RECORD;
BEGIN
    FOR reg IN SELECT r.table_name FROM private.transfer_registry r ORDER BY r.position LOOP
        EXECUTE format(
            'SELECT count(*) FROM (SELECT 1 FROM public.%1$I x WHERE x.id IN ('
            'SELECT r.source_id FROM pg_temp.transfer_rows r WHERE r.table_name = %1$L) ORDER BY x.id FOR UPDATE) l',
            reg.table_name
        );
    END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_lock_rows () FROM PUBLIC, anon, authenticated;

-- The id map (see the header).
CREATE OR REPLACE FUNCTION private.transfer_build_map (transfer_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    conflicts JSONB;
    picks JSONB;
BEGIN
    SELECT coalesce(t.report -> 'conflicts', '[]'), coalesce(t.decisions, '{}') INTO conflicts, picks
    FROM public.transfer t WHERE t.id = transfer_build_map.transfer_id;

    IF to_regclass('pg_temp.transfer_map') IS NOT NULL THEN
        DROP TABLE pg_temp.transfer_map;
    END IF;

    CREATE TEMP TABLE transfer_map (
        table_name TEXT NOT NULL,
        source_id UUID NOT NULL,
        target_id UUID NOT NULL,
        mapped BOOLEAN NOT NULL DEFAULT FALSE,
        PRIMARY KEY (table_name, source_id)
    ) ON COMMIT DROP;

    INSERT INTO pg_temp.transfer_map (table_name, source_id, target_id, mapped)
    SELECT r.table_name, r.source_id, coalesce(d.target, gen_random_uuid()), d.target IS NOT NULL
    FROM pg_temp.transfer_rows r
    CROSS JOIN LATERAL (
        -- 072 checked a map: it names a supplier of the target.
        SELECT CASE WHEN r.table_name = 'supplier' AND picks -> ('supplier:' || r.source_id) ->> 'action' = 'map'
                    THEN private.transfer_uuid(picks -> ('supplier:' || r.source_id) ->> 'target_id') END AS target
    ) d
    WHERE NOT r.seq IN (SELECT o.seq FROM private.transfer_omitted(conflicts, picks) o);

    -- The source files a move removes (transfer_delete_source): their objects go after the copy.
    IF to_regclass('pg_temp.transfer_removed_media') IS NOT NULL THEN
        DROP TABLE pg_temp.transfer_removed_media;
    END IF;

    CREATE TEMP TABLE transfer_removed_media (source_id UUID PRIMARY KEY) ON COMMIT DROP;

    -- A file only rows that are not written use is not copied.
    DELETE FROM pg_temp.transfer_map f
    WHERE f.table_name = 'media'
      AND f.source_id IN (SELECT u.source_id FROM private.transfer_unused_media(conflicts, picks) u);

    -- I1 (final review): each copied file's restriction in the source, before a move removes anything.
    IF to_regclass('pg_temp.transfer_media_groups') IS NOT NULL THEN
        DROP TABLE pg_temp.transfer_media_groups;
    END IF;

    CREATE TEMP TABLE transfer_media_groups (source_id UUID PRIMARY KEY, groups TEXT[] NOT NULL) ON COMMIT DROP;

    INSERT INTO pg_temp.transfer_media_groups (source_id, groups)
    SELECT m.source_id, private.media_restriction(m.source_id)
    FROM pg_temp.transfer_map m
    WHERE m.table_name = 'media' AND NOT m.mapped;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_build_map (UUID) FROM PUBLIC, anon, authenticated;

-- The package rows of one table into the target (see the header). Returns the files to copy.
CREATE OR REPLACE FUNCTION private.transfer_write (transfer_id UUID, tbl TEXT) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    target UUID;
    source UUID;
    picks JSONB;
    moving BOOLEAN;
    reg private.transfer_registry;
    columns TEXT;
    insert_sql TEXT;
    refs JSONB;
    outside TEXT[];
    ref RECORD;
    uc RECORD;
    r RECORD;
    data JSONB;
    v TEXT;
    found_id UUID;
    omit BOOLEAN;
    col TEXT;
    members JSONB := '{}';
    paths RECORD;
    files JSONB := '[]';
BEGIN
    SELECT t.tenant_id, t.source_tenant_id, coalesce(t.decisions, '{}'), t.mode = 'move' INTO target, source, picks, moving
    FROM public.transfer t WHERE t.id = transfer_write.transfer_id;

    SELECT * INTO reg FROM private.transfer_registry g WHERE g.table_name = transfer_write.tbl;

    -- Every column but the generated ones, introspected once.
    SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum) INTO columns
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = format('public.%I', transfer_write.tbl)::REGCLASS
      AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = '';

    insert_sql := format(
        'INSERT INTO public.%1$I (%2$s) SELECT %2$s FROM jsonb_populate_record(NULL::public.%1$I, $1)',
        transfer_write.tbl, columns
    );

    -- References to registry rows, through the map.
    SELECT coalesce(jsonb_agg(jsonb_build_object('col', f.column_name, 'table', f.ref_table, 'not_null', f.not_null)), '[]')
    INTO refs
    FROM private.transfer_references() f
    WHERE f.table_name = transfer_write.tbl;

    -- References to a tenant's rows outside the registry (paired with tenant_id): cleared.
    outside := ARRAY(
        SELECT DISTINCT a.attname::TEXT
        FROM pg_catalog.pg_constraint c
        JOIN pg_catalog.pg_class frel ON frel.oid = c.confrelid
        CROSS JOIN LATERAL unnest(c.conkey, c.confkey) AS k (f, t)
        JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.f
        JOIN pg_catalog.pg_attribute ta ON ta.attrelid = c.confrelid AND ta.attnum = k.t
        WHERE c.contype = 'f' AND c.conrelid = format('public.%I', transfer_write.tbl)::REGCLASS
          AND ta.attname = 'id'
          AND NOT EXISTS (SELECT 1 FROM private.transfer_registry g WHERE g.table_name = frel.relname)
          AND EXISTS (
              SELECT 1 FROM unnest(c.confkey) AS tk (attnum)
              JOIN pg_catalog.pg_attribute tt ON tt.attrelid = c.confrelid AND tt.attnum = tk.attnum
              WHERE tt.attname = 'tenant_id'
          )
    );

    FOR r IN
        SELECT x.source_id, x.row, x.copy_only, m.target_id
        FROM pg_temp.transfer_rows x
        JOIN pg_temp.transfer_map m ON m.table_name = x.table_name AND m.source_id = x.source_id AND NOT m.mapped
        WHERE x.table_name = transfer_write.tbl
        ORDER BY (x.row ->> 'parent_id') IS NOT NULL, x.seq
    LOOP
        -- F5, the second line: only the source's own rows, never one with a client link.
        IF r.row ->> 'tenant_id' IS DISTINCT FROM source::TEXT OR r.row ->> 'client_tenant_id' IS NOT NULL THEN
            RAISE EXCEPTION 'transfer_package_invalid';
        END IF;

        data := r.row || jsonb_build_object('id', r.target_id, 'tenant_id', target);
        omit := FALSE;

        -- Every other tenant column that named the source names the target.
        FOR col IN
            SELECT e.key FROM jsonb_each_text(r.row) e
            WHERE e.key LIKE '%\_tenant\_id' AND e.key NOT IN ('tenant_id', 'client_tenant_id') AND e.value = source::TEXT
        LOOP
            data := data || jsonb_build_object(col, target);
        END LOOP;

        FOR ref IN
            SELECT e ->> 'col' AS col, e ->> 'table' AS rt, (e ->> 'not_null')::BOOLEAN AS nn
            FROM jsonb_array_elements(refs) e
        LOOP
            v := r.row ->> ref.col;
            CONTINUE WHEN v IS NULL;

            SELECT m.target_id INTO found_id
            FROM pg_temp.transfer_map m WHERE m.table_name = ref.rt AND m.source_id = v::UUID;

            IF FOUND THEN
                data := data || jsonb_build_object(ref.col, found_id);
            ELSIF ref.nn THEN
                -- An omitted package row (or, which the collection never gives, a row outside it).
                omit := TRUE;
                EXIT;
            ELSE
                data := data || jsonb_build_object(ref.col, NULL);
            END IF;
        END LOOP;

        -- L3: a move removed the row from the source already; it is never dropped.
        IF omit AND moving AND NOT r.copy_only THEN
            RAISE EXCEPTION 'transfer_package_invalid';
        END IF;

        CONTINUE WHEN omit;

        FOREACH col IN ARRAY outside LOOP
            IF r.row ->> col IS NOT NULL THEN
                data := data || jsonb_build_object(col, NULL);
            END IF;
        END LOOP;

        -- The polymorphic entity.
        IF reg.parent_column = 'entity' THEN
            SELECT m.target_id INTO found_id
            FROM private.transfer_registry e
            JOIN pg_temp.transfer_map m ON m.table_name = e.table_name AND m.source_id = (r.row ->> 'entity_id')::UUID
            WHERE e.entity::TEXT = r.row ->> 'entity_type' AND NOT m.mapped;

            -- An omitted entity (or a mapped supplier, whose documents stay): the row goes with it;
            -- never in a move (L3).
            IF NOT FOUND AND moving AND NOT r.copy_only THEN
                RAISE EXCEPTION 'transfer_package_invalid';
            END IF;
            CONTINUE WHEN NOT FOUND;
            data := data || jsonb_build_object('entity_id', found_id);
        END IF;

        FOREACH col IN ARRAY reg.reset_columns LOOP
            data := data || jsonb_build_object(col, NULL);
        END LOOP;

        -- The users rule: a user of neither a member nor an owner of the target.
        FOR uc IN SELECT u.key AS col, u.value #>> '{}' AS action FROM jsonb_each(reg.user_columns) u LOOP
            v := r.row ->> uc.col;
            CONTINUE WHEN v IS NULL OR uc.action = 'keep';

            IF NOT members ? v THEN
                members := members || jsonb_build_object(v,
                    EXISTS (SELECT 1 FROM public.tenant_user tu WHERE tu.user_id = v::UUID AND tu.tenant_id = target)
                    OR target = ANY (private.owned_tenants(v::UUID)));
            END IF;

            IF NOT (members ->> v)::BOOLEAN THEN
                data := data || jsonb_build_object(uc.col, CASE uc.action WHEN 'actor' THEN auth.uid() END);
            END IF;
        END LOOP;

        -- The decisions.
        IF transfer_write.tbl = 'product' THEN
            IF picks -> ('sku:' || r.source_id) ->> 'action' = 'rename' THEN
                data := data || jsonb_build_object('sku', (r.row ->> 'sku') || (picks -> ('sku:' || r.source_id) ->> 'suffix'));
            END IF;
            IF picks -> ('gtin:' || r.source_id) ->> 'action' = 'clear_gtin' THEN
                data := data || '{"gtin": null}'::JSONB;
            END IF;
        ELSIF transfer_write.tbl = 'supplier' AND picks -> ('supplier:' || r.source_id) ->> 'action' = 'new_code' THEN
            data := data || jsonb_build_object('code', picks -> ('supplier:' || r.source_id) ->> 'code');
        END IF;

        IF transfer_write.tbl = 'media' THEN
            SELECT * INTO paths
            FROM private.transfer_media_paths(target, r.target_id, r.row ->> 'storage_path', r.row ->> 'thumbnail_path');
            data := data || jsonb_build_object(
                'storage_path', paths.target_storage_path, 'thumbnail_path', paths.target_thumbnail_path
            );
            files := files || jsonb_build_array(jsonb_build_object(
                'media_id', r.target_id, 'from', r.row ->> 'storage_path', 'to', paths.target_storage_path,
                'keep_source', NOT EXISTS (SELECT 1 FROM pg_temp.transfer_removed_media x WHERE x.source_id = r.source_id)
            ));
            IF paths.target_thumbnail_path IS NOT NULL THEN
                files := files || jsonb_build_array(jsonb_build_object(
                    'media_id', r.target_id, 'from', r.row ->> 'thumbnail_path', 'to', paths.target_thumbnail_path,
                    'keep_source', NOT EXISTS (SELECT 1 FROM pg_temp.transfer_removed_media x WHERE x.source_id = r.source_id)
                ));
            END IF;
        END IF;

        EXECUTE insert_sql USING data;
    END LOOP;

    RETURN files;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_write (UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- The source package removed, in a move (see the header).
CREATE OR REPLACE FUNCTION private.transfer_delete_source (transfer_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    source UUID;
    reg RECORD;
    picked CONSTANT TEXT :=
        'SELECT r.source_id FROM pg_temp.transfer_rows r WHERE r.table_name = %L AND NOT r.copy_only';
    saved_transaction TEXT := current_setting('audit.transaction_id', TRUE);
    saved_tenant TEXT := current_setting('audit.tenant_id', TRUE);
    saved_depth TEXT := current_setting('audit.depth', TRUE);
    source_transaction UUID;
    deleted BIGINT;
    restrictions JSONB;
BEGIN
    SELECT t.source_tenant_id INTO source FROM public.transfer t WHERE t.id = transfer_delete_source.transfer_id;

    -- I2: the package files' read restrictions, before their links and documents go.
    SELECT coalesce(jsonb_object_agg(r.source_id, to_jsonb(private.media_restriction(r.source_id))), '{}') INTO restrictions
    FROM pg_temp.transfer_rows r WHERE r.table_name = 'media';

    -- The source's own audit transaction.
    PERFORM set_config('audit.transaction_id', '', TRUE);

    FOR reg IN SELECT g.table_name FROM private.transfer_registry g WHERE NOT g.copy_only ORDER BY g.position DESC LOOP
        IF reg.table_name = 'product' THEN
            -- The variants before their parents, level by level.
            LOOP
                EXECUTE format(
                    'DELETE FROM public.product x WHERE x.tenant_id = $1 AND x.id IN (%s) AND NOT EXISTS ('
                    'SELECT 1 FROM public.product c WHERE c.tenant_id = $1 AND c.parent_id = x.id)',
                    format(picked, 'product')
                )
                USING source;
                GET DIAGNOSTICS deleted = ROW_COUNT;
                EXIT WHEN deleted = 0;
            END LOOP;
        END IF;

        EXECUTE format('DELETE FROM public.%I x WHERE x.tenant_id = $1 AND x.id IN (%s)', reg.table_name, format(picked, reg.table_name))
        USING source;
    END LOOP;

    -- I2: a package file nothing in the source uses any more goes too: its row now, its object after
    -- the copy (keep_source FALSE in the files list); the restriction it had is held for the object.
    INSERT INTO pg_temp.transfer_removed_media (source_id)
    SELECT m.id FROM public.media m
    WHERE m.tenant_id = source
      AND m.id IN (SELECT r.source_id FROM pg_temp.transfer_rows r WHERE r.table_name = 'media')
      AND NOT EXISTS (SELECT 1 FROM public.media_link l WHERE l.tenant_id = source AND l.media_id = m.id)
      AND NOT EXISTS (SELECT 1 FROM public.document d WHERE d.tenant_id = source AND d.media_id = m.id);

    INSERT INTO private.media_restriction_hold (media_id, tenant_id, groups)
    SELECT x.source_id, source, ARRAY(SELECT jsonb_array_elements_text(restrictions -> x.source_id::TEXT))
    FROM pg_temp.transfer_removed_media x
    WHERE jsonb_array_length(coalesce(restrictions -> x.source_id::TEXT, '[]')) > 0
    ON CONFLICT (media_id) DO UPDATE SET groups = EXCLUDED.groups;

    DELETE FROM public.media m
    WHERE m.tenant_id = source AND m.id IN (SELECT x.source_id FROM pg_temp.transfer_removed_media x);

    -- The target's audit transaction back, then the source's recorded with it.
    source_transaction := nullif(current_setting('audit.transaction_id', TRUE), '')::UUID;
    PERFORM set_config('audit.transaction_id', coalesce(saved_transaction, ''), TRUE);
    PERFORM set_config('audit.tenant_id', coalesce(saved_tenant, ''), TRUE);
    PERFORM set_config('audit.depth', coalesce(saved_depth, ''), TRUE);

    IF source_transaction IS NOT NULL THEN
        UPDATE public.transfer t
        SET audit_transaction_ids = t.audit_transaction_ids || source_transaction
        WHERE t.id = transfer_delete_source.transfer_id;
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_delete_source (UUID) FROM PUBLIC, anon, authenticated;

-- The copy (see the header).
CREATE OR REPLACE FUNCTION private.transfer_apply_copy (transfer_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    reg RECORD;
    listed JSONB := '[]';
BEGIN
    FOR reg IN SELECT g.table_name FROM private.transfer_registry g ORDER BY g.position LOOP
        listed := listed || private.transfer_write(transfer_apply_copy.transfer_id, reg.table_name);
    END LOOP;

    -- I1 (final review): a copied file whose source restriction the copied rows do not all give it
    -- keeps that restriction in the target.
    INSERT INTO private.media_restriction_hold (media_id, tenant_id, groups)
    SELECT m.target_id, t.tenant_id, g.groups
    FROM pg_temp.transfer_media_groups g
    JOIN pg_temp.transfer_map m ON m.table_name = 'media' AND m.source_id = g.source_id AND NOT m.mapped
    JOIN public.transfer t ON t.id = transfer_apply_copy.transfer_id
    WHERE cardinality(g.groups) > 0
      AND NOT (g.groups <@ private.media_restriction(m.target_id))
    ON CONFLICT (media_id) DO UPDATE SET groups = EXCLUDED.groups;

    UPDATE public.transfer t
    SET id_map = coalesce((
            SELECT jsonb_object_agg(g.table_name, g.ids)
            FROM (
                SELECT m.table_name, jsonb_object_agg(m.source_id::TEXT, m.target_id) AS ids
                FROM pg_temp.transfer_map m GROUP BY m.table_name
            ) g
        ), '{}'),
        files = listed,
        files_status = CASE WHEN jsonb_array_length(listed) > 0 THEN 'pending' ELSE 'done' END
    WHERE t.id = transfer_apply_copy.transfer_id;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_apply_copy (UUID) FROM PUBLIC, anon, authenticated;

-- The run (see the header).
CREATE OR REPLACE FUNCTION private.transfer_apply (transfer_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    transfer_mode public.transfer_mode;
BEGIN
    SELECT t.mode INTO transfer_mode FROM public.transfer t WHERE t.id = transfer_apply.transfer_id;

    PERFORM private.transfer_build_map(transfer_apply.transfer_id);

    -- A move empties the source first: its GTINs are free when the rows are written.
    IF transfer_mode = 'move' THEN
        PERFORM private.transfer_delete_source(transfer_apply.transfer_id);
    END IF;

    PERFORM private.transfer_apply_copy(transfer_apply.transfer_id);
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_apply (UUID) FROM PUBLIC, anon, authenticated;

-- L4: the stored description of the source is read under the source's rights.
ALTER TABLE public.transfer
ALTER COLUMN product_ids
SET DEFAULT '{}',
ALTER COLUMN report
SET DEFAULT '{}';

UPDATE public.field_class
SET
   class = 'sensitive',
   group_name = 'internal_note',
   rights_column = 'source_tenant_id'
WHERE
   resource_name = 'public.transfer'
   AND field IN ('product_ids', 'report', 'decisions', 'id_map', 'files');

-- R1 (049), as 071: the built-in profiles get their defaults, any other tenant role reads them as far
-- as it reads transfers.
INSERT INTO
   public.role_field_permission (role_id, resource_name, field, can_read, can_write)
SELECT
   r.id,
   f.resource_name,
   f.field,
   d.can_read,
   d.can_write
FROM
   public.role r
   JOIN private.field_default d ON d.profile = r.display_name
   JOIN public.field_class f ON f.resource_name = 'public.transfer'
   AND f.class = 'sensitive'
   AND f.group_name = d.group_name
WHERE
   r.tenant_id IS NOT NULL
ON CONFLICT (role_id, resource_name, field) DO NOTHING;

INSERT INTO
   public.role_field_permission (role_id, resource_name, field, can_read, can_write)
SELECT
   r.id,
   f.resource_name,
   f.field,
   TRUE,
   FALSE
FROM
   public.role r
   JOIN public.field_class f ON f.resource_name = 'public.transfer'
   AND f.class = 'sensitive'
WHERE
   r.tenant_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM private.field_default d WHERE d.profile = r.display_name)
   AND EXISTS (
      SELECT 1
      FROM public.role_permission rp
      JOIN public.permission p ON p.id = rp.permission_id
      WHERE rp.role_id = r.id AND p.resource_name = 'public.transfer' AND p.command = 'select'
   )
ON CONFLICT (role_id, resource_name, field) DO NOTHING;

-- The view again, with the new classes (as 072).
GRANT CREATE ON SCHEMA api TO api_owner;

SELECT private.enable_field_security ('transfer', TRUE);

REVOKE CREATE ON SCHEMA api FROM api_owner;

-- A transfer row as api.transfer shows it to p_user (see the header).
CREATE OR REPLACE FUNCTION private.transfer_row_for (p_user UUID, p_transfer_id UUID) RETURNS api.transfer LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    data JSONB;
    f RECORD;
    rights_tenant UUID;
BEGIN
    SELECT to_jsonb(t) INTO data FROM public.transfer t WHERE t.id = transfer_row_for.p_transfer_id;

    IF data IS NULL THEN
        RETURN NULL;
    END IF;

    FOR f IN
        SELECT c.field, private.field_rights_column(c.resource_name, c.field) AS rights_column
        FROM public.field_class c
        WHERE c.resource_name = 'public.transfer' AND c.class = 'sensitive'
    LOOP
        rights_tenant := (data ->> f.rights_column)::UUID;
        IF NOT coalesce(rights_tenant = ANY (private.field_tenants(p_user, ARRAY[rights_tenant], 'public.transfer', f.field, FALSE)), FALSE) THEN
            data := data || jsonb_build_object(f.field, NULL);
        END IF;
    END LOOP;

    RETURN jsonb_populate_record(NULL::api.transfer, data);
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_row_for (UUID, UUID) FROM PUBLIC, anon, authenticated;

-- 072's entry point (pinned in 052); 073: the run (see the header, F19).
CREATE OR REPLACE FUNCTION public.transfer_products (
   source_tenant UUID,
   target_tenant UUID,
   product_ids UUID[],
   mode TEXT,
   decisions JSONB DEFAULT NULL,
   rehearse BOOLEAN DEFAULT TRUE
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    refusal TEXT := private.transfer_refusal(source_tenant, target_tenant, transfer_products.mode);
    excluded TEXT[];
    report JSONB;
    -- 073
    new_id UUID;
    saved_transaction TEXT;
    saved_tenant TEXT;
    saved_depth TEXT;
    stored_report JSONB;
    expected_hash TEXT;
BEGIN
    IF refusal IS NOT NULL THEN
        PERFORM private.transfer_raise(
            refusal, CASE WHEN refusal IN ('transfer_mode_invalid', 'transfer_same_tenant') THEN 400
                          WHEN refusal = 'transfer_files_pending' THEN 409
                          ELSE 403 END
        );
    END IF;

    IF transfer_products.product_ids IS NULL
       OR cardinality(transfer_products.product_ids) = 0
       OR EXISTS (
           SELECT 1 FROM unnest(transfer_products.product_ids) AS s (id)
           WHERE s.id IS NULL OR NOT EXISTS (
               SELECT 1 FROM public.product p WHERE p.id = s.id AND p.tenant_id = transfer_products.source_tenant
           )
       ) THEN
        PERFORM private.transfer_raise('transfer_products_invalid', 400);
    END IF;

    IF decisions IS NOT NULL AND jsonb_typeof(decisions) NOT IN ('object', 'null') THEN
        PERFORM private.transfer_raise('transfer_decision_invalid', 400);
    END IF;

    -- 073 (L1): the hash of the rehearsal the caller approved rides in the decisions; it is not one.
    IF jsonb_typeof(transfer_products.decisions) = 'object' THEN
        expected_hash := transfer_products.decisions ->> 'report_hash';
        transfer_products.decisions := transfer_products.decisions - 'report_hash';
    END IF;

    excluded := private.transfer_excluded(source_tenant, target_tenant);

    PERFORM private.transfer_collect(source_tenant, transfer_products.product_ids, excluded, target_tenant);

    -- 073: a real run locks the package, then reads it again: what a concurrent writer committed
    -- before the lock is in it, and nothing in it changes until commit.
    IF NOT coalesce(rehearse, TRUE) THEN
        PERFORM private.transfer_lock_rows();
        PERFORM private.transfer_collect(source_tenant, transfer_products.product_ids, excluded, target_tenant);
        PERFORM private.transfer_lock_rows();
    END IF;

    -- 073 (C1), rule 5 for the package: a copied media link needs the update right on its entity in
    -- the target (media_link_check asks it), so it is refused here, not halfway through the run.
    -- 075 first: a package row of a module the target's plan lacks (market cells into a company
    -- without the market matrix) would land where nobody there can see it, so the transfer is
    -- refused, in the rehearsal too (transfer_target_plan_lacks_module). The module is the
    -- permission group of the row's table; a table without one is not a plan's to withhold.
    IF EXISTS (
        SELECT 1
        FROM (SELECT DISTINCT r.table_name FROM pg_temp.transfer_rows r) t
        JOIN public.permission p ON p.resource_name = 'public.' || t.table_name
        WHERE p.group_name IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM private.entitlements(ARRAY[target_tenant]) e WHERE p.group_name = ANY (e.modules)
          )
    ) THEN
        PERFORM private.transfer_raise('transfer_target_plan_lacks_module', 403);
    END IF;

    -- The same function media_link_check uses (tenants_permitting: roles, plan module and a
    -- writable subscription). A move also deletes the source's links, which media_link_check asks
    -- the same right for in the source.
    IF EXISTS (
        SELECT 1
        FROM (SELECT r.row ->> 'entity_type' AS entity, bool_or(NOT r.copy_only) AS removed
              FROM pg_temp.transfer_rows r WHERE r.table_name = 'media_link' GROUP BY 1) l
        WHERE NOT (target_tenant = ANY (private.tenants_permitting(auth.uid(), ARRAY[target_tenant], 'public.' || l.entity, 'update')))
           OR (transfer_products.mode = 'move' AND l.removed
               AND NOT (transfer_products.source_tenant = ANY (
                   private.tenants_permitting(auth.uid(), ARRAY[transfer_products.source_tenant], 'public.' || l.entity, 'update'))))
    ) THEN
        PERFORM private.transfer_raise('transfer_permissions_required', 403);
    END IF;

    -- 073 (R5): a move that leaves package files unused in the source removes their rows (I2), which
    -- needs the media delete right there.
    IF transfer_products.mode = 'move'
       AND EXISTS (
           SELECT 1 FROM pg_temp.transfer_rows f
           WHERE f.table_name = 'media'
             AND NOT EXISTS (
                 SELECT 1 FROM public.media_link l
                 WHERE l.tenant_id = transfer_products.source_tenant AND l.media_id = f.source_id
                   AND NOT EXISTS (SELECT 1 FROM pg_temp.transfer_rows q WHERE q.table_name = 'media_link' AND q.source_id = l.id AND NOT q.copy_only)
             )
             AND NOT EXISTS (
                 SELECT 1 FROM public.document d
                 WHERE d.tenant_id = transfer_products.source_tenant AND d.media_id = f.source_id
                   AND NOT EXISTS (SELECT 1 FROM pg_temp.transfer_rows q WHERE q.table_name = 'document' AND q.source_id = d.id AND NOT q.copy_only)
             )
       )
       AND NOT (transfer_products.source_tenant = ANY (
           private.tenants_granting(auth.uid(), ARRAY[transfer_products.source_tenant], 'public.media', 'delete'))) THEN
        PERFORM private.transfer_raise('transfer_permissions_required', 403);
    END IF;

    -- A package file that an earlier transfer into the source has not copied yet.
    IF EXISTS (
        SELECT 1
        FROM public.transfer t
        CROSS JOIN LATERAL jsonb_array_elements(t.files) f
        JOIN pg_temp.transfer_rows r ON r.table_name = 'media' AND r.source_id::TEXT = f ->> 'media_id'
        WHERE t.tenant_id = transfer_products.source_tenant AND t.files_status <> 'done'
          AND (t.files_status = 'pending' OR f ->> 'to' = ANY (t.missing_files)
               OR 'mismatch:' || (f ->> 'to') = ANY (t.missing_files))
    ) THEN
        PERFORM private.transfer_raise('transfer_files_pending', 409);
    END IF;

    report := private.transfer_report(
        source_tenant, target_tenant, transfer_products.mode, transfer_products.decisions, transfer_products.product_ids, excluded
    );

    IF coalesce(rehearse, TRUE) THEN
        RETURN report;
    END IF;

    PERFORM private.transfer_check_decisions(report, transfer_products.decisions, target_tenant, transfer_products.mode);

    -- A move never loses data: into a client, what a copy would withhold or blank stays (072).
    IF transfer_products.mode = 'move' AND coalesce((report ->> 'move_loses_data')::BOOLEAN, FALSE) THEN
        PERFORM private.transfer_raise('transfer_move_would_lose_data', 409);
    END IF;

    IF transfer_products.mode = 'move'
       AND EXISTS (SELECT 1 FROM jsonb_array_elements(report -> 'left_behind') e WHERE (e ->> 'blocks')::BOOLEAN) THEN
        PERFORM private.transfer_raise('transfer_product_in_use', 409);
    END IF;

    -- 073 (L1): what runs is what the caller rehearsed.
    IF expected_hash IS DISTINCT FROM report ->> 'report_hash' THEN
        PERFORM private.transfer_raise('transfer_report_stale', 409);
    END IF;

    -- 073: the run. The gate once more, with the package locked, right before anything is written.
    refusal := private.transfer_refusal(source_tenant, target_tenant, transfer_products.mode);
    IF refusal IS NOT NULL THEN
        PERFORM private.transfer_raise(refusal, CASE WHEN refusal = 'transfer_files_pending' THEN 409 ELSE 403 END);
    END IF;

    -- Its own audit transaction, even after an earlier write of the caller's transaction.
    saved_transaction := current_setting('audit.transaction_id', TRUE);
    saved_tenant := current_setting('audit.tenant_id', TRUE);
    saved_depth := current_setting('audit.depth', TRUE);
    PERFORM set_config('audit.transaction_id', '', TRUE);

    stored_report := report;

    -- The row first, its description at the defaults (no field right is needed for an empty row).
    new_id := gen_random_uuid();
    INSERT INTO public.transfer (id, tenant_id, source_tenant_id, mode, started_by)
    VALUES (new_id, target_tenant, source_tenant, transfer_products.mode::public.transfer_mode, auth.uid());

    -- The flag, for this row and this run alone (L5).
    PERFORM set_config('moesa.transfer_id', new_id::TEXT, TRUE);

    UPDATE public.transfer t
    SET product_ids = transfer_products.product_ids,
        report = stored_report,
        decisions = coalesce(transfer_products.decisions, '{}'),
        audit_transaction_ids = array_remove(ARRAY[nullif(current_setting('audit.transaction_id', TRUE), '')::UUID], NULL)
    WHERE t.id = new_id;

    PERFORM private.transfer_apply(new_id);

    PERFORM set_config('moesa.transfer_id', '', TRUE);

    -- The caller's audit transaction back (none: a later write opens its own).
    PERFORM set_config('audit.transaction_id', coalesce(saved_transaction, ''), TRUE);
    PERFORM set_config('audit.tenant_id', coalesce(saved_tenant, ''), TRUE);
    PERFORM set_config('audit.depth', coalesce(saved_depth, ''), TRUE);

    RETURN to_jsonb(private.transfer_row_for(auth.uid(), new_id));
END;
$$;

REVOKE ALL ON FUNCTION public.transfer_products (UUID, UUID, UUID[], TEXT, JSONB, BOOLEAN) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.transfer_products (UUID, UUID, UUID[], TEXT, JSONB, BOOLEAN) TO authenticated;
