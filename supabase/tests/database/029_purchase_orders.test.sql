CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Purchase orders (M6): the code from next_code (the tenant's code, or the client_code of the
-- relationship), the terms defaulted from the supplier and the company setting, the Incoterms and PI
-- checklist checks, the fixed code, supplier and client, the lines (computed total, one per product,
-- the order's client inherited, the product snapshot and the selling price from sourcing), the
-- project link, the relationship rules of a provider order for a client tenant, no deleting, and the
-- product's last order in public.product_evidence. What it writes is rolled back.
BEGIN;

SELECT plan(49);

-- Fixture, built here as postgres (the seed is not on the new model yet):
--   provider         ...2901  code PRV; owned by staff
--   client           ...2902  provider procures (relationship 2921, client_code THO)
--   client2          ...2903  provider procures (relationship 2922, client_code ODN)
--   stranger         ...2904  no relationship; product LOK-001 (2944)
--   client_proc      ...2905  client procures (relationship 2923, client_code FRY)
--   provider second  ...2906  also owned by staff; no relationship
--   staff            ...2911  provider owner, invited into the client with role 2931 (read products
--                             and projects)
--   uninvited        ...2912  provider member with role 2932 (every purchase order right), not in
--                             the client
--   client owner     ...2913
--   products         THO-MOP 2941, THO-BKT 2942, THO-CUP 2943 (client); PRV-001 2945 (provider)
--   suppliers        TR1 2981 (EXW, 30 %), TR9 2982 (incoterm 'Ex Works', no deposit)
INSERT INTO public.plan (display_name, is_active) VALUES ('Purchase orders test plan', TRUE);

INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000002901', 'Provider Trading', 'PRV'),
   ('00000000-0000-4000-8000-000000002902', 'Thor Trading', 'THO'),
   ('00000000-0000-4000-8000-000000002903', 'Odin Goods', 'ODN'),
   ('00000000-0000-4000-8000-000000002904', 'Loki Wares', 'LOK'),
   ('00000000-0000-4000-8000-000000002905', 'Freya Home', 'FRY'),
   ('00000000-0000-4000-8000-000000002906', 'Provider Second', 'PRS');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000002911', 'staff@orders.test'),
   ('00000000-0000-4000-8000-000000002912', 'uninvited@orders.test'),
   ('00000000-0000-4000-8000-000000002913', 'client-owner@orders.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002901'),
   ('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002906'),
   ('00000000-0000-4000-8000-000000002913', '00000000-0000-4000-8000-000000002902');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002901'),
   ('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002902'),
   ('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002906'),
   ('00000000-0000-4000-8000-000000002912', '00000000-0000-4000-8000-000000002901'),
   ('00000000-0000-4000-8000-000000002913', '00000000-0000-4000-8000-000000002902');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000002931', '00000000-0000-4000-8000-000000002902', 'Provider staff'),
   ('00000000-0000-4000-8000-000000002932', '00000000-0000-4000-8000-000000002901', 'Order clerk');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000002931', p.id
FROM public.permission p
WHERE p.resource_name IN ('public.product', 'public.project') AND p.command = 'select';

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000002932', p.id
FROM public.permission p
WHERE p.group_name = 'purchase_order';

INSERT INTO public.user_role (user_id, role_id) VALUES
   ('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002931'),
   ('00000000-0000-4000-8000-000000002912', '00000000-0000-4000-8000-000000002932');

-- Every field right of the tables each role holds (049, R1), so a refusal below is the rule tested
-- and not a missing field right.
SELECT private.grant_all_fields(r) FROM unnest(ARRAY['00000000-0000-4000-8000-000000002931', '00000000-0000-4000-8000-000000002932']::UUID[]) AS r;

INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, procurement_model) VALUES
   ('00000000-0000-4000-8000-000000002921', '00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002902',
    'THO', 'Thor Trading', 'provider'),
   ('00000000-0000-4000-8000-000000002922', '00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002903',
    'ODN', 'Odin Goods', 'provider'),
   ('00000000-0000-4000-8000-000000002923', '00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002905',
    'FRY', 'Freya Home', 'client');

