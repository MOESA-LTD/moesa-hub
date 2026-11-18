CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Shipments (031): the code from next_code (the tenant's code, or the client_code of the
-- relationship), the delivery warehouse in the tenant the shipment is for and its address snapshot,
-- the client inherited by the orders, lines and events of a shipment, an order of the shipment's
-- own client only, the open orders only, the lines of linked orders, the quantity cap with the
-- order's tolerance (a cancelled shipment frees its quantity), the status flow and what each status
-- needs (a line before loading), the lock from loaded, the dispute deadline from the supplier's
-- damage notice, acceptance (the delivery receipt, no reservations straight from delivered, a
-- settled dispute as it is), the overview's client, orders, products and PSI warning, the
-- relationship rules of a shipment for a client tenant, the share lock on the shipment, the
-- rules_bypass flag a user cannot use, and the cascade of a removed shipment. What it writes is
-- rolled back.
BEGIN;

SELECT plan(73);

-- Fixture, built here as postgres (the seed is not on the new model yet):
--   provider         ...3101  code PRV; owned by staff; warehouse 3163 (Istanbul)
--   client           ...3102  provider procures (relationship 3121, client_code THO); warehouses
--                             Rosbach 3161 and Hamburg 3165; products THO-MOP 3141, THO-CONES 3142
--   client2          ...3103  provider procures (relationship 3122, client_code ODN); warehouse 3162
--   stranger         ...3104  no relationship; warehouse 3164
--   client_proc      ...3105  client procures (relationship 3123)
--   provider second  ...3106  also owned by staff; no relationship
--   staff            ...3111  provider owner, invited into the client (not client2) with role 3131
--                             (read products and warehouses)
--   uninvited        ...3112  provider member with role 3132 (every shipment and purchase order
--                             right), not in the client, no warehouse right
--   client owner     ...3113
--   suppliers        CN1 3181 (FOB, 48 hours to report damage), TR1 3182 (EXW)
INSERT INTO public.plan (display_name, is_active) VALUES ('Shipments test plan', TRUE);

INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000003101', 'Provider Trading', 'PRV'),
   ('00000000-0000-4000-8000-000000003102', 'Thor Trading', 'THO'),
   ('00000000-0000-4000-8000-000000003103', 'Odin Goods', 'ODN'),
   ('00000000-0000-4000-8000-000000003104', 'Loki Wares', 'LOK'),
   ('00000000-0000-4000-8000-000000003105', 'Freya Home', 'FRY'),
   ('00000000-0000-4000-8000-000000003106', 'Provider Second', 'PRS');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000003111', 'staff@shipments.test'),
   ('00000000-0000-4000-8000-000000003112', 'uninvited@shipments.test'),
   ('00000000-0000-4000-8000-000000003113', 'client-owner@shipments.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003101'),
   ('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003106'),
   ('00000000-0000-4000-8000-000000003113', '00000000-0000-4000-8000-000000003102');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003101'),
   ('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003102'),
   ('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003106'),
   ('00000000-0000-4000-8000-000000003112', '00000000-0000-4000-8000-000000003101'),
   ('00000000-0000-4000-8000-000000003113', '00000000-0000-4000-8000-000000003102');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000003131', '00000000-0000-4000-8000-000000003102', 'Provider staff'),
   ('00000000-0000-4000-8000-000000003132', '00000000-0000-4000-8000-000000003101', 'Shipping clerk');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000003131', p.id
FROM public.permission p
WHERE p.resource_name IN ('public.product', 'public.warehouse') AND p.command = 'select';

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000003132', p.id
FROM public.permission p
WHERE p.group_name IN ('shipment', 'purchase_order');

INSERT INTO public.user_role (user_id, role_id) VALUES
   ('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003131'),
   ('00000000-0000-4000-8000-000000003112', '00000000-0000-4000-8000-000000003132');

INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, procurement_model) VALUES
   ('00000000-0000-4000-8000-000000003121', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003102',
    'THO', 'Thor Trading', 'provider'),
   ('00000000-0000-4000-8000-000000003122', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003103',
    'ODN', 'Odin Goods', 'provider'),
   ('00000000-0000-4000-8000-000000003123', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003105',
    'FRY', 'Freya Home', 'client');

