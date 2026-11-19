CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Provider order links (Plan 2): a client's incident or change request may cite a provider order or
-- shipment shared with it (client_tenant_id = its tenant), never an unshared one, another client's,
-- or one of a provider it has no relationship with. After the relationship ends the client may still
-- cite the rows shared with it (Q4); the provider may still delete its order (F7).
-- A change request on a provider order keeps its cost (cost_impact, cost_payer) under the provider's
-- rights: the client reads NULL, cannot write it, cannot unlink or relink out of it, and its audit
-- history shows it masked; the provider's staff read and write it (Task 6). The same for the cost of a
-- log of an incident on a provider order (cost_amount, cost_currency, cost_payer), and a revert of the
-- provider's change is refused before anything is written (Task 6 fix round 1).
--
-- Sections: links (Task 5), guarded (Task 6).
--
-- Signing in (F4): `RESET ROLE; SELECT private.impersonate_scope(user, active, scope);`.
BEGIN;

SELECT plan(68);

-- Fixture, built here as postgres (ids 0000000068xx):
--   P  ...6801  provider (code LPV); C ...6802 client (rel_c ...6821); D ...6803 another client (rel_d ...6822)
--   pc ...6811  P coordinator (every purchase order and shipment right, every field)
--   co ...6812  C owner
--   cx ...6813  C member whose role holds incidents and change requests, but no purchase order or shipment
--   pm ...6814  provider management: in P every change request and audit right with every field
--               (role ...6833), in C change requests and the audit log without the cost (role ...6834)
--   cr_c ...6892 C's change request on po_c (cost written by pm in the guarded section)
--   inc_c ...6895 C's incident on po_c; its logs ...68a1 (pm's cost), ...68a2 (on C's 'Own order' incident)
--   orders: po_c ...6851 (P for C, sent), po_d ...6852 (P for D, sent), po_own ...6853 (P, no client),
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
   ('00000000-0000-4000-8000-000000006813', 'cx@link.test'),
   ('00000000-0000-4000-8000-000000006814', 'pm@link.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000006811', '00000000-0000-4000-8000-000000006801'),
   ('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802'),
   ('00000000-0000-4000-8000-000000006813', '00000000-0000-4000-8000-000000006802'),
   ('00000000-0000-4000-8000-000000006814', '00000000-0000-4000-8000-000000006801'),
   ('00000000-0000-4000-8000-000000006814', '00000000-0000-4000-8000-000000006802');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000006831', '00000000-0000-4000-8000-000000006801', 'Coordinator'),
   ('00000000-0000-4000-8000-000000006832', '00000000-0000-4000-8000-000000006802', 'Incidents only'),
   ('00000000-0000-4000-8000-000000006833', '00000000-0000-4000-8000-000000006801', 'Management'),
   ('00000000-0000-4000-8000-000000006834', '00000000-0000-4000-8000-000000006802', 'Provider desk');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000006831', p.id FROM public.permission p
WHERE p.group_name IN ('purchase_order', 'shipment', 'product', 'client');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000006832', p.id FROM public.permission p
WHERE p.resource_name IN ('public.incident', 'public.change_request');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT r.id, p.id FROM public.permission p
CROSS JOIN (VALUES ('00000000-0000-4000-8000-000000006833'::UUID), ('00000000-0000-4000-8000-000000006834'::UUID)) AS r (id)
WHERE p.resource_name IN ('public.change_request', 'public.incident', 'public.incident_log', 'public.audit_log', 'public.audit_transaction');

INSERT INTO public.user_role (user_id, role_id) VALUES
   ('00000000-0000-4000-8000-000000006811', '00000000-0000-4000-8000-000000006831'),
   ('00000000-0000-4000-8000-000000006813', '00000000-0000-4000-8000-000000006832'),
   ('00000000-0000-4000-8000-000000006814', '00000000-0000-4000-8000-000000006833'),
   ('00000000-0000-4000-8000-000000006814', '00000000-0000-4000-8000-000000006834');

SELECT private.grant_all_fields('00000000-0000-4000-8000-000000006831');
SELECT private.grant_all_fields('00000000-0000-4000-8000-000000006833');
-- pm writes incident log notes in C (internal_note), never the cost there.
INSERT INTO public.role_field_permission (role_id, resource_name, field, can_read, can_write) VALUES
   ('00000000-0000-4000-8000-000000006834', 'public.incident_log', 'note', TRUE, TRUE);

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
    'May', 'June', 'x', '00000000-0000-4000-8000-000000006854', '00000000-0000-4000-8000-000000006801'),
   ('00000000-0000-4000-8000-000000006892', '00000000-0000-4000-8000-000000006802', 'Guarded', 'customer', '{design}',
    'Red', 'Blue', 'x', '00000000-0000-4000-8000-000000006851', '00000000-0000-4000-8000-000000006801');