INSERT INTO public.product (id, tenant_id, sku, display_name) VALUES
   ('00000000-0000-4000-8000-000000002941', '00000000-0000-4000-8000-000000002902', 'THO-MOP', 'Mop 40 cm'),
   ('00000000-0000-4000-8000-000000002942', '00000000-0000-4000-8000-000000002902', 'THO-BKT', 'Bucket 10 l'),
   ('00000000-0000-4000-8000-000000002943', '00000000-0000-4000-8000-000000002902', 'THO-CUP', 'Cup'),
   ('00000000-0000-4000-8000-000000002944', '00000000-0000-4000-8000-000000002904', 'LOK-001', 'Loki item'),
   ('00000000-0000-4000-8000-000000002945', '00000000-0000-4000-8000-000000002901', 'PRV-001', 'Provider lamp');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, default_incoterm, deposit_rate, status) VALUES
   ('00000000-0000-4000-8000-000000002981', '00000000-0000-4000-8000-000000002901', 'TR1', 'Bir', 'Türkiye', 'EXW', 30, 'approved'),
   ('00000000-0000-4000-8000-000000002982', '00000000-0000-4000-8000-000000002901', 'TR9', 'Dokuz', 'Türkiye', 'Ex Works', NULL, 'approved');

-- The provider's selling price of the client's mop (a client link written without a user: bypass).
SELECT set_config('moesa.rules_bypass', '1', TRUE);
INSERT INTO public.sourcing (tenant_id, client_tenant_id, product_id, sell_price_eur)
VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002902', '00000000-0000-4000-8000-000000002941', 9.90);
SELECT set_config('moesa.rules_bypass', '', TRUE);

-- The relation users read and write: the api view once the api views exist (the base tables are
-- closed to users then), the base table before.
CREATE FUNCTION pg_temp.rel (p_name TEXT) RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT coalesce(to_regclass('api.' || p_name), to_regclass('public.' || p_name))::TEXT;
$$;

-- Runs a user-side statement built with pg_temp.rel.
CREATE FUNCTION pg_temp.exec (p_sql TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
END;
$$;

-- Projects: the client's own (2971, made by its owner) and the provider's own (2972).
SELECT private.impersonate('00000000-0000-4000-8000-000000002913', '00000000-0000-4000-8000-000000002902');
SELECT pg_temp.exec(format($$
    INSERT INTO %s (id, tenant_id, display_name, type, path, packages)
    VALUES ('00000000-0000-4000-8000-000000002971', '00000000-0000-4000-8000-000000002902', 'Mop pilot', 'npi', 'a_sourcing', ARRAY['A1'])
$$, pg_temp.rel('project')));
RESET ROLE;

SELECT private.impersonate('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002901');
SELECT pg_temp.exec(format($$
    INSERT INTO %s (id, tenant_id, display_name, type, path, packages)
    VALUES ('00000000-0000-4000-8000-000000002972', '00000000-0000-4000-8000-000000002901', 'Lamp', 'npi', 'a_sourcing', ARRAY['A1'])
$$, pg_temp.rel('project')));

-- An own order (no client), as the provider's owner.
SELECT pg_temp.exec(format($$
    INSERT INTO %s (id, tenant_id, supplier_id, currency, code)
    VALUES ('00000000-0000-4000-8000-000000002951', '00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002981', 'USD', 'X')
$$, pg_temp.rel('purchase_order')));

SELECT is((SELECT code FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000002951'),
          'PO-PRV-' || extract(year FROM now())::INT || '-001', 'the code of an own order comes from next_code under the tenant''s code');
SELECT is((SELECT incoterm || ':' || deposit_rate FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000002951'),
          'EXW:30.00', 'incoterm and deposit come from the supplier');

RESET ROLE;
UPDATE public.setting SET value = '25' WHERE tenant_id = '00000000-0000-4000-8000-000000002901' AND key = 'deposit_rate_default';
SELECT private.impersonate('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002901');

SELECT pg_temp.exec(format($$
    INSERT INTO %s (id, tenant_id, supplier_id, currency, incoterm)
    VALUES ('00000000-0000-4000-8000-000000002952', '00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002982', 'USD', 'FOB')
$$, pg_temp.rel('purchase_order')));

SELECT is((SELECT deposit_rate FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000002952'), 25.00::NUMERIC(5,2),
          'without a supplier deposit, the company setting');
SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, supplier_id, currency)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002982', 'USD') $$, pg_temp.rel('purchase_order')),
                 '23502', 'null value in column "incoterm" of relation "purchase_order" violates not-null constraint',
                 'an invalid supplier incoterm is not copied; incoterm stays required');
SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, supplier_id, currency, incoterm)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002981', 'USD', 'XYZ') $$, pg_temp.rel('purchase_order')),
                 '23514', 'new row for relation "purchase_order" violates check constraint "purchase_order_incoterm_valid"',
                 'only Incoterms 2020 codes');
