-- Tenant-to-tenant product transfer (Plan 3, decisions 11 and 14), its core: the transfer record, the
-- table registry, the transaction-local flag that lets a transfer pass the business rules, the revert
-- guard, the rights gate and the rehearsal (the dry-run report). Ported from M21 (055b03b: 040 and
-- 042) and reshaped for customer = tenant: no customer root, no projects, orders, shipments,
-- incidents, change requests or listing submissions (they stay where they were created, decision 13),
-- no cheap path, no code renumbering. The run itself (copy, move, files) is 073/074 (Task 13): here a
-- real run (rehearse => FALSE) checks everything a run checks, then refuses with
-- transfer_apply_unavailable (501) until 073 replaces public.transfer_products.
--
-- transfer              One transfer of products from a source tenant to a target tenant; tenant_id is
--                       the target. It keeps the rehearsal's report, the decisions taken, the map of
--                       source to target ids ({"<table>": {"<source_id>": "<target_id>"}}), the files
--                       to copy and their state, and the audit transactions it wrote. Only the transfer
--                       definers write it: users read it through api.transfer (read-only), they never
--                       insert, change or delete it. xact_id is the transaction that wrote it.
-- transfer_registry     The tables a transfer carries, in the order it writes them: the root they hang
--                       from (product or supplier), their parent (parent_column 'entity' when they are
--                       scoped by entity_type and entity_id), the document entity they are, the columns
--                       written after every row is in (late_columns) or that hold arrays of ids
--                       (array_columns), what happens to their user columns (actor: the caller; clear:
--                       NULL; keep: unchanged), the columns a copy resets to NULL (reset_columns), how
--                       their code is made and whether they are only ever copied (copy_only: a supplier,
--                       its contacts and a file may be used by rows left behind).
--
-- Transfer flag  private.transferring() is TRUE when moesa.transfer_id names a transfer row written by
--                the current transaction (xact_id = pg_current_xact_id_if_assigned()). No API role can
--                write a transfer row, and a row of another transaction never matches, so a client
--                cannot raise the flag: neither with a GUC (PostgREST passes headers and claims as
--                request.* JSON, never as settings; no exposed function sets moesa.*) nor with SET
--                LOCAL. private.rules_bypassed() honours it (restated: its current body OR the flag),
--                and with it private.field_guard_bypassed (050).
-- Revert guard   public.revert_audit_transaction (restated: 068's body plus the check) refuses (409
--                audit_transfer_not_revertable) a transaction a transfer wrote (in
--                transfer.audit_transaction_ids) or one that wrote a transfer row: a transfer is undone
--                by transferring back. The check is private.audit_transfer_locked, SECURITY DEFINER
--                since the caller does not read every transfer row.
--
-- Module transfer (core, F22); permissions select and insert on public.transfer: the owner role and
-- every role that may change the settings (management), not the coordinator (create_standard_role is
-- restated with that one exclusion).

CREATE TYPE public.transfer_mode AS ENUM ('copy', 'move');