INSERT INTO public.incident (id, tenant_id, family, severity, title, what_happened, entity_type, entity_id, entity_tenant_id) VALUES
   ('00000000-0000-4000-8000-000000006895', '00000000-0000-4000-8000-000000006802', 'ol', 's3', 'Guarded incident', 'x',
    'purchase_order', '00000000-0000-4000-8000-000000006851', '00000000-0000-4000-8000-000000006801');

-- The shared orders po_c and po_d are sent: a draft is not shared yet (decision 20). po_del stays a
-- draft (cr_del cites it through the bypass: a client cannot cite a draft, 067's decision 20 section).
UPDATE public.purchase_order SET status = 'sent'
WHERE id IN ('00000000-0000-4000-8000-000000006851', '00000000-0000-4000-8000-000000006852');

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

-- ---------------------------------------------------------------------------------------------------
-- Guarded (Task 6): cr_c's cost is read and written under P's rights (guard_tenant_id = P), whoever
-- in C holds the cost right; a change request on C's own order keeps C's rights.
-- The provider's management, with C in its scope, writes the cost.
RESET ROLE;
-- Each write its own audit transaction, in the row's tenant (one test is one transaction).
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006814', '00000000-0000-4000-8000-000000006801', ARRAY['00000000-0000-4000-8000-000000006801', '00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT lives_ok($$ UPDATE api.change_request SET cost_impact = '500', cost_payer = 'company' WHERE id = '00000000-0000-4000-8000-000000006892' $$,
                'provider management writes the guarded cost');
SELECT results_eq($$ SELECT cost_impact, cost_payer FROM api.change_request WHERE id = '00000000-0000-4000-8000-000000006892' $$,
                  $$ VALUES ('500'::TEXT, 'company'::public.cost_payer) $$, 'provider management reads the guarded cost');

-- The client owner.
RESET ROLE;
SELECT set_config('test.cx_permissions', ARRAY(SELECT p.id FROM public.permission p
                  WHERE p.resource_name IN ('public.incident', 'public.incident_log', 'public.change_request', 'public.audit_log'))::TEXT, TRUE);
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802', ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT results_eq($$ SELECT cost_impact, cost_payer FROM api.change_request WHERE id = '00000000-0000-4000-8000-000000006892' $$,
                  $$ VALUES (NULL::TEXT, NULL::public.cost_payer) $$, 'client owner: cost of a provider-order change request is NULL');
SELECT throws_ok($$ UPDATE api.change_request SET cost_impact = '1' WHERE id = '00000000-0000-4000-8000-000000006892' $$,
                 '42501', 'field_write_forbidden', 'client owner cannot write the guarded cost');
SELECT throws_ok($$ UPDATE api.change_request SET cost_payer = 'customer' WHERE id = '00000000-0000-4000-8000-000000006892' $$,
                 '42501', 'field_write_forbidden', 'client owner cannot write the guarded cost payer');
SELECT throws_ok($$ UPDATE api.change_request SET purchase_order_id = NULL, order_tenant_id = NULL WHERE id = '00000000-0000-4000-8000-000000006892' $$,
                 '42501', 'cost_link_forbidden', 'client cannot unlink to unmask');