SELECT throws_ok(format($$ UPDATE %s SET code = 'PO-X' WHERE id = '00000000-0000-4000-8000-000000002951' $$, pg_temp.rel('purchase_order')),
                 '23514', 'purchase_order_immutable_field', 'the code is fixed');
SELECT throws_ok(format($$ UPDATE %s SET supplier_id = '00000000-0000-4000-8000-000000002982' WHERE id = '00000000-0000-4000-8000-000000002951' $$, pg_temp.rel('purchase_order')),
                 '23514', 'purchase_order_immutable_field', 'the supplier is fixed');

SELECT pg_temp.exec(format($$
    INSERT INTO %s (id, tenant_id, purchase_order_id, product_id, quantity, unit_price)
    VALUES ('00000000-0000-4000-8000-000000002961', '00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002951',
            '00000000-0000-4000-8000-000000002945', 3, 1.9)
$$, pg_temp.rel('purchase_order_line')));

SELECT is((SELECT line_total::TEXT || ':' || (client_tenant_id IS NULL) || ':' || product_sku FROM api.purchase_order_line WHERE id = '00000000-0000-4000-8000-000000002961'),
          '5.7000:true:PRV-001', 'the line total is computed; a line of an own order names no client and snapshots its product');
SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, purchase_order_id, product_id, quantity, unit_price)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002951', '00000000-0000-4000-8000-000000002944', 1, 1) $$,
                        pg_temp.rel('purchase_order_line')),
                 '23514', 'client_link_forbidden', 'an own order''s line cannot name another tenant''s product');
SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, purchase_order_id, product_id, quantity, unit_price)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002951', '00000000-0000-4000-8000-000000002945', 1, 1) $$,
                        pg_temp.rel('purchase_order_line')),
                 '23505', 'duplicate key value violates unique constraint "unique_purchase_order_line_product"', 'a product once per order');
-- A line names its product: none on insert (whatever snapshot is sent), and it is not emptied while
-- the product exists (else the product could go on the order twice, and the spec rule be skipped).
SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, purchase_order_id, product_sku, product_name, quantity, unit_price)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002951', 'FORGED', 'Forged', 1, 1) $$,
                        pg_temp.rel('purchase_order_line')),
                 '23514', 'po_line_product_required', 'a line needs a product');
SELECT throws_ok(format($$ UPDATE %s SET product_id = NULL WHERE id = '00000000-0000-4000-8000-000000002961' $$, pg_temp.rel('purchase_order_line')),
                 '23514', 'po_line_product_required', 'a line''s product is not emptied while it exists');
SELECT throws_ok(format($$ UPDATE %s SET project_id = '00000000-0000-4000-8000-000000002971' WHERE id = '00000000-0000-4000-8000-000000002951' $$, pg_temp.rel('purchase_order')),
                 '23514', 'client_link_forbidden', 'an own order cannot name another tenant''s project');
SELECT throws_ok(format($$ UPDATE %s SET pi_check = '{"31":"ok"}' WHERE id = '00000000-0000-4000-8000-000000002951' $$, pg_temp.rel('purchase_order')),
                 '23514', 'new row for relation "purchase_order" violates check constraint "purchase_order_pi_check_valid"',
                 'only the 30 S09 items');
SELECT throws_ok(format($$ DELETE FROM %s WHERE id = '00000000-0000-4000-8000-000000002951' $$, pg_temp.rel('purchase_order')),
                 '42501', 'permission denied for ' || CASE WHEN pg_temp.rel('purchase_order') LIKE 'api.%' THEN 'view' ELSE 'table' END || ' purchase_order',
                 'purchase orders are not deleted');