INSERT INTO public.warehouse (id, tenant_id, display_name, address, postal_code, city, country) VALUES
   ('00000000-0000-4000-8000-000000003161', '00000000-0000-4000-8000-000000003102', 'Rosbach', 'Industriestr. 1', '61191', 'Rosbach', 'DE'),
   ('00000000-0000-4000-8000-000000003162', '00000000-0000-4000-8000-000000003103', 'Odin DC', NULL, NULL, 'Oslo', 'NO'),
   ('00000000-0000-4000-8000-000000003163', '00000000-0000-4000-8000-000000003101', 'Provider WH', NULL, NULL, 'Istanbul', 'TR'),
   ('00000000-0000-4000-8000-000000003164', '00000000-0000-4000-8000-000000003104', 'Loki WH', NULL, NULL, 'Bergen', 'NO'),
   ('00000000-0000-4000-8000-000000003165', '00000000-0000-4000-8000-000000003102', 'Hamburg', NULL, NULL, 'Hamburg', 'DE');

INSERT INTO public.product (id, tenant_id, sku, display_name) VALUES
   ('00000000-0000-4000-8000-000000003141', '00000000-0000-4000-8000-000000003102', 'THO-MOP', 'Mop 40 cm'),
   ('00000000-0000-4000-8000-000000003142', '00000000-0000-4000-8000-000000003102', 'THO-CONES', 'Cones'),
   ('00000000-0000-4000-8000-000000003143', '00000000-0000-4000-8000-000000003101', 'PRV-001', 'Provider lamp');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, default_incoterm, damage_notice_hours, status) VALUES
   ('00000000-0000-4000-8000-000000003181', '00000000-0000-4000-8000-000000003101', 'CN1', 'Bir', 'China', 'FOB', 48, 'approved'),
   ('00000000-0000-4000-8000-000000003182', '00000000-0000-4000-8000-000000003101', 'TR1', 'Iki', 'Türkiye', 'EXW', NULL, 'approved');