CREATE TABLE IF NOT EXISTS public.transfer (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   source_tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   product_ids UUID[] NOT NULL,
   mode public.transfer_mode NOT NULL,
   started_by UUID NOT NULL,
   report JSONB NOT NULL,
   decisions JSONB NOT NULL DEFAULT '{}',
   id_map JSONB NOT NULL DEFAULT '{}',
   files JSONB NOT NULL DEFAULT '[]',
   files_status TEXT NOT NULL DEFAULT 'done' CHECK (files_status IN ('pending', 'done', 'partial')),
   missing_files TEXT[] NOT NULL DEFAULT '{}',
   audit_transaction_ids UUID[] NOT NULL DEFAULT '{}',
   xact_id XID8 NOT NULL DEFAULT pg_current_xact_id(),
   created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
   updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The transfers whose files are still being copied.
CREATE INDEX IF NOT EXISTS idx_transfer_files_open ON public.transfer (tenant_id)
WHERE
   files_status <> 'done';

CREATE INDEX IF NOT EXISTS idx_transfer_source ON public.transfer (source_tenant_id);

-- Written by the transfer definers only (service_role keeps its rights); read through api.transfer.
REVOKE ALL ON public.transfer FROM anon, authenticated;

CREATE OR REPLACE TRIGGER set_updated_at BEFORE
UPDATE ON public.transfer FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at ();

SELECT
   private.enable_tenant_level_security ('transfer');

SELECT
   private.audit_enable ('public.transfer'::REGCLASS);

INSERT INTO
   public.module (id, is_core, position)
VALUES
   ('transfer', TRUE, 220)
ON CONFLICT (id) DO NOTHING;

-- Inserting a permission creates its RLS policies (private.manage_policies). The record is written by
-- the transfer definers only: insert is the right to start a transfer.
INSERT INTO
   public.permission (resource_name, group_name, command, kind, bypass, throws_error, resource_condition)
VALUES
   ('public.transfer', 'transfer', 'select', 'read', FALSE, FALSE, NULL),
   ('public.transfer', 'transfer', 'insert', 'create', FALSE, TRUE, NULL)
ON CONFLICT ON CONSTRAINT unique_permission_resource_command DO NOTHING;

-- The built-in owner role (008) and every role made before this migration that may change the
-- settings (management).
INSERT INTO
   public.role_permission (role_id, permission_id)
SELECT
   r.id,
   p.id
FROM
   public.role r,
   public.permission p
WHERE
   p.resource_name = 'public.transfer'
   AND (
      (r.display_name = 'owner' AND r.tenant_id IS NULL)
      OR (
         r.tenant_id IS NOT NULL
         AND EXISTS (
            SELECT 1
            FROM public.role_permission rp
            JOIN public.permission held ON held.id = rp.permission_id
            WHERE rp.role_id = r.id AND held.resource_name = 'public.setting' AND held.command = 'update'
         )
      )
   )
ON CONFLICT DO NOTHING;

-- The tables a transfer carries (see the header).
CREATE TABLE IF NOT EXISTS private.transfer_registry (
   table_name TEXT PRIMARY KEY,
   position INT UNIQUE NOT NULL,
   root TEXT NOT NULL CHECK (root IN ('product', 'supplier')),
   parent_table TEXT,
   parent_column TEXT,
   key_columns TEXT[],
   entity public.document_entity,
   late_columns TEXT[] NOT NULL DEFAULT '{}',
   array_columns JSONB NOT NULL DEFAULT '{}',
   user_columns JSONB NOT NULL DEFAULT '{}',
   reset_columns TEXT[] NOT NULL DEFAULT '{}',
   code_kind TEXT CHECK (code_kind IN ('typed')),
   copy_only BOOLEAN NOT NULL DEFAULT FALSE
);

ALTER TABLE private.transfer_registry OWNER TO postgres;

ALTER TABLE private.transfer_registry ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON private.transfer_registry FROM PUBLIC, anon, authenticated, service_role, api_owner;

INSERT INTO
   private.transfer_registry (
      table_name,
      position,
      root,
      parent_table,
      parent_column,
      entity,
      user_columns,
      reset_columns,
      code_kind,
      copy_only
   )
VALUES
   ('supplier', 10, 'supplier', NULL, NULL, 'supplier', '{}', '{}', 'typed', TRUE),
   ('supplier_contact', 20, 'supplier', 'supplier', 'supplier_id', NULL, '{}', '{}', NULL, TRUE),
   ('product', 30, 'product', NULL, NULL, 'product', '{}', '{}', NULL, FALSE),
   ('sourcing', 40, 'product', 'product', 'product_id', 'sourcing', '{}', '{}', NULL, FALSE),
   (
      'market_cell',
      50,
      'product',
      'product',
      'product_id',
      'market_cell',
      '{}',
      '{listing_state,listing_checked_at,listing_match}',
      NULL,
      FALSE
   ),
   ('media', 60, 'product', NULL, NULL, NULL, '{"uploaded_by": "actor"}', '{}', NULL, TRUE),
   ('media_link', 70, 'product', NULL, 'entity', NULL, '{}', '{}', NULL, FALSE),
   ('document', 80, 'product', NULL, 'entity', NULL, '{"created_by": "actor"}', '{}', NULL, FALSE)
ON CONFLICT (table_name) DO NOTHING;

-- The transfer flag (see the header). SECURITY DEFINER: it reads every transfer row. Executable by
-- authenticated because private.rules_bypassed (an invoker, granted to authenticated in 050) calls it.
CREATE OR REPLACE FUNCTION private.transferring () RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    setting TEXT := nullif(current_setting('moesa.transfer_id', TRUE), '');
    v UUID;
BEGIN
    IF setting IS NULL THEN
        RETURN FALSE;
    END IF;

    BEGIN
        v := setting::UUID;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN FALSE;
    END;

    RETURN EXISTS (
        SELECT 1 FROM public.transfer t
        WHERE t.id = v AND t.xact_id = pg_current_xact_id_if_assigned()
    );
END;
$$;

REVOKE ALL ON FUNCTION private.transferring () FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION private.transferring () TO authenticated;

-- 019/030's body, unchanged (pinned in 052), OR a running transfer (F4).
CREATE OR REPLACE FUNCTION private.rules_bypassed () RETURNS BOOLEAN LANGUAGE sql STABLE
SET
   search_path = '' AS $$
    SELECT coalesce(
        current_setting('moesa.rules_bypass', TRUE) = '1'
        AND current_setting('role') = 'none'
        AND session_user IN ('postgres', 'supabase_admin'),
        FALSE
    ) OR private.transferring();
$$;

-- Whether a transfer wrote this audit transaction, or the transaction wrote a transfer row.
-- SECURITY DEFINER: every transfer row, whatever the caller may read. Called by
-- revert_audit_transaction, a definer owned by api_owner.
CREATE OR REPLACE FUNCTION private.audit_transfer_locked (p_transaction_id UUID) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT EXISTS (
            SELECT 1 FROM public.transfer t WHERE p_transaction_id = ANY (t.audit_transaction_ids)
        )
        OR EXISTS (
            SELECT 1
            FROM public.audit_transaction a
            JOIN public.audit_log l ON l.transaction_id = a.id AND l.created_at = a.created_at
            WHERE a.id = p_transaction_id
              AND l.table_schema = 'public'
              AND l.table_name = 'transfer'
        );
$$;

REVOKE ALL ON FUNCTION private.audit_transfer_locked (UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION private.audit_transfer_locked (UUID) TO api_owner;

-- 068's revert_audit_transaction (pinned in 052); 072: the transfer lock, before anything is checked or
-- written (F4: only this delta).
CREATE OR REPLACE FUNCTION public.revert_audit_transaction (transaction_id UUID) RETURNS TEXT[] LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    target public.audit_transaction;
    change public.audit_log;
    pending BIGINT[];
    waiting BIGINT[];
    change_id BIGINT;
    relation REGCLASS;
    columns TEXT;
    row_columns TEXT;
    affected INT;
    blocked TEXT;
    forbidden TEXT;
    chk RECORD;
    api_view REGCLASS;
    -- 068
    rights_column TEXT;
    rights_tenant UUID;
BEGIN
    SELECT * INTO target FROM public.audit_transaction t WHERE t.id = revert_audit_transaction.transaction_id;

    IF NOT FOUND THEN
        RAISE SQLSTATE 'PGRST' USING
            MESSAGE = json_build_object('code', 'P0002', 'message', 'audit transaction not found')::TEXT,
            DETAIL = json_build_object('status', 404, 'headers', json_build_object())::TEXT;
    END IF;

    IF target.reverted_at IS NOT NULL THEN
        RAISE SQLSTATE 'PGRST' USING
            MESSAGE = json_build_object('code', 'P0001', 'message', 'audit_already_reverted')::TEXT,
            DETAIL = json_build_object('status', 409, 'headers', json_build_object())::TEXT;
    END IF;

    -- 072: a transfer is undone by transferring back, never from the log.
    IF private.audit_transfer_locked(target.id) THEN
        RAISE SQLSTATE 'PGRST' USING
            MESSAGE = json_build_object('code', 'P0001', 'message', 'audit_transfer_not_revertable')::TEXT,
            DETAIL = json_build_object('status', 409, 'headers', json_build_object())::TEXT;
    END IF;

    -- Before anything is written, every change the revert makes must be one the caller could make
    -- through the api: an UPDATE writes back the keys of old_data (UPDATE rows hold only the changed
    -- ones), an INSERT is undone by a delete, a DELETE by inserting its non-NULL values again.
    --   Grants: the column UPDATE/INSERT or table DELETE authenticated holds on api.<table> (they
    --   mirror its base grants and stay after the cutover); no api view, nothing is granted.
    --   C3: a sensitive key must be writable by the caller in the row's tenant (system paths pass, S2).
    FOR chk IN
        SELECT l.table_schema, l.table_name, l.operation, l.tenant_id, k.key, l.record_id, l.old_data, l.new_data,
               coalesce(a.attgenerated = '', FALSE) AS stored
        FROM public.audit_log l
        LEFT JOIN LATERAL (
            SELECT e.key FROM jsonb_each(CASE WHEN l.operation = 'INSERT' THEN l.new_data ELSE l.old_data END) AS e (key, value)
            WHERE l.operation = 'UPDATE' OR e.value <> 'null'::JSONB
        ) AS k ON TRUE
        LEFT JOIN pg_catalog.pg_attribute a
          ON a.attrelid = to_regclass(format('%I.%I', l.table_schema, l.table_name)) AND a.attname = k.key
         AND a.attnum > 0 AND NOT a.attisdropped
        WHERE l.transaction_id = target.id AND l.created_at = target.created_at
        ORDER BY l.id, k.key
    LOOP
        api_view := CASE WHEN chk.table_schema = 'public' THEN to_regclass(format('api.%I', chk.table_name)) END;
        IF api_view IS NULL
           OR (chk.operation = 'INSERT' AND NOT has_table_privilege('authenticated', api_view, 'DELETE')) THEN
            forbidden := chk.table_name;
        ELSIF chk.key IS NULL THEN
            CONTINUE;
        ELSIF chk.stored AND chk.operation = 'UPDATE' AND NOT has_column_privilege('authenticated', api_view, chk.key, 'UPDATE') THEN
            forbidden := chk.table_name || '.' || chk.key;
        ELSIF chk.stored AND chk.operation = 'DELETE' AND NOT has_column_privilege('authenticated', api_view, chk.key, 'INSERT') THEN
            forbidden := chk.table_name || '.' || chk.key;
        ELSIF NOT private.field_guard_bypassed()
              AND private.api_is_sensitive(chk.table_schema || '.' || chk.table_name, chk.key) THEN
            -- 068: in the field's rights tenant: its rights column in the stored row (the snapshots when
            -- the row is gone or out of reach), the row's tenant when the catalog names no other.
            rights_column := private.field_rights_column(chk.table_schema || '.' || chk.table_name, chk.key);
            rights_tenant := NULL;
            IF rights_column <> 'tenant_id' THEN
                EXECUTE format('SELECT (to_jsonb(t) ->> %L)::UUID FROM %I.%I t WHERE t.id = $1', rights_column, chk.table_schema, chk.table_name)
                INTO rights_tenant USING chk.record_id;
                rights_tenant := coalesce(rights_tenant, (chk.new_data ->> rights_column)::UUID, (chk.old_data ->> rights_column)::UUID);
            END IF;
            IF NOT coalesce(coalesce(rights_tenant, chk.tenant_id) = ANY (private.field_write_tenants(chk.table_schema || '.' || chk.table_name, chk.key)), FALSE) THEN
                forbidden := chk.table_name || '.' || chk.key;
            END IF;
        END IF;
        IF forbidden IS NOT NULL THEN
            RAISE EXCEPTION 'audit_revert_field_forbidden' USING ERRCODE = '42501', DETAIL = forbidden;
        END IF;
    END LOOP;

    -- Read by private.audit_begin when this transaction's first write is logged.
    PERFORM set_config('audit.reverts', target.id::TEXT, true);

    pending := ARRAY(
        SELECT l.id FROM public.audit_log l
        WHERE l.transaction_id = target.id AND l.created_at = target.created_at
        ORDER BY l.id DESC
    );

    WHILE cardinality(pending) > 0 LOOP
        waiting := '{}';

        FOREACH change_id IN ARRAY pending LOOP
            SELECT * INTO change FROM public.audit_log l WHERE l.id = change_id AND l.created_at = target.created_at;
            relation := format('%I.%I', change.table_schema, change.table_name)::REGCLASS;

            -- The columns to write back, without generated ones.
            SELECT string_agg(format('%I', a.attname), ', '), string_agg(format('r.%I', a.attname), ', ')
            INTO columns, row_columns
            FROM jsonb_object_keys(coalesce(change.old_data, '{}')) AS k (name)
            JOIN pg_catalog.pg_attribute a ON a.attrelid = relation AND a.attname = k.name
            WHERE a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = '';

            BEGIN
                CASE change.operation
                    WHEN 'INSERT' THEN
                        EXECUTE format('DELETE FROM %s t WHERE t.id = $1 AND to_jsonb(t) = $2', relation)
                        USING change.record_id, change.new_data;
                        GET DIAGNOSTICS affected = ROW_COUNT;

                        -- Already gone (a cascade of this revert, or deleted since) is what undoing
                        -- an insert asks for; only a row that was changed since is a conflict.
                        IF affected = 0 THEN
                            EXECUTE format('SELECT count(*) FROM %s t WHERE t.id = $1', relation)
                            INTO affected USING change.record_id;
                            affected := 1 - affected;
                        END IF;
                    WHEN 'UPDATE' THEN
                        EXECUTE format(
                            'UPDATE %s t SET (%s) = (SELECT %s FROM jsonb_populate_record(NULL::%s, $1) r) '
                            'WHERE t.id = $2 AND NOT EXISTS ('
                            '  SELECT 1 FROM jsonb_object_keys($1) k WHERE to_jsonb(t) -> k IS DISTINCT FROM $3 -> k)',
                            relation, columns, row_columns, relation
                        )
                        USING change.old_data, change.record_id, change.new_data;
                        GET DIAGNOSTICS affected = ROW_COUNT;
                    WHEN 'DELETE' THEN
                        EXECUTE format(
                            'INSERT INTO %s (%s) SELECT %s FROM jsonb_populate_record(NULL::%s, $1) r',
                            relation, columns, row_columns, relation
                        )
                        USING change.old_data;
                        GET DIAGNOSTICS affected = ROW_COUNT;
                END CASE;
            EXCEPTION
                WHEN foreign_key_violation THEN
                    waiting := waiting || change_id;
                    blocked := SQLERRM;
                    CONTINUE;
                -- A deleted row that was created again.
                WHEN unique_violation THEN
                    affected := 0;
                -- A row the table refuses: a conflict, without the DETAIL (it would show the row's values,
                -- read with api_owner's rights).
                WHEN check_violation OR not_null_violation OR exclusion_violation THEN
                    RAISE SQLSTATE 'PGRST' USING
                        MESSAGE = json_build_object('code', 'P0001', 'message', 'audit_conflict')::TEXT,
                        DETAIL = json_build_object('status', 409, 'headers', json_build_object())::TEXT;
            END;

            IF affected = 0 THEN
                RAISE SQLSTATE 'PGRST' USING
                    MESSAGE = json_build_object(
                        'code', 'P0001',
                        'message', 'audit_conflict',
                        'details', format('%s %s was changed after this change', change.table_name, change.record_id)
                    )::TEXT,
                    DETAIL = json_build_object('status', 409, 'headers', json_build_object())::TEXT;
            END IF;
        END LOOP;

        -- Nothing moved: the rows they refer to are gone for good.
        IF cardinality(waiting) = cardinality(pending) THEN
            RAISE SQLSTATE 'PGRST' USING
                MESSAGE = json_build_object('code', 'P0001', 'message', 'audit_conflict', 'details', blocked)::TEXT,
                DETAIL = json_build_object('status', 409, 'headers', json_build_object())::TEXT;
        END IF;
        pending := waiting;
    END LOOP;

    RETURN ARRAY(
        SELECT DISTINCT l.table_name FROM public.audit_log l
        WHERE l.transaction_id = target.id AND l.created_at = target.created_at
    );
END;
$$;

GRANT CREATE ON SCHEMA public TO api_owner;

ALTER FUNCTION public.revert_audit_transaction (UUID) OWNER TO api_owner;

REVOKE CREATE ON SCHEMA public FROM api_owner;

REVOKE ALL ON FUNCTION public.revert_audit_transaction (UUID) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.revert_audit_transaction (UUID) TO authenticated, service_role;

-- 070's create_standard_role (pinned in 052); 072: the coordinator does not transfer (as M21: only the
-- roles that may change the settings, and the owner, start a transfer).
CREATE OR REPLACE FUNCTION private.create_standard_role (p_tenant UUID, p_role TEXT) RETURNS UUID LANGUAGE plpgsql
SET
   search_path = '' AS $$
DECLARE
    role_id UUID;
BEGIN
    IF p_role NOT IN ('management', 'coordinator', 'viewer') THEN
        RAISE EXCEPTION 'standard_role_unknown';
    END IF;

    INSERT INTO public.role (display_name, tenant_id)
    VALUES (p_role, p_tenant)
    RETURNING id INTO role_id;

    INSERT INTO public.role_permission (role_id, permission_id)
    SELECT role_id, p.id
    FROM public.permission p
    WHERE p.group_name IN (SELECT m.id FROM public.module m)
      AND CASE p_role
              WHEN 'management' THEN TRUE
              WHEN 'coordinator' THEN NOT (p.group_name = 'ops_setting' AND p.command = 'update'
                                           OR p.group_name IN ('role', 'user') AND p.command <> 'select'
                                           OR p.resource_name = 'public.tenant' AND p.command <> 'select'
                                           OR p.resource_name = 'public.media' AND p.command = 'delete'
                                           OR p.group_name = 'transfer')
              ELSE p.command = 'select'
                   AND (p.group_name IN ('product', 'project', 'purchase_order', 'shipment', 'market_matrix',
                                         'media', 'document')
                        OR p.resource_name = 'public.provider_relationship')
          END;

    PERFORM private.apply_field_defaults(role_id, p_role);
    RETURN role_id;
END;
$$;

-- The rehearsal.
--
-- private.transfer_refusal   The first reason the caller may not transfer from p_source to p_target in
--                            p_mode, or NULL, in this order:
--   1 transfer_mode_invalid          the mode is not copy or move;
--   2 transfer_same_tenant           the source is the target;
--   3 transfer_forbidden             the caller is not a member (tenant_user) or an owner
--                                    (private.owned_tenants) of both. No super-admin bypass (F6);
--   4 transfer_target_unavailable    the target is read-only (subscription expired or cancelled) or
--                                    its plan lacks the product module;
--   5 transfer_permissions_required  the table rights (private.tenants_granting: roles and the owner
--                                    role, no super-admin bypass): public.transfer insert in both; for
--                                    every registry table select in the source and insert and select
--                                    in the target (a copy_only table only where it has an insert
--                                    permission; select so that a conflict's existing_id never names a
--                                    target row the caller cannot read);
--                                    a move also delete in the source of every table it removes rows
--                                    from (not copy_only), or update where the table has no delete
--                                    permission at all (products and documents, which users never
--                                    delete: retiring them is an update);
--   6 transfer_field_rights_required the field rights, from the catalog: every field of every registry
--                                    table classified sensitive (client-visible ones included) read in
--                                    the source and written in the target, and for a move also written
--                                    in the source (private.transfer_field_granted: field_tenants, but
--                                    without the super-admin pass). A field the caller cannot read in
--                                    the source is never copied to where it could read it. A table or a
--                                    sensitive field added to the registry or the catalog is covered
--                                    without a code change;
--   7 transfer_source_read_only      a move out of a read-only source (a copy out of it is allowed);
--   8 transfer_files_pending         an earlier transfer into the target whose files are not all
--                                    copied yet (files_status pending or partial).
-- private.transfer_excluded  F5: supplier, supplier_contact and sourcing (cost, supplier identity and
--                            terms) never go into a tenant a provider procures for, nor into any
--                            client (active or ended) of the source; the report lists them. Both
--                            sides are matched by company: a relationship held anywhere in the
--                            source's company names a client anywhere in the target's company, so a
--                            branch of the provider (or a copy through one first) carries nothing
--                            the company itself could not.
-- private.transfer_collect   Fills pg_temp.transfer_rows and transfer_edges (dropped at commit) with
--                            the package, walked in registry order. Every row is the source's own
--                            (tenant_id = source): a shared row of another tenant never comes in.
--                            - The selected products, their variants and the parent of a selected
--                              variant; their market cells; their sourcing rows (the source's own,
--                              client_tenant_id IS NULL, product in the source);
--                            - the suppliers of that sourcing and their contacts, copy_only;
--                            - the documents and media links of a package row ((entity_type,
--                              entity_id)); the files they use, copy_only (another row may use them).
--                            A collected row carrying a client_tenant_id stops the run (an internal
--                            error: the filters above make it impossible).
-- private.transfer_references  The columns of the registry tables that hold the id of a row of a
--                            registry table, through the foreign keys between them.
-- private.transfer_omission_closure(s)  The package rows that go with seed rows: a NOT NULL reference,
--                            the registry parent or the entity naming one of them, and so on.
-- private.transfer_omitted   What the decisions leave out: the skipped rows with their closure, and
--                            the contacts, documents and media links of a mapped supplier.
-- private.transfer_unused_media  The files no written row uses.
-- private.transfer_report    The rehearsal's report. It holds counts, ids, table and column names and
--                            codes only: never a value of a row (no SKU, name, price or file name), so
--                            nothing the caller could not read reaches it:
--                            {mode, source_tenant, target_tenant, product_ids, counts, excluded,
--                             conflicts, left_behind, left_behind_links, cleared, settings_gaps, files,
--                             unresolved, report_hash}
--                            - counts {table: n}: the rows the run writes, after the decisions.
--                            - conflicts [{key, kind, table, source_id, existing_id, actions,
--                              skip_drops?, taken?}]: supplier_code (key supplier:<id>; map, new_code),
--                              sku (key sku:<id>; a SKU the target has: rename with a suffix, and skip
--                              in a copy), gtin (key gtin:<id>, a copy only: an active GTIN is unique
--                              across tenants; clear_gtin, skip). skip_drops {table: n} is what a skip
--                              takes with the row; taken marks a typed code or renamed SKU that another
--                              decision or another package row already uses.
--                            - left_behind [{table, column, refers_to, refers_to_id, rows, blocks}]:
--                              the source's rows outside the package that refer to a package row
--                              (through any foreign key, or an incident's entity), counted; blocks when
--                              a move could not remove the package row without breaking or deleting
--                              them (a move refuses then: transfer_product_in_use).
--                            - left_behind_links {table: n}: rows of other tenants that reference a
--                              package row through a client link (sourcing, purchase_order_line with
--                              product_tenant_id = source, an incident's entity_tenant_id): a move
--                              leaves them only their snapshot.
--                            - cleared [{table, column, refers_to, rows}]: package rows whose
--                              reference to a row outside the package a copy clears.
--                            - settings_gaps [{rule, table, source_id}]: products the target company's
--                              spec_sheet_required_from would hold back.
--                            - files: the files the run copies (with thumbnails).
--                            - unresolved: the conflicts without a valid decision.
--                            - report_hash: sha256 of the report, the target and the sorted products.
-- private.transfer_decision_error, transfer_check_decisions  A decision fits its conflict: an offered
--                            action; a map names a supplier of the target; a new supplier code is
--                            ^[A-Z]{2}[0-9]{1,3}$ and free in the target; a rename suffix is
--                            ^[A-Za-z0-9._-]{1,20}$ and the new SKU free in the target
--                            (transfer_code_invalid); 400 transfer_decision_invalid, then 409
--                            transfer_decision_required while a conflict is unresolved.
-- public.transfer_options    The caller's candidate targets out of a source, each with its refusal.
-- public.transfer_products   The entry point (SECURITY DEFINER, authenticated): refusal (400/403/409),
--                            the products (transfer_products_invalid), the package, a package file an
--                            earlier transfer into the source has not copied yet
--                            (transfer_files_pending), the report. A rehearsal returns the report; a
--                            real run checks the decisions and a move's blocking links, then refuses
--                            with transfer_apply_unavailable (501) until 073.

-- A refusal in the next_code pattern.
CREATE OR REPLACE FUNCTION private.transfer_raise (code TEXT, status INT) RETURNS VOID LANGUAGE plpgsql
SET
   search_path = '' AS $$
BEGIN
    RAISE SQLSTATE 'PGRST' USING
        MESSAGE = json_build_object('code', 'P0001', 'message', code)::TEXT,
        DETAIL = json_build_object('status', status, 'headers', json_build_object())::TEXT;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_raise (TEXT, INT) FROM PUBLIC, anon, authenticated;

-- A UUID from text, or NULL when the text is not one (decisions are user input).
CREATE OR REPLACE FUNCTION private.transfer_uuid (value TEXT) RETURNS UUID LANGUAGE plpgsql IMMUTABLE
SET
   search_path = '' AS $$
BEGIN
    RETURN value::UUID;
EXCEPTION WHEN invalid_text_representation THEN
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_uuid (TEXT) FROM PUBLIC, anon, authenticated;

-- private.field_tenants for one tenant, without its super-admin pass (rule 6: a super admin holds the
-- field rights its roles give it, like anyone). A field known not to be sensitive passes.
CREATE OR REPLACE FUNCTION private.transfer_field_granted (
   p_user UUID,
   p_tenant UUID,
   p_resource TEXT,
   p_field TEXT,
   p_write BOOLEAN
) RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF p_user IS NULL OR p_tenant IS NULL THEN
        RETURN FALSE;
    END IF;

    IF NOT private.check_super_admin(p_user) THEN
        RETURN coalesce(p_tenant = ANY (private.field_tenants(p_user, ARRAY[p_tenant], p_resource, p_field, p_write)), FALSE);
    END IF;

    -- A super admin: field_tenants' rules, its super-admin pass left out.
    RETURN EXISTS (
            SELECT 1 FROM public.field_class f
            WHERE f.resource_name = p_resource AND f.field = p_field AND f.class <> 'sensitive'
        )
        OR EXISTS (
            SELECT 1
            FROM public.user_role ur
            JOIN public.role r ON r.id = ur.role_id
            JOIN public.role_field_permission rfp ON rfp.role_id = r.id
            WHERE ur.user_id = p_user AND r.tenant_id = p_tenant
              AND EXISTS (SELECT 1 FROM public.tenant_user tu WHERE tu.user_id = p_user AND tu.tenant_id = r.tenant_id)
              AND rfp.resource_name = p_resource AND rfp.field = p_field
              AND CASE WHEN p_write THEN rfp.can_write ELSE rfp.can_read END
        )
        OR (NOT (p_write AND p_resource = 'public.user') AND p_tenant = ANY (private.owned_tenants(p_user)));
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_field_granted (UUID, UUID, TEXT, TEXT, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- The first refusal, or NULL (see the header).
CREATE OR REPLACE FUNCTION private.transfer_refusal (p_source UUID, p_target UUID, p_mode TEXT) RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    caller UUID := auth.uid();
    mine UUID[];
    e RECORD;
    source_writable BOOLEAN;
    target_writable BOOLEAN;
    target_modules TEXT[];
BEGIN
    -- 1, 2.
    IF p_mode IS NULL OR p_mode NOT IN ('copy', 'move') THEN
        RETURN 'transfer_mode_invalid';
    END IF;

    IF p_source IS NOT DISTINCT FROM p_target THEN
        RETURN 'transfer_same_tenant';
    END IF;

    -- 3. A member or an owner of both; nobody else, a super admin included (F6).
    IF caller IS NULL THEN
        RETURN 'transfer_forbidden';
    END IF;

    mine := ARRAY(
        SELECT tu.tenant_id FROM public.tenant_user tu WHERE tu.user_id = caller
        UNION
        SELECT o.id FROM unnest(private.owned_tenants(caller)) AS o (id)
    );

    IF NOT (ARRAY[p_source, p_target] <@ mine) THEN
        RETURN 'transfer_forbidden';
    END IF;

    -- 4. One read of both tenants' subscriptions.
    FOR e IN SELECT x.tenant_id, x.modules, x.writable FROM private.entitlements(ARRAY[p_source, p_target]) x LOOP
        IF e.tenant_id = p_source THEN
            source_writable := e.writable;
        ELSE
            target_writable := e.writable;
            target_modules := e.modules;
        END IF;
    END LOOP;

    IF NOT coalesce(target_writable, FALSE) OR NOT coalesce('product' = ANY (target_modules), FALSE) THEN
        RETURN 'transfer_target_unavailable';
    END IF;

    -- 5. Table rights.
    IF NOT (ARRAY[p_source, p_target] <@ private.tenants_granting(caller, ARRAY[p_source, p_target], 'public.transfer', 'insert'))
       OR EXISTS (
           SELECT 1 FROM private.transfer_registry r
           WHERE NOT (p_source = ANY (private.tenants_granting(caller, ARRAY[p_source], 'public.' || r.table_name, 'select')))
       )
       OR EXISTS (
           SELECT 1 FROM private.transfer_registry r
           WHERE (NOT r.copy_only OR EXISTS (
                      SELECT 1 FROM public.permission p
                      WHERE p.resource_name = 'public.' || r.table_name AND p.command = 'insert'
                  ))
             AND NOT (p_target = ANY (private.tenants_granting(caller, ARRAY[p_target], 'public.' || r.table_name, 'insert'))
                      AND p_target = ANY (private.tenants_granting(caller, ARRAY[p_target], 'public.' || r.table_name, 'select')))
       )
       OR (p_mode = 'move' AND EXISTS (
           SELECT 1 FROM private.transfer_registry r
           WHERE NOT r.copy_only
             AND NOT (p_source = ANY (private.tenants_granting(
                 caller, ARRAY[p_source], 'public.' || r.table_name,
                 CASE WHEN EXISTS (
                          SELECT 1 FROM public.permission p
                          WHERE p.resource_name = 'public.' || r.table_name AND p.command = 'delete'
                      ) THEN 'delete' ELSE 'update' END
             )))
       )) THEN
        RETURN 'transfer_permissions_required';
    END IF;

    -- 6. Field rights, from the catalog.
    IF EXISTS (
        SELECT 1
        FROM private.transfer_registry r
        JOIN public.field_class f ON f.resource_name = 'public.' || r.table_name AND f.class = 'sensitive'
        WHERE NOT private.transfer_field_granted(caller, p_source, f.resource_name, f.field, FALSE)
           OR NOT private.transfer_field_granted(caller, p_target, f.resource_name, f.field, TRUE)
           OR (p_mode = 'move' AND NOT private.transfer_field_granted(caller, p_source, f.resource_name, f.field, TRUE))
    ) THEN
        RETURN 'transfer_field_rights_required';
    END IF;

    -- 7.
    IF p_mode = 'move' AND NOT coalesce(source_writable, FALSE) THEN
        RETURN 'transfer_source_read_only';
    END IF;

    -- 8.
    IF EXISTS (SELECT 1 FROM public.transfer t WHERE t.tenant_id = p_target AND t.files_status <> 'done') THEN
        RETURN 'transfer_files_pending';
    END IF;

    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_refusal (UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- F5 (see the header): the procurement tables left out of this transfer.
CREATE OR REPLACE FUNCTION private.transfer_excluded (p_source UUID, p_target UUID) RETURNS TEXT[] LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    WITH source_company AS (
        SELECT e.company_id FROM private.entitlements(ARRAY[p_source]) e
    ),
    target_company AS (
        SELECT e.company_id FROM private.entitlements(ARRAY[p_target]) e
    )
    SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM public.provider_relationship r
        CROSS JOIN LATERAL (SELECT e.company_id FROM private.entitlements(ARRAY[r.client_tenant_id]) e) client
        CROSS JOIN LATERAL (SELECT e.company_id FROM private.entitlements(ARRAY[r.tenant_id]) e) provider
        WHERE r.status IN ('active', 'ended')
          AND client.company_id IN (SELECT t.company_id FROM target_company t)
          AND (r.procurement_model = 'provider' OR provider.company_id IN (SELECT c.company_id FROM source_company c))
    ) THEN ARRAY['supplier', 'supplier_contact', 'sourcing'] ELSE '{}'::TEXT[] END;
$$;

REVOKE ALL ON FUNCTION private.transfer_excluded (UUID, UUID) FROM PUBLIC, anon, authenticated;

-- The references between registry tables (see the header).
CREATE OR REPLACE FUNCTION private.transfer_references () RETURNS TABLE (
   table_name TEXT,
   column_name TEXT,
   ref_table TEXT,
   not_null BOOLEAN
) LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT DISTINCT rel.relname::TEXT, a.attname::TEXT, frel.relname::TEXT, a.attnotnull
    FROM pg_catalog.pg_constraint c
    JOIN pg_catalog.pg_class rel ON rel.oid = c.conrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = rel.relnamespace AND n.nspname = 'public'
    JOIN pg_catalog.pg_class frel ON frel.oid = c.confrelid
    JOIN pg_catalog.pg_namespace fn ON fn.oid = frel.relnamespace AND fn.nspname = 'public'
    JOIN private.transfer_registry fr ON fr.table_name = rel.relname
    JOIN private.transfer_registry tr ON tr.table_name = frel.relname
    CROSS JOIN LATERAL unnest(c.conkey, c.confkey) AS k (attnum, fattnum)
    JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    JOIN pg_catalog.pg_attribute fa ON fa.attrelid = c.confrelid AND fa.attnum = k.fattnum
    WHERE c.contype = 'f' AND fa.attname = 'id';
$$;

REVOKE ALL ON FUNCTION private.transfer_references () FROM PUBLIC, anon, authenticated;

-- The package into pg_temp.transfer_rows (see the header). p_exclude: the tables left out (F5).
CREATE OR REPLACE FUNCTION private.transfer_collect (p_source UUID, p_product_ids UUID[], p_exclude TEXT[] DEFAULT '{}') RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    products UUID[];
    suppliers UUID[];
    reg RECORD;
    from_sql TEXT;
    where_sql TEXT;
    copy_expr TEXT;
    -- A polymorphic row %1$s (entity_type, entity_id) naming a package row.
    entity_match CONSTANT TEXT :=
        'SELECT p.copy_only FROM private.transfer_registry e '
        'JOIN pg_temp.transfer_rows p ON p.table_name = e.table_name AND p.source_id = %1$s.entity_id '
        'WHERE e.entity = %1$s.entity_type LIMIT 1';
BEGIN
    IF to_regclass('pg_temp.transfer_edges') IS NOT NULL THEN
        DROP TABLE pg_temp.transfer_edges;
    END IF;

    IF to_regclass('pg_temp.transfer_rows') IS NOT NULL THEN
        DROP TABLE pg_temp.transfer_rows;
    END IF;

    CREATE TEMP TABLE transfer_rows (
        seq BIGSERIAL PRIMARY KEY,
        table_name TEXT NOT NULL,
        source_id UUID NOT NULL,
        row JSONB NOT NULL,
        copy_only BOOLEAN NOT NULL,
        UNIQUE (table_name, source_id)
    ) ON COMMIT DROP;

    -- The selected products, their variants and the parent of each selected variant.
    products := ARRAY(
        SELECT p.id FROM public.product p
        WHERE p.tenant_id = p_source
          AND (
              p.id = ANY (p_product_ids)
              OR p.parent_id = ANY (p_product_ids)
              OR p.id IN (SELECT s.parent_id FROM public.product s WHERE s.tenant_id = p_source AND s.id = ANY (p_product_ids))
          )
    );

    -- The suppliers of the source's own sourcing of those products.
    suppliers := ARRAY(
        SELECT DISTINCT s.supplier_id FROM public.sourcing s
        WHERE s.tenant_id = p_source AND s.client_tenant_id IS NULL AND s.product_tenant_id = p_source
          AND s.product_id = ANY (products) AND s.supplier_id IS NOT NULL
          AND NOT ('sourcing' = ANY (coalesce(p_exclude, '{}')))
    );

    FOR reg IN
        SELECT * FROM private.transfer_registry r
        WHERE NOT (r.table_name = ANY (coalesce(p_exclude, '{}')))
        ORDER BY r.position
    LOOP
        from_sql := format('public.%I x', reg.table_name);
        where_sql := 'TRUE';

        IF reg.table_name = 'supplier' THEN
            where_sql := 'x.id = ANY ($3)';
            copy_expr := 'TRUE';
        ELSIF reg.table_name = 'product' THEN
            where_sql := 'x.id = ANY ($2)';
            copy_expr := 'FALSE';
        ELSIF reg.table_name = 'sourcing' THEN
            -- The source's own rows only: never one it shares with a client (F5).
            where_sql := 'x.client_tenant_id IS NULL AND x.product_tenant_id = $1 AND x.product_id = ANY ($2)';
            copy_expr := 'FALSE';
        ELSIF reg.table_name = 'media' THEN
            -- The links and documents are collected later in the walk; they are matched here the same
            -- way, against the entity rows already in.
            where_sql := format(
                'EXISTS (SELECT 1 FROM public.media_link l WHERE l.tenant_id = $1 AND l.media_id = x.id AND EXISTS (%s)) '
                'OR EXISTS (SELECT 1 FROM public.document d WHERE d.tenant_id = $1 AND d.media_id = x.id AND EXISTS (%s))',
                format(entity_match, 'l'),
                format(entity_match, 'd')
            );
            copy_expr := 'TRUE';
        ELSIF reg.parent_column = 'entity' THEN
            from_sql := from_sql || format(' JOIN LATERAL (%s) p ON TRUE', format(entity_match, 'x'));
            copy_expr := 'p.copy_only';
        ELSE
            from_sql := from_sql || format(
                ' JOIN pg_temp.transfer_rows p ON p.table_name = %L AND p.source_id = x.%I',
                reg.parent_table,
                reg.parent_column
            );
            copy_expr := 'p.copy_only';
        END IF;

        EXECUTE format(
            'INSERT INTO pg_temp.transfer_rows (table_name, source_id, row, copy_only) '
            'SELECT %L, x.id, to_jsonb(x), %s FROM %s WHERE x.tenant_id = $1 AND (%s)',
            reg.table_name, copy_expr, from_sql, where_sql
        )
        USING p_source, products, suppliers;
    END LOOP;

    -- Defence in depth: no shared row, no row of another tenant (the filters above).
    IF EXISTS (
        SELECT 1 FROM pg_temp.transfer_rows r
        WHERE r.row ->> 'tenant_id' IS DISTINCT FROM p_source::TEXT OR r.row ->> 'client_tenant_id' IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'transfer_package_invalid';
    END IF;

    -- The edges of transfer_omission_closure, found once: a row (child) whose NOT NULL reference or
    -- registry parent names a package row (parent), and a document or media link whose entity is one.
    CREATE TEMP TABLE transfer_edges (
        parent BIGINT NOT NULL,
        child BIGINT NOT NULL,
        PRIMARY KEY (parent, child)
    ) ON COMMIT DROP;

    INSERT INTO pg_temp.transfer_edges (parent, child)
    SELECT o.seq, r.seq
    FROM private.transfer_references() f
    JOIN pg_temp.transfer_rows r ON r.table_name = f.table_name
    JOIN pg_temp.transfer_rows o ON o.table_name = f.ref_table AND o.source_id::TEXT = r.row ->> f.column_name
    WHERE f.not_null
    UNION
    SELECT o.seq, r.seq
    FROM pg_temp.transfer_rows r
    JOIN private.transfer_registry g ON g.table_name = r.table_name AND g.parent_table IS NOT NULL
    JOIN pg_temp.transfer_rows o ON o.table_name = g.parent_table AND o.source_id::TEXT = r.row ->> g.parent_column
    UNION
    SELECT o.seq, r.seq
    FROM pg_temp.transfer_rows r
    JOIN private.transfer_registry e ON e.entity IS NOT NULL AND e.entity::TEXT = r.row ->> 'entity_type'
    JOIN pg_temp.transfer_rows o ON o.table_name = e.table_name AND o.source_id::TEXT = r.row ->> 'entity_id'
    WHERE r.table_name IN ('document', 'media_link');

    ANALYZE pg_temp.transfer_rows;
    ANALYZE pg_temp.transfer_edges;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_collect (UUID, UUID[], TEXT[]) FROM PUBLIC, anon, authenticated;

-- The rows that go with each seed row, seeds included, in one walk: (seed, seq).
CREATE OR REPLACE FUNCTION private.transfer_omission_closures (seeds BIGINT[]) RETURNS TABLE (seed BIGINT, seq BIGINT) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE omitted (seed, seq) AS (
        SELECT r.seq, r.seq FROM pg_temp.transfer_rows r WHERE r.seq = ANY (transfer_omission_closures.seeds)
        UNION
        SELECT o.seed, e.child FROM omitted o JOIN pg_temp.transfer_edges e ON e.parent = o.seq
    )
    SELECT o.seed, o.seq FROM omitted o;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_omission_closures (BIGINT[]) FROM PUBLIC, anon, authenticated;

-- The rows that go with the seed rows, seeds included.
CREATE OR REPLACE FUNCTION private.transfer_omission_closure (seeds BIGINT[]) RETURNS TABLE (seq BIGINT) LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT DISTINCT c.seq FROM private.transfer_omission_closures(seeds) c;
$$;

REVOKE ALL ON FUNCTION private.transfer_omission_closure (BIGINT[]) FROM PUBLIC, anon, authenticated;

-- The rows the decisions leave out (see the header): the skipped rows and what goes with them, and
-- the contacts, documents and media links of a mapped supplier.
CREATE OR REPLACE FUNCTION private.transfer_omitted (conflicts JSONB, decisions JSONB) RETURNS TABLE (seq BIGINT) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    picks JSONB := CASE WHEN jsonb_typeof(decisions) = 'object' THEN decisions ELSE '{}'::JSONB END;
BEGIN
    RETURN QUERY
    SELECT c.seq FROM private.transfer_omission_closure(ARRAY(
        SELECT r.seq
        FROM jsonb_array_elements(coalesce(conflicts, '[]')) k
        JOIN pg_temp.transfer_rows r ON r.table_name = k ->> 'table' AND r.source_id::TEXT = k ->> 'source_id'
        WHERE k -> 'actions' ? 'skip' AND picks -> (k ->> 'key') ->> 'action' = 'skip'
        UNION
        SELECT r.seq
        FROM pg_temp.transfer_rows r
        JOIN pg_temp.transfer_rows s ON s.table_name = 'supplier'
         AND picks -> ('supplier:' || s.source_id) ->> 'action' = 'map'
        WHERE (r.table_name = 'supplier_contact' AND r.row ->> 'supplier_id' = s.source_id::TEXT)
           OR (r.table_name IN ('document', 'media_link') AND r.row ->> 'entity_type' = 'supplier'
               AND r.row ->> 'entity_id' = s.source_id::TEXT)
    )) c;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_omitted (JSONB, JSONB) FROM PUBLIC, anon, authenticated;

-- The files no written row uses: every row that uses it (a link or a document) is omitted.
CREATE OR REPLACE FUNCTION private.transfer_unused_media (conflicts JSONB, decisions JSONB) RETURNS TABLE (source_id UUID) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    omitted BIGINT[] := ARRAY(SELECT o.seq FROM private.transfer_omitted(conflicts, decisions) o);
BEGIN
    RETURN QUERY
    SELECT f.source_id
    FROM pg_temp.transfer_rows f
    WHERE f.table_name = 'media'
      AND NOT EXISTS (
          SELECT 1 FROM pg_temp.transfer_rows u
          WHERE u.table_name IN ('media_link', 'document') AND u.row ->> 'media_id' = f.source_id::TEXT
            AND NOT u.seq = ANY (omitted)
      );
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_unused_media (JSONB, JSONB) FROM PUBLIC, anon, authenticated;

-- The values a decision types: a new supplier code, or the SKU a rename gives.
CREATE OR REPLACE FUNCTION private.transfer_typed (conflict JSONB, decision JSONB) RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF jsonb_typeof(decision) IS DISTINCT FROM 'object' THEN
        RETURN NULL;
    END IF;

    IF conflict ->> 'kind' = 'supplier_code' AND decision ->> 'action' = 'new_code' THEN
        RETURN decision ->> 'code';
    END IF;

    IF conflict ->> 'kind' = 'sku' AND decision ->> 'action' = 'rename' THEN
        RETURN (
            SELECT (r.row ->> 'sku') || (decision ->> 'suffix')
            FROM pg_temp.transfer_rows r
            WHERE r.table_name = 'product' AND r.source_id::TEXT = conflict ->> 'source_id'
        );
    END IF;

    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_typed (JSONB, JSONB) FROM PUBLIC, anon, authenticated;

-- Why a decision does not settle its conflict, or NULL when it does (see the header).
CREATE OR REPLACE FUNCTION private.transfer_decision_error (conflict JSONB, decision JSONB, target_tenant UUID) RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    kind TEXT := conflict ->> 'kind';
    action TEXT;
    typed TEXT;
BEGIN
    IF decision IS NULL THEN
        RETURN 'transfer_decision_required';
    END IF;

    IF jsonb_typeof(decision) <> 'object' THEN
        RETURN 'transfer_decision_invalid';
    END IF;

    action := decision ->> 'action';

    IF action IS NULL OR NOT (conflict -> 'actions') ? action THEN
        RETURN 'transfer_decision_invalid';
    END IF;

    IF action = 'map' THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.supplier s
            WHERE s.id = private.transfer_uuid(decision ->> 'target_id') AND s.tenant_id = target_tenant
        ) THEN
            RETURN 'transfer_decision_invalid';
        END IF;
    ELSIF action = 'new_code' THEN
        typed := decision ->> 'code';
        IF typed IS NULL OR typed !~ '^[A-Z]{2}[0-9]{1,3}$'
           OR EXISTS (SELECT 1 FROM public.supplier s WHERE s.tenant_id = target_tenant AND s.code = typed) THEN
            RETURN 'transfer_code_invalid';
        END IF;
    ELSIF action = 'rename' THEN
        IF coalesce(decision ->> 'suffix', '') !~ '^[A-Za-z0-9._-]{1,20}$' THEN
            RETURN 'transfer_code_invalid';
        END IF;
        typed := private.transfer_typed(conflict, decision);
        IF typed IS NULL OR EXISTS (SELECT 1 FROM public.product p WHERE p.tenant_id = target_tenant AND p.sku = typed) THEN
            RETURN 'transfer_code_invalid';
        END IF;
    END IF;

    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_decision_error (JSONB, JSONB, UUID) FROM PUBLIC, anon, authenticated;

-- The conflict keys whose typed value another decision or another package row already uses: two
-- typed alike in one table, or one equal to the code or SKU of a package row written with it.
CREATE OR REPLACE FUNCTION private.transfer_taken (conflicts JSONB, decisions JSONB) RETURNS TABLE (conflict_key TEXT) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    RETURN QUERY
    WITH picks AS (
        SELECT CASE WHEN jsonb_typeof(decisions) = 'object' THEN decisions ELSE '{}'::JSONB END AS p
    ),
    typed AS (
        SELECT c ->> 'key' AS key, c ->> 'table' AS tbl, c ->> 'source_id' AS source_id,
               private.transfer_typed(c, (SELECT p FROM picks) -> (c ->> 'key')) AS value
        FROM jsonb_array_elements(coalesce(conflicts, '[]')) c
    ),
    -- A package row keeps its code or SKU unless a decision renames, recodes, maps or skips it.
    kept AS (
        SELECT r.table_name AS tbl, r.source_id::TEXT AS source_id,
               CASE r.table_name WHEN 'supplier' THEN r.row ->> 'code' ELSE r.row ->> 'sku' END AS value
        FROM pg_temp.transfer_rows r
        WHERE r.table_name IN ('supplier', 'product')
          AND NOT EXISTS (SELECT 1 FROM typed t WHERE t.tbl = r.table_name AND t.source_id = r.source_id::TEXT AND t.value IS NOT NULL)
          AND coalesce((SELECT p FROM picks) -> ((CASE r.table_name WHEN 'supplier' THEN 'supplier:' ELSE 'sku:' END) || r.source_id) ->> 'action', '')
              NOT IN ('map', 'skip')
          AND coalesce((SELECT p FROM picks) -> ('gtin:' || r.source_id) ->> 'action', '') <> 'skip'
    )
    SELECT t.key FROM typed t
    WHERE t.value IS NOT NULL
      AND (EXISTS (SELECT 1 FROM typed o WHERE o.tbl = t.tbl AND o.key <> t.key AND o.value = t.value)
           OR EXISTS (SELECT 1 FROM kept k WHERE k.tbl = t.tbl AND k.source_id <> t.source_id AND k.value = t.value));
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_taken (JSONB, JSONB) FROM PUBLIC, anon, authenticated;

-- The report of the collected package (see the header).
CREATE OR REPLACE FUNCTION private.transfer_report (
   p_source UUID,
   p_target UUID,
   p_mode TEXT,
   p_decisions JSONB,
   p_product_ids UUID[],
   p_excluded TEXT[] DEFAULT '{}'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    picks JSONB := CASE WHEN jsonb_typeof(p_decisions) = 'object' THEN p_decisions ELSE '{}'::JSONB END;
    conflicts JSONB := '[]';
    taken TEXT[];
    fk RECORD;
    part JSONB;
    left_behind JSONB := '[]';
    links JSONB := '[]';
    cleared JSONB := '[]';
    required_from DATE;
    gaps JSONB;
    files BIGINT;
    unused_media UUID[];
    omitted BIGINT[];
    counts JSONB;
    unresolved BIGINT;
    report JSONB;
BEGIN
    -- The suppliers' codes.
    conflicts := conflicts || coalesce((
        SELECT jsonb_agg(jsonb_build_object(
            'key', 'supplier:' || r.source_id, 'kind', 'supplier_code', 'table', 'supplier', 'source_id', r.source_id,
            'existing_id', s.id, 'actions', '["map", "new_code"]'::JSONB
        ))
        FROM pg_temp.transfer_rows r
        JOIN public.supplier s ON s.tenant_id = p_target AND s.code = r.row ->> 'code'
        WHERE r.table_name = 'supplier'
    ), '[]');

    -- The SKUs the target already has.
    conflicts := conflicts || coalesce((
        SELECT jsonb_agg(jsonb_build_object(
            'key', 'sku:' || r.source_id, 'kind', 'sku', 'table', 'product', 'source_id', r.source_id,
            'existing_id', p.id,
            'actions', CASE p_mode WHEN 'copy' THEN '["rename", "skip"]'::JSONB ELSE '["rename"]'::JSONB END
        ))
        FROM pg_temp.transfer_rows r
        JOIN public.product p ON p.tenant_id = p_target AND p.sku = r.row ->> 'sku'
        WHERE r.table_name = 'product'
    ), '[]');

    -- An active GTIN is unique across tenants, so a copy cannot keep it.
    IF p_mode = 'copy' THEN
        conflicts := conflicts || coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                'key', 'gtin:' || r.source_id, 'kind', 'gtin', 'table', 'product', 'source_id', r.source_id,
                'existing_id', NULL, 'actions', '["clear_gtin", "skip"]'::JSONB
            ))
            FROM pg_temp.transfer_rows r
            WHERE r.table_name = 'product' AND r.row ->> 'gtin' IS NOT NULL AND r.row ->> 'status' <> 'archived'
        ), '[]');
    END IF;

    -- What a skip drops with the row: the closures of every skippable conflict's row, in one walk.
    WITH seeded AS (
        SELECT c ->> 'key' AS key, s.seq
        FROM jsonb_array_elements(conflicts) c
        JOIN pg_temp.transfer_rows s ON s.table_name = c ->> 'table' AND s.source_id::TEXT = c ->> 'source_id'
        WHERE c -> 'actions' ? 'skip'
    ),
    drops AS (
        SELECT k.key, jsonb_object_agg(k.table_name, k.n) AS skip_drops
        FROM (
            SELECT d.key, r.table_name, count(DISTINCT o.seq) AS n
            FROM seeded d
            JOIN private.transfer_omission_closures(ARRAY(SELECT x.seq FROM seeded x)) o ON o.seed = d.seq
            JOIN pg_temp.transfer_rows r ON r.seq = o.seq
            WHERE o.seq <> o.seed
            GROUP BY d.key, r.table_name
        ) k
        GROUP BY k.key
    )
    SELECT coalesce(jsonb_agg(CASE WHEN c -> 'actions' ? 'skip'
                                   THEN c || jsonb_build_object('skip_drops', coalesce(d.skip_drops, '{}'::JSONB))
                                   ELSE c END
                              ORDER BY g.position, c ->> 'kind', c ->> 'source_id'), '[]')
    INTO conflicts
    FROM jsonb_array_elements(conflicts) c
    JOIN private.transfer_registry g ON g.table_name = c ->> 'table'
    LEFT JOIN drops d ON d.key = c ->> 'key';

    -- A typed value another decision or package row already uses: the conflict stays unresolved.
    taken := ARRAY(SELECT t.conflict_key FROM private.transfer_taken(conflicts, picks) t);
    conflicts := coalesce((
        SELECT jsonb_agg(CASE WHEN c.c ->> 'key' = ANY (taken) THEN c.c || '{"taken": true}'::JSONB ELSE c.c END ORDER BY c.n)
        FROM jsonb_array_elements(conflicts) WITH ORDINALITY AS c (c, n)
    ), '[]');

    SELECT count(*) INTO unresolved
    FROM jsonb_array_elements(conflicts) c
    WHERE private.transfer_decision_error(c, picks -> (c ->> 'key'), p_target) IS NOT NULL
       OR c ? 'taken';

    -- The source's rows outside the package that refer to a package row (removed by a move), through
    -- every foreign key into a registry table: counted by referring table, column and package row
    -- (left_behind), or, for another tenant's row linked through its own tenant column (a client
    -- link), counted by table (left_behind_links).
    FOR fk IN
        SELECT rel.relname::TEXT AS from_table, frel.relname::TEXT AS to_table, c.confdeltype,
               (SELECT a.attname::TEXT FROM unnest(c.conkey, c.confkey) WITH ORDINALITY AS k (f, t, i)
                JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.f
                JOIN pg_catalog.pg_attribute ta ON ta.attrelid = c.confrelid AND ta.attnum = k.t
                WHERE ta.attname = 'id' ORDER BY k.i LIMIT 1) AS ref_col,
               (SELECT a.attname::TEXT FROM unnest(c.conkey, c.confkey) WITH ORDINALITY AS k (f, t, i)
                JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.f
                JOIN pg_catalog.pg_attribute ta ON ta.attrelid = c.confrelid AND ta.attnum = k.t
                WHERE ta.attname = 'tenant_id' ORDER BY k.i LIMIT 1) AS tenant_col,
               EXISTS (SELECT 1 FROM private.transfer_registry g WHERE g.table_name = rel.relname) AS registered
        FROM pg_catalog.pg_constraint c
        JOIN pg_catalog.pg_class rel ON rel.oid = c.conrelid AND rel.relkind = 'r'
        JOIN pg_catalog.pg_namespace n ON n.oid = rel.relnamespace AND n.nspname = 'public'
        JOIN pg_catalog.pg_class frel ON frel.oid = c.confrelid
        JOIN pg_catalog.pg_namespace fn ON fn.oid = frel.relnamespace AND fn.nspname = 'public'
        JOIN private.transfer_registry tr ON tr.table_name = frel.relname
        WHERE c.contype = 'f'
        ORDER BY 1, 4, 2
    LOOP
        CONTINUE WHEN fk.ref_col IS NULL;

        EXECUTE format(
            'SELECT coalesce(jsonb_agg(jsonb_build_object(''same'', g.same, ''refers_to_id'', g.ref_id, ''rows'', g.n)), ''[]'') '
            'FROM (SELECT x.tenant_id = $1 AS same, x.%2$I AS ref_id, count(*) AS n FROM public.%1$I x '
            'WHERE x.%3$I = $1 AND x.%2$I IN (SELECT r.source_id FROM pg_temp.transfer_rows r WHERE r.table_name = %4$L AND NOT r.copy_only) '
            '%5$s GROUP BY 1, 2) g',
            fk.from_table,
            fk.ref_col,
            coalesce(fk.tenant_col, 'tenant_id'),
            fk.to_table,
            CASE WHEN fk.registered
                 THEN format('AND NOT EXISTS (SELECT 1 FROM pg_temp.transfer_rows q WHERE q.table_name = %L AND q.source_id = x.id)', fk.from_table)
                 ELSE '' END
        )
        INTO part
        USING p_source;

        left_behind := left_behind || coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                'table', fk.from_table, 'column', fk.ref_col, 'refers_to', fk.to_table,
                'refers_to_id', e ->> 'refers_to_id', 'rows', (e ->> 'rows')::INT,
                -- The delete a move makes would fail (restrict, no action) or take them along (cascade).
                'blocks', fk.confdeltype IN ('r', 'a', 'c')
            ))
            FROM jsonb_array_elements(part) e WHERE (e ->> 'same')::BOOLEAN
        ), '[]');

        links := links || coalesce((
            SELECT jsonb_agg(jsonb_build_object('table', fk.from_table, 'rows', (e ->> 'rows')::INT))
            FROM jsonb_array_elements(part) e WHERE NOT (e ->> 'same')::BOOLEAN
        ), '[]');
    END LOOP;

    -- An entity reference from a table outside the registry (an incident on a product): no foreign key
    -- holds it, so a move would leave it dangling. Its tenant column is entity_tenant_id when it has one.
    FOR fk IN
        SELECT c.table_name::TEXT AS from_table,
               EXISTS (SELECT 1 FROM information_schema.columns t
                       WHERE t.table_schema = 'public' AND t.table_name = c.table_name AND t.column_name = 'entity_tenant_id') AS has_entity_tenant
        FROM information_schema.columns c
        JOIN information_schema.tables b ON b.table_schema = c.table_schema AND b.table_name = c.table_name AND b.table_type = 'BASE TABLE'
        WHERE c.table_schema = 'public' AND c.column_name = 'entity_type' AND c.udt_name = 'document_entity'
          AND c.table_name NOT IN (SELECT g.table_name FROM private.transfer_registry g)
        ORDER BY 1
    LOOP
        EXECUTE format(
            'SELECT coalesce(jsonb_agg(jsonb_build_object(''same'', g.same, ''refers_to'', g.refers_to, ''refers_to_id'', g.ref_id, ''rows'', g.n)), ''[]'') '
            'FROM (SELECT x.tenant_id = $1 AS same, e.table_name AS refers_to, x.entity_id AS ref_id, count(*) AS n FROM public.%1$I x '
            'JOIN private.transfer_registry e ON e.entity = x.entity_type '
            'JOIN pg_temp.transfer_rows r ON r.table_name = e.table_name AND r.source_id = x.entity_id AND NOT r.copy_only '
            'WHERE %2$s = $1 GROUP BY 1, 2, 3) g',
            fk.from_table,
            CASE WHEN fk.has_entity_tenant THEN 'coalesce(x.entity_tenant_id, x.tenant_id)' ELSE 'x.tenant_id' END
        )
        INTO part
        USING p_source;

        left_behind := left_behind || coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                'table', fk.from_table, 'column', 'entity_id', 'refers_to', e ->> 'refers_to',
                'refers_to_id', e ->> 'refers_to_id', 'rows', (e ->> 'rows')::INT, 'blocks', TRUE
            ))
            FROM jsonb_array_elements(part) e WHERE (e ->> 'same')::BOOLEAN
        ), '[]');

        links := links || coalesce((
            SELECT jsonb_agg(jsonb_build_object('table', fk.from_table, 'rows', (e ->> 'rows')::INT))
            FROM jsonb_array_elements(part) e WHERE NOT (e ->> 'same')::BOOLEAN
        ), '[]');
    END LOOP;

    left_behind := coalesce((
        SELECT jsonb_agg(e ORDER BY e ->> 'table', e ->> 'column', e ->> 'refers_to', e ->> 'refers_to_id')
        FROM jsonb_array_elements(left_behind) e
    ), '[]');

    -- The package rows whose reference to a tenant's row outside the package a copy clears (a foreign
    -- key paired with the tenant; a reference to shared reference data, such as a platform, stays).
    FOR fk IN
        SELECT DISTINCT rel.relname::TEXT AS from_table, frel.relname::TEXT AS to_table, a.attname::TEXT AS ref_col
        FROM pg_catalog.pg_constraint c
        JOIN pg_catalog.pg_class rel ON rel.oid = c.conrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = rel.relnamespace AND n.nspname = 'public'
        JOIN pg_catalog.pg_class frel ON frel.oid = c.confrelid
        JOIN private.transfer_registry fr ON fr.table_name = rel.relname
        CROSS JOIN LATERAL unnest(c.conkey, c.confkey) AS k (f, t)
        JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.f
        JOIN pg_catalog.pg_attribute ta ON ta.attrelid = c.confrelid AND ta.attnum = k.t
        WHERE c.contype = 'f' AND ta.attname = 'id'
          AND EXISTS (
              SELECT 1 FROM unnest(c.confkey) AS tk (attnum)
              JOIN pg_catalog.pg_attribute tt ON tt.attrelid = c.confrelid AND tt.attnum = tk.attnum
              WHERE tt.attname = 'tenant_id'
          )
        ORDER BY 1, 3
    LOOP
        cleared := cleared || coalesce((
            SELECT jsonb_build_array(jsonb_build_object(
                'table', fk.from_table, 'column', fk.ref_col, 'refers_to', fk.to_table, 'rows', count(*)
            ))
            FROM pg_temp.transfer_rows p
            WHERE p.table_name = fk.from_table AND p.row ->> fk.ref_col IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM pg_temp.transfer_rows q
                  WHERE q.table_name = fk.to_table AND q.source_id::TEXT = p.row ->> fk.ref_col
              )
            HAVING count(*) > 0
        ), '[]');
    END LOOP;

    -- The products the target's settings would hold back for a spec sheet.
    BEGIN
        required_from := (private.company_setting(p_target, 'spec_sheet_required_from') #>> '{}')::DATE;
    EXCEPTION WHEN data_exception THEN
        required_from := NULL;
    END;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'rule', 'spec_sheet_required', 'table', 'product', 'source_id', r.source_id
    ) ORDER BY r.source_id), '[]')
    INTO gaps
    FROM pg_temp.transfer_rows r
    WHERE r.table_name = 'product'
      AND (required_from IS NULL OR current_date >= required_from
           OR r.row ->> 'status' IN ('concept', 'development', 'approved'))
      AND NOT EXISTS (
          SELECT 1 FROM pg_temp.transfer_rows d
          WHERE d.table_name = 'document' AND d.row ->> 'entity_type' = 'product'
            AND d.row ->> 'entity_id' = r.source_id::TEXT
            AND d.row ->> 'type' = 'spec_sheet' AND d.row ->> 'status' = 'signed'
      );

    omitted := ARRAY(SELECT o.seq FROM private.transfer_omitted(conflicts, picks) o);
    unused_media := ARRAY(SELECT u.source_id FROM private.transfer_unused_media(conflicts, picks) u);

    -- The files the run copies: not those only omitted rows use.
    SELECT count(*) + count(r.row ->> 'thumbnail_path') INTO files
    FROM pg_temp.transfer_rows r
    WHERE r.table_name = 'media' AND NOT r.source_id = ANY (unused_media);

    -- The rows the run writes, by table: not an omitted row, a mapped supplier, or a file not copied.
    SELECT coalesce(jsonb_object_agg(t.table_name, t.n), '{}') INTO counts
    FROM (
        SELECT r.table_name, count(*) AS n
        FROM pg_temp.transfer_rows r
        WHERE NOT r.seq = ANY (omitted)
          AND NOT (r.table_name = 'supplier' AND coalesce(picks -> ('supplier:' || r.source_id) ->> 'action', '') = 'map')
          AND NOT (r.table_name = 'media' AND r.source_id = ANY (unused_media))
        GROUP BY r.table_name
    ) t;

    report := jsonb_build_object(
        'mode', p_mode,
        'source_tenant', p_source,
        'target_tenant', p_target,
        'product_ids', (SELECT coalesce(to_jsonb(array_agg(DISTINCT p ORDER BY p)), '[]'::JSONB) FROM unnest(p_product_ids) AS p),
        'counts', counts,
        'excluded', to_jsonb(coalesce(p_excluded, '{}'::TEXT[])),
        'conflicts', conflicts,
        'left_behind', left_behind,
        'left_behind_links', coalesce((
            SELECT jsonb_object_agg(l.tbl, l.n)
            FROM (SELECT e ->> 'table' AS tbl, sum((e ->> 'rows')::INT) AS n FROM jsonb_array_elements(links) e GROUP BY 1) l
        ), '{}'),
        'cleared', cleared,
        'settings_gaps', gaps,
        'files', files,
        'unresolved', unresolved
    );

    RETURN report || jsonb_build_object('report_hash', encode(sha256(convert_to(report::TEXT, 'UTF8')), 'hex'));
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_report (UUID, UUID, TEXT, JSONB, UUID[], TEXT[]) FROM PUBLIC, anon, authenticated;

