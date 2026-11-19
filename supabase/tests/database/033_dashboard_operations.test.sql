CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Dashboard boxes for orders and shipments (033): only open orders (neither draft, closed nor
-- cancelled) with their planned balance date, the late flag and the days to ETA of open shipments,
-- accepted shipments left out, the client named by its client_code (none for an own row), and
-- another tenant that sees none of them. What it writes is rolled back.
BEGIN;

SELECT plan(9);

-- Fixture, built here as postgres (the seed is not on the new model yet):
--   provider  ...3301  code PRV; owned by staff 3311; warehouse 3363; supplier TR1 3381
--   client    ...3302  provider procures (relationship 3321, client_code THO); warehouse 3361;
--                      staff invited with role 3331 (read warehouses)
--   other     ...3303  owned by 3312, no relationship
INSERT INTO public.plan (display_name, is_active) VALUES ('Dashboard test plan', TRUE);

INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000003301', 'Provider Trading', 'PRV'),
   ('00000000-0000-4000-8000-000000003302', 'Thor Trading', 'THO'),
   ('00000000-0000-4000-8000-000000003303', 'Other Company', 'OTH');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000003311', 'staff@dashboard.test'),
   ('00000000-0000-4000-8000-000000003312', 'other@dashboard.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003311', '00000000-0000-4000-8000-000000003301'),
   ('00000000-0000-4000-8000-000000003312', '00000000-0000-4000-8000-000000003303');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003311', '00000000-0000-4000-8000-000000003301'),
   ('00000000-0000-4000-8000-000000003311', '00000000-0000-4000-8000-000000003302'),
   ('00000000-0000-4000-8000-000000003312', '00000000-0000-4000-8000-000000003303');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000003331', '00000000-0000-4000-8000-000000003302', 'Provider staff');
INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000003331', p.id FROM public.permission p
WHERE p.resource_name = 'public.warehouse' AND p.command = 'select';
INSERT INTO public.user_role (user_id, role_id) VALUES
   ('00000000-0000-4000-8000-000000003311', '00000000-0000-4000-8000-000000003331');

INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, procurement_model) VALUES
   ('00000000-0000-4000-8000-000000003321', '00000000-0000-4000-8000-000000003301', '00000000-0000-4000-8000-000000003302',
    'THO', 'Thor Trading', 'provider');

INSERT INTO public.warehouse (id, tenant_id, display_name, city, country) VALUES
   ('00000000-0000-4000-8000-000000003361', '00000000-0000-4000-8000-000000003302', 'Rosbach', 'Rosbach', 'DE'),
   ('00000000-0000-4000-8000-000000003363', '00000000-0000-4000-8000-000000003301', 'Provider WH', 'Istanbul', 'TR');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, default_incoterm, status) VALUES
   ('00000000-0000-4000-8000-000000003381', '00000000-0000-4000-8000-000000003301', 'TR1', 'Bir', 'Türkiye', 'EXW', 'approved');

SELECT private.impersonate('00000000-0000-4000-8000-000000003311', '00000000-0000-4000-8000-000000003301');

-- Four client orders (one left a draft, one cancelled below), an own order, three client shipments
-- (one accepted below) and an own shipment.
INSERT INTO api.purchase_order (id, tenant_id, client_tenant_id, supplier_id, currency)
SELECT x.id, '00000000-0000-4000-8000-000000003301', '00000000-0000-4000-8000-000000003302', '00000000-0000-4000-8000-000000003381', 'USD'
FROM (VALUES ('00000000-0000-4000-8000-000000033011'::UUID), ('00000000-0000-4000-8000-000000033012'), ('00000000-0000-4000-8000-000000033013'), ('00000000-0000-4000-8000-000000033014')) AS x (id);
INSERT INTO api.purchase_order (id, tenant_id, supplier_id, currency)
VALUES ('00000000-0000-4000-8000-000000033015', '00000000-0000-4000-8000-000000003301', '00000000-0000-4000-8000-000000003381', 'USD');
INSERT INTO api.purchase_order_payment (tenant_id, purchase_order_id, kind, amount, currency, planned_on)
VALUES ('00000000-0000-4000-8000-000000003301', '00000000-0000-4000-8000-000000033012', 'balance', 100, 'USD', '2027-02-01');
INSERT INTO api.shipment (id, tenant_id, client_tenant_id, mode, delivery_warehouse_id)
SELECT x.id, '00000000-0000-4000-8000-000000003301', '00000000-0000-4000-8000-000000003302', 'road', '00000000-0000-4000-8000-000000003361'
FROM (VALUES ('00000000-0000-4000-8000-000000033041'::UUID), ('00000000-0000-4000-8000-000000033042'), ('00000000-0000-4000-8000-000000033043')) AS x (id);
INSERT INTO api.shipment (id, tenant_id, mode, delivery_warehouse_id)
VALUES ('00000000-0000-4000-8000-000000033044', '00000000-0000-4000-8000-000000003301', 'road', '00000000-0000-4000-8000-000000003363');
RESET ROLE;
SELECT set_config('moesa.rules_bypass', '1', TRUE);
UPDATE public.purchase_order SET status = x.status::public.purchase_order_status
FROM (VALUES ('00000000-0000-4000-8000-000000033011'::UUID, 'sent'), ('00000000-0000-4000-8000-000000033012', 'in_production'),
             ('00000000-0000-4000-8000-000000033014', 'cancelled'), ('00000000-0000-4000-8000-000000033015', 'sent')) AS x (id, status)