-- The snapshot follows the link: an order without a project has no project code, whatever is sent.
SELECT pg_temp.exec(format($$
    INSERT INTO %s (id, tenant_id, supplier_id, currency, project_code)
    VALUES ('00000000-0000-4000-8000-000000002955', '00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002981', 'USD', 'FORGED')
$$, pg_temp.rel('purchase_order')));
SELECT is((SELECT project_code FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000002955'), NULL,
          'a project code sent without a project is not stored');

-- The project is chosen while the order is a draft.
RESET ROLE;
SELECT set_config('moesa.rules_bypass', '1', TRUE);
UPDATE public.purchase_order SET status = 'pi_approved' WHERE id = '00000000-0000-4000-8000-000000002955';
SELECT set_config('moesa.rules_bypass', '', TRUE);
SELECT private.impersonate('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002901');
SELECT throws_ok(format($$ UPDATE %s SET project_id = '00000000-0000-4000-8000-000000002972' WHERE id = '00000000-0000-4000-8000-000000002955' $$, pg_temp.rel('purchase_order')),
                 '23514', 'po_project_locked', 'an order past draft cannot be pointed at a project');
SELECT is((SELECT last_po_code FROM api.product_evidence WHERE product_id = '00000000-0000-4000-8000-000000002945'),
          (SELECT code FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000002951'), 'the product shows its last order');

-- A provider order for a client tenant.
SELECT lives_ok(format($$ INSERT INTO %s (id, tenant_id, client_tenant_id, supplier_id, currency)
                   VALUES ('00000000-0000-4000-8000-000000002953', '00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002902',
                           '00000000-0000-4000-8000-000000002981', 'USD') $$, pg_temp.rel('purchase_order')),
                'provider order for an active provider-procures client');
SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, client_tenant_id, supplier_id, currency)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002905', '00000000-0000-4000-8000-000000002981', 'USD') $$,
                        pg_temp.rel('purchase_order')),
                 '23514', 'relationship_inactive', 'no provider order for a client-procures client');
SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, client_tenant_id, supplier_id, currency)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002904', '00000000-0000-4000-8000-000000002981', 'USD') $$,
                        pg_temp.rel('purchase_order')),
                 '23514', 'relationship_inactive', 'no order for a tenant without relationship');
SELECT matches((SELECT code FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000002953'), '^PO-THO-', 'code scoped by client_code');
SELECT lives_ok(format($$ INSERT INTO %s (tenant_id, purchase_order_id, product_id, quantity, unit_price)
                   VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002953', '00000000-0000-4000-8000-000000002941', 100, 2.5) $$,
                       pg_temp.rel('purchase_order_line')),
                'line on a client product');
SELECT results_eq($$ SELECT client_tenant_id, product_sku, sell_price_eur FROM api.purchase_order_line WHERE purchase_order_id = '00000000-0000-4000-8000-000000002953' $$,
                  $$ VALUES ('00000000-0000-4000-8000-000000002902'::UUID, 'THO-MOP', 9.90::NUMERIC(12,2)) $$,
                  'line inherits client, snapshots sku, defaults sell price from sourcing');
SELECT throws_ok(format($$ UPDATE %s SET client_tenant_id = '00000000-0000-4000-8000-000000002903' WHERE id = '00000000-0000-4000-8000-000000002953' $$, pg_temp.rel('purchase_order')),
                 '23514', 'client_tenant_immutable', 'client of an order is immutable');

-- The order's project: in the client's tenant for a client order, with its code as the snapshot.
SELECT lives_ok(format($$ INSERT INTO %s (id, tenant_id, client_tenant_id, supplier_id, currency, project_id)
                   VALUES ('00000000-0000-4000-8000-000000002954', '00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002902',
                           '00000000-0000-4000-8000-000000002981', 'USD', '00000000-0000-4000-8000-000000002971') $$, pg_temp.rel('purchase_order')),
                'a client order names the client''s project');
RESET ROLE;
SELECT results_eq($$ SELECT project_tenant_id, project_code FROM public.purchase_order WHERE id = '00000000-0000-4000-8000-000000002954' $$,
                  $$ SELECT tenant_id, code FROM public.project WHERE id = '00000000-0000-4000-8000-000000002971' $$,
                  'the order points into the client''s tenant and snapshots the project code');
SELECT private.impersonate('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002901');
SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, client_tenant_id, supplier_id, currency, project_id)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002902', '00000000-0000-4000-8000-000000002981', 'USD',
                            '00000000-0000-4000-8000-000000002972') $$, pg_temp.rel('purchase_order')),
                 '23514', 'client_link_forbidden', 'a client order cannot name the provider''s own project');
SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, purchase_order_id, product_id, quantity, unit_price)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002953', '00000000-0000-4000-8000-000000002944', 1, 1) $$,
                        pg_temp.rel('purchase_order_line')),
                 '23514', 'client_link_forbidden', 'a client order''s line cannot name a third tenant''s product');

-- The client a line names is the order's, whatever is sent, and never changes.
SELECT lives_ok(format($$ INSERT INTO %s (id, tenant_id, client_tenant_id, purchase_order_id, product_id, quantity, unit_price)
                   VALUES ('00000000-0000-4000-8000-000000002962', '00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002903',
                           '00000000-0000-4000-8000-000000002953', '00000000-0000-4000-8000-000000002942', 5, 1) $$, pg_temp.rel('purchase_order_line')),
                'a line naming another client is accepted');