-- Orders, as the provider's owner: 3191 and 3192 for the client, 3193 for client2, 3194 an own one.
SELECT private.impersonate('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003101');
INSERT INTO api.purchase_order (id, tenant_id, client_tenant_id, supplier_id, currency, tolerance_pct) VALUES
   ('00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003102', '00000000-0000-4000-8000-000000003181', 'USD', 5),
   ('00000000-0000-4000-8000-000000003192', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003102', '00000000-0000-4000-8000-000000003182', 'USD', NULL),
   ('00000000-0000-4000-8000-000000003193', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003103', '00000000-0000-4000-8000-000000003182', 'USD', NULL),
   ('00000000-0000-4000-8000-000000003194', '00000000-0000-4000-8000-000000003101', NULL, '00000000-0000-4000-8000-000000003182', 'USD', NULL);
INSERT INTO api.purchase_order_line (id, tenant_id, purchase_order_id, product_id, quantity, unit_price) VALUES
   ('00000000-0000-4000-8000-000000003144', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003141', 1000, 2),
   ('00000000-0000-4000-8000-000000003145', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003192', '00000000-0000-4000-8000-000000003142', 10, 1),
   ('00000000-0000-4000-8000-000000003147', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003194', '00000000-0000-4000-8000-000000003143', 5, 1);
RESET ROLE;
SELECT set_config('moesa.rules_bypass', '1', TRUE);
UPDATE public.purchase_order SET status = 'pi_approved'
WHERE id IN ('00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003193', '00000000-0000-4000-8000-000000003194');
SELECT set_config('moesa.rules_bypass', '', TRUE);

-- Shipments for the client to Rosbach (3151–3154, 3156), an own one to the provider's warehouse
-- (3157) and one sent with a forged address (3158).
SELECT private.impersonate('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003101');
INSERT INTO api.shipment (id, tenant_id, client_tenant_id, mode, delivery_warehouse_id)
SELECT x.id, '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003102', 'fcl20', '00000000-0000-4000-8000-000000003161'
FROM (VALUES ('00000000-0000-4000-8000-000000003151'::UUID), ('00000000-0000-4000-8000-000000003152'), ('00000000-0000-4000-8000-000000003153'),
             ('00000000-0000-4000-8000-000000003154'), ('00000000-0000-4000-8000-000000003156')) AS x (id);
INSERT INTO api.shipment (id, tenant_id, mode, delivery_warehouse_id)
VALUES ('00000000-0000-4000-8000-000000003157', '00000000-0000-4000-8000-000000003101', 'road', '00000000-0000-4000-8000-000000003163');
INSERT INTO api.shipment (id, tenant_id, client_tenant_id, mode, delivery_warehouse_id, delivery_address, warehouse_tenant_id)
VALUES ('00000000-0000-4000-8000-000000003158', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003102', 'road',
        '00000000-0000-4000-8000-000000003161', 'FORGED', '00000000-0000-4000-8000-000000003101');

-- Codes and the delivery snapshot.
SELECT is((SELECT code FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003151'),
          'SHP-THO-' || extract(year FROM now())::INT || '-001', 'a client shipment''s code comes from next_code under the client_code');
SELECT is((SELECT code FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003157'),
          'SHP-PRV-' || extract(year FROM now())::INT || '-001', 'an own shipment''s code comes from next_code under the tenant''s code');
SELECT is((SELECT warehouse_tenant_id || '|' || delivery_address FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003151'),
          '00000000-0000-4000-8000-000000003102|Rosbach, Industriestr. 1, 61191, Rosbach, DE',
          'a client shipment to a client warehouse snapshots its delivery address');
SELECT is((SELECT warehouse_tenant_id || '|' || delivery_address FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003157'),
          '00000000-0000-4000-8000-000000003101|Provider WH, Istanbul, TR', 'an own shipment goes to an own warehouse');
SELECT is((SELECT warehouse_tenant_id || '|' || delivery_address FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003158'),
          '00000000-0000-4000-8000-000000003102|Rosbach, Industriestr. 1, 61191, Rosbach, DE',
          'the address and the warehouse tenant sent with a shipment are not stored');

-- The warehouse and the relationship on a new shipment.
SELECT throws_ok($$ INSERT INTO api.shipment (tenant_id, client_tenant_id, mode, delivery_warehouse_id)
                    VALUES ('00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003102', 'road', '00000000-0000-4000-8000-000000003164') $$,
                 '23514', 'client_link_forbidden', 'not another tenant''s warehouse');
SELECT throws_ok($$ INSERT INTO api.shipment (tenant_id, client_tenant_id, mode, delivery_warehouse_id)
                    VALUES ('00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003103', 'road', '00000000-0000-4000-8000-000000003162') $$,
                 '23514', 'client_link_forbidden', 'not a warehouse of a client the caller was not invited into');
SELECT throws_ok($$ INSERT INTO api.shipment (tenant_id, mode, delivery_warehouse_id)
                    VALUES ('00000000-0000-4000-8000-000000003101', 'road', '00000000-0000-4000-8000-000000003161') $$,
                 '23514', 'client_link_forbidden', 'an own shipment cannot go to a client''s warehouse');
SELECT throws_ok($$ INSERT INTO api.shipment (tenant_id, client_tenant_id, mode, delivery_warehouse_id)
                    VALUES ('00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003104', 'road', '00000000-0000-4000-8000-000000003164') $$,
                 '23514', 'relationship_inactive', 'no shipment for a tenant without a relationship');
SELECT throws_ok($$ INSERT INTO api.shipment (tenant_id, client_tenant_id, mode, delivery_warehouse_id)
                    VALUES ('00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003105', 'road', '00000000-0000-4000-8000-000000003161') $$,
                 '23514', 'relationship_inactive', 'no shipment for a client that procures itself');
SELECT throws_ok($$ INSERT INTO api.shipment (tenant_id, client_tenant_id, mode)
                    VALUES ('00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003102', 'road') $$,
                 '23514', 'shipment_warehouse_required', 'a shipment goes to a warehouse');
RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000003112', '00000000-0000-4000-8000-000000003101');
SELECT throws_ok($$ INSERT INTO api.shipment (tenant_id, client_tenant_id, mode, delivery_warehouse_id)
                    VALUES ('00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003102', 'road', '00000000-0000-4000-8000-000000003161') $$,
                 '23514', 'client_link_forbidden', 'staff not invited into the client cannot name its warehouse');
SELECT throws_ok($$ INSERT INTO api.shipment (tenant_id, mode, delivery_warehouse_id)
                    VALUES ('00000000-0000-4000-8000-000000003101', 'road', '00000000-0000-4000-8000-000000003163') $$,
                 '23514', 'client_link_forbidden', 'a user who may not read the tenant''s warehouses cannot name one');
RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003101');

-- The orders on a shipment, and its lines.
SELECT throws_ok($$ INSERT INTO api.shipment_purchase_order (shipment_id, purchase_order_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000003151', '00000000-0000-4000-8000-000000003192', '00000000-0000-4000-8000-000000003101') $$,
                 '23514', 'shipment_po_not_open', 'a draft order is not shipped');
SELECT throws_ok($$ INSERT INTO api.shipment_purchase_order (shipment_id, purchase_order_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000003151', '00000000-0000-4000-8000-000000003193', '00000000-0000-4000-8000-000000003101') $$,
                 '23514', 'client_mismatch', 'not another client''s order');
SELECT throws_ok($$ INSERT INTO api.shipment_purchase_order (shipment_id, purchase_order_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000003151', '00000000-0000-4000-8000-000000003194', '00000000-0000-4000-8000-000000003101') $$,
                 '23514', 'client_mismatch', 'not an own order on a client shipment');
SELECT throws_ok($$ INSERT INTO api.shipment_purchase_order (shipment_id, purchase_order_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000003157', '00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003101') $$,
                 '23514', 'client_mismatch', 'not a client order on an own shipment');
SELECT lives_ok($$ INSERT INTO api.shipment_purchase_order (shipment_id, purchase_order_id, tenant_id, client_tenant_id) VALUES ('00000000-0000-4000-8000-000000003151', '00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003103') $$,
                'an approved order of the shipment''s client is linked');
SELECT is((SELECT client_tenant_id FROM public.shipment_purchase_order WHERE shipment_id = '00000000-0000-4000-8000-000000003151'),
          '00000000-0000-4000-8000-000000003102'::UUID, 'the link takes the shipment''s client whatever is sent');
SELECT throws_ok($$ INSERT INTO api.shipment_line (id, tenant_id, shipment_id, purchase_order_id, purchase_order_line_id, quantity) VALUES ('00000000-0000-4000-8000-000000003170', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003151', '00000000-0000-4000-8000-000000003192', '00000000-0000-4000-8000-000000003145', 1) $$,
                 '23503', NULL, 'a line needs its order on the shipment');
SELECT lives_ok($$ INSERT INTO api.shipment_line (id, tenant_id, shipment_id, purchase_order_id, purchase_order_line_id, quantity, client_tenant_id) VALUES ('00000000-0000-4000-8000-000000003171', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003151', '00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003144', 1000, NULL) $$, 'the ordered quantity');
SELECT is((SELECT client_tenant_id FROM public.shipment_line WHERE id = '00000000-0000-4000-8000-000000003171'),
          '00000000-0000-4000-8000-000000003102'::UUID, 'a line takes the shipment''s client whatever is sent');

INSERT INTO api.shipment_purchase_order (shipment_id, purchase_order_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000003152', '00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003101');
INSERT INTO api.shipment_purchase_order (shipment_id, purchase_order_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000003153', '00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003101');

-- Quantities, the status flow, acceptance and the overview.
SELECT lives_ok($$ INSERT INTO api.shipment_line (id, tenant_id, shipment_id, purchase_order_id, purchase_order_line_id, quantity) VALUES ('00000000-0000-4000-8000-000000003172', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003152', '00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003144', 50) $$, 'within the 5 % tolerance');
SELECT throws_ok($$ INSERT INTO api.shipment_line (id, tenant_id, shipment_id, purchase_order_id, purchase_order_line_id, quantity) VALUES ('00000000-0000-4000-8000-000000003173', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003153', '00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003144', 1) $$, '23514', 'shipment_quantity_exceeds_po', 'not beyond the tolerance');

UPDATE api.shipment SET status = 'cancelled' WHERE id = '00000000-0000-4000-8000-000000003152';

SELECT lives_ok($$ INSERT INTO api.shipment_line (id, tenant_id, shipment_id, purchase_order_id, purchase_order_line_id, quantity) VALUES ('00000000-0000-4000-8000-000000003173', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003153', '00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003144', 50) $$, 'a cancelled shipment frees its quantity');
SELECT throws_ok($$ UPDATE api.shipment SET status = 'loaded' WHERE id = '00000000-0000-4000-8000-000000003151' $$,
                 '23514', 'shipment_status_order', 'no skipping statuses');
SELECT throws_ok($$ UPDATE api.shipment SET status = 'booked' WHERE id = '00000000-0000-4000-8000-000000003151' $$,
                 '23514', 'shipment_booking_date_required', 'booking needs its confirmation date');
SELECT throws_ok($$ UPDATE api.shipment SET status = 'booked', booking_confirmed_on = current_date WHERE id = '00000000-0000-4000-8000-000000003154' $$,
                 '23514', 'shipment_po_required', 'booking needs an order');

INSERT INTO api.shipment_purchase_order (shipment_id, purchase_order_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000003156', '00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003101');
UPDATE api.shipment SET status = 'booked', booking_confirmed_on = current_date WHERE id = '00000000-0000-4000-8000-000000003156';

SELECT throws_ok($$ UPDATE api.shipment SET status = 'loaded' WHERE id = '00000000-0000-4000-8000-000000003156' $$,
                 '23514', 'shipment_lines_required', 'nothing is loaded without a line');

UPDATE api.shipment SET status = 'booked', booking_confirmed_on = current_date WHERE id = '00000000-0000-4000-8000-000000003151';
UPDATE api.shipment SET status = 'loaded' WHERE id = '00000000-0000-4000-8000-000000003151';

SELECT throws_ok($$ UPDATE api.shipment_line SET quantity = 900 WHERE id = '00000000-0000-4000-8000-000000003171' $$,
                 '23514', 'shipment_locked', 'loaded goods do not change');
SELECT throws_ok($$ UPDATE api.shipment SET status = 'in_transit' WHERE id = '00000000-0000-4000-8000-000000003151' $$,
                 '23514', 'shipment_eta_required', 'in transit needs ETD and ETA');

UPDATE api.shipment SET status = 'in_transit', etd = current_date, eta = current_date + 20 WHERE id = '00000000-0000-4000-8000-000000003151';

SELECT throws_ok($$ UPDATE api.shipment SET status = 'delivered' WHERE id = '00000000-0000-4000-8000-000000003151' $$,
                 '23514', 'shipment_delivery_time_required', 'delivered needs the time');

UPDATE api.shipment SET status = 'delivered', delivered_at = '2027-01-10 10:00+00' WHERE id = '00000000-0000-4000-8000-000000003151';

SELECT is((SELECT dispute_deadline_at FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003151'), '2027-01-12 10:00+00'::TIMESTAMPTZ,
          'the supplier''s 48 hours to report damage');
SELECT throws_ok($$ UPDATE api.shipment SET status = 'accepted' WHERE id = '00000000-0000-4000-8000-000000003151' $$,
                 '23514', 'shipment_delivery_receipt_required', 'acceptance needs the delivery receipt (G5)');

INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, status, url)
VALUES ('00000000-0000-4000-8000-000000003176', '00000000-0000-4000-8000-000000003101', 'shipment', '00000000-0000-4000-8000-000000003151', 'delivery_receipt', 'approved', 'https://example.test/receipt.pdf');
UPDATE api.shipment SET quantity_matches = TRUE, has_damage = TRUE WHERE id = '00000000-0000-4000-8000-000000003151';

SELECT throws_ok($$ UPDATE api.shipment SET status = 'accepted' WHERE id = '00000000-0000-4000-8000-000000003151' $$,
                 '23514', 'shipment_acceptance_issue', 'damage means disputed, not accepted');

UPDATE api.shipment SET status = 'disputed' WHERE id = '00000000-0000-4000-8000-000000003151';

SELECT lives_ok($$ UPDATE api.shipment SET status = 'accepted' WHERE id = '00000000-0000-4000-8000-000000003151' $$,
                'a settled dispute is accepted with the damage it records');
SELECT is((SELECT has_damage FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003151'), TRUE,
          'the damage stays on record');
SELECT is((SELECT accepted_on FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003151'), current_date,
          'acceptance is dated today by default');
SELECT throws_ok($$ UPDATE api.shipment SET status = 'disputed' WHERE id = '00000000-0000-4000-8000-000000003151' $$,
                 '23514', 'shipment_status_order', 'accepted is final');
SELECT is((SELECT purchase_order_codes FROM api.shipment_overview WHERE id = '00000000-0000-4000-8000-000000003151'),
          ARRAY[(SELECT code FROM public.purchase_order WHERE id = '00000000-0000-4000-8000-000000003191')],
          'the overview names the shipment''s orders');
SELECT is((SELECT product_ids FROM api.shipment_overview WHERE id = '00000000-0000-4000-8000-000000003151'),
          ARRAY['00000000-0000-4000-8000-000000003141'::UUID], 'the overview lists the products of its lines');
SELECT is((SELECT psi_missing_po_codes FROM api.shipment_overview WHERE id = '00000000-0000-4000-8000-000000003151'),
          ARRAY[(SELECT code FROM public.purchase_order WHERE id = '00000000-0000-4000-8000-000000003191')],
          'an order without an approved PSI is a warning');

INSERT INTO api.document (tenant_id, entity_type, entity_id, type, status, url)
VALUES ('00000000-0000-4000-8000-000000003101', 'purchase_order', '00000000-0000-4000-8000-000000003191', 'psi_report', 'approved', 'https://example.test/psi.pdf');

SELECT is((SELECT psi_missing_po_codes FROM api.shipment_overview WHERE id = '00000000-0000-4000-8000-000000003151'),
          '{}'::TEXT[], 'an approved PSI clears the warning');
SELECT is((SELECT string_agg(coalesce(client_code, '-'), ',' ORDER BY code) FROM api.shipment_overview
           WHERE id IN ('00000000-0000-4000-8000-000000003151', '00000000-0000-4000-8000-000000003157')),
          '-,THO', 'the overview names the client by its client_code, none for an own shipment');

-- The other guards, the fixed code and client.
SELECT throws_ok($$ INSERT INTO api.shipment_purchase_order (shipment_id, purchase_order_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000003151', '00000000-0000-4000-8000-000000003192', '00000000-0000-4000-8000-000000003101') $$,
                 '23514', 'shipment_locked', 'a loaded shipment takes no order');
SELECT throws_ok($$ DELETE FROM api.shipment_purchase_order WHERE shipment_id = '00000000-0000-4000-8000-000000003153' $$,
                 '23514', 'shipment_po_has_lines', 'an order with lines on the shipment stays linked');
SELECT throws_ok($$ UPDATE api.shipment SET client_tenant_id = '00000000-0000-4000-8000-000000003103' WHERE id = '00000000-0000-4000-8000-000000003154' $$,
                 '23514', 'client_tenant_immutable', 'the client is fixed');
SELECT throws_ok($$ UPDATE api.shipment SET client_tenant_id = NULL WHERE id = '00000000-0000-4000-8000-000000003154' $$,
                 '23514', 'client_tenant_immutable', 'a client shipment does not become an own one');
SELECT throws_ok($$ UPDATE api.shipment SET code = 'SHP-X' WHERE id = '00000000-0000-4000-8000-000000003154' $$,
                 '23514', 'shipment_immutable_field', 'the code is fixed');

INSERT INTO api.shipment (id, tenant_id, client_tenant_id, mode, delivery_warehouse_id, status)
VALUES ('00000000-0000-4000-8000-000000003155', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003102', 'road', '00000000-0000-4000-8000-000000003161', 'accepted');

SELECT is((SELECT status FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003155'), 'planned'::public.shipment_status,
          'a new shipment is planned whatever the client sends');
SELECT throws_ok($$ DELETE FROM api.shipment WHERE id = '00000000-0000-4000-8000-000000003154' $$,
                 '42501', NULL, 'shipments are cancelled, not deleted');
SELECT throws_ok($$ INSERT INTO api.shipment_event (tenant_id, shipment_id, step) VALUES ('00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003153', 21) $$,
                 '23514', NULL, 'an event step is an S15 row');

-- The client of events and lines, a tenant move, the snapshot and the warehouse link.
INSERT INTO api.shipment_event (id, tenant_id, shipment_id, step, note, client_tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003178', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003153', 3, 'booking requested', '00000000-0000-4000-8000-000000003103'),
   ('00000000-0000-4000-8000-000000003179', '00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003157', 3, 'booking requested', '00000000-0000-4000-8000-000000003102');
SELECT is((SELECT array_agg(coalesce(client_tenant_id::TEXT, 'none') ORDER BY id) FROM public.shipment_event
           WHERE id IN ('00000000-0000-4000-8000-000000003178', '00000000-0000-4000-8000-000000003179')),
          ARRAY['00000000-0000-4000-8000-000000003102', 'none'], 'an event takes its shipment''s client whatever is sent');
SELECT throws_ok($$ UPDATE api.shipment_event SET shipment_id = '00000000-0000-4000-8000-000000003157' WHERE id = '00000000-0000-4000-8000-000000003178' $$,
                 '23514', 'client_tenant_immutable', 'an event does not move to a shipment of another client');
SELECT throws_ok($$ UPDATE api.shipment_line SET client_tenant_id = NULL WHERE id = '00000000-0000-4000-8000-000000003173' $$,
                 '23514', 'client_tenant_immutable', 'a line''s client is fixed');

-- A user working in both of its tenants cannot move a shipment naming a client.
SELECT set_config('request.headers', json_build_object(
    'x-tenant-id', '00000000-0000-4000-8000-000000003101',
    'x-tenant-ids', '00000000-0000-4000-8000-000000003101,00000000-0000-4000-8000-000000003106')::TEXT, TRUE);
SELECT throws_ok($$ UPDATE api.shipment SET tenant_id = '00000000-0000-4000-8000-000000003106' WHERE id = '00000000-0000-4000-8000-000000003154' $$,
                 '23514', 'client_tenant_immutable', 'a shipment naming a client cannot move to another tenant');
RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003101');

UPDATE api.shipment SET delivery_address = 'FORGED' WHERE id = '00000000-0000-4000-8000-000000003154';
SELECT is((SELECT delivery_address FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003154'),
          'Rosbach, Industriestr. 1, 61191, Rosbach, DE', 'the address is not forged while the warehouse is kept');
SELECT throws_ok($$ UPDATE api.shipment SET delivery_warehouse_id = NULL WHERE id = '00000000-0000-4000-8000-000000003154' $$,
                 '23514', 'shipment_warehouse_required', 'a shipment''s warehouse is not emptied while it exists');
UPDATE api.shipment SET delivery_warehouse_id = '00000000-0000-4000-8000-000000003165' WHERE id = '00000000-0000-4000-8000-000000003154';
SELECT is((SELECT delivery_address FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003154'),
          'Hamburg, Hamburg, DE', 'another warehouse of the client brings its address');
SELECT throws_ok($$ UPDATE api.shipment SET delivery_warehouse_id = '00000000-0000-4000-8000-000000003163' WHERE id = '00000000-0000-4000-8000-000000003154' $$,
                 '23514', 'client_link_forbidden', 'a client shipment does not go to the provider''s warehouse');

-- The line guard reads its shipment FOR SHARE, so a concurrent move to loaded waits for the
-- write (the foreign key alone takes FOR KEY SHARE). pgrowlocks names a share lock 'For Share', or
-- 'Share' inside a multixact.
UPDATE api.shipment_line SET carton_count = 5 WHERE id = '00000000-0000-4000-8000-000000003173';
RESET ROLE;
CREATE EXTENSION IF NOT EXISTS pgrowlocks WITH SCHEMA extensions;
SELECT ok((SELECT r.modes && ARRAY['For Share', 'Share'] FROM extensions.pgrowlocks('public.shipment') r JOIN public.shipment s ON s.ctid = r.locked_row
           WHERE s.id = '00000000-0000-4000-8000-000000003153'), 'a line write share-locks its shipment');
SELECT private.impersonate('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003101');

SELECT set_config('moesa.rules_bypass', '1', TRUE);
SELECT throws_ok($$ UPDATE api.shipment SET status = 'loaded' WHERE id = '00000000-0000-4000-8000-000000003154' $$,
                 '23514', 'shipment_status_order', 'an impersonated user cannot use the bypass flag');
SELECT set_config('moesa.rules_bypass', '', TRUE);

-- The relationship ends. Nothing new is linked; the client's warehouse delete is not blocked.
RESET ROLE;
UPDATE public.provider_relationship SET status = 'ended' WHERE id = '00000000-0000-4000-8000-000000003121';
SELECT private.impersonate('00000000-0000-4000-8000-000000003111', '00000000-0000-4000-8000-000000003101');

SELECT throws_ok($$ INSERT INTO api.shipment (tenant_id, client_tenant_id, mode, delivery_warehouse_id)
                    VALUES ('00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003102', 'road', '00000000-0000-4000-8000-000000003161') $$,
                 '23514', 'relationship_inactive', 'no new shipment after the end');
SELECT throws_ok($$ INSERT INTO api.shipment_purchase_order (shipment_id, purchase_order_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000003154', '00000000-0000-4000-8000-000000003191', '00000000-0000-4000-8000-000000003101') $$,
                 '23514', 'relationship_inactive', 'no new order on a client shipment after the end');
SELECT throws_ok($$ INSERT INTO api.shipment_event (tenant_id, shipment_id, step) VALUES ('00000000-0000-4000-8000-000000003101', '00000000-0000-4000-8000-000000003154', 4) $$,
                 '23514', 'relationship_inactive', 'no new event on a client shipment after the end');
SELECT throws_ok($$ UPDATE api.shipment SET delivery_warehouse_id = '00000000-0000-4000-8000-000000003161' WHERE id = '00000000-0000-4000-8000-000000003154' $$,
                 '23514', 'relationship_inactive', 'no relinking of the warehouse after the end');
SELECT lives_ok($$ UPDATE api.shipment SET notes = 'relationship ended' WHERE id = '00000000-0000-4000-8000-000000003154' $$,
                'other fields of a client shipment still change after the end');
RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000003113', '00000000-0000-4000-8000-000000003102');
SELECT lives_ok($$ DELETE FROM api.warehouse WHERE id = '00000000-0000-4000-8000-000000003161' $$,
                'the client deletes its warehouse although shipments went there');
RESET ROLE;
SELECT is((SELECT count(*)::INT FROM public.shipment
           WHERE id IN ('00000000-0000-4000-8000-000000003151', '00000000-0000-4000-8000-000000003158')
             AND delivery_warehouse_id IS NULL AND delivery_address = 'Rosbach, Industriestr. 1, 61191, Rosbach, DE'),
          2, 'the shipments keep the delivery address of the deleted warehouse');

-- The shape, and the cascade of a shipment removed with its tenant (the guards let it
-- through); as postgres, on one shipment.
SELECT is((SELECT array_agg(conrelid::REGCLASS::TEXT ORDER BY conrelid::REGCLASS::TEXT) FROM pg_constraint
           WHERE contype = 'f' AND confrelid = 'public.provider_relationship'::REGCLASS
             AND conrelid IN ('public.shipment'::REGCLASS, 'public.shipment_purchase_order'::REGCLASS, 'public.shipment_line'::REGCLASS, 'public.shipment_event'::REGCLASS)),
          ARRAY['shipment', 'shipment_event', 'shipment_line', 'shipment_purchase_order'], 'every shipment table names its client under a relationship');
SELECT has_index('public', 'shipment', 'shipment_client_idx', 'a client''s shipments are listed by index');
SELECT lives_ok($$ DELETE FROM public.shipment WHERE id = '00000000-0000-4000-8000-000000003153' $$, 'a removed shipment cascades');
SELECT is((SELECT (SELECT count(*) FROM public.shipment_line WHERE shipment_id = '00000000-0000-4000-8000-000000003153')
                + (SELECT count(*) FROM public.shipment_purchase_order WHERE shipment_id = '00000000-0000-4000-8000-000000003153')
                + (SELECT count(*) FROM public.shipment_event WHERE shipment_id = '00000000-0000-4000-8000-000000003153'))::INT,
          0, 'its orders, lines and events go with it');

SELECT * FROM finish();

ROLLBACK;
