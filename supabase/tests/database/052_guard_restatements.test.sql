CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Functions defined in more than one migration. A later migration restates a body an earlier one
-- owns (052 the guards' cascade exits (R7) and request identity (R6), 058 the RPCs as api_owner
-- definers and the figures over api, 059 the audit revert, 060 the Storage read, 067 the tenant
-- policies' shared-row call, the signed access caches (tenant_scope, permitted_tenants), the api
-- view generator's shared-row masking, and the forwarder's and the base write guard's rights
-- tenant, 068 the incident guard's provider link and the audit snapshots' rights columns, and the
-- revert's and the forwarder's rights tenant, 070 register_tenant's delegation to create_company and
-- save_plan's audience, 071 the audit's trusted service actors with the invitation's, 072 the
-- rules bypass's transfer flag, the revert's transfer lock and the coordinator's standard role without
-- the transfer right, 073 the media file check's transfer copy, the file restriction's hold and the
-- transfer entry point's run, 074 the media Storage checks' transfer holds), or
-- extends it (a chain such as 021 → 032 → 036). A
-- restated body is the owner's current body plus only the restating migration's own delta, so an
-- edit of the owner that is not carried into the restatement would be undone silently, and so
-- would a chain step a later restatement forgot. Each row below names, for the live function,
-- every rule its owner raises (by error code), the logic that matters where no error code shows it
-- (non-error needles), and the markers of each later step; a missing one fails here. Needs no seed rows.
--
-- Not pinned, on purpose:
--   private.rules_bypassed (019, 030, 072): 030 restates 019's body unchanged (050 only grants it),
--     072 adds OR private.transferring(); the row below pins that body, so a drift in any copy shows.
--   notify_access_changed in 012 and 013: those files create triggers on it, not a body.
--   save_role in 058: ALTER FUNCTION only (SECURITY DEFINER, owner api_owner); the 058 test pins it.
BEGIN;