-- The decisions of a real run against its report (see the header).
CREATE OR REPLACE FUNCTION private.transfer_check_decisions (report JSONB, decisions JSONB, target_tenant UUID, mode TEXT) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    pick RECORD;
    conflict JSONB;
    failure TEXT;
BEGIN
    IF decisions IS NOT NULL AND jsonb_typeof(decisions) <> 'object' THEN
        PERFORM private.transfer_raise('transfer_decision_invalid', 400);
    END IF;

    FOR pick IN SELECT d.key, d.value FROM jsonb_each(coalesce(decisions, '{}'::JSONB)) d ORDER BY d.key LOOP
        conflict := NULL;
        SELECT c INTO conflict FROM jsonb_array_elements(report -> 'conflicts') c WHERE c ->> 'key' = pick.key;

        IF conflict IS NULL THEN
            -- A package supplier may be mapped without a conflict.
            IF pick.key LIKE 'supplier:%'
               AND jsonb_typeof(pick.value) = 'object'
               AND pick.value ->> 'action' = 'map'
               AND EXISTS (
                   SELECT 1 FROM pg_temp.transfer_rows r
                   WHERE r.table_name = 'supplier' AND r.source_id = private.transfer_uuid(substr(pick.key, 10))
               )
               AND EXISTS (
                   SELECT 1 FROM public.supplier s
                   WHERE s.tenant_id = target_tenant AND s.id = private.transfer_uuid(pick.value ->> 'target_id')
               ) THEN
                failure := NULL;
            ELSE
                failure := 'transfer_decision_invalid';
            END IF;
        -- Defence in depth: a move's conflicts never offer skip.
        ELSIF mode = 'move' AND jsonb_typeof(pick.value) = 'object' AND pick.value ->> 'action' = 'skip' THEN
            failure := 'transfer_decision_invalid';
        ELSE
            -- A JSON null is a decision that does not fit, not a missing one.
            failure := coalesce(
                nullif(private.transfer_decision_error(conflict, pick.value, target_tenant), 'transfer_decision_required'),
                CASE WHEN jsonb_typeof(pick.value) = 'null' THEN 'transfer_decision_invalid' END
            );
        END IF;

        IF failure IS NOT NULL THEN
            PERFORM private.transfer_raise(failure, 400);
        END IF;
    END LOOP;

    IF EXISTS (SELECT 1 FROM jsonb_array_elements(report -> 'conflicts') c WHERE c ? 'taken') THEN
        PERFORM private.transfer_raise('transfer_code_invalid', 400);
    END IF;

    IF (report ->> 'unresolved')::INT > 0 THEN
        PERFORM private.transfer_raise('transfer_decision_required', 409);
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION private.transfer_check_decisions (JSONB, JSONB, UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- The caller's candidate targets out of source_tenant (each tenant the caller is a member or an owner
-- of, but the source), each with the refusal of a copy into it. Nothing for a source the caller is
-- not in.
CREATE OR REPLACE FUNCTION public.transfer_options (source_tenant UUID) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    caller UUID := auth.uid();
    mine UUID[];
    source_e RECORD;
