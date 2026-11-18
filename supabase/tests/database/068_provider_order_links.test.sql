CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Provider order links (Plan 2): a client's incident or change request may cite a provider order or
-- shipment shared with it (client_tenant_id = its tenant), never an unshared one, another client's,
-- or one of a provider it has no relationship with. After the relationship ends the client may still
-- cite the rows shared with it (Q4); the provider may still delete its order (F7).
--
-- Sections: links (Task 5).
--
-- Signing in (F4): `RESET ROLE; SELECT private.impersonate_scope(user, active, scope);`.
BEGIN;

SELECT plan(22);

-- Fixture, built here as postgres (ids 0000000068xx):
--   P  ...6801  provider (code LPV); C ...6802 client (rel_c ...6821); D ...6803 another client (rel_d ...6822)
--   pc ...6811  P coordinator (every purchase order and shipment right, every field)
--   co ...6812  C owner
--   cx ...6813  C member whose role holds incidents and change requests, but no purchase order or shipment
--   orders: po_c ...6851 (P for C), po_d ...6852 (P for D), po_own ...6853 (P, no client),
--           po_del ...6854 (P for C, draft, cited by the client's change request cr_del ...6891),
--           po_cown ...6855 (C's own order, its supplier ...6882)
--   shipments: shp_c ...6871 (P for C), shp_own ...6872 (P, no client); warehouses ...6875 (C), ...6876 (P)
INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000006801', 'Link Provider', 'LPV'),
   ('00000000-0000-4000-8000-000000006802', 'Link Client', 'LCL'),
   ('00000000-0000-4000-8000-000000006803', 'Link Other', 'LOC');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000006811', 'pc@link.test'),
   ('00000000-0000-4000-8000-000000006812', 'co@link.test'),
   ('00000000-0000-4000-8000-000000006813', 'cx@link.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000006811', '00000000-0000-4000-8000-000000006801'),
   ('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802'),
   ('00000000-0000-4000-8000-000000006813', '00000000-0000-4000-8000-000000006802');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000006831', '00000000-0000-4000-8000-000000006801', 'Coordinator'),
   ('00000000-0000-4000-8000-000000006832', '00000000-0000-4000-8000-000000006802', 'Incidents only');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000006831', p.id FROM public.permission p
WHERE p.group_name IN ('purchase_order', 'shipment', 'product', 'client');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000006832', p.id FROM public.permission p
WHERE p.resource_name IN ('public.incident', 'public.change_request');

INSERT INTO public.user_role (user_id, role_id) VALUES
   ('00000000-0000-4000-8000-000000006811', '00000000-0000-4000-8000-000000006831'),
   ('00000000-0000-4000-8000-000000006813', '00000000-0000-4000-8000-000000006832');

SELECT private.grant_all_fields('00000000-0000-4000-8000-000000006831');

INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, procurement_model) VALUES
   ('00000000-0000-4000-8000-000000006821', '00000000-0000-4000-8000-000000006801', '00000000-0000-4000-8000-000000006802',
    'LCL', 'Link Client', 'provider'),
   ('00000000-0000-4000-8000-000000006822', '00000000-0000-4000-8000-000000006801', '00000000-0000-4000-8000-000000006803',
    'LOC', 'Link Other', 'provider');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, default_incoterm, deposit_rate, status) VALUES
   ('00000000-0000-4000-8000-000000006881', '00000000-0000-4000-8000-000000006801', 'SU1', 'Supplier One', 'Türkiye', 'EXW', 30, 'approved'),
   ('00000000-0000-4000-8000-000000006882', '00000000-0000-4000-8000-000000006802', 'SU2', 'Supplier Two', 'Türkiye', 'EXW', 30, 'approved');

-- The rows, written without a user (bypass), as a provider would through the app.
SELECT set_config('moesa.rules_bypass', '1', TRUE);

INSERT INTO public.purchase_order (id, tenant_id, client_tenant_id, supplier_id, currency, incoterm, deposit_rate) VALUES
   ('00000000-0000-4000-8000-000000006851', '00000000-0000-4000-8000-000000006801', '00000000-0000-4000-8000-000000006802',
    '00000000-0000-4000-8000-000000006881', 'USD', 'EXW', 30),
   ('00000000-0000-4000-8000-000000006852', '00000000-0000-4000-8000-000000006801', '00000000-0000-4000-8000-000000006803',
    '00000000-0000-4000-8000-000000006881', 'USD', 'EXW', 30),
   ('00000000-0000-4000-8000-000000006853', '00000000-0000-4000-8000-000000006801', NULL,
    '00000000-0000-4000-8000-000000006881', 'USD', 'EXW', 30),
   ('00000000-0000-4000-8000-000000006854', '00000000-0000-4000-8000-000000006801', '00000000-0000-4000-8000-000000006802',
    '00000000-0000-4000-8000-000000006881', 'USD', 'EXW', 30),
   ('00000000-0000-4000-8000-000000006855', '00000000-0000-4000-8000-000000006802', NULL,
    '00000000-0000-4000-8000-000000006882', 'USD', 'EXW', 30);