SELECT throws_ok($$ UPDATE api.change_request SET purchase_order_id = '00000000-0000-4000-8000-000000006855', order_tenant_id = NULL
                    WHERE id = '00000000-0000-4000-8000-000000006892' $$,
                 '23514', 'order_tenant_immutable', 'client cannot relink to its own order to unmask');
SELECT throws_ok($$ INSERT INTO api.change_request (tenant_id, title, source, change_kinds, current_value, requested_value, reason,
                                                    purchase_order_id, order_tenant_id, cost_impact)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'X', 'customer', '{design}', 'Red', 'Blue', 'x',
                            '00000000-0000-4000-8000-000000006851', '00000000-0000-4000-8000-000000006801', '1') $$,
                 '42501', 'field_write_forbidden', 'client cannot create a provider-order change request with a cost (F1)');
SELECT throws_ok($$ INSERT INTO api.change_request (tenant_id, title, source, change_kinds, current_value, requested_value, reason,
                                                    purchase_order_id, cost_impact)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'X', 'customer', '{design}', 'Red', 'Blue', 'x',
                            '00000000-0000-4000-8000-000000006851', '1') $$,
                 '42501', 'field_write_forbidden', 'nor by leaving out the order tenant (filled before the write guard)');
SELECT throws_ok($$ INSERT INTO api.change_request (tenant_id, title, source, change_kinds, current_value, requested_value, reason,
                                                    purchase_order_id, order_tenant_id, guard_tenant_id, cost_impact)
                    VALUES ('00000000-0000-4000-8000-000000006802', 'X', 'customer', '{design}', 'Red', 'Blue', 'x',
                            '00000000-0000-4000-8000-000000006851', '00000000-0000-4000-8000-000000006801', '00000000-0000-4000-8000-000000006802', '1') $$,
                 '42501', 'field_write_forbidden', 'nor by sending its own tenant as the rights column (F1)');
-- The owner gives a C role the cost (save_role); its own order's change request is C's to cost.
SELECT lives_ok($$ SELECT public.save_role(
                       jsonb_build_object('id', '00000000-0000-4000-8000-000000006832', 'display_name', 'Incidents only'),
                       current_setting('test.cx_permissions')::UUID[],
                       '[{"resource_name": "public.change_request", "field": "cost_impact", "can_read": true, "can_write": true},
                         {"resource_name": "public.change_request", "field": "cost_payer", "can_read": true, "can_write": true},
                         {"resource_name": "public.incident_log", "field": "cost_amount", "can_read": true, "can_write": true},
                         {"resource_name": "public.incident_log", "field": "cost_currency", "can_read": true, "can_write": true},
                         {"resource_name": "public.incident_log", "field": "cost_payer", "can_read": true, "can_write": true}]'::JSONB) $$,
                'client owner grants a role the cost (save_role)');
SELECT lives_ok($$ UPDATE api.change_request SET cost_impact = '42' WHERE title = 'Own order change' $$,
                'client owner writes the cost of a change request on its own order');
SELECT is((SELECT cost_impact FROM api.change_request WHERE title = 'Own order change'), '42', 'client owner reads it');

-- The C role granted the cost.
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006813', '00000000-0000-4000-8000-000000006802', ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT results_eq($$ SELECT cost_impact, cost_payer FROM api.change_request WHERE id = '00000000-0000-4000-8000-000000006892' $$,
                  $$ VALUES (NULL::TEXT, NULL::public.cost_payer) $$, 'client role granted the cost: still NULL on a provider order');
SELECT throws_ok($$ UPDATE api.change_request SET cost_impact = '1', cost_payer = 'customer' WHERE id = '00000000-0000-4000-8000-000000006892' $$,
                 '42501', 'field_write_forbidden', 'client role granted the cost cannot write it on a provider order');
SELECT lives_ok($$ UPDATE api.change_request SET cost_impact = '43', cost_payer = 'customer' WHERE title = 'Own order change' $$,
                'client role writes the cost on its own order');
SELECT results_eq($$ SELECT cost_impact, cost_payer FROM api.change_request WHERE title = 'Own order change' $$,
                  $$ VALUES ('43'::TEXT, 'customer'::public.cost_payer) $$, 'client role reads it on its own order');