BEGIN
    mine := ARRAY(
        SELECT tu.tenant_id FROM public.tenant_user tu WHERE tu.user_id = caller
        UNION
        SELECT o.id FROM unnest(private.owned_tenants(caller)) AS o (id)
    );

    IF caller IS NULL OR source_tenant IS NULL OR NOT (source_tenant = ANY (mine)) THEN
        RETURN jsonb_build_object('source_writable', FALSE, 'targets', '[]'::JSONB);
    END IF;

    SELECT e.company_id, e.writable INTO source_e FROM private.entitlements(ARRAY[source_tenant]) e;

    RETURN jsonb_build_object(
        'source_writable', coalesce(source_e.writable, FALSE),
        'targets', coalesce((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'id', t.id,
                    'display_name', t.display_name,
                    'same_company', e.company_id IS NOT DISTINCT FROM source_e.company_id,
                    'refusal', private.transfer_refusal(transfer_options.source_tenant, t.id, 'copy')
                )
                ORDER BY t.display_name, t.id
            )
            FROM public.tenant t
            JOIN private.entitlements(mine) e ON e.tenant_id = t.id
            WHERE t.id = ANY (mine) AND t.id <> transfer_options.source_tenant
        ), '[]'::JSONB)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.transfer_options (UUID) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.transfer_options (UUID) TO authenticated;