INSERT INTO public.warehouse (id, tenant_id, display_name, city, country) VALUES
   ('00000000-0000-4000-8000-000000006875', '00000000-0000-4000-8000-000000006802', 'Client DC', 'Rosbach', 'DE'),
   ('00000000-0000-4000-8000-000000006876', '00000000-0000-4000-8000-000000006801', 'Provider DC', 'Istanbul', 'TR');

INSERT INTO public.shipment (id, tenant_id, client_tenant_id, mode, delivery_warehouse_id, warehouse_tenant_id, is_insured) VALUES
   ('00000000-0000-4000-8000-000000006871', '00000000-0000-4000-8000-000000006801', '00000000-0000-4000-8000-000000006802',
    'road', '00000000-0000-4000-8000-000000006875', '00000000-0000-4000-8000-000000006802', FALSE),
   ('00000000-0000-4000-8000-000000006872', '00000000-0000-4000-8000-000000006801', NULL,
    'road', '00000000-0000-4000-8000-000000006876', '00000000-0000-4000-8000-000000006801', FALSE);

INSERT INTO public.change_request (id, tenant_id, title, source, change_kinds, current_value, requested_value, reason,
                                   purchase_order_id, order_tenant_id) VALUES
   ('00000000-0000-4000-8000-000000006891', '00000000-0000-4000-8000-000000006802', 'Cancel draft', 'customer', '{deadline}',
    'May', 'June', 'x', '00000000-0000-4000-8000-000000006854', '00000000-0000-4000-8000-000000006801');

SELECT set_config('moesa.rules_bypass', '', TRUE);

-- The constraint itself (the guard is bypassed): a provider link names an order or a shipment only.
SELECT set_config('moesa.rules_bypass', '1', TRUE);
SELECT throws_ok($$ INSERT INTO public.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'ol', 's2', 'X', 'x', 'product', gen_random_uuid(),
                            '00000000-0000-4000-8000-000000006801') $$,
                 '23514', 'new row for relation "incident" violates check constraint "incident_entity_tenant_kind"',
                 'a provider link names an order or a shipment only (constraint)');
SELECT set_config('moesa.rules_bypass', '', TRUE);

-- ---------------------------------------------------------------------------------------------------
-- Links (Task 5), as the client owner.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802',
                                 ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);

SELECT lives_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                   VALUES ('00000000-0000-4000-8000-000000006802', 'ol', 's2', 'Damaged', 'x', 'purchase_order',
                           '00000000-0000-4000-8000-000000006851', '00000000-0000-4000-8000-000000006801') $$,
                'client incident on a shared provider order');
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'ol', 's2', 'X', 'x', 'purchase_order',
                            '00000000-0000-4000-8000-000000006852', '00000000-0000-4000-8000-000000006801') $$,
                 '23514', 'provider_link_forbidden', 'an order shared with another client is refused');
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'ol', 's2', 'X', 'x', 'purchase_order',
                            '00000000-0000-4000-8000-000000006853', '00000000-0000-4000-8000-000000006801') $$,
                 '23514', 'provider_link_forbidden', 'an unshared provider order is refused');
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'ol', 's2', 'X', 'x', 'purchase_order',
                            gen_random_uuid(), '00000000-0000-4000-8000-000000006801') $$,
                 '23514', 'provider_link_forbidden', 'an unknown id gets the same message');
SELECT lives_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                   VALUES ('00000000-0000-4000-8000-000000006802', 'ot', 's3', 'Late truck', 'x', 'shipment',
                           '00000000-0000-4000-8000-000000006871', '00000000-0000-4000-8000-000000006801') $$,
                'client incident on a shared provider shipment');
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'ot', 's3', 'X', 'x', 'shipment',
                            '00000000-0000-4000-8000-000000006872', '00000000-0000-4000-8000-000000006801') $$,
                 '23514', 'provider_link_forbidden', 'an unshared provider shipment is refused');
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'ol', 's2', 'X', 'x', 'purchase_order',
                            '00000000-0000-4000-8000-000000006852', '00000000-0000-4000-8000-000000006803') $$,
                 '23514', 'relationship_inactive', 'a tenant that is not the client''s provider is refused');
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'ol', 's2', 'X', 'x', 'product',
                            gen_random_uuid(), '00000000-0000-4000-8000-000000006801') $$,
                 '23514', 'provider_link_forbidden', 'a provider link names an order or a shipment only (guard)');
