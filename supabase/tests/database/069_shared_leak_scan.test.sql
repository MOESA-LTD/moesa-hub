CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Leak scan (Plan 2, Task 7): every provider-only column of a provider's order shared with its client
-- holds a sentinel, and no api relation returns a sentinel to the client's users.
--
-- The scan is generic. It enumerates from pg_catalog, so a relation added later is covered:
--   * every view in schema api;
--   * every api function taking one composite argument (the R4 embeds: supplier, pi_document, ...),
--     called with each row of its argument's relation the caller reads;
--   * every stable public or api function the caller may execute that takes no argument (or only
--     defaulted ones), or only UUID arguments (called with each tenant of the scope): my_access, ...
-- Each column of each row (to_jsonb, one key per column) is matched against the sentinels; a hit names
-- the relation and the column.
--
-- A draft order for C and its line (decision 20) carry sentinels in their client-visible columns
-- (ids ...69fd and ...69ff, ready date, quantity): a draft must not reach the client at all.
-- Sentinels (written as postgres with the rules bypassed, column by column from field_class: every
-- column that is not client_visible on a shared table, every column of a provider-only table, the
-- provider-guarded cost on client records):
--   text 'LEAK-<table>.<column>', numeric 987654.32, integer 987654, date 2987-06-05, the ids of
--   provider-only rows (...69fN), and the provider role 'LEAK-ROLE' (F15, Plan 1 user_role carry).
-- Enum, boolean and char(3) columns cannot hold a sentinel; Task 3's masking tests pin them.
-- sourcing.manufacturer_art_no is client-visible (Q3), so it gets none.
--
-- Actors: THO's owner (thomas), its viewer (portal) and a spy whose role the owner granted every
-- permission and every sensitive field through save_role; each with scope {THO} and with the forged
-- scope {THO, provider}.
--
-- Signing in (F4): `RESET ROLE; SELECT private.impersonate_scope(user, active, scope);`.
BEGIN;

SELECT plan(20);

SELECT private.create_test_helpers();

-- Fixture (ids 0000000069xx) on the seed: C = THO, P = its provider (from the relationship), rel_c the
-- seed relationship. Client-visible rows: product ...6941 (C), sourcing ...6944, po_c ...6951,
-- line ...6961, shipment ...6971, event ...6973, shipment line ...6974, warehouse ...6975 (C),
-- cr_c ...6992, inc_c ...6995 and its log ...69a1, spy ...6912 with role 'Spy' ...6934.
-- Provider-only rows (their ids are sentinels, ...69fN): supplier f1, contact f2, payment f3,
-- update f4, documents pi f5, packing f6, spec f7, contract f8, media f9, LEAK-ROLE fa; a transfer
-- ...6981 from the provider into C (final review M4: the row is C's, its description the provider's,
-- guarded by source_tenant_id), naming the provider-only product id ...69fe.
SELECT set_config('test.c', (SELECT id::TEXT FROM public.tenant WHERE code = 'THO'), TRUE);
SELECT set_config('test.p', (SELECT tenant_id::TEXT FROM public.provider_relationship WHERE client_tenant_id = current_setting('test.c')::UUID), TRUE);
SELECT set_config('test.rel', (SELECT id::TEXT FROM public.provider_relationship WHERE client_tenant_id = current_setting('test.c')::UUID), TRUE);
SELECT set_config('test.thomas', (SELECT id::TEXT FROM public.user WHERE email = 'thomas@moesa-panel.test'), TRUE);
SELECT set_config('test.portal', (SELECT id::TEXT FROM public.user WHERE email = 'portal@moesa-panel.test'), TRUE);
SELECT set_config('test.koordinator', (SELECT id::TEXT FROM public.user WHERE email = 'koordinator@moesa-panel.test'), TRUE);

