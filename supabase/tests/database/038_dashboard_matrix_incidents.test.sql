CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Dashboard boxes for the market matrix, incidents and change requests (038): the live, preparing
-- and suppressed cells of the tenant against its target, the open incidents only with the missing
-- management notice and the late customer notice, the change requests past their decision date,
-- applied requests leaving the box, no customer column, and another tenant that sees none of them.
-- What it writes is rolled back.
BEGIN;

SELECT plan(8);

-- Fixture, built here as postgres (the seed is not on the new model yet):
--   tenant ...3801  Thor Trading (THO), owned by 3811; products 3821, 3822, 3823
--   other  ...3802  Other Company (OTH), owned by 3812
INSERT INTO public.plan (display_name, is_active) VALUES ('Dashboard matrix test plan', TRUE);

INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000003801', 'Thor Trading', 'THO'),
   ('00000000-0000-4000-8000-000000003802', 'Other Company', 'OTH');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000003811', 'owner@dashboard-matrix.test'),
   ('00000000-0000-4000-8000-000000003812', 'other@dashboard-matrix.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003811', '00000000-0000-4000-8000-000000003801'),
   ('00000000-0000-4000-8000-000000003812', '00000000-0000-4000-8000-000000003802');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003811', '00000000-0000-4000-8000-000000003801'),
   ('00000000-0000-4000-8000-000000003812', '00000000-0000-4000-8000-000000003802');

SELECT private.impersonate('00000000-0000-4000-8000-000000003811', '00000000-0000-4000-8000-000000003801');

INSERT INTO api.product (id, tenant_id, sku, display_name)
VALUES ('00000000-0000-4000-8000-000000003821', '00000000-0000-4000-8000-000000003801', 'THO-MOP40-2P', 'Mop'),
       ('00000000-0000-4000-8000-000000003822', '00000000-0000-4000-8000-000000003801', 'THO-TIPS-6-50', 'Tips'),
       ('00000000-0000-4000-8000-000000003823', '00000000-0000-4000-8000-000000003801', 'THO-CONES-100', 'Cones');
INSERT INTO api.market_cell (id, tenant_id, product_id, platform_id, country)
SELECT x.id, '00000000-0000-4000-8000-000000003801', x.product, x.platform, x.country
FROM (VALUES ('00000000-0000-4000-8000-000000038011'::UUID, '00000000-0000-4000-8000-000000003821'::UUID, 'amazon', 'DE'),
             ('00000000-0000-4000-8000-000000038012', '00000000-0000-4000-8000-000000003821', 'amazon', 'FR'),
             ('00000000-0000-4000-8000-000000038013', '00000000-0000-4000-8000-000000003822', 'ebay', 'DE'),
             ('00000000-0000-4000-8000-000000038014', '00000000-0000-4000-8000-000000003823', 'amazon', 'IT')) AS x (id, product, platform, country);
INSERT INTO api.incident (id, tenant_id, family, severity, title, what_happened, opened_at)
VALUES ('00000000-0000-4000-8000-000000038021', '00000000-0000-4000-8000-000000003801', 'ol', 's1', 'Truck refused', 'The warehouse refused the truck.', now() - INTERVAL '5 hours'),
       ('00000000-0000-4000-8000-000000038022', '00000000-0000-4000-8000-000000003801', 'ot', 's3', 'Late sample', 'The supplier sent the sample late.', now()),
       ('00000000-0000-4000-8000-000000038023', '00000000-0000-4000-8000-000000003801', 'om', 's3', 'Old', 'Closed.', now());
INSERT INTO api.change_request (id, tenant_id, title, source, change_kinds, current_value, requested_value, reason, created_at)
VALUES ('00000000-0000-4000-8000-000000038031', '00000000-0000-4000-8000-000000003801', 'Carton print', 'company', ARRAY['packaging']::public.change_kind[],
        'Black print', 'Two-colour print', 'Brand guide v2.', now() - INTERVAL '10 days'),
       ('00000000-0000-4000-8000-000000038032', '00000000-0000-4000-8000-000000003801', 'Price', 'supplier', ARRAY['price']::public.change_kind[],
        '1.90 USD', '1.95 USD', 'Cotton price.', now());
RESET ROLE;
SELECT set_config('moesa.rules_bypass', '1', TRUE);
UPDATE public.market_cell SET status = x.status::public.market_cell_status
FROM (VALUES ('00000000-0000-4000-8000-000000038011'::UUID, 'live'), ('00000000-0000-4000-8000-000000038012', 'preparing'), ('00000000-0000-4000-8000-000000038013', 'suppressed')) AS x (id, status)
WHERE market_cell.id = x.id;
UPDATE public.incident SET status = 'closed' WHERE id = '00000000-0000-4000-8000-000000038023';
UPDATE public.change_request SET status = 'applied' WHERE id = '00000000-0000-4000-8000-000000038032';
-- created_at is set to now() on insert and decision_due_on recomputed from it on every write, so
-- the request made "ten days ago" gets its past decision date with the trigger off.
ALTER TABLE public.change_request DISABLE TRIGGER change_request_due;
UPDATE public.change_request SET decision_due_on = current_date - 3 WHERE id = '00000000-0000-4000-8000-000000038031';
ALTER TABLE public.change_request ENABLE TRIGGER change_request_due;
SELECT set_config('moesa.rules_bypass', '', TRUE);
SELECT private.impersonate('00000000-0000-4000-8000-000000003811', '00000000-0000-4000-8000-000000003801');

SELECT is((SELECT live_count || ':' || preparing_count || ':' || suppressed_count || ':' || target_count FROM api.dashboard_market WHERE tenant_id = '00000000-0000-4000-8000-000000003801'),
          '1:1:1:3', 'live, preparing and suppressed against the target (candidates are not targets)');
SELECT is((SELECT count(*)::INT FROM api.dashboard_incident WHERE incident_id IN ('00000000-0000-4000-8000-000000038021', '00000000-0000-4000-8000-000000038022', '00000000-0000-4000-8000-000000038023')),
          2, 'open incidents only');
SELECT is((SELECT management_notice_missing FROM api.dashboard_incident WHERE incident_id = '00000000-0000-4000-8000-000000038021'), TRUE,
          'an S1 without the management notice is flagged');
SELECT is((SELECT customer_notice_late FROM api.dashboard_incident WHERE incident_id = '00000000-0000-4000-8000-000000038021'), TRUE,
          'four hours passed without telling the customer');
SELECT is((SELECT overdue FROM api.dashboard_change_request WHERE change_request_id = '00000000-0000-4000-8000-000000038031'), TRUE,
          'a request past its decision date');
SELECT is((SELECT count(*)::INT FROM api.dashboard_change_request WHERE change_request_id = '00000000-0000-4000-8000-000000038032'), 0,
          'applied requests leave the dashboard');
SELECT ok(NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name IN ('dashboard_market', 'dashboard_incident', 'dashboard_change_request')
                        AND column_name IN ('customer_id', 'customer_code')), 'the dashboards name no customer');

RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000003812', '00000000-0000-4000-8000-000000003802');
SELECT is((SELECT count(*)::INT FROM api.dashboard_market), 0, 'another tenant sees none');

SELECT * FROM finish();
ROLLBACK;