-- The provider again: 500 → 600, so the history holds the old value too.
RESET ROLE;
-- Each write its own audit transaction, in the row's tenant (one test is one transaction).
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006814', '00000000-0000-4000-8000-000000006801', ARRAY['00000000-0000-4000-8000-000000006801', '00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT lives_ok($$ UPDATE api.change_request SET cost_impact = '600' WHERE id = '00000000-0000-4000-8000-000000006892' $$, 'provider management writes it again');
SELECT is((SELECT count(*)::INT FROM api.audit_log WHERE record_id = '00000000-0000-4000-8000-000000006892' AND old_data ->> 'cost_impact' = '500'), 1,
          'provider management reads the old cost in the history');

-- The history as the client: the rows of cr_c that carry the cost keys (more than one: the insert and
-- the provider's updates), every cost value masked (F14).
RESET ROLE;
CREATE TEMP VIEW cr_c_cost_history AS
SELECT count(*)::INT AS with_cost,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM unnest(ARRAY[a.old_data, a.new_data]) AS d (data), unnest(ARRAY['cost_impact', 'cost_payer']) AS k (key)
           WHERE d.data ? k.key AND d.data -> k.key <> '{"masked": true}'::JSONB))::INT AS unmasked
FROM api.audit_log a
WHERE a.record_id = '00000000-0000-4000-8000-000000006892'
  AND (a.old_data ? 'cost_impact' OR a.new_data ? 'cost_impact');
GRANT SELECT ON cr_c_cost_history TO authenticated;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802', ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT results_eq($$ SELECT with_cost > 1, unmasked FROM cr_c_cost_history $$, $$ VALUES (TRUE, 0) $$,
                  'client owner: the audit history masks the guarded cost');
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006813', '00000000-0000-4000-8000-000000006802', ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT results_eq($$ SELECT with_cost > 1, unmasked FROM cr_c_cost_history $$, $$ VALUES (TRUE, 0) $$,
                  'client role granted the cost: the audit history masks it');

-- Incident cost (fix round 1): the log of inc_c (C's incident on po_c) carries P's cost.
RESET ROLE;
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006814', '00000000-0000-4000-8000-000000006801', ARRAY['00000000-0000-4000-8000-000000006801', '00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT lives_ok($$ INSERT INTO api.incident_log (id, tenant_id, incident_id, note, cost_amount, cost_currency, cost_payer)
                   VALUES ('00000000-0000-4000-8000-0000000068a1', '00000000-0000-4000-8000-000000006802', '00000000-0000-4000-8000-000000006895', 'Rework', 250, 'EUR', 'company') $$,
                'provider management logs a cost on the client''s provider-order incident');
SELECT results_eq($$ SELECT cost_amount, cost_currency::TEXT, cost_payer FROM api.incident_log WHERE id = '00000000-0000-4000-8000-0000000068a1' $$,
                  $$ VALUES (250::NUMERIC, 'EUR'::TEXT, 'company'::public.cost_payer) $$, 'provider management reads the log cost');

RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802', ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT results_eq($$ SELECT cost_amount, cost_currency::TEXT, cost_payer FROM api.incident_log WHERE id = '00000000-0000-4000-8000-0000000068a1' $$,
                  $$ VALUES (NULL::NUMERIC, NULL::TEXT, NULL::public.cost_payer) $$,
                  'client owner: cost of a provider-order incident log is NULL');
SELECT throws_ok($$ UPDATE api.incident_log SET cost_amount = 1 WHERE id = '00000000-0000-4000-8000-0000000068a1' $$,
                 '42501', 'field_write_forbidden', 'client owner cannot write the log cost');
SELECT throws_ok($$ INSERT INTO api.incident_log (tenant_id, incident_id, note, cost_amount, cost_currency, cost_payer)
                    VALUES ('00000000-0000-4000-8000-000000006802', '00000000-0000-4000-8000-000000006895', 'X', 1, 'EUR', 'customer') $$,
                 '42501', 'field_write_forbidden', 'client owner cannot log a cost on a provider-order incident');
