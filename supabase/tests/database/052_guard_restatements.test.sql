CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Later migrations restate functions an earlier migration owns: 052 the guards' cascade exits (R7)
-- and request identity (R6), 058 the RPCs as api_owner definers, 059 the audit revert, 060 the
-- Storage read. A restated body is the owner's current body plus only the restating migration's own
-- delta, so a later edit of the owner that is not carried into the restatement would be undone
-- silently. Each row below names, for the live function, every rule its owner raises (by error code)
-- and the markers of the restating delta; a missing one fails here. Needs no seed rows.
BEGIN;

SELECT plan(16);

CREATE TEMP TABLE restated (fn REGPROCEDURE, owner TEXT, restater TEXT, needle TEXT[]) ON COMMIT DROP;

INSERT INTO restated (fn, owner, restater, needle)
VALUES
   ('private.purchase_order_line_guard()', '030', '052',
    ARRAY['po_line_identity_immutable', 'po_line_product_required', 'po_line_spec_invalid', 'po_locked', 'po_spec_sheet_required',
          'parent_gone(''public.purchase_order''']),
   ('private.purchase_order_child_guard()', '030', '052',
    ARRAY['po_closed', 'parent_gone(''public.purchase_order''']),
   ('private.shipment_purchase_order_guard()', '031', '052',
    ARRAY['client_mismatch', 'shipment_locked', 'shipment_po_has_lines', 'shipment_po_link_immutable', 'shipment_po_not_open',
          'parent_gone(''public.shipment''']),
   ('private.shipment_line_guard()', '031', '052',
    ARRAY['shipment_locked', 'shipment_quantity_exceeds_po', 'parent_gone(''public.shipment''']),
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
   ('public.revert_audit_transaction(uuid)', '010', '059',
    ARRAY['audit_already_reverted', 'audit_conflict', 'audit_revert_field_forbidden']),
   ('private.can_read_media_file(text)', '024', '060',
    ARRAY['private.tenants_permitting', 'private.media_restriction']);

SELECT is_empty(format($q$ SELECT n FROM unnest(%L::TEXT[]) AS n WHERE strpos(pg_get_functiondef(%L::REGPROCEDURE), n) = 0 $q$,
                       r.needle, r.fn),
                format('%s (owner %s, restated in %s) keeps the owner''s rules and its own delta', r.fn, r.owner, r.restater))
FROM restated r
ORDER BY r.restater, r.owner, r.fn::TEXT;

SELECT * FROM finish();
ROLLBACK;