INSERT INTO public.user (id, email) VALUES ('00000000-0000-4000-8000-000000006912', 'spy@leak.test');
INSERT INTO public.tenant_user (user_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000006912', current_setting('test.c')::UUID);
INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000006934', current_setting('test.c')::UUID, 'Spy'),
   ('00000000-0000-4000-8000-0000000069fa', current_setting('test.p')::UUID, 'LEAK-ROLE');
INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-0000000069fa', p.id FROM public.permission p WHERE p.command = 'select';
INSERT INTO public.user_role (user_id, role_id) VALUES
   ('00000000-0000-4000-8000-000000006912', '00000000-0000-4000-8000-000000006934'),
   (current_setting('test.koordinator')::UUID, '00000000-0000-4000-8000-0000000069fa');

INSERT INTO public.product (id, tenant_id, sku, display_name) VALUES
   ('00000000-0000-4000-8000-000000006941', current_setting('test.c')::UUID, 'SCAN-1', 'Scan product');
INSERT INTO public.warehouse (id, tenant_id, display_name, city, country) VALUES
   ('00000000-0000-4000-8000-000000006975', current_setting('test.c')::UUID, 'Scan DC', 'Rosbach', 'DE');

SELECT set_config('moesa.rules_bypass', '1', TRUE);

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, default_incoterm, deposit_rate, status) VALUES
   ('00000000-0000-4000-8000-0000000069f1', current_setting('test.p')::UUID, 'SC1', 'Scan Supplier', 'Türkiye', 'EXW', 30, 'approved');
INSERT INTO public.supplier_contact (id, tenant_id, supplier_id, name) VALUES
   ('00000000-0000-4000-8000-0000000069f2', current_setting('test.p')::UUID, '00000000-0000-4000-8000-0000000069f1', 'Contact');
INSERT INTO public.sourcing (id, tenant_id, client_tenant_id, product_id, sell_price_eur, supplier_id, manufacturer_art_no) VALUES
   ('00000000-0000-4000-8000-000000006944', current_setting('test.p')::UUID, current_setting('test.c')::UUID,
    '00000000-0000-4000-8000-000000006941', 9.90, '00000000-0000-4000-8000-0000000069f1', 'ART-SCAN');
INSERT INTO public.purchase_order (id, tenant_id, client_tenant_id, supplier_id, currency, incoterm, deposit_rate) VALUES
   ('00000000-0000-4000-8000-000000006951', current_setting('test.p')::UUID, current_setting('test.c')::UUID,
    '00000000-0000-4000-8000-0000000069f1', 'USD', 'EXW', 30);
INSERT INTO public.purchase_order_line (id, tenant_id, purchase_order_id, product_id, quantity, unit_price, sell_price_eur) VALUES
   ('00000000-0000-4000-8000-000000006961', current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000006951',
    '00000000-0000-4000-8000-000000006941', 10, 2.50, 9.90);
INSERT INTO storage.objects (bucket_id, name, metadata) VALUES
   ('media', current_setting('test.p') || '/00000000-0000-4000-8000-0000000069f9/pi.pdf', '{"mimetype": "application/pdf", "size": 10}'::JSONB);
INSERT INTO public.media (id, tenant_id, storage_path, file_name, mime_type, size_bytes) VALUES
   ('00000000-0000-4000-8000-0000000069f9', current_setting('test.p')::UUID,
    current_setting('test.p') || '/00000000-0000-4000-8000-0000000069f9/pi.pdf', 'pi.pdf', 'application/pdf', 10);
INSERT INTO public.document (id, tenant_id, entity_type, entity_id, type, url, media_id, version) VALUES
   ('00000000-0000-4000-8000-0000000069f5', current_setting('test.p')::UUID, 'purchase_order', '00000000-0000-4000-8000-000000006951', 'pi',
    NULL, '00000000-0000-4000-8000-0000000069f9', 1),
   ('00000000-0000-4000-8000-0000000069f6', current_setting('test.p')::UUID, 'purchase_order', '00000000-0000-4000-8000-000000006951', 'other',
    'https://example.test/packing.pdf', NULL, 1),
   ('00000000-0000-4000-8000-0000000069f7', current_setting('test.p')::UUID, 'purchase_order', '00000000-0000-4000-8000-000000006951', 'spec_sheet',
    'https://example.test/spec.pdf', NULL, 1),
   ('00000000-0000-4000-8000-0000000069f8', current_setting('test.p')::UUID, 'provider_relationship', current_setting('test.rel')::UUID, 'contract',
    'https://example.test/contract.pdf', NULL,
    (SELECT coalesce(max(version), 0) + 1 FROM public.document WHERE entity_id = current_setting('test.rel')::UUID AND type = 'contract'));
UPDATE public.provider_relationship SET contract_document_id = '00000000-0000-4000-8000-0000000069f8' WHERE id = current_setting('test.rel')::UUID;

UPDATE public.purchase_order SET pi_document_id = '00000000-0000-4000-8000-0000000069f5',
                                 packing_instruction_document_id = '00000000-0000-4000-8000-0000000069f6'