SELECT throws_ok($$ INSERT INTO api.incident_log (tenant_id, incident_id, note, cost_amount, cost_currency, cost_payer, guard_tenant_id)
                    VALUES ('00000000-0000-4000-8000-000000006802', '00000000-0000-4000-8000-000000006895', 'X', 1, 'EUR', 'customer', '00000000-0000-4000-8000-000000006802') $$,
                 '42501', 'field_write_forbidden', 'nor by sending its own tenant as the log''s rights column');
SELECT throws_ok($$ UPDATE api.incident SET entity_type = NULL, entity_id = NULL, entity_tenant_id = NULL WHERE id = '00000000-0000-4000-8000-000000006895' $$,
                 '23514', 'incident_entity_tenant_immutable', 'client cannot unlink the incident to unmask');
SELECT throws_ok($$ UPDATE api.incident SET entity_id = '00000000-0000-4000-8000-000000006855', entity_tenant_id = NULL WHERE id = '00000000-0000-4000-8000-000000006895' $$,
                 '23514', 'incident_entity_tenant_immutable', 'client cannot relink the incident to its own order');
SELECT throws_ok($$ UPDATE api.incident_log SET incident_id = (SELECT id FROM api.incident WHERE title = 'Own order') WHERE id = '00000000-0000-4000-8000-0000000068a1' $$,
                 '42501', 'cost_link_forbidden', 'client cannot move the log to its own incident');
SELECT lives_ok($$ INSERT INTO api.incident_log (id, tenant_id, incident_id, note, cost_amount, cost_currency, cost_payer)
                   SELECT '00000000-0000-4000-8000-0000000068a2', '00000000-0000-4000-8000-000000006802', i.id, 'Own rework', 10, 'EUR', 'company' FROM api.incident i WHERE i.title = 'Own order' $$,
                'client owner logs a cost on its own-order incident');
SELECT results_eq($$ SELECT cost_amount, cost_currency::TEXT, cost_payer FROM api.incident_log WHERE id = '00000000-0000-4000-8000-0000000068a2' $$,
                  $$ VALUES (10::NUMERIC, 'EUR'::TEXT, 'company'::public.cost_payer) $$, 'client owner reads it');

RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006813', '00000000-0000-4000-8000-000000006802', ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT results_eq($$ SELECT cost_amount, cost_currency::TEXT, cost_payer FROM api.incident_log WHERE id = '00000000-0000-4000-8000-0000000068a1' $$,
                  $$ VALUES (NULL::NUMERIC, NULL::TEXT, NULL::public.cost_payer) $$,
                  'client role granted the cost: log cost still NULL on a provider order');
SELECT throws_ok($$ UPDATE api.incident_log SET cost_amount = 1 WHERE id = '00000000-0000-4000-8000-0000000068a1' $$,
                 '42501', 'field_write_forbidden', 'client role granted the cost cannot write the log cost');
SELECT lives_ok($$ UPDATE api.incident_log SET cost_amount = 11 WHERE id = '00000000-0000-4000-8000-0000000068a2' $$,
                'client role writes the log cost on its own-order incident');
SELECT results_eq($$ SELECT cost_amount, cost_currency::TEXT, cost_payer FROM api.incident_log WHERE id = '00000000-0000-4000-8000-0000000068a2' $$,
                  $$ VALUES (11::NUMERIC, 'EUR'::TEXT, 'company'::public.cost_payer) $$, 'client role reads it');

RESET ROLE;
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006814', '00000000-0000-4000-8000-000000006801', ARRAY['00000000-0000-4000-8000-000000006801', '00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT lives_ok($$ UPDATE api.incident_log SET cost_amount = 300 WHERE id = '00000000-0000-4000-8000-0000000068a1' $$, 'provider management changes the log cost');
SELECT is((SELECT count(*)::INT FROM api.audit_log WHERE record_id = '00000000-0000-4000-8000-0000000068a1' AND (old_data ->> 'cost_amount')::NUMERIC = 250), 1,
          'provider management reads the old log cost in the history');

