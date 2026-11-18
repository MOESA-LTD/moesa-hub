CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Market cells (034): a cell lives in the tenant that owns its product, one per product, platform
-- and country, only the platform's countries, the product and project of the cell's own tenant, the
-- S05 status order, what live needs (L-G1) and keeps, the reasons suppressed, stopped and removed
-- need, the compliance note and the red rule, the fixed product, platform and country, deleting only
-- candidates, the product's live cell count, the overview, no customer column, and another tenant
-- that sees none of them. What it writes is rolled back.
BEGIN;

SELECT plan(25);

-- Fixture, built here as postgres (the seed is not on the new model yet):
--   tenant ...3401  Thor Trading (THO), owned by 3411; products mop 3421, tips 3422, cones 3423;
--                   project pilot 3424
--   other  ...3402  Other Company (OTH), owned by 3412; product 3425, project 3426
INSERT INTO public.plan (display_name, is_active) VALUES ('Market test plan', TRUE);

INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000003401', 'Thor Trading', 'THO'),
   ('00000000-0000-4000-8000-000000003402', 'Other Company', 'OTH');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000003411', 'owner@market.test'),
   ('00000000-0000-4000-8000-000000003412', 'other@market.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003411', '00000000-0000-4000-8000-000000003401'),
   ('00000000-0000-4000-8000-000000003412', '00000000-0000-4000-8000-000000003402');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003411', '00000000-0000-4000-8000-000000003401'),
   ('00000000-0000-4000-8000-000000003412', '00000000-0000-4000-8000-000000003402');

SELECT private.impersonate('00000000-0000-4000-8000-000000003412', '00000000-0000-4000-8000-000000003402');
INSERT INTO api.product (id, tenant_id, sku, display_name)
VALUES ('00000000-0000-4000-8000-000000003425', '00000000-0000-4000-8000-000000003402', 'OTH-LAMP', 'Other lamp');
INSERT INTO api.project (id, tenant_id, display_name, type, path, packages)
VALUES ('00000000-0000-4000-8000-000000003426', '00000000-0000-4000-8000-000000003402', 'Other lamp', 'npi', 'a_sourcing', ARRAY['A1']);
RESET ROLE;

SELECT private.impersonate('00000000-0000-4000-8000-000000003411', '00000000-0000-4000-8000-000000003401');
INSERT INTO api.product (id, tenant_id, sku, display_name)
VALUES ('00000000-0000-4000-8000-000000003421', '00000000-0000-4000-8000-000000003401', 'THO-MOP40-2P', 'Mop 40 cm, 2 pack'),
       ('00000000-0000-4000-8000-000000003422', '00000000-0000-4000-8000-000000003401', 'THO-TIPS-6-50', 'Tips'),
       ('00000000-0000-4000-8000-000000003423', '00000000-0000-4000-8000-000000003401', 'THO-CONES-100', 'Cones');
INSERT INTO api.project (id, tenant_id, display_name, type, path, packages)
VALUES ('00000000-0000-4000-8000-000000003424', '00000000-0000-4000-8000-000000003401', 'Mop pilot', 'npi', 'a_sourcing', ARRAY['A1']);

-- The first cell is sent as planned: a new cell is a candidate.
INSERT INTO api.market_cell (id, tenant_id, product_id, project_id, platform_id, country, status)
VALUES ('00000000-0000-4000-8000-000000034011', '00000000-0000-4000-8000-000000003401', '00000000-0000-4000-8000-000000003421', '00000000-0000-4000-8000-000000003424', 'amazon', 'DE', 'planned');
INSERT INTO api.market_cell (id, tenant_id, product_id, platform_id, country)
VALUES ('00000000-0000-4000-8000-000000034012', '00000000-0000-4000-8000-000000003401', '00000000-0000-4000-8000-000000003422', 'ebay', 'DE');

SELECT hasnt_column('public', 'market_cell', 'customer_id', 'a cell names no customer');
SELECT hasnt_column('public', 'market_cell_overview', 'customer_code', 'the overview names no customer');
SELECT enum_has_labels('public', 'stock_source', ARRAY['own_warehouse', '3pl', 'platform', 'pan_eu'], 'stock is shipped from the own warehouse, a 3PL, the platform or Pan-EU');
SELECT is((SELECT status::TEXT FROM api.market_cell WHERE id = '00000000-0000-4000-8000-000000034011'),
          'candidate', 'a new cell is a candidate, whatever is sent');
SELECT throws_ok($$ INSERT INTO api.market_cell (tenant_id, product_id, platform_id, country) VALUES ('00000000-0000-4000-8000-000000003401', '00000000-0000-4000-8000-000000003421', 'amazon', 'DE') $$,
                 '23505', NULL, 'one cell per product, platform and country');
SELECT throws_ok($$ INSERT INTO api.market_cell (tenant_id, product_id, platform_id, country) VALUES ('00000000-0000-4000-8000-000000003401', '00000000-0000-4000-8000-000000003421', 'amazon', 'TR') $$,
                 '23514', 'market_cell_country_invalid', 'the country is one of the platform''s');
SELECT throws_ok($$ INSERT INTO api.market_cell (tenant_id, product_id, platform_id, country) VALUES ('00000000-0000-4000-8000-000000003401', '00000000-0000-4000-8000-000000003421', 'amazon', 'de') $$,
                 '23514', NULL, 'an ISO 3166-1 alpha-2 code');
SELECT throws_ok($$ INSERT INTO api.market_cell (tenant_id, product_id, platform_id, country) VALUES ('00000000-0000-4000-8000-000000003401', '00000000-0000-4000-8000-000000003425', 'amazon', 'FR') $$,
                 '23503', 'insert or update on table "market_cell" violates foreign key constraint "market_cell_product_fkey"',
                 'not another tenant''s product');