WHERE id = '00000000-0000-4000-8000-000000006951';
UPDATE public.purchase_order_line SET spec_document_id = '00000000-0000-4000-8000-0000000069f7' WHERE id = '00000000-0000-4000-8000-000000006961';
-- The shared order is sent (decision 20: a draft does not reach the client at all).
UPDATE public.purchase_order SET status = 'sent' WHERE id = '00000000-0000-4000-8000-000000006951';
-- Decision 20: a draft order for C (...69fd) and its line (...69ff). Their ids are id sentinels and
-- the order's ready date a date sentinel, client-visible columns all: no client run may meet them.
INSERT INTO public.purchase_order (id, tenant_id, client_tenant_id, supplier_id, currency, incoterm, deposit_rate, ready_on) VALUES
   ('00000000-0000-4000-8000-0000000069fd', current_setting('test.p')::UUID, current_setting('test.c')::UUID,
    '00000000-0000-4000-8000-0000000069f1', 'USD', 'EXW', 30, '2987-06-05');
INSERT INTO public.purchase_order_line (id, tenant_id, purchase_order_id, product_id, quantity, unit_price, sell_price_eur) VALUES
   ('00000000-0000-4000-8000-0000000069ff', current_setting('test.p')::UUID, '00000000-0000-4000-8000-0000000069fd',
    '00000000-0000-4000-8000-000000006941', 987654, 2.50, 9.90);