RESET ROLE;
CREATE TEMP VIEW lg_c_cost_history AS
SELECT count(*)::INT AS with_cost,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM unnest(ARRAY[a.old_data, a.new_data]) AS d (data),
                         unnest(ARRAY['cost_amount', 'cost_currency', 'cost_payer']) AS k (key)
           WHERE d.data ? k.key AND d.data -> k.key <> '{"masked": true}'::JSONB))::INT AS unmasked
FROM api.audit_log a
WHERE a.record_id = '00000000-0000-4000-8000-0000000068a1'
  AND (a.old_data ? 'cost_amount' OR a.new_data ? 'cost_amount');
GRANT SELECT ON lg_c_cost_history TO authenticated;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802', ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT results_eq($$ SELECT with_cost > 1, unmasked FROM lg_c_cost_history $$, $$ VALUES (TRUE, 0) $$,
                  'client owner: the audit history masks the log cost');
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006813', '00000000-0000-4000-8000-000000006802', ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT results_eq($$ SELECT with_cost > 1, unmasked FROM lg_c_cost_history $$, $$ VALUES (TRUE, 0) $$,
                  'client role granted the cost: the audit history masks the log cost');

-- Citing a provider's order later moves the logs' cost to the provider (narrows only).
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802', ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT lives_ok($$ UPDATE api.incident SET entity_id = '00000000-0000-4000-8000-000000006851', entity_tenant_id = '00000000-0000-4000-8000-000000006801'
                   WHERE title = 'Own order' $$,
                'client owner links its own-order incident to the provider''s order');
SELECT is((SELECT cost_amount FROM api.incident_log WHERE id = '00000000-0000-4000-8000-0000000068a2'), NULL::NUMERIC,
          'the incident''s logs follow: their cost is now the provider''s');

-- Nor does undoing the provider's change write it: refused before anything is written, in the
-- field's rights tenant.
RESET ROLE;
SELECT set_config('test.cost_tx', (SELECT transaction_id::TEXT FROM public.audit_log
                                   WHERE record_id = '00000000-0000-4000-8000-000000006892' AND new_data ->> 'cost_impact' = '600'), TRUE);
SELECT set_config('test.log_tx', (SELECT transaction_id::TEXT FROM public.audit_log
                                  WHERE record_id = '00000000-0000-4000-8000-0000000068a1' AND (new_data ->> 'cost_amount')::NUMERIC = 300), TRUE);
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802', ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT throws_ok($$ SELECT public.revert_audit_transaction(current_setting('test.cost_tx')::UUID) $$,
                 '42501', 'audit_revert_field_forbidden', 'client owner cannot revert the provider''s cost change');
SELECT throws_ok($$ SELECT public.revert_audit_transaction(current_setting('test.log_tx')::UUID) $$,
                 '42501', 'audit_revert_field_forbidden', 'client owner cannot revert the provider''s log cost change');

-- The overview labels a provider link with the provider order's code (client-visible), looked up in
-- coalesce(entity_tenant_id, tenant_id) through the masked api views; a non-member sees no row.
RESET ROLE;
SELECT set_config('test.po_c_code', (SELECT code FROM public.purchase_order WHERE id = '00000000-0000-4000-8000-000000006851'), TRUE);
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006812', '00000000-0000-4000-8000-000000006802', ARRAY['00000000-0000-4000-8000-000000006802']::UUID[]);
SELECT is((SELECT entity_label FROM api.incident_overview WHERE id = '00000000-0000-4000-8000-000000006895'),
          current_setting('test.po_c_code'), 'client owner: the overview labels a provider link with the order code');
RESET ROLE;
SELECT private.impersonate_scope('00000000-0000-4000-8000-000000006811', '00000000-0000-4000-8000-000000006801', ARRAY['00000000-0000-4000-8000-000000006801']::UUID[]);
SELECT is_empty($$ SELECT entity_label FROM api.incident_overview WHERE id = '00000000-0000-4000-8000-000000006895' $$,
                'non-member of the client: no overview row, no label');

SELECT * FROM finish();
ROLLBACK;