-- The entry point (see the header). SECURITY DEFINER: the package is read past the caller's RLS once
-- the gate has passed; the report it returns holds counts and ids only.
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

    excluded := private.transfer_excluded(source_tenant, target_tenant);

    PERFORM private.transfer_collect(source_tenant, transfer_products.product_ids, excluded);

    -- A package file that an earlier transfer into the source has not copied yet.
    IF EXISTS (
        SELECT 1
        FROM public.transfer t
        CROSS JOIN LATERAL jsonb_array_elements(t.files) f
        JOIN pg_temp.transfer_rows r ON r.table_name = 'media' AND r.source_id::TEXT = f ->> 'media_id'
        WHERE t.tenant_id = transfer_products.source_tenant AND t.files_status <> 'done'
          AND (t.files_status = 'pending' OR f ->> 'to' = ANY (t.missing_files))
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

    IF transfer_products.mode = 'move'
       AND EXISTS (SELECT 1 FROM jsonb_array_elements(report -> 'left_behind') e WHERE (e ->> 'blocks')::BOOLEAN) THEN
        PERFORM private.transfer_raise('transfer_product_in_use', 409);
    END IF;

    -- The run is 073's (Task 13).
    PERFORM private.transfer_raise('transfer_apply_unavailable', 501);
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.transfer_products (UUID, UUID, UUID[], TEXT, JSONB, BOOLEAN) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.transfer_products (UUID, UUID, UUID[], TEXT, JSONB, BOOLEAN) TO authenticated;

-- Classification (F13: in the owning migration). Nothing in a transfer row is sensitive: the report
-- holds counts and ids only, the rest is ids, codes and file paths.
INSERT INTO
   public.field_class (resource_name, field, class, group_name)
VALUES
   ('public.transfer', 'id', 'system', NULL),
   ('public.transfer', 'tenant_id', 'system', NULL),
   ('public.transfer', 'source_tenant_id', 'system', NULL),
   ('public.transfer', 'product_ids', 'system', NULL),
   ('public.transfer', 'mode', 'open', NULL),
   ('public.transfer', 'started_by', 'system', NULL),
   ('public.transfer', 'report', 'open', NULL),
   ('public.transfer', 'decisions', 'open', NULL),
   ('public.transfer', 'id_map', 'system', NULL),
   ('public.transfer', 'files', 'open', NULL),
   ('public.transfer', 'files_status', 'open', NULL),
   ('public.transfer', 'missing_files', 'open', NULL),
   ('public.transfer', 'audit_transaction_ids', 'system', NULL),
   ('public.transfer', 'xact_id', 'system', NULL),
   ('public.transfer', 'created_at', 'system', NULL),
   ('public.transfer', 'updated_at', 'system', NULL)
ON CONFLICT DO NOTHING;

-- The api view, read-only. A new view changes owner to api_owner, which needs api_owner's CREATE on the
-- schema for that moment (as in 057).
GRANT CREATE ON SCHEMA api TO api_owner;

SELECT private.enable_field_security ('transfer', TRUE);

REVOKE CREATE ON SCHEMA api FROM api_owner;