SELECT plan(55);

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
   -- 072: a transfer's audit transactions are locked before anything is checked.
   ('public.revert_audit_transaction(uuid)', '010', '059, 068, 072',
    ARRAY['audit_already_reverted', 'audit_conflict', 'audit_revert_field_forbidden', 'private.field_rights_column(chk.table_schema',
          'coalesce(rights_tenant, chk.tenant_id) = ANY (private.field_write_tenants(',
          'audit_transfer_not_revertable', 'private.audit_transfer_locked(target.id)']),
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
   -- 073: a row a transfer copies keeps the source's type and size; the allowlist and the cap hold.
   ('private.media_check_file()', '024', '073',
    ARRAY['media_file_immutable', 'media_file_missing', 'media_type_not_allowed', 'media_too_large', 'FROM storage.objects o',
          'NEW.mime_type := meta ->> ''mimetype''', 'private.media_max_bytes(NEW.tenant_id)',
          'copying CONSTANT BOOLEAN := TG_OP = ''INSERT'' AND private.transferring()', 'IF NOT copying']),
   -- 073: the run (F19), after every check of 072's.
   ('public.transfer_products(uuid, uuid, uuid[], text, jsonb, boolean)', '072', '073',
    ARRAY['private.transfer_refusal(source_tenant, target_tenant, transfer_products.mode)', 'transfer_products_invalid',
          'transfer_decision_invalid', 'private.transfer_excluded(source_tenant, target_tenant)', 'transfer_files_pending',
          'private.transfer_check_decisions(report', 'transfer_product_in_use', 'private.transfer_lock_rows()',
          'set_config(''moesa.transfer_id'', new_id::TEXT, TRUE)', 'set_config(''moesa.transfer_id'', '''', TRUE)',
          'private.transfer_apply(new_id)', 'transfer_report_stale', 'transfer_permissions_required',
          'private.tenants_permitting(auth.uid(), ARRAY[target_tenant]',
          'private.tenants_permitting(auth.uid(), ARRAY[transfer_products.source_tenant]']),
   -- 074: no object is planted at, or removed from, a path a transfer still needs (R1, R2).
   ('private.can_write_media_file(text)', '024', '074',
    ARRAY['private.storage_folder_id(object_name) IS NOT NULL', '''public.media'', ''insert''',
          'NOT EXISTS (SELECT 1 FROM public.media m WHERE m.id = private.storage_folder_id(object_name))',
          'private.transfer_upload_allowed(object_name)']),
   ('private.can_delete_media_file(text)', '024', '074',
    ARRAY['private.can_write_media_file(object_name)', 'm.id = private.storage_folder_id(object_name)',
          'NOT private.transfer_file_locked(object_name)']),
   -- 073: a file a move removed keeps its read restriction (I2).
   ('private.media_restriction(uuid)', '060', '073',
    ARRAY['''supplier_identity''', '''supplier_terms''', 'l.entity_type IN (''supplier'', ''purchase_order'')',
          'd.type IN (''pi'', ''commercial_invoice'', ''po'')', 'd.type = ''contract'' AND d.entity_type = ''supplier''',
          'private.media_restriction_hold']),
   ('private.media_guard_delete()', '025', '026',
    ARRAY['public.media_link l WHERE l.tenant_id = OLD.tenant_id AND l.media_id = OLD.id',
          'public.document d WHERE d.tenant_id = OLD.tenant_id AND d.media_id = OLD.id']),
   ('private.document_signed_requires()', '016', '023',
    ARRAY['NEW.status = ''approved'' AND NEW.type = ''spec_sheet''']),
   ('private.rules_bypassed()', '019', '030, 072',
    ARRAY['current_setting(''moesa.rules_bypass'', TRUE) = ''1''', 'current_setting(''role'') = ''none''',
          'session_user IN (''postgres'', ''supabase_admin'')', 'OR private.transferring()']),
   -- 072: the coordinator's standard role leaves the transfer right out.
   ('private.create_standard_role(uuid, text)', '070', '072',
    ARRAY['standard_role_unknown', 'WHEN ''management'' THEN TRUE', 'p.group_name = ''ops_setting'' AND p.command = ''update''',
          'p.resource_name = ''public.media'' AND p.command = ''delete''', 'p.group_name = ''transfer''',
          'OR p.resource_name = ''public.provider_relationship''', 'private.apply_field_defaults(role_id, p_role)']),
   ('public.save_role(jsonb, uuid[], jsonb)', '009', '050',
    ARRAY['role not found', 'DELETE FROM public.role_permission', 'field_grant_exceeds_own', 'private.save_role_field_rights']),
   ('public.my_access(uuid)', '011', '050',
    ARRAY['''permissions''', '''subscription''', '''is_super_admin''', '''fields''', '''code'', t.code', 'private.field_rights(uid, tenant)']),
   ('private.notify_access_changed()', '011', '050',
    ARRAY['public.tenant_owner o', 'TG_TABLE_NAME IN (''role_permission'', ''role_field_permission'')',
          'set_config(''access.tenant_scope'', '''', true)', 'set_config(''access.permitted_tenants'', '''', true)']),
   -- 067: the results are kept for the statement (the views' s repeats the policies' lookup), signed:
   -- an entry whose HMAC does not match is a miss.
   ('private.permitted_tenants(text, text)', '004', '067',
    ARRAY['private.tenants_permitting(auth.uid(), private.tenant_scope(), p_resource_name, p_command)', 'statement_timestamp()',
          'access.permitted_tenants', 'jsonb_build_array(current_setting(''request.jwt.claim.sub'', true)',
          'current_setting(''request.headers'', true), statement_timestamp())', 'SELECT c.secret FROM private.cache_secret c',
          'IF substr(cached, 65, length(cache_key) + 1) = '':'' || cache_key THEN',
          'IF left(cached, 64) = encode(extensions.hmac(convert_to(substr(cached, 66), ''UTF8''), secret, ''sha256''), ''hex'') THEN']),
   -- 067: the transaction's cache is signed the same way, under an array key.
   ('private.tenant_scope()', '004', '067',
    ARRAY['string_to_array(header, '','')::UUID[]', 'private.allowed_tenant()', 'private.requested_tenant()', 'access.tenant_scope',
          'jsonb_build_array(current_setting(''request.jwt.claim.sub'', true)', 'SELECT c.secret FROM private.cache_secret c',
          'IF substr(cached, 65, length(cache_key) + 1) = '':'' || cache_key THEN',
          'IF left(cached, 64) = encode(extensions.hmac(convert_to(substr(cached, 66), ''UTF8''), secret, ''sha256''), ''hex'') THEN']),
   -- Not restated: a test sign-in empties 067's permitted_tenants cache.
   ('private.impersonate_scope(uuid, uuid, uuid[])', '050', '067',
    ARRAY['request.jwt.claims', '''x-tenant-ids''', 'set_config(''access.permitted_tenants'', '''', true)']),
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
          'NEW.entity_tenant_id IS DISTINCT FROM OLD.entity_tenant_id']),
   -- 070: self-signup takes the one company-creation path (allowlisted payload, standard roles).
   ('public.register_tenant(uuid, jsonb)', '009', '070',
    ARRAY['SECURITY DEFINER', 'private.create_company(register_tenant.owner_id, register_tenant.company, NULL)']),
   -- 070: the plan editor writes the audience (final review M2).
   ('public.save_plan(jsonb, text[], jsonb)', '013', '070',
    ARRAY['SECURITY DEFINER', 'plan_default_inactive', 'plan_default_required', 'plan_not_found',
          'UPDATE public.plan p SET is_default = FALSE WHERE p.is_default AND p.id IS DISTINCT FROM saved_id',
          'audience = plan_data ->> ''audience''', 'DELETE FROM public.plan_module pm WHERE pm.plan_id = saved_id',
          'DELETE FROM public.plan_limit pl']),
   -- 071: the audit trusts a header-named actor only on a service-role transaction of a known function,
   -- the provider-invitation function among them (final review M2).
   ('private.audit_service_actor()', '046', '071',
    ARRAY['NEW.actor_id IS NOT NULL OR NEW.actor_role IS DISTINCT FROM ''service_role''', '''x-audit-role''',
          '''amazon-auth''', '''amazon-listing''', '''amazon-schema''', '''amazon-poll''', '''amazon-schema-refresh''',
          '''provider-invitation''', 'NEW.actor_role := v_headers ->> ''x-audit-role''',
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$']);

SELECT is_empty(format($q$ SELECT n FROM unnest(%L::TEXT[]) AS n WHERE strpos(pg_get_functiondef(%L::REGPROCEDURE), n) = 0 $q$,
                       r.needle, r.fn),
                format('%s (owner %s, restated in %s) keeps the owner''s rules and every later step', r.fn, r.owner, r.restater))
FROM restated r
ORDER BY r.restater, r.owner, r.fn::TEXT;

SELECT * FROM finish();
ROLLBACK;
