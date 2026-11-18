CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Functions defined in more than one migration. A later migration restates a body an earlier one
-- owns (052 the guards' cascade exits (R7) and request identity (R6), 058 the RPCs as api_owner
-- definers and the figures over api, 059 the audit revert, 060 the Storage read, 067 the tenant
-- policies' shared-row call, permitted_tenants' statement cache, the api view generator's shared-row
-- masking, and the forwarder's and the base write guard's rights tenant, 068 the incident guard's
-- provider link and the audit snapshots' rights columns, and the revert's and the forwarder's rights
-- tenant), or extends it (a chain such as 021 → 032 → 036). A restated body is
-- the owner's current body plus only the restating migration's own delta, so an edit of the owner
-- that is not carried into the restatement would be undone silently, and so would a chain step a
-- later restatement forgot. Each row below names, for the live function, every rule its owner raises
-- (by error code), the logic that matters where no error code shows it (non-error needles), and the
-- markers of each later step; a missing one fails here. Needs no seed rows.
--
-- Not pinned, on purpose:
--   private.rules_bypassed (019, 030): 030 restates 019's body unchanged (050 only grants it); the
--     row below pins that body, so a drift in either copy shows.
--   notify_access_changed in 012 and 013: those files create triggers on it, not a body.
--   save_role in 058: ALTER FUNCTION only (SECURITY DEFINER, owner api_owner); the 058 test pins it.
BEGIN;

SELECT plan(44);

CREATE TEMP TABLE restated (fn REGPROCEDURE, owner TEXT, restater TEXT, needle TEXT[]) ON COMMIT DROP;