SELECT lives_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                   VALUES ('00000000-0000-4000-8000-000000006802', 'ol', 's3', 'Own order', 'x', 'purchase_order',
                           '00000000-0000-4000-8000-000000006855', '00000000-0000-4000-8000-000000006802') $$,
                'client incident on its own order, naming its own tenant');
RESET ROLE;
SELECT is((SELECT entity_tenant_id FROM public.incident WHERE title = 'Own order'), NULL::UUID,
          'an own-tenant link is stored without a tenant');

SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802',
                                 ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT lives_ok($$ INSERT INTO api.change_request (tenant_id, title, source, change_kinds, current_value, requested_value, reason,
                                                   purchase_order_id, order_tenant_id)
                   VALUES ('00000000-0000-4000-8000-000000006802', 'Change colour', 'customer', '{design}', 'Red', 'Blue', 'x',
                           '00000000-0000-4000-8000-000000006851', '00000000-0000-4000-8000-000000006801') $$,
                'client change request on a shared provider order');
SELECT throws_ok($$ INSERT INTO api.change_request (tenant_id, title, source, change_kinds, current_value, requested_value, reason,
                                                    purchase_order_id, order_tenant_id)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'X', 'customer', '{design}', 'Red', 'Blue', 'x',
                            '00000000-0000-4000-8000-000000006852', '00000000-0000-4000-8000-000000006801') $$,
                 '23514', 'provider_link_forbidden', 'a change request on another client''s order is refused');
SELECT lives_ok($$ INSERT INTO api.change_request (tenant_id, title, source, change_kinds, current_value, requested_value, reason,
                                                   purchase_order_id)
                   VALUES ('00000000-0000-4000-8000-000000006802', 'Own order change', 'customer', '{design}', 'Red', 'Blue', 'x',
                           '00000000-0000-4000-8000-000000006855') $$,
                'client change request on its own order, without the order tenant');
RESET ROLE;
SELECT is((SELECT order_tenant_id FROM public.change_request WHERE title = 'Own order change'),
          '00000000-0000-4000-8000-000000006802'::UUID, 'an own order link stores the own tenant (F8)');

-- A member without the read right on orders cannot cite one.
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006813', '00000000-0000-4000-8000-000000006802',
                                 ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'ol', 's2', 'X', 'x', 'purchase_order',
                            '00000000-0000-4000-8000-000000006851', '00000000-0000-4000-8000-000000006801') $$,
                 '23514', 'provider_link_forbidden', 'a member without the order read right cannot cite one');

-- The end: existing links stay; the shared rows may still be cited (Q4), others stay refused.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802',
                                 ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT lives_ok($$ SELECT public.end_provider_relationship('00000000-0000-4000-8000-000000006821') $$,
                'relationship ended (as the client owner)');
SELECT lives_ok($$ UPDATE api.incident SET title = 'Damaged on arrival' WHERE title = 'Damaged' $$,
                'an existing link stays valid after the end');
SELECT lives_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                   VALUES ('00000000-0000-4000-8000-000000006802', 'ol', 's2', 'Late', 'x', 'purchase_order',
                           '00000000-0000-4000-8000-000000006851', '00000000-0000-4000-8000-000000006801') $$,
                'a shared order may still be cited after the end (Q4)');
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'ol', 's2', 'X', 'x', 'purchase_order',
                            '00000000-0000-4000-8000-000000006853', '00000000-0000-4000-8000-000000006801') $$,
                 '23514', 'provider_link_forbidden', 'an unshared provider order stays refused after the end');

-- The provider's draft order cited by the client's change request is deleted (F7). Users never delete
-- orders (029 revokes DELETE); a delete comes from the system, as here (postgres, no bypass), or from
-- the provider tenant's delete cascading to its orders.
RESET ROLE;
SELECT lives_ok($$ DELETE FROM public.purchase_order WHERE id = '00000000-0000-4000-8000-000000006854' $$,
                'a draft order a client change request cites can be deleted');
SELECT is((SELECT ROW(purchase_order_id, order_tenant_id)::TEXT FROM public.change_request
           WHERE id = '00000000-0000-4000-8000-000000006891'),
          ROW(NULL::UUID, '00000000-0000-4000-8000-000000006801'::UUID)::TEXT,
          'the change request loses the order and keeps its tenant');

SELECT * FROM finish();
ROLLBACK;