WHERE purchase_order.id = x.id;
UPDATE public.shipment SET status = x.status::public.shipment_status, eta = x.eta
FROM (VALUES ('00000000-0000-4000-8000-000000033041'::UUID, 'in_transit', current_date - 2), ('00000000-0000-4000-8000-000000033042', 'loaded', current_date + 3),
             ('00000000-0000-4000-8000-000000033043', 'accepted', current_date), ('00000000-0000-4000-8000-000000033044', 'booked', current_date + 9)) AS x (id, status, eta)
WHERE shipment.id = x.id;
SELECT set_config('moesa.rules_bypass', '', TRUE);
SELECT private.impersonate('00000000-0000-4000-8000-000000003311', '00000000-0000-4000-8000-000000003301');

SELECT is((SELECT string_agg(status::TEXT, ',' ORDER BY status) FROM api.dashboard_purchase_order
           WHERE purchase_order_id IN ('00000000-0000-4000-8000-000000033011', '00000000-0000-4000-8000-000000033012', '00000000-0000-4000-8000-000000033013', '00000000-0000-4000-8000-000000033014')),
          'sent,in_production', 'open orders only');
SELECT is((SELECT balance_planned_on FROM api.dashboard_purchase_order WHERE purchase_order_id = '00000000-0000-4000-8000-000000033012'),
          '2027-02-01'::DATE, 'the balance date');
SELECT is((SELECT overdue FROM api.dashboard_shipment WHERE shipment_id = '00000000-0000-4000-8000-000000033041'), TRUE, 'a passed ETA is late');
SELECT is((SELECT days_to_eta FROM api.dashboard_shipment WHERE shipment_id = '00000000-0000-4000-8000-000000033042'), 3, 'days to ETA');
SELECT is((SELECT count(*)::INT FROM api.dashboard_shipment WHERE shipment_id = '00000000-0000-4000-8000-000000033043'), 0,
          'accepted shipments leave the dashboard');
SELECT is((SELECT string_agg(coalesce(client_code, '-') || ':' || coalesce(client_tenant_id::TEXT, '-'), ',' ORDER BY code)
           FROM api.dashboard_purchase_order WHERE purchase_order_id IN ('00000000-0000-4000-8000-000000033011', '00000000-0000-4000-8000-000000033015')),
          '-:-,THO:00000000-0000-4000-8000-000000003302', 'an order names its client by client_code, an own order none');
SELECT is((SELECT string_agg(concat_ws(':', coalesce(client_code, '-'), coalesce(warehouse_name, '-'), delivery_address), ',' ORDER BY code)
           FROM api.dashboard_shipment WHERE shipment_id IN ('00000000-0000-4000-8000-000000033041', '00000000-0000-4000-8000-000000033044')),
          '-:Provider WH:Provider WH, Istanbul, TR,THO:-:Rosbach, Rosbach, DE',
          'a shipment names its client by client_code, and its delivery address (the client''s warehouse is not in the caller''s scope)');
SELECT ok(NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name IN ('dashboard_purchase_order', 'dashboard_shipment')
                        AND column_name LIKE 'customer%'), 'the dashboards name no customer');

-- Another company's user: private is not reachable while impersonating, so back to postgres first.
RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000003312', '00000000-0000-4000-8000-000000003303');
SELECT is((SELECT count(*)::INT FROM api.dashboard_shipment), 0, 'another tenant sees none');

SELECT * FROM finish();

ROLLBACK;