SELECT is((SELECT client_tenant_id FROM api.purchase_order_line WHERE id = '00000000-0000-4000-8000-000000002962'),
          '00000000-0000-4000-8000-000000002902'::UUID, 'and takes the order''s client instead');
SELECT throws_ok(format($$ UPDATE %s SET client_tenant_id = NULL WHERE id = '00000000-0000-4000-8000-000000002962' $$, pg_temp.rel('purchase_order_line')),
                 '23514', 'client_tenant_immutable', 'a line''s client cannot change');

-- A user working in both of its tenants cannot move an order or a line naming a client.
SELECT set_config('request.headers', json_build_object(
    'x-tenant-id', '00000000-0000-4000-8000-000000002901',
    'x-tenant-ids', '00000000-0000-4000-8000-000000002901,00000000-0000-4000-8000-000000002906')::TEXT, TRUE);
SELECT throws_matching(format($$ UPDATE %s SET tenant_id = '00000000-0000-4000-8000-000000002906' WHERE id = '00000000-0000-4000-8000-000000002953' $$, pg_temp.rel('purchase_order')),
                 '^(client_tenant_immutable|tenant_move_forbidden)$', 'an order naming a client cannot move to another tenant');
SELECT throws_matching(format($$ UPDATE %s SET tenant_id = '00000000-0000-4000-8000-000000002906' WHERE id = '00000000-0000-4000-8000-000000002962' $$, pg_temp.rel('purchase_order_line')),
                 '^(client_tenant_immutable|tenant_move_forbidden)$', 'a line naming a client cannot move to another tenant');
RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002901');

-- The snapshot changes only with the link: an update cannot forge it.
SELECT lives_ok(format($$ UPDATE %s SET product_sku = 'FORGED', product_name = 'Forged' WHERE id = '00000000-0000-4000-8000-000000002962' $$, pg_temp.rel('purchase_order_line')),
                'an update naming the line snapshot runs');
SELECT pg_temp.exec(format($$ UPDATE %s SET project_code = 'FORGED' WHERE id = '00000000-0000-4000-8000-000000002954' $$, pg_temp.rel('purchase_order')));
RESET ROLE;
SELECT results_eq($$ SELECT l.product_sku || ':' || l.product_name || ':' || (po.project_code = pr.code)
                     FROM public.purchase_order_line l, public.purchase_order po, public.project pr
                     WHERE l.id = '00000000-0000-4000-8000-000000002962' AND po.id = '00000000-0000-4000-8000-000000002954'
                       AND pr.id = '00000000-0000-4000-8000-000000002971' $$,
                  $$ VALUES ('THO-BKT:Bucket 10 l:true') $$,
                  'neither the line nor the order snapshot is forged while the link is kept');

-- Unlinking the project of a draft order while the project exists clears its code.
SELECT private.impersonate('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002901');
SELECT pg_temp.exec(format($$ UPDATE %s SET project_id = NULL WHERE id = '00000000-0000-4000-8000-000000002954' $$, pg_temp.rel('purchase_order')));
RESET ROLE;
SELECT is((SELECT project_code FROM public.purchase_order WHERE id = '00000000-0000-4000-8000-000000002954'), NULL,
          'an unlinked project leaves no code behind');

-- Provider staff not invited into the client.
SELECT private.impersonate('00000000-0000-4000-8000-000000002912', '00000000-0000-4000-8000-000000002901');
SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, purchase_order_id, product_id, quantity, unit_price)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002953', '00000000-0000-4000-8000-000000002943', 1, 1) $$,
                        pg_temp.rel('purchase_order_line')),
                 '23514', 'client_link_forbidden', 'uninvited staff cannot put a client product on a line');

-- The code is numbered in the row's tenant, not the active one: staff with the client active writes
-- a provider order for it; the number comes from the provider's counter under the client's code, and
-- the client's tenant gets no counter.
RESET ROLE;
CREATE TEMP TABLE po_counter ON COMMIT DROP AS
SELECT coalesce((SELECT last_no FROM public.code_sequence
                 WHERE tenant_id = '00000000-0000-4000-8000-000000002901' AND kind = 'po' AND scope = 'THO'
                   AND year = extract(year FROM now())::INT), 0) AS last_no;