INSERT INTO public.purchase_order_payment (id, tenant_id, purchase_order_id, kind, amount, currency) VALUES
   ('00000000-0000-4000-8000-0000000069f3', current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000006951', 'deposit', 1, 'USD');
INSERT INTO public.purchase_order_update (id, tenant_id, purchase_order_id, happened_on, note) VALUES
   ('00000000-0000-4000-8000-0000000069f4', current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000006951', '2026-11-01', 'x');
INSERT INTO public.shipment (id, tenant_id, client_tenant_id, mode, delivery_warehouse_id, warehouse_tenant_id, is_insured) VALUES
   ('00000000-0000-4000-8000-000000006971', current_setting('test.p')::UUID, current_setting('test.c')::UUID,
    'road', '00000000-0000-4000-8000-000000006975', current_setting('test.c')::UUID, FALSE);
INSERT INTO public.shipment_purchase_order (tenant_id, shipment_id, purchase_order_id) VALUES
   (current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000006971', '00000000-0000-4000-8000-000000006951');
INSERT INTO public.shipment_line (id, tenant_id, shipment_id, purchase_order_id, purchase_order_line_id, quantity) VALUES
   ('00000000-0000-4000-8000-000000006974', current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000006971',
    '00000000-0000-4000-8000-000000006951', '00000000-0000-4000-8000-000000006961', 4);
INSERT INTO public.shipment_event (id, tenant_id, shipment_id, step) VALUES
   ('00000000-0000-4000-8000-000000006973', current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000006971', 3);

-- The client's records on the provider order (their cost is provider-guarded).
INSERT INTO public.change_request (id, tenant_id, title, source, change_kinds, current_value, requested_value, reason,
                                   purchase_order_id, order_tenant_id) VALUES
   ('00000000-0000-4000-8000-000000006992', current_setting('test.c')::UUID, 'Scan', 'customer', '{design}', 'Red', 'Blue', 'x',
    '00000000-0000-4000-8000-000000006951', current_setting('test.p')::UUID);
INSERT INTO public.incident (id, tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id) VALUES
   ('00000000-0000-4000-8000-000000006995', current_setting('test.c')::UUID, 'ol', 's3', 'Scan incident', 'x',
    'purchase_order', '00000000-0000-4000-8000-000000006951', current_setting('test.p')::UUID);
INSERT INTO public.incident_log (id, tenant_id, incident_id, note, cost_amount, cost_currency, cost_payer, guard_tenant_id) VALUES
   ('00000000-0000-4000-8000-0000000069a1', current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000006995', 'Rework',
    1, 'EUR', 'company', current_setting('test.p')::UUID);

-- The sentinels, column by column. 'provider': every column of a table that is never shared, every
-- column of a shared table that is not client_visible; 'guarded': the provider-guarded fields
-- (field_class.rights_column).
-- A provider invitation (...69fb) and its staff row (071): never shared, so the client reads neither;
-- the staff row's id (...69fc) is a provider-only id sentinel, as is its invitation_id.
INSERT INTO public.provider_invitation (id, tenant_id, email, company_name, client_code, procurement_model, created_by) VALUES
   ('00000000-0000-4000-8000-0000000069fb', current_setting('test.p')::UUID, 'leak@invite.test', 'Leak invite', 'LKI', 'provider',
    current_setting('test.koordinator')::UUID);
INSERT INTO public.provider_invitation_staff (id, invitation_id, tenant_id, user_id, role_name) VALUES
   ('00000000-0000-4000-8000-0000000069fc', '00000000-0000-4000-8000-0000000069fb', current_setting('test.p')::UUID, current_setting('test.koordinator')::UUID, 'viewer');
-- A transfer from the provider into C (072/073): C's row; report, decisions, id_map and files take
-- their sentinels below (guarded: rights column source_tenant_id), product_ids an id sentinel.
INSERT INTO public.transfer (id, tenant_id, source_tenant_id, product_ids, mode, started_by, files_status) VALUES
   ('00000000-0000-4000-8000-000000006981', current_setting('test.c')::UUID, current_setting('test.p')::UUID,
    ARRAY['00000000-0000-4000-8000-0000000069fe']::UUID[], 'copy', current_setting('test.koordinator')::UUID, 'done');

CREATE TEMP TABLE leak_target (tbl TEXT, id UUID, mode TEXT) ON COMMIT DROP;
INSERT INTO leak_target VALUES
   ('provider_relationship', current_setting('test.rel')::UUID, 'provider'),
   ('sourcing', '00000000-0000-4000-8000-000000006944', 'provider'),
   ('purchase_order', '00000000-0000-4000-8000-000000006951', 'provider'),
   ('purchase_order_line', '00000000-0000-4000-8000-000000006961', 'provider'),
   ('shipment', '00000000-0000-4000-8000-000000006971', 'provider'),
   ('shipment_event', '00000000-0000-4000-8000-000000006973', 'provider'),
   ('shipment_line', '00000000-0000-4000-8000-000000006974', 'provider'),
   ('supplier', '00000000-0000-4000-8000-0000000069f1', 'provider'),
   ('supplier_contact', '00000000-0000-4000-8000-0000000069f2', 'provider'),
   ('purchase_order_payment', '00000000-0000-4000-8000-0000000069f3', 'provider'),
   ('purchase_order_update', '00000000-0000-4000-8000-0000000069f4', 'provider'),
   ('document', '00000000-0000-4000-8000-0000000069f5', 'provider'),
   ('document', '00000000-0000-4000-8000-0000000069f6', 'provider'),
   ('document', '00000000-0000-4000-8000-0000000069f7', 'provider'),
   ('document', '00000000-0000-4000-8000-0000000069f8', 'provider'),
   ('media', '00000000-0000-4000-8000-0000000069f9', 'provider'),
   ('provider_invitation', '00000000-0000-4000-8000-0000000069fb', 'provider'),
   ('transfer', '00000000-0000-4000-8000-000000006981', 'guarded'),
   ('change_request', '00000000-0000-4000-8000-000000006992', 'guarded'),
   ('incident_log', '00000000-0000-4000-8000-0000000069a1', 'guarded');

CREATE TEMP TABLE leak_seeded (tbl TEXT, id UUID, col TEXT, sentinel TEXT, error TEXT) ON COMMIT DROP;

DO $$
DECLARE
    c RECORD;
    v TEXT;
    n INT;
BEGIN
    FOR c IN
        SELECT t.tbl, t.id, a.attname::TEXT AS col, format_type(a.atttypid, a.atttypmod) AS typ,
               ty.typcategory AS cat, a.atttypid AS typid
        FROM leak_target t
        JOIN pg_attribute a ON a.attrelid = ('public.' || t.tbl)::regclass AND a.attnum > 0 AND NOT a.attisdropped
        JOIN pg_type ty ON ty.oid = a.atttypid
        LEFT JOIN public.field_class f ON f.resource_name = 'public.' || t.tbl AND f.field = a.attname
        WHERE a.attname NOT IN ('id', 'tenant_id', 'client_tenant_id', 'created_at', 'updated_at')
          AND CASE t.mode
                  WHEN 'provider' THEN NOT private.is_shared_table(t.tbl) OR NOT coalesce(f.client_visible, FALSE)
                  ELSE f.rights_column IS NOT NULL
              END
        ORDER BY t.tbl, t.id, a.attnum
    LOOP
        v := CASE
                 WHEN c.typid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype) THEN 'LEAK-' || c.tbl || '.' || c.col
                 WHEN c.typid = 'numeric'::regtype THEN '987654.32'
                 WHEN c.typid IN ('int2'::regtype, 'int4'::regtype, 'int8'::regtype) THEN '987654'
                 WHEN c.typid IN ('date'::regtype, 'timestamptz'::regtype, 'timestamp'::regtype) THEN '2987-06-05'
                 WHEN c.typid IN ('jsonb'::regtype, 'json'::regtype) THEN json_build_object('leak', 'LEAK-' || c.tbl || '.' || c.col)::TEXT
                 WHEN c.typid = 'text[]'::regtype THEN ARRAY['LEAK-' || c.tbl || '.' || c.col]::TEXT
             END;
        IF v IS NULL THEN
            INSERT INTO leak_seeded VALUES (c.tbl, c.id, c.col, NULL, 'no sentinel for ' || c.typ);
            CONTINUE;
        END IF;
        BEGIN
            EXECUTE format('UPDATE public.%I SET %I = %L::%s WHERE id = %L', c.tbl, c.col, v, c.typ, c.id);
            GET DIAGNOSTICS n = ROW_COUNT;
            INSERT INTO leak_seeded VALUES (c.tbl, c.id, c.col, v, CASE WHEN n = 1 THEN NULL ELSE 'no row' END);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO leak_seeded VALUES (c.tbl, c.id, c.col, NULL, SQLSTATE || ' ' || SQLERRM);
        END;
    END LOOP;
END;
$$;

SELECT set_config('moesa.rules_bypass', '', TRUE);

-- The sentinels still held after every update (a trigger may have recomputed a column).
CREATE TEMP TABLE leak_held ON COMMIT DROP AS
SELECT s.tbl, s.col FROM leak_seeded s
WHERE s.sentinel IS NOT NULL
  AND (SELECT t.peek(s.tbl, s.col, s.id)) LIKE '%' || CASE WHEN s.sentinel LIKE '{%' THEN 'LEAK-' ELSE s.sentinel END || '%';

SELECT is_empty($$
   SELECT unnest(ARRAY['purchase_order.pi_total', 'purchase_order.pi_number', 'purchase_order.notes', 'purchase_order.pi_checked_at',
                       'purchase_order_line.unit_price', 'purchase_order_line.notes', 'sourcing.purchase_price',
                       'sourcing.supplier_product_code', 'sourcing.landed_cost_on', 'provider_relationship.notes',
                       'provider_relationship.restricted_drive_url', 'shipment.forwarder', 'shipment.free_days_port',
                       'shipment_event.note', 'shipment_event.channel', 'supplier.display_name', 'supplier.product_groups',
                       'supplier_contact.email', 'purchase_order_payment.amount', 'purchase_order_update.note',
                       'document.file_name', 'media.file_name', 'change_request.cost_impact', 'incident_log.cost_amount',
                       'provider_invitation.company_name', 'provider_invitation.extra_cost_rule',
                       'transfer.report', 'transfer.decisions', 'transfer.id_map', 'transfer.files'])
   EXCEPT SELECT tbl || '.' || col FROM leak_held $$,
   'a sentinel sits in every provider-only column the scan relies on');
SELECT diag('not seeded: ' || string_agg(tbl || '.' || col || ' (' || error || ')', '; ' ORDER BY tbl, col))
FROM (SELECT DISTINCT tbl, col, error FROM leak_seeded WHERE error IS NOT NULL) e;

-- The scan. p_tenants: the UUID arguments tried on functions taking only UUIDs.
CREATE FUNCTION t.leak_patterns () RETURNS TEXT[] LANGUAGE sql IMMUTABLE AS $$
    SELECT ARRAY['LEAK-', '(^|[^0-9a-fA-F-])987654([^0-9a-fA-F-]|$)', '2987-06-05', '0000000069f'];
$$;

CREATE FUNCTION t.leak_scan (p_tenants UUID[]) RETURNS TABLE (kind TEXT, relation TEXT, col TEXT) LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    k TEXT;
    flat CONSTANT TEXT := 'jsonb_each_text(CASE jsonb_typeof(s.j) WHEN ''object'' THEN s.j ELSE jsonb_build_object(''value'', s.j) END) e';
BEGIN
    FOR r IN
        -- every api view
        SELECT format('%I.%I', n.nspname, c.relname) AS rel,
               format('SELECT DISTINCT e.key FROM (SELECT to_jsonb(x) AS j FROM %I.%I x) s, %s WHERE e.value ~ ANY ($1)',
                      n.nspname, c.relname, flat) AS q
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'api' AND c.relkind IN ('v', 'm') AND has_table_privilege(c.oid, 'SELECT')
        UNION ALL
        -- every api function of one composite argument, over the rows of that argument's relation
        SELECT format('%I.%I(%s)', n.nspname, p.proname, p.proargtypes[0]::regtype),
               format('SELECT DISTINCT e.key FROM %s a CROSS JOIN LATERAL (SELECT to_jsonb(%I.%I(a)) AS j) s, %s WHERE e.value ~ ANY ($1)',
                      ty.typrelid::regclass, n.nspname, p.proname, flat)
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_type ty ON ty.oid = p.proargtypes[0]
        WHERE n.nspname = 'api' AND p.prokind = 'f' AND p.pronargs = 1 AND ty.typtype = 'c' AND ty.typrelid <> 0
          AND has_function_privilege(p.oid, 'EXECUTE')
        UNION ALL
        -- every stable public or api function callable without arguments, or with UUIDs only
        SELECT format('%I.%I(%s)', n.nspname, p.proname, coalesce(a.arg, '')),
               format('SELECT DISTINCT e.key FROM (SELECT to_jsonb(x) AS j FROM %I.%I(%s) x) s, %s WHERE e.value ~ ANY ($1)',
                      n.nspname, p.proname, coalesce(a.arg, ''), flat)
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        CROSS JOIN LATERAL (
            SELECT NULL::TEXT AS arg WHERE p.pronargs = p.pronargdefaults
            UNION ALL
            SELECT array_to_string(array_fill(quote_literal(tid) || '::UUID', ARRAY[p.pronargs]), ', ')
            FROM unnest(p_tenants) AS tid
            WHERE p.pronargs > 0 AND NOT EXISTS (SELECT 1 FROM unnest(p.proargtypes::OID[]) AS g WHERE g <> 'uuid'::regtype)
        ) a
        WHERE n.nspname IN ('public', 'api') AND p.prokind = 'f' AND p.provolatile IN ('s', 'i')
          AND p.prorettype NOT IN ('void'::regtype, 'trigger'::regtype)
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
          AND has_function_privilege(p.oid, 'EXECUTE')
    LOOP
        BEGIN
            FOR k IN EXECUTE r.q USING t.leak_patterns() LOOP
                kind := 'hit'; relation := r.rel; col := k;
                RETURN NEXT;
            END LOOP;
            kind := 'scanned'; relation := r.rel; col := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            kind := 'error'; relation := r.rel; col := SQLSTATE || ' ' || SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION t.leak_patterns (), t.leak_scan (UUID[]) TO authenticated;

CREATE TEMP TABLE leak_run (actor TEXT, kind TEXT, relation TEXT, col TEXT) ON COMMIT DROP;
CREATE TEMP TABLE leak_role_seen (actor TEXT, relation TEXT) ON COMMIT DROP;
GRANT SELECT, INSERT ON leak_run, leak_role_seen TO authenticated;

-- One run: the scan, and the provider role through user_role, role and role_permission.
CREATE FUNCTION pg_temp.run (p_actor TEXT, p_tenants UUID[]) RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO leak_run SELECT p_actor, s.kind, s.relation, s.col FROM t.leak_scan(p_tenants) s;
    INSERT INTO leak_role_seen
    SELECT p_actor, 'role' FROM api.role WHERE id = '00000000-0000-4000-8000-0000000069fa' OR display_name = 'LEAK-ROLE'
    UNION ALL SELECT p_actor, 'user_role' FROM api.user_role WHERE role_id = '00000000-0000-4000-8000-0000000069fa'
    UNION ALL SELECT p_actor, 'role_permission' FROM api.role_permission WHERE role_id = '00000000-0000-4000-8000-0000000069fa';
$$;

-- The spy: the owner grants its role every permission and every sensitive field.
RESET ROLE;
SELECT private.impersonate_scope(current_setting('test.thomas')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT lives_ok($$ SELECT public.save_role('{"id": "00000000-0000-4000-8000-000000006934", "display_name": "Spy"}'::JSONB,
                                           ARRAY(SELECT id FROM api.permission),
                                           (SELECT jsonb_agg(jsonb_build_object('resource_name', f.resource_name, 'field', f.field, 'can_read', TRUE, 'can_write', TRUE))
                                            FROM api.field_class f WHERE f.class = 'sensitive' AND f.resource_name <> 'public.user')) $$,
                'the client owner grants its spy role every permission and every sensitive field');

-- The owner, in {THO} and in the forged {THO, provider}.
SELECT results_eq($$ SELECT (SELECT count(*)::INT FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000006951')
                          + (SELECT count(*)::INT FROM api.purchase_order_line WHERE id = '00000000-0000-4000-8000-000000006961')
                          + (SELECT count(*)::INT FROM api.sourcing WHERE id = '00000000-0000-4000-8000-000000006944')
                          + (SELECT count(*)::INT FROM api.shipment WHERE id = '00000000-0000-4000-8000-000000006971')
                          + (SELECT count(*)::INT FROM api.shipment_event WHERE id = '00000000-0000-4000-8000-000000006973')
                          + (SELECT count(*)::INT FROM api.provider_relationship WHERE id = current_setting('test.rel')::UUID)
                          + (SELECT count(*)::INT FROM api.change_request WHERE id = '00000000-0000-4000-8000-000000006992')
                          + (SELECT count(*)::INT FROM api.incident_log WHERE id = '00000000-0000-4000-8000-0000000069a1') $$,
                   $$ VALUES (8) $$, 'the owner reads every shared row of the fixture (the scan is not vacuous)');
SELECT results_eq($$ SELECT (SELECT count(*)::INT FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-0000000069fd'),
                            (SELECT count(*)::INT FROM api.purchase_order_line WHERE id = '00000000-0000-4000-8000-0000000069ff') $$,
                  $$ VALUES (0, 0) $$, 'the owner reads neither the draft order nor its line (decision 20)');
SELECT pg_temp.run('thomas {THO}', ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
RESET ROLE;
SELECT private.impersonate_scope(current_setting('test.thomas')::UUID, current_setting('test.c')::UUID,
                                 ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
SELECT pg_temp.run('thomas {THO, provider}', ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
SELECT is_empty($$ SELECT d.purchase_order_id FROM api.dashboard_purchase_order d
                   WHERE d.client_tenant_id = current_setting('test.c')::UUID AND to_jsonb(d)::TEXT ~ '(^|[^0-9a-fA-F-])987654' $$,
                'dashboards carry no provider figure');
SELECT is((SELECT subtotal FROM private.purchase_order_figures('00000000-0000-4000-8000-000000006951', current_setting('test.p')::UUID)), NULL,
          'figures over a shared order are NULL for the client');
SELECT results_eq($$ SELECT coalesce(cardinality(spec_missing_line_ids), 0), coalesce(has_approved_psi, FALSE)
                     FROM api.purchase_order_overview WHERE id = '00000000-0000-4000-8000-000000006951' $$,
                  $$ VALUES (0, FALSE) $$, 'the overview derives nothing from provider settings on a shared order (F16)');

-- The viewer.
RESET ROLE;
SELECT private.impersonate_scope(current_setting('test.portal')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT is((SELECT count(*)::INT FROM api.sourcing WHERE id = '00000000-0000-4000-8000-000000006944'), 1,
          'the viewer reads the shared sourcing row (the scan is not vacuous)');
SELECT pg_temp.run('portal {THO}', ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
RESET ROLE;
SELECT private.impersonate_scope(current_setting('test.portal')::UUID, current_setting('test.c')::UUID,
                                 ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
SELECT pg_temp.run('portal {THO, provider}', ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);

-- The spy.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006912', current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT is((SELECT count(*)::INT FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000006951'), 1,
          'the spy reads the shared order (the scan is not vacuous)');
SELECT pg_temp.run('spy {THO}', ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006912', current_setting('test.c')::UUID,
                                 ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
SELECT pg_temp.run('spy {THO, provider}', ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);

-- The provider's coordinator sees its role, and its scan finds the sentinels (the checks are not vacuous).
RESET ROLE;
SELECT private.impersonate_scope(current_setting('test.koordinator')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT ok((SELECT count(*) FROM api.user_role WHERE role_id = '00000000-0000-4000-8000-0000000069fa') = 1
          AND (SELECT count(*) FROM api.role WHERE display_name = 'LEAK-ROLE') = 1,
          'the provider coordinator reads LEAK-ROLE and its assignment');
INSERT INTO leak_run SELECT 'provider', s.kind, s.relation, s.col FROM t.leak_scan(ARRAY[current_setting('test.p')::UUID]) s;
RESET ROLE;
SELECT private.unimpersonate();

-- The results, per run.
SELECT is_empty($$ SELECT relation || ' -> ' || col FROM leak_run WHERE actor = 'thomas {THO}' AND kind = 'hit' $$, 'owner {THO}: no sentinel in any api relation');
SELECT is_empty($$ SELECT relation || ' -> ' || col FROM leak_run WHERE actor = 'thomas {THO, provider}' AND kind = 'hit' $$, 'owner {THO, provider}: no sentinel in any api relation');
SELECT is_empty($$ SELECT relation || ' -> ' || col FROM leak_run WHERE actor = 'portal {THO}' AND kind = 'hit' $$, 'viewer {THO}: no sentinel in any api relation');
SELECT is_empty($$ SELECT relation || ' -> ' || col FROM leak_run WHERE actor = 'portal {THO, provider}' AND kind = 'hit' $$, 'viewer {THO, provider}: no sentinel in any api relation');
SELECT is_empty($$ SELECT relation || ' -> ' || col FROM leak_run WHERE actor = 'spy {THO}' AND kind = 'hit' $$, 'spy {THO}: no sentinel in any api relation');
SELECT is_empty($$ SELECT relation || ' -> ' || col FROM leak_run WHERE actor = 'spy {THO, provider}' AND kind = 'hit' $$, 'spy {THO, provider}: no sentinel in any api relation');
SELECT is_empty($$
   SELECT unnest(ARRAY['api.purchase_order', 'api.purchase_order_line', 'api.sourcing', 'api.shipment', 'api.shipment_event',
                       'api.provider_relationship', 'api.supplier', 'api.supplier_contact', 'api.purchase_order_payment',
                       'api.purchase_order_update', 'api.document', 'api.user_role', 'api.pi_document(api.purchase_order)',
                       'api.supplier(api.sourcing)', 'api.spec_document(api.purchase_order_line)',
                       'api.provider_invitation', 'api.provider_invitation_staff'])
   EXCEPT SELECT relation FROM leak_run WHERE actor = 'provider' AND kind = 'hit' $$,
   'the provider''s own scan finds its sentinels through api (they reach the layer the client reads)');
SELECT is_empty($$ SELECT actor || ': ' || relation FROM leak_role_seen $$, 'no client run sees LEAK-ROLE through role, user_role or role_permission');

-- Coverage: every run (the six client runs and the provider's) scanned every api view, every R4 function and the read RPCs (none errored).
SELECT is_empty($$
   SELECT a.actor || ': ' || x.rel
   FROM (SELECT DISTINCT actor FROM leak_run) a
   CROSS JOIN (SELECT format('%I.%I', 'api', c.relname) AS rel FROM pg_class c WHERE c.relnamespace = 'api'::regnamespace AND c.relkind = 'v'
               UNION ALL
               SELECT format('%I.%I(%s)', 'api', p.proname, p.proargtypes[0]::regtype)
               FROM pg_proc p JOIN pg_type ty ON ty.oid = p.proargtypes[0]
               WHERE p.pronamespace = 'api'::regnamespace AND p.pronargs = 1 AND ty.typtype = 'c'
               UNION ALL
               SELECT unnest(ARRAY['public.my_access()', 'public.my_memberships()', 'public.client_procurement()'])) x
   WHERE NOT EXISTS (SELECT 1 FROM leak_run r WHERE r.actor = a.actor AND r.relation = x.rel AND r.kind = 'scanned')
   UNION ALL SELECT 'runs: ' || count(DISTINCT actor) FROM leak_run HAVING count(DISTINCT actor) <> 7 $$,
   'every run scanned every api view, every R4 function and the read RPCs');
SELECT diag('errored: ' || string_agg(DISTINCT relation || ' (' || col || ')', '; ')) FROM leak_run WHERE kind = 'error';

-- Red check: unmask purchase_order.pi_total in api.purchase_order; the scan must name it.
DO $$
DECLARE
    def TEXT := pg_get_viewdef('api.purchase_order'::regclass);
    opts TEXT := (SELECT array_to_string(reloptions, ', ') FROM pg_class WHERE oid = 'api.purchase_order'::regclass);
BEGIN
    def := regexp_replace(def, 'WHEN \(t\.tenant_id = ANY \(m\.t\d+\)\) THEN t\.pi_total\M', 'WHEN TRUE THEN t.pi_total');
    EXECUTE format('CREATE OR REPLACE VIEW api.purchase_order WITH (%s) AS %s', opts, def);
END;
$$;
SELECT private.impersonate_scope(current_setting('test.thomas')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT ok(EXISTS (SELECT 1 FROM t.leak_scan(ARRAY[current_setting('test.c')::UUID]) s
                  WHERE s.kind = 'hit' AND s.relation = 'api.purchase_order' AND s.col = 'pi_total'),
          'red: an unmasked pi_total in api.purchase_order is found and named');
RESET ROLE;
SELECT private.unimpersonate();

SELECT * FROM finish();
ROLLBACK;
