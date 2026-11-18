-- 067: shared rows (Plan 2). A provider row with client_tenant_id = C is read by C's members and
-- written by nobody in C.
--
-- Section 1, rows. The sharing predicate: a client user reads a provider row exactly when the row's
-- client_tenant_id is one of the request's tenants (x-tenant-ids ∩ the user's tenants, so a forged
-- header widens nothing) and the user's roles grant select on that table in that client tenant.
-- client_tenant_id exists only under an accepted relationship (Plan 1's foreign key) and never
-- changes, so nothing else is asked: ending the relationship (or switching who procures) leaves the
-- shared history readable (decision 13).
--
-- private.enable_shared_rows(t), for each shared table (private.is_shared_table, 066):
--   restrict_selects_to_current_tenant  RESTRICTIVE: tenant_id or client_tenant_id in the scope
--   shared_select                       PERMISSIVE: client_tenant_id in the tenants of the scope where
--                                       the user may select the table (private.permitted_tenants).
--                                       The permission generator (private.manage_policies) names its
--                                       own policies <command>_public_<table>, so a permission change
--                                       rebuilds those and keeps this one.
--   the write policies                  untouched: their RESTRICTIVE tenant_id = ANY (scope) never
--                                       reaches a row of another tenant, so shared rows are read-only
--                                       (Task 4 tests the forwarders).
--   <table>_client_idx                  ON (client_tenant_id) WHERE client_tenant_id IS NOT NULL,
--                                       unless an index already leads with client_tenant_id (Plan 1
--                                       indexed purchase_order, shipment, sourcing and the
--                                       relationship).
-- Refuses (field_security_unsupported) a table that carries no shared rows. Owner postgres, executable
-- by nobody else.
--
-- private.enable_tenant_level_security (004) is restated with one delta: on a shared table it calls
-- enable_shared_rows after creating the default policies, so a re-run (disable, enable) cannot
-- silently drop sharing. Pinned in 052_guard_restatements.test.sql.

-- ========================================================================================== 1. rows

CREATE OR REPLACE FUNCTION private.enable_shared_rows (p_table TEXT) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    resource TEXT := 'public.' || p_table;
BEGIN
    IF p_table IS NULL OR NOT private.is_shared_table(p_table) THEN
        RAISE EXCEPTION 'field_security_unsupported' USING DETAIL = 'no shared rows: ' || coalesce(p_table, 'NULL');
    END IF;

    EXECUTE format('DROP POLICY IF EXISTS restrict_selects_to_current_tenant ON public.%I', p_table);
    EXECUTE format(
        $f$CREATE POLICY restrict_selects_to_current_tenant ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated
           USING (tenant_id = ANY ((SELECT private.tenant_scope())::UUID[]) OR client_tenant_id = ANY ((SELECT private.tenant_scope())::UUID[]))$f$,
        p_table
    );

    EXECUTE format('DROP POLICY IF EXISTS shared_select ON public.%I', p_table);
    EXECUTE format(
        $f$CREATE POLICY shared_select ON public.%I FOR SELECT TO authenticated
           USING (client_tenant_id = ANY ((SELECT private.permitted_tenants(%L, 'select'))::UUID[]))$f$,
        p_table, resource
    );

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
        WHERE i.indrelid = resource::REGCLASS
          AND a.attname = 'client_tenant_id'
    ) THEN
        EXECUTE format('CREATE INDEX %I ON public.%I (client_tenant_id) WHERE client_tenant_id IS NOT NULL',
                       p_table || '_client_idx', p_table);
    END IF;
END;
$$;

ALTER FUNCTION private.enable_shared_rows (TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.enable_shared_rows (TEXT) FROM PUBLIC, anon, authenticated;

-- 004's body plus the shared-table call at the end.
CREATE OR REPLACE FUNCTION private.enable_tenant_level_security (p_table_name TEXT) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET
    "search_path" = '' AS $$
DECLARE
  t_name text := p_table_name;
  t_schema text := 'public';
  in_scope text;
BEGIN
  IF NOT private.has_table_tenant_id(t_name) THEN
    RAISE NOTICE 'Table "%" does not have tenant_id column. Skipping.', t_name;
    RETURN;
  END IF;

  EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', t_schema, t_name);

  -- The request's tenants (private.tenant_scope): rows outside them are neither read nor written.
  -- Shared rows (tenant_id NULL) only where the column allows them: an OR keeps the index from
  -- narrowing the scan to the tenants, so every tenant's rows would be read and filtered.
  in_scope := 'tenant_id = ANY ((SELECT private.tenant_scope())::UUID[])';

  EXECUTE format(
    $f$CREATE POLICY restrict_selects_to_current_tenant ON %I.%I AS RESTRICTIVE FOR SELECT TO authenticated USING (%s)$f$,
    t_schema, t_name,
    CASE WHEN private.is_tenant_id_nullable(t_name) THEN format('(tenant_id IS NULL OR %s)', in_scope) ELSE in_scope END
  );

  EXECUTE format(
    $f$CREATE POLICY restrict_inserts_to_allowed_tenants ON %I.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (%s)$f$,
    t_schema, t_name, in_scope
  );

  EXECUTE format(
    $f$CREATE POLICY restrict_updates_to_current_tenant ON %I.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (%3$s) WITH CHECK (%3$s)$f$,
    t_schema, t_name, in_scope
  );

  EXECUTE format(
    $f$CREATE POLICY restrict_deletes_to_current_tenant ON %I.%I AS RESTRICTIVE FOR DELETE TO authenticated USING (%s)$f$,
    t_schema, t_name, in_scope
  );

  -- 067: a shared table keeps its shared rows readable by the client tenant.
  IF private.is_shared_table(t_name) THEN
    PERFORM private.enable_shared_rows(t_name);
  END IF;

  RAISE NOTICE 'RLS enabled and policies created for table: %', t_name;
END;
$$;

SELECT private.enable_shared_rows(c.relname::TEXT)
FROM pg_catalog.pg_class c
WHERE c.relnamespace = 'public'::REGNAMESPACE
  AND c.relkind = 'r'
  AND private.is_shared_table(c.relname::TEXT)
ORDER BY c.relname;
