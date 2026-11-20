CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- 001: the build states Supabase's legacy default ACL in public itself. private.enable_field_security
-- copies INSERT/UPDATE/DELETE onto each api view from its base table, so on a project created without
-- those defaults (newer hosted projects) the writable views came out SELECT-only and every save got
-- 42501 "permission denied for view". CI runs this suite with the hosted default simulated, so the
-- pinned sets below fail there if a migration starts depending on the project's default ACL again.
-- A new writable api view belongs in these lists.
BEGIN;

SELECT plan(4);

SELECT set_eq(
    $$ SELECT c.relname::TEXT FROM pg_class c WHERE c.relnamespace = 'api'::regnamespace AND c.relkind = 'v'
       AND has_table_privilege('authenticated', c.oid, 'INSERT') $$,
    ARRAY['amazon_product_type_definition', 'brand', 'change_request', 'change_request_product', 'contact',
          'document', 'incident', 'incident_deadline', 'incident_log', 'market_cell', 'media', 'media_link',
          'module', 'permission', 'plan', 'plan_limit', 'plan_module', 'platform', 'platform_account', 'product',
          'project', 'project_product', 'project_task', 'provider_relationship', 'purchase_order',
          'purchase_order_line', 'purchase_order_payment', 'purchase_order_update', 'role', 'role_permission',
          'setting', 'shipment', 'shipment_event', 'shipment_line', 'shipment_purchase_order', 'sourcing',
          'subscription', 'supplier', 'supplier_contact', 'task_template', 'tenant', 'tenant_owner',
          'tenant_user', 'user', 'user_role', 'warehouse'],
    'authenticated inserts through exactly the writable api views');

SELECT set_eq(
    $$ SELECT c.relname::TEXT FROM pg_class c WHERE c.relnamespace = 'api'::regnamespace AND c.relkind = 'v'
       AND has_any_column_privilege('authenticated', c.oid, 'UPDATE') $$,
    ARRAY['amazon_product_type_definition', 'brand', 'change_request', 'change_request_product', 'contact',
          'document', 'incident', 'incident_deadline', 'incident_log', 'market_cell', 'media', 'media_link',
          'module', 'permission', 'plan', 'plan_limit', 'plan_module', 'platform', 'platform_account', 'product',
          'project', 'project_gate', 'project_product', 'project_task', 'provider_relationship', 'purchase_order',
          'purchase_order_line', 'purchase_order_payment', 'purchase_order_update', 'role', 'role_permission',
          'setting', 'shipment', 'shipment_event', 'shipment_line', 'shipment_purchase_order', 'sourcing',
          'subscription', 'supplier', 'supplier_contact', 'task_template', 'tenant', 'tenant_owner', 'user',
          'user_role', 'warehouse'],
    'authenticated updates through exactly the writable api views');

SELECT set_eq(
    $$ SELECT c.relname::TEXT FROM pg_class c WHERE c.relnamespace = 'api'::regnamespace AND c.relkind = 'v'
       AND has_table_privilege('authenticated', c.oid, 'DELETE') $$,
    ARRAY['amazon_product_type_definition', 'brand', 'change_request_product', 'contact', 'incident_deadline',
          'incident_log', 'market_cell', 'media', 'media_link', 'module', 'permission', 'plan', 'plan_limit',
          'plan_module', 'platform', 'platform_account', 'project_product', 'project_task',
          'provider_relationship', 'purchase_order_line', 'purchase_order_payment', 'purchase_order_update',
          'role', 'role_permission', 'setting', 'shipment_event', 'shipment_line', 'shipment_purchase_order',
          'sourcing', 'subscription', 'supplier_contact', 'task_template', 'tenant', 'tenant_owner',
          'tenant_user', 'user', 'user_role', 'warehouse'],
    'authenticated deletes through exactly the deletable api views');

-- 064 takes the defaults back: a table or sequence postgres creates in public grants the client roles nothing.
SELECT is_empty(
    $$ SELECT d.defaclobjtype, a.grantee::regrole
       FROM pg_default_acl d, aclexplode(d.defaclacl) a
       WHERE d.defaclrole = 'postgres'::regrole AND d.defaclnamespace = 'public'::regnamespace
         AND d.defaclobjtype IN ('r', 'S') AND a.grantee IN ('anon'::regrole, 'authenticated'::regrole) $$,
    'postgres''s default ACL in public grants anon and authenticated nothing on tables or sequences');

SELECT * FROM finish();

ROLLBACK;