INSERT INTO restated (fn, owner, restater, needle)
VALUES
   ('private.purchase_order_line_guard()', '030', '052',
    ARRAY['po_line_identity_immutable', 'po_line_product_required', 'po_line_spec_invalid', 'po_locked', 'po_spec_sheet_required',
          'NEW.product_id IS NULL AND OLD.product_id IS NOT NULL', 'private.po_line_needs_spec(NEW.product_id, NEW.tenant_id)',
          'parent_gone(''public.purchase_order''']),
   ('private.purchase_order_child_guard()', '030', '052',
    ARRAY['po_closed', 'FOR SHARE', 'parent_gone(''public.purchase_order''']),
   ('private.shipment_purchase_order_guard()', '031', '052',
    ARRAY['client_mismatch', 'shipment_locked', 'shipment_po_has_lines', 'shipment_po_link_immutable', 'shipment_po_not_open',
          'SELECT po.client_tenant_id INTO order_client', 'order_client IS DISTINCT FROM NEW.client_tenant_id',
          'parent_gone(''public.shipment''']),
   ('private.shipment_line_guard()', '031', '052',
    ARRAY['shipment_locked', 'shipment_quantity_exceeds_po', 'sum(l.quantity)', 'parent_gone(''public.shipment''']),
   ('private.incident_child_guard()', '035', '052',
    ARRAY['incident_closed', 'parent_gone(''public.incident''']),
   ('private.market_cell_guard()', '034', '052',
    ARRAY['market_cell_compliance_note_required', 'market_cell_compliance_red', 'market_cell_country_invalid',
          'market_cell_delete_candidate_only', 'market_cell_immutable_field', 'market_cell_live_incomplete',
          'market_cell_reason_required', 'market_cell_status_order', 'parent_gone(''public.tenant''']),
   ('private.market_cell_listing_server_only()', '046', '052',
    ARRAY['market_cell_listing_server_only', 'auth.role()', 'private.server_write()']),
   ('private.platform_account_api_server_only()', '046', '052',
    ARRAY['platform_account_api_server_only', 'auth.role()', 'private.server_write()']),
   ('public.amazon_account_disconnect(uuid, public.api_connection)', '046', '052',
    ARRAY['private.platform_account_authorize(p_account_id, p_state)', 'private.amazon_token_set', 'private.begin_server_write()',
          'private.end_server_write()']),
   ('public.listing_begin_submission(uuid, public.listing_submission_kind, jsonb)', '046', '052',
    ARRAY['listing_in_progress', 'private.begin_server_write()', 'private.end_server_write()']),
   -- The figures over api: a masked unit price must make the subtotal NULL, never a wrong figure.
   ('private.purchase_order_figures(uuid, uuid, numeric, numeric, numeric)', '030', '058',
    ARRAY['api.purchase_order_line', 'api.purchase_order', 'bool_or(l.unit_price IS NULL)']),
   ('public.import_products(jsonb)', '020', '058',
    ARRAY['rows_must_be_an_array', 'tenant_required', 'gtin_duplicate', 'gtin_in_use', 'gtin_invalid', 'invalid_value',
          'parent_unknown', 'sku_duplicate', 'supplier_unknown', 'public.sourcing', 'private.require_field_write']),
   ('public.pass_gate(uuid, text, date, uuid, uuid[])', '032', '058',
    ARRAY['gate_approval_document_invalid', 'gate_evidence_invalid', 'po.project_tenant_id = passed.tenant_id',
          'private.require_field_write']),
   ('public.rollback_gate(uuid, text, uuid)', '036', '058',
    ARRAY['gate_not_passed', 'gate_reason_required', 'api.project_gate']),
   ('public.set_primary_media(uuid)', '025', '058',
    ARRAY['media_link_entity_missing', 'api.media_link']),
   -- The audit embeds return api.user (S5), from 010's actor and reverter ids.
   ('public.actor(public.audit_transaction)', '010', '058',
    ARRAY['$1.actor_id', 'FROM api.user u']),
   ('public.reverter(public.audit_transaction)', '010', '058',
    ARRAY['$1.reverted_by', 'FROM api.user u']),
   -- 068: the revert's pre-check reads a field's rights tenant from its rights column.
   ('public.revert_audit_transaction(uuid)', '010', '059, 068',
    ARRAY['audit_already_reverted', 'audit_conflict', 'audit_revert_field_forbidden', 'private.field_rights_column(chk.table_schema',
          'coalesce(rights_tenant, chk.tenant_id) = ANY (private.field_write_tenants(']),
   ('private.can_read_media_file(text)', '024', '060',
    ARRAY['private.tenants_permitting', 'private.media_restriction']),
   -- Chains: each later definition extends the one before; the live body holds every step.
   ('private.next_code(uuid, text, text)', '015', '035',
    ARRAY['''project'', ''po'', ''shp'', ''cr''', '''ol'', ''oa'', ''ou'', ''ot'', ''om''', 'tenant_required',
          'invalid_code_kind_or_scope', 'VALUES (p_tenant, p_kind, p_scope, current_year, 1)']),
   -- The wrapper numbers in the active tenant; the code triggers number in the row's own tenant.
   ('public.next_code(text, text)', '015', '015',
    ARRAY['tenant_required', 'private.tenant_id()', 'private.next_code(active, next_code.kind, next_code.scope)']),
   ('private.project_set_code()', '021', '021',
    ARRAY['private.next_code(NEW.tenant_id, ''project''']),
   ('private.purchase_order_set_code()', '029', '029',
    ARRAY['private.next_code(NEW.tenant_id, ''po''']),
   ('private.shipment_set_code()', '031', '031',
    ARRAY['private.next_code(NEW.tenant_id, ''shp''']),
   ('private.incident_set_code()', '035', '035',
    ARRAY['private.next_code(NEW.tenant_id, NEW.family::TEXT']),
   ('private.change_request_set_code()', '037', '037',
    ARRAY['private.next_code(NEW.tenant_id, ''cr''']),
   ('private.project_gate_guard()', '021', '032, 036',
    ARRAY['po.project_tenant_id = NEW.tenant_id', 'public.shipment_purchase_order spo',
          'gate_rollback_incident_required', 'gate_incident_invalid', 'gate_rollback_immutable',
          'NEW.rolled_back_incident_id := NULL']),
   ('private.media_guard_delete()', '025', '026',
    ARRAY['public.media_link l WHERE l.tenant_id = OLD.tenant_id AND l.media_id = OLD.id',
          'public.document d WHERE d.tenant_id = OLD.tenant_id AND d.media_id = OLD.id']),
   ('private.document_signed_requires()', '016', '023',
    ARRAY['NEW.status = ''approved'' AND NEW.type = ''spec_sheet''']),
   ('private.rules_bypassed()', '019', '030',
    ARRAY['current_setting(''moesa.rules_bypass'', TRUE) = ''1''', 'current_setting(''role'') = ''none''',
          'session_user IN (''postgres'', ''supabase_admin'')']),
   ('public.save_role(jsonb, uuid[], jsonb)', '009', '050',
    ARRAY['role not found', 'DELETE FROM public.role_permission', 'field_grant_exceeds_own', 'private.save_role_field_rights']),
   ('public.my_access(uuid)', '011', '050',
    ARRAY['''permissions''', '''subscription''', '''is_super_admin''', '''fields''', '''code'', t.code', 'private.field_rights(uid, tenant)']),
   ('private.notify_access_changed()', '011', '050',
    ARRAY['public.tenant_owner o', 'TG_TABLE_NAME IN (''role_permission'', ''role_field_permission'')',
          'set_config(''access.tenant_scope'', '''', true)', 'set_config(''access.permitted_tenants'', '''', true)']),
   -- 067: the results are kept for the statement (the views' s repeats the policies' lookup).
   ('private.permitted_tenants(text, text)', '004', '067',
    ARRAY['private.tenants_permitting(auth.uid(), private.tenant_scope(), p_resource_name, p_command)', 'statement_timestamp()',
          '''x-tenant-ids''', 'private.requested_tenant()', 'access.permitted_tenants']),
   -- 067: a re-run of the tenant policies keeps a shared table's shared rows.
   ('private.enable_tenant_level_security(text)', '004', '067',
    ARRAY['restrict_selects_to_current_tenant', 'restrict_inserts_to_allowed_tenants', 'restrict_updates_to_current_tenant',
          'restrict_deletes_to_current_tenant', 'private.is_tenant_id_nullable(t_name)', 'tenant_id = ANY ((SELECT private.tenant_scope())::UUID[])',
          'IF private.is_shared_table(t_name) THEN', 'PERFORM private.enable_shared_rows(t_name)']),
   -- 067: the generator masks a shared row by the row's own tenant (053 → 059 → 067).
   -- 068: the audit snapshots' mask takes the rights columns (and new_data for an update's old_data).
   ('private.api_column_expr(text, text)', '053', '059, 067, 068',
    ARRAY['field_security_unsupported', 'CASE WHEN t.id = auth.uid() OR t.id = ANY (m.u%s)', 'CASE WHEN m.a%1$s OR t.tenant_id = ANY (m.t%1$s) THEN',
          'private.mask_audit_data(t.table_name', 'private.mask_json_deep(t.%1$I', 'private.is_shared_table(p_table)',
          'JSON masking on a shared table', 'CASE WHEN t.%1$I = ANY (m.t%2$s) THEN', 'OR t.client_tenant_id = ANY (m.t%1$s) THEN',
          'CASE WHEN t.tenant_id = ANY (m.t%1$s) THEN', 'CASE WHEN t.tenant_id = ANY (m.s) THEN t.%1$I ELSE NULL::%2$s END',
          'm.rights, m.sensitive, m.rcols, t.new_data)']),
   ('private.api_view_from(text)', '053', '067, 068',
    ARRAY['WITH r AS MATERIALIZED', 'private.field_user_rights(', 'private.field_read_rights(', 'private.api_rights_expr(p_table, a.attname)',
          'OFFSET 0) m', '(SELECT coalesce(private.permitted_tenants(%L, ''select''), ''{}'')) AS s', '(SELECT private.rights_columns_map()) AS rcols']),
   -- 068: a field with a rights column is masked under the tenant it names in the snapshot.
   ('private.mask_audit_data(text, uuid, jsonb, jsonb, jsonb, jsonb, jsonb)', '059', '068',
    ARRAY['p_tenant IS NULL', '''{"masked": true}''::JSONB', 'p_sensitive -> p_table', '(p_readable -> r.tenant) ? (p_table || ''.'' || f.field)',
          'coalesce(p_data ->> rc.name, p_row ->> rc.name, p_tenant::TEXT)', '(p_rcols -> p_table) ->> f.field']),
   ('private.api_view_query(text)', '053', '067',
    ARRAY['private.api_column_expr(p_table, a.attname)', 'private.api_view_from(p_table)', 'private.api_view_derived_columns(p_table)',
          'private.api_view_derived_from(p_table)']),
   ('private.api_view_drift()', '053', '059, 067',
    ARRAY['''columns''', '''unmasked ''', '''masked ''', '''expression ''', '''definition''', '''owner''', '''security_invoker''', '''trigger''',
          '''anon or public privilege''', '''anon or public execute ''', '''guard''', 'mask_audit_data(', '''unshared ''',
          '''shared without s''', 'private.api_view_derived_columns(v.name)']),
   ('private.enable_field_security(text, boolean)', '053', '057, 067',
    ARRAY['private.api_view_query(p_table)', 'security_invoker = false', 'OWNER TO api_owner', 'DROP TRIGGER IF EXISTS api_forward',
          'INSTEAD OF INSERT OR UPDATE OR DELETE', 'field_security_unsupported', '_by_', 'private.enable_field_write_guard(p_table)',
          'private.is_shared_table(p_table)', 'f.client_visible']),
   -- 067: a written sensitive field is checked in its rights tenant, computed from base columns (F1).
   -- 068: a rights column kept by triggers is left to the base write guard.
   ('private.api_forward()', '053', '067, 068',
    ARRAY['field_security_unsupported', 'field_write_forbidden', 'gate_one_at_a_time', 'private.api_is_sensitive(resource, a.attname)',
          'private.field_user_ids(col.name, TRUE)', 'typbasetype', 'FOR UPDATE', 'jsonb_populate_record(NULL::%2$s, $1)',
          'private.field_rights_column(resource, col.name)', 'private.field_rights_generated(resource, col.name)',
          'ARRAY[old_j, new_j]', 'pg_catalog.jsonb_to_record($1)', 'IF rc <> ''tenant_id'' AND rc_expr IS NULL THEN']),
   ('private.enable_field_write_guard(text)', '051', '067',
    ARRAY['tenant_move_forbidden', 'field_write_forbidden', 'field_security_unsupported', 'private.field_guard_bypassed()',
          'aa_field_write_guard', 'private.field_user_ids(%L, TRUE)', 'NEXTVALEXPR',
          'private.field_rights_column(resource, col.field)', 'private.field_rights_generated(resource, col.field)',
          '(SELECT <row>.*) x', $n$replace(allowed, '<row>', 'OLD') || ' AND ' || replace(allowed, '<row>', 'NEW')$n$]),
   -- 068: the linked record is looked up in the provider's tenant the incident names.
   ('private.incident_guard()', '035', '068',
    ARRAY['incident_immutable_field', 'incident_type_family', 'incident_entity_invalid', 'incident_severity_downgrade_requires_management',
          'incident_status_order', 'incident_management_notice_required', 'incident_closure_incomplete', 'incident_close_management',
          'NEW.closed_by := auth.uid()', 'coalesce(NEW.entity_tenant_id, NEW.tenant_id)',
          'NEW.entity_tenant_id IS DISTINCT FROM OLD.entity_tenant_id']);

SELECT is_empty(format($q$ SELECT n FROM unnest(%L::TEXT[]) AS n WHERE strpos(pg_get_functiondef(%L::REGPROCEDURE), n) = 0 $q$,
                       r.needle, r.fn),
                format('%s (owner %s, restated in %s) keeps the owner''s rules and every later step', r.fn, r.owner, r.restater))
FROM restated r
ORDER BY r.restater, r.owner, r.fn::TEXT;

SELECT * FROM finish();
ROLLBACK;