SELECT throws_ok($$ UPDATE api.market_cell SET project_id = '00000000-0000-4000-8000-000000003426' WHERE id = '00000000-0000-4000-8000-000000034012' $$,
                 '23503', 'insert or update on table "market_cell" violates foreign key constraint "market_cell_project_fkey"',
                 'not another tenant''s project');
SELECT throws_ok($$ INSERT INTO api.market_cell (tenant_id, product_id, platform_id, country) VALUES ('00000000-0000-4000-8000-000000003402', '00000000-0000-4000-8000-000000003425', 'amazon', 'FR') $$,
                 '42501', NULL, 'no cell in a tenant the caller is not in');
SELECT throws_ok($$ UPDATE api.market_cell SET status = 'live' WHERE id = '00000000-0000-4000-8000-000000034011' $$,
                 '23514', 'market_cell_status_order', 'statuses move as S05 says');

UPDATE api.market_cell SET status = 'planned' WHERE id = '00000000-0000-4000-8000-000000034011';
UPDATE api.market_cell SET status = 'preparing' WHERE id = '00000000-0000-4000-8000-000000034011';
UPDATE api.market_cell SET status = 'uploaded' WHERE id = '00000000-0000-4000-8000-000000034011';

SELECT throws_ok($$ UPDATE api.market_cell SET status = 'live', platform_product_id = 'B0TEST0001', platform_sku = 'THO-MOP40-2P', price = 12.99, currency = 'EUR', stock_source = 'own_warehouse', content_status = 'translated'
                    WHERE id = '00000000-0000-4000-8000-000000034011' $$,
                 '23514', 'market_cell_live_incomplete', 'live needs approved content (L-G1)');
SELECT throws_ok($$ UPDATE api.market_cell SET status = 'live', platform_product_id = 'B0TEST0001', platform_sku = 'THO-MOP40-2P', stock_source = 'own_warehouse', content_status = 'approved'
                    WHERE id = '00000000-0000-4000-8000-000000034011' $$,
                 '23514', 'market_cell_live_incomplete', 'live needs the price');
UPDATE api.market_cell SET status = 'live', platform_product_id = 'B0TEST0001', platform_sku = 'THO-MOP40-2P', price = 12.99, currency = 'EUR', stock_source = 'own_warehouse', content_status = 'approved'
WHERE id = '00000000-0000-4000-8000-000000034011';

SELECT is((SELECT status || ':' || launched_on || ':' || stock_source FROM api.market_cell WHERE id = '00000000-0000-4000-8000-000000034011'),
          'live:' || current_date || ':own_warehouse', 'going live dates the launch');
SELECT is((SELECT live_cell_count FROM api.product_evidence WHERE product_id = '00000000-0000-4000-8000-000000003421'), 1,
          'the product counts its live cells');
SELECT throws_ok($$ UPDATE api.market_cell SET status = 'suppressed' WHERE id = '00000000-0000-4000-8000-000000034011' $$,
                 '23514', 'market_cell_reason_required', 'a suppressed cell names its open issue');
SELECT throws_ok($$ UPDATE api.market_cell SET platform_product_id = NULL WHERE id = '00000000-0000-4000-8000-000000034011' $$,
                 '23514', 'market_cell_live_incomplete', 'a live cell keeps its listing data');
SELECT throws_ok($$ UPDATE api.market_cell SET platform_sku = '  ' WHERE id = '00000000-0000-4000-8000-000000034011' $$,
                 '23514', 'market_cell_live_incomplete', 'a blanked SKU counts as missing');
SELECT throws_ok($$ UPDATE api.market_cell SET compliance = 'yellow' WHERE id = '00000000-0000-4000-8000-000000034012' $$,
                 '23514', 'market_cell_compliance_note_required', 'yellow needs a compliance note');

UPDATE api.market_cell SET status = 'planned' WHERE id = '00000000-0000-4000-8000-000000034012';

SELECT throws_ok($$ UPDATE api.market_cell SET compliance = 'red', compliance_note = 'No EPR registration' WHERE id = '00000000-0000-4000-8000-000000034012' $$,
                 '23514', 'market_cell_compliance_red', 'a red cell is not planned');
SELECT throws_ok($$ UPDATE api.market_cell SET country = 'FR' WHERE id = '00000000-0000-4000-8000-000000034011' $$,
                 '23514', 'market_cell_immutable_field', 'a cell keeps its product, platform and country');
SELECT throws_ok($$ DELETE FROM api.market_cell WHERE id = '00000000-0000-4000-8000-000000034012' $$,
                 '23514', 'market_cell_delete_candidate_only', 'only a candidate is deleted');

INSERT INTO api.market_cell (id, tenant_id, product_id, platform_id, country)
VALUES ('00000000-0000-4000-8000-000000034013', '00000000-0000-4000-8000-000000003401', '00000000-0000-4000-8000-000000003423', 'amazon', 'FR');

SELECT lives_ok($$ DELETE FROM api.market_cell WHERE id = '00000000-0000-4000-8000-000000034013' $$, 'a candidate is deleted');
SELECT is((SELECT cell_key || ':' || sku || ':' || project_code FROM api.market_cell_overview WHERE id = '00000000-0000-4000-8000-000000034011'),
          'amazon_DE:THO-MOP40-2P:THO-' || extract(year FROM now())::INT || '-001', 'the overview names the cell, its SKU and its project');

RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000003412', '00000000-0000-4000-8000-000000003402');
SELECT is((SELECT count(*)::INT FROM api.market_cell), 0, 'another tenant sees none');

SELECT * FROM finish();

ROLLBACK;