SELECT private.impersonate('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002902');
SELECT set_config('request.headers', json_build_object(
    'x-tenant-id', '00000000-0000-4000-8000-000000002902',
    'x-tenant-ids', '00000000-0000-4000-8000-000000002901,00000000-0000-4000-8000-000000002902')::TEXT, TRUE);
SELECT lives_ok(format($$ INSERT INTO %s (id, tenant_id, client_tenant_id, supplier_id, currency)
                    VALUES ('00000000-0000-4000-8000-000000002956', '00000000-0000-4000-8000-000000002901',
                            '00000000-0000-4000-8000-000000002902', '00000000-0000-4000-8000-000000002981', 'USD') $$,
                        pg_temp.rel('purchase_order')),
                'a provider order for the client is written with the client active');
RESET ROLE;
SELECT is((SELECT code FROM public.purchase_order WHERE id = '00000000-0000-4000-8000-000000002956'),
          'PO-THO-' || extract(year FROM now())::INT || '-' || lpad(((SELECT last_no FROM po_counter) + 1)::TEXT, 3, '0'),
          'its number comes from the row tenant''s counter, whatever tenant is active');
SELECT is_empty($$ SELECT 1 FROM public.code_sequence WHERE tenant_id = '00000000-0000-4000-8000-000000002902' AND kind = 'po' $$,
                'the active tenant gets no counter for a row of another tenant');
SELECT private.impersonate('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002901');

-- The relationship ends.
RESET ROLE;
UPDATE public.provider_relationship SET status = 'ended' WHERE id = '00000000-0000-4000-8000-000000002921';
SELECT private.impersonate('00000000-0000-4000-8000-000000002911', '00000000-0000-4000-8000-000000002901');

SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, client_tenant_id, supplier_id, currency)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002902', '00000000-0000-4000-8000-000000002981', 'USD') $$,
                        pg_temp.rel('purchase_order')),
                 '23514', 'relationship_inactive', 'no new order after the end');
SELECT throws_ok(format($$ INSERT INTO %s (tenant_id, purchase_order_id, product_id, quantity, unit_price)
                    VALUES ('00000000-0000-4000-8000-000000002901', '00000000-0000-4000-8000-000000002953', '00000000-0000-4000-8000-000000002943', 1, 1) $$,
                        pg_temp.rel('purchase_order_line')),
                 '23514', 'relationship_inactive', 'no new line after the end');
SELECT throws_ok(format($$ UPDATE %s SET product_id = '00000000-0000-4000-8000-000000002943' WHERE id = '00000000-0000-4000-8000-000000002962' $$, pg_temp.rel('purchase_order_line')),
                 '23514', 'relationship_inactive', 'no relink after the end');
SELECT lives_ok(format($$ UPDATE %s SET quantity = 6 WHERE id = '00000000-0000-4000-8000-000000002962' $$, pg_temp.rel('purchase_order_line')),
                'a quantity edit passes after the end');

-- The order's PI is approved, so its lines are locked; the client still deletes its product
-- (product deletes are not a user action: run as postgres).
RESET ROLE;
SELECT set_config('moesa.rules_bypass', '1', TRUE);
UPDATE public.purchase_order SET status = 'pi_approved' WHERE id = '00000000-0000-4000-8000-000000002953';
SELECT set_config('moesa.rules_bypass', '', TRUE);

SELECT lives_ok($$ DELETE FROM public.product WHERE id = '00000000-0000-4000-8000-000000002941' $$, 'client product delete keeps the line snapshot');
SELECT results_eq($$ SELECT product_id IS NULL, product_sku FROM public.purchase_order_line WHERE purchase_order_id = '00000000-0000-4000-8000-000000002953' AND product_sku = 'THO-MOP' $$,
                  $$ VALUES (TRUE, 'THO-MOP') $$, 'the line keeps its snapshot');
-- The relationship is not deleted while orders name it (the sourcing row, which would also refuse
-- it, goes first, so the order's key is the one that refuses).
DELETE FROM public.sourcing WHERE client_tenant_id = '00000000-0000-4000-8000-000000002902';
SELECT throws_ok($$ DELETE FROM public.provider_relationship WHERE client_tenant_id = '00000000-0000-4000-8000-000000002902' $$, '23503',
                 'update or delete on table "provider_relationship" violates foreign key constraint "purchase_order_relationship_fkey" on table "purchase_order"',
                 'a referenced relationship cannot be deleted');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'purchase_order_line_relationship_fkey' AND contype = 'f'),
          'lines name their client under a relationship too');

SELECT * FROM finish();

ROLLBACK;
